import Foundation
import Combine

/// Drives one always-on station: advances tracks with the
/// `WeightedRotationEngine`, accepts votes, and publishes the current
/// `NowPlaying` state to every observer — the phone UI *and* the CarPlay scene
/// watch the same object, so the car always mirrors the live stream.
///
/// This mock advances tracks on a timer to simulate a real server-driven
/// stream. In production the "current track + start time" comes from the
/// backend over a websocket; this class becomes a thin client that renders it.
@MainActor
public final class LiveStreamService: ObservableObject {

    public let station: Station

    @Published public private(set) var nowPlaying: NowPlaying?
    @Published public private(set) var upNextPreview: [Track] = []

    private let catalog: [Track]
    private let engine: WeightedRotationEngine
    private let tally: VoteTally

    /// The listener using this device.
    public let currentListener: Listener

    private var votes: [Vote] = []
    private var listeners: [UUID: Listener] = [:]
    private var history: [WeightedRotationEngine.PlayRecord] = []
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
        now: @escaping () -> Date = { Date() },
        random: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.station = station
        self.catalog = catalog
        self.engine = engine
        self.tally = tally
        self.now = now
        self.random = random
        let me = currentListener ?? Listener(
            createdAt: now().addingTimeInterval(-60 * 60 * 24 * 30),
            isVerified: true,
            lifetimeListeningSeconds: 60 * 60 * 40
        )
        self.currentListener = me
        self.listeners[me.id] = me
    }

    // MARK: - Lifecycle

    /// Begin (or resume) the live stream. Idempotent.
    public func start() {
        guard advanceTask == nil else { return }
        if nowPlaying == nil { advance() }
        advanceTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        advanceTask?.cancel()
        advanceTask = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            guard let np = nowPlaying else { advance(); continue }
            let remaining = np.track.durationSeconds - np.elapsed(at: now())
            let sleepFor = max(0.25, remaining)
            try? await Task.sleep(nanoseconds: UInt64(sleepFor * 1_000_000_000))
            if Task.isCancelled { break }
            advance()
        }
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

    // MARK: - Rotation

    private func advance() {
        let n = now()
        let next = engine.selectNext(
            candidates: catalog,
            netVoteWeight: { [weak self] track in self?.netWeights()[track.id] ?? 0 },
            history: history,
            now: n,
            random: random
        )
        guard let track = next else { return }
        history.append(.init(trackID: track.id, artistID: track.artistID, playedAt: n))
        nowPlaying = NowPlaying(
            track: track,
            startedAt: n,
            boostScore: Int(netWeights()[track.id] ?? 0),
            liveListeners: max(1, listeners.count)
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
        let n = now()
        let weights = netWeights()
        let ranked = catalog
            .map { ($0, engine.weight(for: $0, netVoteWeight: weights[$0.id] ?? 0, history: history, now: n)) }
            .filter { $0.1 > 0 && $0.0.id != nowPlaying?.track.id }
            .sorted { $0.1 > $1.1 }
            .prefix(3)
            .map(\.0)
        upNextPreview = Array(ranked)
    }
}
