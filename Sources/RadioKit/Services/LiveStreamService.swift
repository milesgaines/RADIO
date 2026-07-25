import Foundation
import Combine

/// Drives one always-on station: renders whatever is on air, accepts votes,
/// and publishes the current `NowPlaying` to every observer — the phone UI
/// *and* the CarPlay scene watch the same object, so the car always mirrors
/// the live stream.
///
/// What plays is decided by a `StationScheduleSource`, not here. With the
/// default `LocalScheduleSource` the rotation engine runs on-device, which is
/// the offline/demo station. Point it at a `RemoteScheduleSource` and the same
/// service renders a server timeline every listener shares — the shared-clock
/// swap, and the reason this class holds no rotation state of its own.
///
/// The schedule is expressed in station time; `NowPlaying.startedAt` is in
/// device time, because that's what `AVPlayer` seeks and Now Playing elapsed
/// times are quoted against. `StationClock` is the conversion, so a listener
/// whose phone clock is a minute fast still joins the track at the right
/// second instead of a minute into it.
@MainActor
public final class LiveStreamService: ObservableObject {

    public let station: Station

    @Published public private(set) var nowPlaying: NowPlaying?
    @Published public private(set) var upNextPreview: [Track] = []
    /// True when the timeline comes from a server rather than this device.
    @Published public private(set) var isSynchronized = false

    private var catalog: [Track]
    private let engine: WeightedRotationEngine
    private let tally: VoteTally
    private let source: any StationScheduleSource

    /// The listener using this device.
    public let currentListener: Listener

    private var votes: [Vote] = []
    private var listeners: [UUID: Listener] = [:]
    private var advanceTask: Task<Void, Never>?

    /// Injectable clock + RNG keep this testable and deterministic.
    private let now: () -> Date
    private let random: () -> Double

    public init(
        station: Station = MockCatalog.flagshipStation,
        catalog: [Track] = MockCatalog.tracks,
        engine: WeightedRotationEngine = WeightedRotationEngine(),
        tally: VoteTally = VoteTally(),
        currentListener: Listener? = nil,
        scheduleSource: (any StationScheduleSource)? = nil,
        now: @escaping () -> Date = { Date() },
        random: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.station = station
        self.catalog = catalog
        self.engine = engine
        self.tally = tally
        self.now = now
        self.random = random
        self.source = scheduleSource
            ?? LocalScheduleSource(engine: engine, catalog: catalog, random: random)
        let me = currentListener ?? Listener(
            createdAt: now().addingTimeInterval(-60 * 60 * 24 * 30),
            isVerified: true,
            lifetimeListeningSeconds: 60 * 60 * 40
        )
        self.currentListener = me
        self.listeners[me.id] = me

        if scheduleSource != nil {
            self.source.updateCatalog(catalog)
        }
        self.source.netVoteWeight = { [weak self] trackID in
            self?.netWeights()[trackID] ?? 0
        }
        self.source.onScheduleChange = { [weak self] in
            self?.refresh()
        }
    }

    // MARK: - Lifecycle

    /// Begin (or resume) the live stream. Idempotent.
    public func start() {
        guard advanceTask == nil else { return }
        source.start()
        refresh()
        advanceTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        advanceTask?.cancel()
        advanceTask = nil
        source.stop()
    }

    /// Station time right now — the clock the schedule is quoted in.
    public var stationTime: Date {
        source.clock.stationTime(forDevice: now())
    }

    /// Tick until the current track ends, then pick up whatever is next.
    ///
    /// Ticking at least once a second rather than sleeping exactly to the end
    /// of the track means a server push, a clock correction, or a device that
    /// woke up late all land within a second, and a wrong duration can never
    /// wedge the station on a track that already ended.
    private func runLoop() async {
        while !Task.isCancelled {
            let interval = tickInterval()
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { break }
            refresh()
        }
    }

