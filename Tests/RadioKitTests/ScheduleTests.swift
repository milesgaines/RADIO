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

    // The "Rendering a shared timeline" LiveStreamService tests from the
    // RadioPlus line were written against a scheduleSource-injected API this
    // branch's LiveStreamService does not have; its shared-clock rendering is
    // covered by StationAndPersistenceTests.
}
