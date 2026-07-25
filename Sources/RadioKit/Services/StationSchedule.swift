import Foundation

/// One entry on the station's timeline: what is on air, and from when.
///
/// Timestamps are in **station time** (see `StationClock`), never device time.
/// A slot is the whole of what a listener needs to join a stream already in
/// progress — the track and the instant it started, from which elapsed time
/// falls out. Nobody is ever told "here is the next song", which is the line
/// between a radio station and an interactive service.
public struct ScheduleSlot: Hashable, Sendable {
    public let trackID: UUID
    /// When the track started, in station time.
    public let startedAt: Date
    public let durationSeconds: Double

    public init(trackID: UUID, startedAt: Date, durationSeconds: Double) {
        self.trackID = trackID
        self.startedAt = startedAt
        self.durationSeconds = max(0, durationSeconds)
    }

    public var endsAt: Date { startedAt.addingTimeInterval(durationSeconds) }

    /// Whether this slot is the one on air at `stationNow`.
    public func contains(_ stationNow: Date) -> Bool {
        stationNow >= startedAt && stationNow < endsAt
    }

    /// How far into the track a listener joining at `stationNow` arrives.
    public func elapsed(at stationNow: Date) -> Double {
        max(0, min(durationSeconds, stationNow.timeIntervalSince(startedAt)))
    }
}

/// Where the current slot comes from.
///
/// The whole point of this seam is that "the station decides what plays" and
/// "this device renders what's playing" are different jobs. `LiveStreamService`
/// only ever does the second one, so moving the first onto a server is a swap
/// of the object behind this protocol — not a rewrite of the app.
@MainActor
public protocol StationScheduleSource: AnyObject {

    /// Fired when the schedule changes out of band (a server push), so the
    /// service can render the new track without waiting for its next tick.
    var onScheduleChange: (@MainActor () -> Void)? { get set }

    /// How this source's timestamps relate to the device clock.
    var clock: StationClock { get }

    /// Recent plays, so the rotation preview can respect the same
    /// repeat-gap and per-artist rules the scheduler applied.
    var recentPlays: [WeightedRotationEngine.PlayRecord] { get }

    /// Listeners currently tuned in, when the source knows. A local timeline
    /// doesn't, and says so rather than inventing a number.
    var liveListenerCount: Int? { get }

    /// Live vote weight per track id. A local source needs this to schedule;
    /// a server-backed one tallies votes itself and ignores it.
    var netVoteWeight: (@MainActor (UUID) -> Double)? { get set }

    /// The slot on air at `stationNow`, or `nil` if the source doesn't know
    /// yet (a socket that hasn't delivered its first message).
    func slot(at stationNow: Date) -> ScheduleSlot?

    /// Resolve a scheduled id against the catalog this source knows.
    func track(withID id: UUID) -> Track?

    func updateCatalog(_ tracks: [Track])

    func start()
    func stop()
}

/// Generates the timeline on-device with the `WeightedRotationEngine`.
///
/// This is the station when there's no server to sync against — the demo
/// catalog, a listener on a plane, a self-hosted Navidrome library with
/// nothing in front of it. It produces a real timeline (contiguous slots with
/// start times) rather than "advance on a timer", so everything downstream —
/// joining mid-track, seeking, catching up after the screen was off — works
/// identically to the server-backed path. What it *can't* do is agree with
/// another device: two listeners each get their own timeline, starting when
/// they tuned in. Sharing that requires `RemoteScheduleSource`.
@MainActor
public final class LocalScheduleSource: StationScheduleSource {

    /// Generating more than this many slots to catch up would mean replaying
    /// hours of rotation nobody heard; past it we cut a fresh slot at the
    /// current instant instead.
    private static let maxCatchUpSlots = 64
    /// History kept for the complement rules — a few hours of rotation.
    private static let maxHistory = 256

    public var onScheduleChange: (@MainActor () -> Void)?
    public var netVoteWeight: (@MainActor (UUID) -> Double)?

    /// A locally-generated timeline is quoted in device time by definition,
    /// so the identity clock is the correct answer, not a placeholder.
    public private(set) var clock = StationClock()

    public var liveListenerCount: Int? { nil }
    public var recentPlays: [WeightedRotationEngine.PlayRecord] { history }

    private let engine: WeightedRotationEngine
    private let random: () -> Double

    private var catalog: [Track]
    /// Includes the on-air track even after a catalog swap drops it, so the
    /// current song can always finish.
    private var knownTracks: [UUID: Track]
    private var history: [WeightedRotationEngine.PlayRecord] = []
    private var current: ScheduleSlot?

    public init(
        engine: WeightedRotationEngine = WeightedRotationEngine(),
        catalog: [Track] = MockCatalog.tracks,
        random: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.engine = engine
        self.random = random
        self.catalog = catalog
        self.knownTracks = Dictionary(catalog.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func start() {}
    public func stop() {}

    public func track(withID id: UUID) -> Track? { knownTracks[id] }

    public func updateCatalog(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        catalog = tracks
        var known = Dictionary(tracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // The track on air finishes even if it just left the library.
        if let id = current?.trackID, let playing = knownTracks[id] {
            known[id] = playing
        }
        knownTracks = known
        onScheduleChange?()
    }

    public func slot(at stationNow: Date) -> ScheduleSlot? {
        if let current, current.contains(stationNow) { return current }

        // Walk the timeline forward until a slot covers `stationNow`. Slots
        // are butt-joined — each starts exactly where the last ended — so a
        // listener who locked their phone for two songs rejoins where the
        // station actually is, not two songs behind.
        var cursor = current?.endsAt ?? stationNow
        if cursor > stationNow { cursor = stationNow }

        for _ in 0..<Self.maxCatchUpSlots {
            guard let slot = makeSlot(startingAt: cursor) else { return current }
            current = slot
            if slot.endsAt > stationNow { return slot }
            cursor = slot.endsAt
        }

        // Still behind — the device was away far longer than the catch-up
        // budget. Start fresh at the current instant; dead air is the only
        // outcome worse than a jump.
        if let slot = makeSlot(startingAt: stationNow) { current = slot }
        return current
    }

    private func makeSlot(startingAt start: Date) -> ScheduleSlot? {
        let weights = netVoteWeight
        let next = engine.selectNext(
            candidates: catalog,
            netVoteWeight: { track in weights?(track.id) ?? 0 },
            history: history,
            now: start,
            random: random
        )
        guard let track = next else { return nil }

        history.append(.init(trackID: track.id, artistID: track.artistID, playedAt: start))
        if history.count > Self.maxHistory {
            history.removeFirst(history.count - Self.maxHistory)
        }
        knownTracks[track.id] = track

        // A zero-length slot would spin the catch-up loop, so floor it.
        return ScheduleSlot(
            trackID: track.id,
            startedAt: start,
            durationSeconds: max(1, track.durationSeconds)
        )
    }
}