    private func tickInterval() -> Double {
        guard let np = nowPlaying else { return 0.25 }
        let remaining = np.track.durationSeconds - np.elapsed(at: now())
        return min(1.0, max(0.25, remaining))
    }

    // MARK: - Catalog

    /// Swap in a new catalog (e.g. after connecting a Navidrome server).
    /// The current track finishes; the next slot draws from the new pool.
    public func updateCatalog(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        catalog = tracks
        source.updateCatalog(tracks)
        recomputePreview()
    }

    // MARK: - Voting

    /// Boost or bury a track from the live audience. Returns the new net tally.
    @discardableResult
    public func vote(_ direction: VoteDirection, on trackID: UUID) -> Int {
        let vote = Vote(
            listenerID: currentListener.id,
            trackID: trackID,
            stationID: station.id,
            direction: direction,
            castAt: now()
        )
        votes.append(vote)
        // Forward to the server for a remote station (no-op for the local
        // source, which tallies in-app). The optimistic bump below gives
        // instant feedback; the server's next slot update carries the truth.
        source.castVote(direction, on: trackID)
        recomputePreview()
        if var np = nowPlaying, np.track.id == trackID {
            np.boostScore += direction.rawValue
            nowPlaying = np
        }
        return Int(netWeights()[trackID] ?? 0)
    }

    /// Convenience for the single CarPlay / Siri "boost current track" action.
    @discardableResult
    public func boostCurrent() -> Int {
        guard let id = nowPlaying?.track.id else { return 0 }
        return vote(.boost, on: id)
    }

    // MARK: - Rendering the schedule

    /// Pull the current slot and publish it in device time. Cheap and
    /// idempotent — it's both the tick handler and the push handler.
    private func refresh() {
        let clock = source.clock
        // Assign only on change: this runs every tick, and a no-op write to a
        // @Published would redraw the whole stage once a second.
        if isSynchronized != clock.isSynchronized {
            isSynchronized = clock.isSynchronized
        }

        guard
            let slot = source.slot(at: clock.stationTime(forDevice: now())),
            let track = source.track(withID: slot.trackID)
        else { return }

        let startedAt = clock.deviceTime(forStation: slot.startedAt)
        let liveListeners = source.liveListenerCount ?? max(1, listeners.count)

        if var np = nowPlaying,
           np.track.id == track.id,
           abs(np.startedAt.timeIntervalSince(startedAt)) < 0.5 {
            // Same slot. Refresh the live numbers, but leave `boostScore`
            // alone: a vote cast on this device already moved it, and
            // recomputing here would snap the tap back under the listener.
            if np.liveListeners != liveListeners {
                np.liveListeners = liveListeners
                nowPlaying = np
            }
            return
        }

        nowPlaying = NowPlaying(
            track: track,
            startedAt: startedAt,
            boostScore: Int((netWeights()[track.id] ?? 0).rounded()),
            liveListeners: liveListeners
        )
        recomputePreview()
    }

    private func netWeights() -> [UUID: Double] {
        tally.netWeights(votes: votes, listeners: listeners, now: now())
    }

    /// A *preview* of likely-next tracks (top weighted, eligible). Shown on the
    /// phone only — never presented as "the exact next song", which would push
    /// us toward an interactive service. It's a teaser, not a schedule.
    private func recomputePreview() {
        // A shared station owns what's next and doesn't tell the client; only
        // the local source, which ranks the full candidate catalog, previews.
        guard source.supportsLocalPreview else {
            if !upNextPreview.isEmpty { upNextPreview = [] }
            return
        }
        let n = now()
        let weights = netWeights()
        let history = source.recentPlays
        let ranked = catalog
            .map { ($0, engine.weight(for: $0, netVoteWeight: weights[$0.id] ?? 0, history: history, now: n)) }
            .filter { $0.1 > 0 && $0.0.id != nowPlaying?.track.id }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map(\.0)
        upNextPreview = Array(ranked)
    }
}
