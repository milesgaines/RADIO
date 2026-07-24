import Foundation

/// Turns a raw vote into an *effective* weight, engineered against the two
/// documented failure modes of every crowd-voted music app to date:
///
///  1. **Bots / vote-gaming** (Turntable.fm's "AutoAwesomer" auto-upvoted every
///     song and defeated the idle timer). Countered by requiring earned trust:
///     brand-new, unverified, zero-listening accounts carry almost no weight.
///
///  2. **The "passionate few"** dominating the tally (Jelli's documented flaw).
///     Countered by a per-listener *decaying vote power*: your first vote in a
///     window counts fully, each subsequent vote counts less, so a hardcore
///     user cannot outshout a room.
public struct AntiGaming: Sendable {

    public struct Config: Sendable {
        /// Account age (seconds) at which the age factor saturates to 1.0.
        public var ageSaturationSeconds: Double
        /// Listening time (seconds) at which the tenure factor saturates to 1.0.
        public var listeningSaturationSeconds: Double
        /// Weight multiplier granted purely for being a verified human.
        public var verifiedBonus: Double
        /// Floor so a brand-new account still counts a little (avoids zero).
        public var minimumWeight: Double
        /// Per-listener decay: the n-th vote in the active window is multiplied
        /// by `perVoteDecay^(n-1)`. 1.0 disables decay; 0.5 halves each time.
        public var perVoteDecay: Double

        public init(
            ageSaturationSeconds: Double = 60 * 60 * 24 * 14, // two weeks
            listeningSaturationSeconds: Double = 60 * 60 * 20, // twenty hours
            verifiedBonus: Double = 0.5,
            minimumWeight: Double = 0.05,
            perVoteDecay: Double = 0.6
        ) {
            self.ageSaturationSeconds = ageSaturationSeconds
            self.listeningSaturationSeconds = listeningSaturationSeconds
            self.verifiedBonus = verifiedBonus
            self.minimumWeight = minimumWeight
            self.perVoteDecay = perVoteDecay
        }
    }

    public let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Effective weight of a listener's vote, before per-window decay.
    /// Range: `[minimumWeight, 1 + verifiedBonus]`.
    public func trustWeight(for listener: Listener, at now: Date) -> Double {
        let age = max(0, now.timeIntervalSince(listener.createdAt))
        let ageFactor = min(1.0, age / config.ageSaturationSeconds)
        let tenureFactor = min(1.0, listener.lifetimeListeningSeconds / config.listeningSaturationSeconds)

        // Age and tenure each contribute half of the base; a fresh account with
        // no history sits near the floor, a two-week-old regular reaches 1.0.
        let base = 0.5 * ageFactor + 0.5 * tenureFactor
        let verified = listener.isVerified ? config.verifiedBonus : 0.0
        return max(config.minimumWeight, base) + verified
    }

    /// Decay factor for the `priorVotesInWindow`-th prior vote by the same
    /// listener in the current window. Zero prior votes → full power (1.0).
    public func decayFactor(priorVotesInWindow: Int) -> Double {
        guard priorVotesInWindow > 0 else { return 1.0 }
        return pow(config.perVoteDecay, Double(priorVotesInWindow))
    }

    /// Final effective weight for a single vote.
    public func effectiveWeight(
        listener: Listener,
        priorVotesInWindow: Int,
        at now: Date
    ) -> Double {
        trustWeight(for: listener, at: now) * decayFactor(priorVotesInWindow: priorVotesInWindow)
    }
}
