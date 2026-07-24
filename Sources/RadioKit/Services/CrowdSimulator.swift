import Foundation

/// Simulates the live audience for one station: synthetic listeners tune in
/// and out on a gentle "daypart" wave, and a fraction of them boost or bury
/// the current track each tick. It exists so the MVP demo *feels* like the
/// real product — the listener count breathes, the boost tally moves, and the
/// up-next teaser reshuffles — without a backend.
///
/// In production this class is deleted outright: presence and votes arrive
/// over the websocket and land on the exact same `LiveStreamService` API
/// (`join`/`leave`/`castVote`) the simulator uses. Nothing downstream can
/// tell the difference, which is the point.
///
/// The clock and RNG are injected, and one simulation step is exposed as
/// `tick()`, so tests can drive the crowd deterministically without timers.
@MainActor
public final class CrowdSimulator {

    public struct Config: Sendable {
        /// Average number of synthetic listeners tuned in.
        public var targetSize: Int
        /// How far the crowd swings around the target over one cycle (0–1).
        public var swing: Double
        /// Length of one tune-in/tune-out wave.
        public var cycleSeconds: Double
        /// How often the simulator steps when running on its own timer.
        public var tickSeconds: Double
        /// Chance that a given listener votes on the current track per tick.
        public var voteProbabilityPerTick: Double
        /// Fraction of votes that are boosts (the rest are buries). Crowds
        /// skew positive — people mostly vote *for* things they like.
        public var boostBias: Double
        /// Chance per tick that some listener boosts an up-next teaser track.
        public var teaserBoostProbabilityPerTick: Double
        /// Fraction of arriving listeners that are established regulars
        /// (aged, verified, with listening tenure) vs. brand-new accounts.
        public var regularFraction: Double

        public init(
            targetSize: Int = 38,
            swing: Double = 0.45,
            cycleSeconds: Double = 60 * 18,
            tickSeconds: Double = 3,
            voteProbabilityPerTick: Double = 0.05,
            boostBias: Double = 0.78,
            teaserBoostProbabilityPerTick: Double = 0.35,
            regularFraction: Double = 0.7
        ) {
            self.targetSize = targetSize
            self.swing = swing
            self.cycleSeconds = cycleSeconds
            self.tickSeconds = tickSeconds
            self.voteProbabilityPerTick = voteProbabilityPerTick
            self.boostBias = boostBias
            self.teaserBoostProbabilityPerTick = teaserBoostProbabilityPerTick
            self.regularFraction = regularFraction
        }
    }

    public let config: Config

    private let stream: LiveStreamService
    private let now: () -> Date
    private let random: () -> Double
    private let epoch: Date

    private(set) var members: [Listener] = []
    private var timerTask: Task<Void, Never>?

    public init(
        stream: LiveStreamService,
        config: Config = Config(),
        now: @escaping () -> Date = { Date() },
        random: @escaping () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.stream = stream
        self.config = config
        self.now = now
        self.random = random
        self.epoch = now()
    }

    // MARK: - Lifecycle

    /// Start stepping on the configured tick interval. Idempotent.
    public func start() {
        guard timerTask == nil else { return }
        tick() // seed the crowd immediately so the UI never shows "1 listening"
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.config.tickSeconds ?? 3
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { break }
                self?.tick()
            }
        }
    }

    public func stop() {
        timerTask?.cancel()
        timerTask = nil
    }

    // MARK: - One simulation step

    /// Advance the crowd by one step: drift the audience toward the current
    /// point on the daypart wave, then let members vote.
    public func tick() {
        driftAudience(toward: desiredSize(at: now()))
        castVotes()
    }

    /// Where the daypart wave says the crowd should be right now.
    func desiredSize(at date: Date) -> Int {
        let elapsed = date.timeIntervalSince(epoch)
        let phase = sin((2 * .pi * elapsed) / config.cycleSeconds)
        let size = Double(config.targetSize) * (1 + config.swing * phase)
        return max(1, Int(size.rounded()))
    }

    private func driftAudience(toward desired: Int) {
        // Move a few listeners per tick, never the whole gap at once, so the
        // count breathes instead of teleporting.
        let gap = desired - members.count
        let step = min(4, abs(gap))
        if gap > 0 {
            for _ in 0..<step {
                let member = makeListener()
                members.append(member)
                stream.join(member)
            }
        } else if gap < 0 {
            for _ in 0..<step {
                guard !members.isEmpty else { break }
                let index = Int(random() * Double(members.count)) % members.count
                let leaving = members.remove(at: index)
                stream.leave(leaving.id)
            }
        }
    }

    private func castVotes() {
        guard let np = stream.nowPlaying else { return }
        for member in members {
            if random() < config.voteProbabilityPerTick {
                let direction: VoteDirection = random() < config.boostBias ? .boost : .bury
                stream.castVote(direction, on: np.track.id, by: member.id)
            }
        }
        // Occasionally someone stumps for a teaser track, which visibly
        // reshuffles "likely up next" — the core loop, demonstrated.
        if random() < config.teaserBoostProbabilityPerTick,
           let teaser = stream.upNextPreview.randomElementDeterministic(random: random),
           let member = members.randomElementDeterministic(random: random) {
            stream.castVote(.boost, on: teaser.id, by: member.id)
        }
    }

    /// New arrivals are a mix of trusted regulars and fresh accounts, so the
    /// anti-gaming trust curve is actually exercised in the demo.
    private func makeListener() -> Listener {
        let n = now()
        if random() < config.regularFraction {
            return Listener(
                createdAt: n.addingTimeInterval(-60 * 60 * 24 * (14 + 90 * random())),
                isVerified: random() < 0.8,
                lifetimeListeningSeconds: 60 * 60 * (20 + 200 * random())
            )
        }
        return Listener(
            createdAt: n.addingTimeInterval(-60 * 60 * 24 * random()),
            isVerified: false,
            lifetimeListeningSeconds: 60 * 60 * random()
        )
    }
}

extension Array {
    /// `randomElement()` driven by the injected RNG so simulations replay
    /// identically in tests.
    func randomElementDeterministic(random: () -> Double) -> Element? {
        guard !isEmpty else { return nil }
        return self[Int(random() * Double(count)) % count]
    }
}
