import XCTest
@testable import RadioKit

/// The shared-clock invariants: station time survives a skewed device clock,
/// the timeline has no gaps, and a listener joining mid-track lands on the
/// right second rather than at zero.
@MainActor
final class ScheduleTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func artist(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-0000000000\(String(format: "%02d", n))")!
    }

    private func track(_ title: String, artist a: Int, dur: Double = 200) -> Track {
        Track(title: title, artistID: artist(a), artistName: "A\(a)", durationSeconds: dur)
    }

    private func catalog(_ count: Int = 8) -> [Track] {
        (0..<count).map { track("t\($0)", artist: $0) }
    }

    // MARK: - StationClock

    func testUnsyncedClockIsTheIdentityMap() {
        let clock = StationClock()
        XCTAssertFalse(clock.isSynchronized)
        XCTAssertEqual(clock.stationTime(forDevice: now), now)
        XCTAssertEqual(clock.deviceTime(forStation: now), now)
    }

    func testOffsetRecoveredFromASymmetricRoundTrip() {
        // The station's clock reads 90s later than this device's.
        var clock = StationClock()
        let sent = now
        let received = now.addingTimeInterval(0.2)
        let stamped = now.addingTimeInterval(0.1 + 90) // stamped mid-flight

        XCTAssertTrue(clock.ingest(.init(stationTime: stamped, sentAt: sent, receivedAt: received)))
        XCTAssertEqual(clock.offset, 90, accuracy: 0.001)
        XCTAssertTrue(clock.isSynchronized)
        XCTAssertEqual(clock.stationTime(forDevice: now).timeIntervalSince(now), 90, accuracy: 0.001)
        // And back again — the conversion has to round-trip or the playhead drifts.
        let station = clock.stationTime(forDevice: now)
        XCTAssertEqual(clock.deviceTime(forStation: station).timeIntervalSince(now), 0, accuracy: 0.001)
    }

    func testSlowRoundTripDoesNotDisplaceABetterSample() {
        var clock = StationClock()
        clock.ingest(.init(
            stationTime: now.addingTimeInterval(90),
            sentAt: now,
            receivedAt: now.addingTimeInterval(0.05)
        ))
        let good = clock.offset

        // Same server, but this reply queued behind a slow radio wake-up: its
        // symmetry assumption is worth ±2.5s, so it must not win.
        let rejected = clock.ingest(.init(
            stationTime: now.addingTimeInterval(95),
            sentAt: now.addingTimeInterval(10),
            receivedAt: now.addingTimeInterval(15)
        ))
        XCTAssertFalse(rejected)
        XCTAssertEqual(clock.offset, good)
    }

    func testStaleSampleIsReplacedEvenByASlowerOne() {
        var clock = StationClock(config: .init(sampleLifetimeSeconds: 60))
        clock.ingest(.init(
            stationTime: now.addingTimeInterval(90),
            sentAt: now,
            receivedAt: now.addingTimeInterval(0.05)
        ))

        // Ten minutes later the offset has aged out; a mediocre fresh sample
        // beats a pristine stale one.
        let later = now.addingTimeInterval(600)
        let accepted = clock.ingest(.init(
            stationTime: later.addingTimeInterval(1 + 120),
            sentAt: later,
            receivedAt: later.addingTimeInterval(2)
        ))
        XCTAssertTrue(accepted)
        XCTAssertEqual(clock.offset, 120, accuracy: 0.001)
    }

    func testReplyThatPredatesItsRequestIsRejected() {
        // The user changed the device clock mid-flight: the round trip is
        // meaningless, so the sample can't be trusted.
        var clock = StationClock()
        let rejected = clock.ingest(.init(
            stationTime: now,
            sentAt: now.addingTimeInterval(5),
            receivedAt: now
        ))
        XCTAssertFalse(rejected)
        XCTAssertFalse(clock.isSynchronized)
    }

    // MARK: - ScheduleSlot

    func testSlotElapsedIsClampedToTheTrack() {
        let slot = ScheduleSlot(trackID: UUID(), startedAt: now, durationSeconds: 200)
        XCTAssertEqual(slot.endsAt, now.addingTimeInterval(200))
        XCTAssertEqual(slot.elapsed(at: now.addingTimeInterval(40)), 40, accuracy: 1e-9)
        XCTAssertEqual(slot.elapsed(at: now.addingTimeInterval(-10)), 0, accuracy: 1e-9)
        XCTAssertEqual(slot.elapsed(at: now.addingTimeInterval(9_999)), 200, accuracy: 1e-9)
        XCTAssertTrue(slot.contains(now))
        XCTAssertFalse(slot.contains(slot.endsAt), "A slot ends the instant the next one starts")
    }

    // MARK: - LocalScheduleSource

    func testTimelineIsContiguous() {
        let source = LocalScheduleSource(catalog: catalog(), random: { 0.5 })
        guard let first = source.slot(at: now) else { return XCTFail("no slot") }
        XCTAssertEqual(first.startedAt, now)

        var previous = first
        for _ in 0..<5 {
            guard let next = source.slot(at: previous.endsAt) else { return XCTFail("no slot") }
            XCTAssertEqual(
                next.startedAt, previous.endsAt,
                "Slots must butt-join — a gap is dead air and an overlap is a skip"
            )
            previous = next
        }
    }

    func testTuningBackInLandsOnTheCurrentSlotNotTheBacklog() {
        let source = LocalScheduleSource(catalog: catalog(), random: { 0.5 })
        _ = source.slot(at: now)

        // Screen off for an hour. The station kept playing; rejoining must
        // put us where it is now, not eighteen tracks behind.
        let later = now.addingTimeInterval(3_600)
        guard let slot = source.slot(at: later) else { return XCTFail("no slot") }
        XCTAssertTrue(slot.contains(later))
    }

    func testAbsurdlyLongAbsenceCutsAFreshSlotInsteadOfGrindingForward() {
        let source = LocalScheduleSource(catalog: catalog(), random: { 0.5 })
        _ = source.slot(at: now)

        // A month later: far past the catch-up budget, so the station starts
        // a new slot at the current instant rather than simulating a month.
        let later = now.addingTimeInterval(60 * 60 * 24 * 30)
        guard let slot = source.slot(at: later) else { return XCTFail("no slot") }
        XCTAssertTrue(slot.contains(later))
        XCTAssertEqual(slot.startedAt, later)
    }

    func testOnAirTrackStaysResolvableAcrossACatalogSwap() {
        let original = catalog()
        let source = LocalScheduleSource(catalog: original, random: { 0.5 })
        guard let slot = source.slot(at: now) else { return XCTFail("no slot") }

        // Connecting a Navidrome library replaces the pool mid-track; the song
        // playing right now still has to finish.
        source.updateCatalog([track("navidrome", artist: 42)])
        XCTAssertNotNil(source.track(withID: slot.trackID))
    }

    // MARK: - Rendering a shared timeline

    /// A stand-in for the server feed: a fixed slot plus whatever clock offset
    /// the test wants to simulate.
    @MainActor
    private final class FixedScheduleSource: StationScheduleSource {
        var onScheduleChange: (@MainActor () -> Void)?
        var netVoteWeight: (@MainActor (UUID) -> Double)?
        var clock: StationClock
        var liveListenerCount: Int?
        var recentPlays: [WeightedRotationEngine.PlayRecord] = []

        private var currentSlot: ScheduleSlot
        private var tracks: [UUID: Track]

        init(slot: ScheduleSlot, track: Track, clock: StationClock, listeners: Int? = nil) {
            self.currentSlot = slot
            self.tracks = [track.id: track]
            self.clock = clock
            self.liveListenerCount = listeners
        }

        func slot(at stationNow: Date) -> ScheduleSlot? { currentSlot }
        func track(withID id: UUID) -> Track? { tracks[id] }
        func updateCatalog(_ tracks: [Track]) {
            for track in tracks { self.tracks[track.id] = track }
        }
        func start() {}
        func stop() {}
    }

    func testJoinsATrackAlreadyInProgress() {
        let song = track("on air", artist: 1, dur: 200)
        let source = FixedScheduleSource(
            slot: .init(trackID: song.id, startedAt: now.addingTimeInterval(-40), durationSeconds: 200),
            track: song,
            clock: StationClock(),
            listeners: 128
        )
        let service = LiveStreamService(
            catalog: [song],
            scheduleSource: source,
            now: { self.now }
        )
        service.start()
        defer { service.stop() }

        guard let np = service.nowPlaying else { return XCTFail("nothing on air") }
        XCTAssertEqual(np.track.id, song.id)
        XCTAssertEqual(np.elapsed(at: now), 40, accuracy: 0.001, "Everyone hears the same second")
        XCTAssertEqual(np.liveListeners, 128, "The server's listener count wins over the local guess")
    }

    func testSkewedDeviceClockDoesNotShiftThePlayhead() {
        // This phone's clock runs 90s ahead of the station's, so station time
        // is device time minus 90.
        var clock = StationClock()
        let deviceNow = now.addingTimeInterval(90)
        clock.ingest(.init(
            stationTime: now,
            sentAt: deviceNow.addingTimeInterval(-0.1),
            receivedAt: deviceNow
        ))
        XCTAssertEqual(clock.offset, -90, accuracy: 0.1)

        let song = track("on air", artist: 1, dur: 200)
        // 40 seconds into the track, in *station* time.
        let source = FixedScheduleSource(
            slot: .init(trackID: song.id, startedAt: now.addingTimeInterval(-40), durationSeconds: 200),
            track: song,
            clock: clock
        )
        let service = LiveStreamService(
            catalog: [song],
            scheduleSource: source,
            now: { deviceNow }
        )
        service.start()
        defer { service.stop() }

        guard let np = service.nowPlaying else { return XCTFail("nothing on air") }
        XCTAssertTrue(service.isSynchronized)
        // The player quotes elapsed time against the device clock, so the
        // conversion has to absorb the whole 90s of skew.
        XCTAssertEqual(np.elapsed(at: deviceNow), 40, accuracy: 0.2)
    }

    func testAPushRendersWithoutWaitingForTheNextTick() {
        let song = track("on air", artist: 1, dur: 200)
        let source = FixedScheduleSource(
            slot: .init(trackID: song.id, startedAt: now, durationSeconds: 200),
            track: song,
            clock: StationClock()
        )
        let service = LiveStreamService(catalog: [song], scheduleSource: source, now: { self.now })
        XCTAssertNil(service.nowPlaying)

        // The service wires itself to the source's change hook in init, so a
        // server push renders immediately rather than up to a second later.
        source.onScheduleChange?()
        XCTAssertEqual(service.nowPlaying?.track.id, song.id)
    }
}
