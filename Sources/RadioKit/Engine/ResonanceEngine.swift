import Foundation

/// Turns one track's research signal into a single **resonance** number —
/// RADI0's "PPM for music". Pure and deterministic (mirrors `VoteTally` /
/// `WeightedRotationEngine`: `Sendable`, no timers, no random, no `Date()`
/// inside), so a fixed input asserts an exact output in tests.
///
/// `resonance ∈ [-1, 1]`, 0 = neutral. It blends four measured things:
///  - **velocity** — boosts vs buries per listener per minute (is the room
///    voting it up or down, right now), audience-normalized so a burst in a
///    small room reads as loud as the same burst in a huge one.
///  - **density** — boosts per listener THIS play (how hard the room is
///    leaning in), a positive-only intensity bonus.
///  - **retention** — is the audience holding or shedding while it plays
///    (the tune-out signal; supplied by the sampler).
///  - **standing** — the trust-weighted net tally, so a long-loved record
///    isn't reset to zero every spin.
public struct ResonanceEngine: Sendable {

    public struct Config: Sendable {
        public var wVelocity: Double
        public var wDensity: Double
        public var wRetention: Double
        public var wStanding: Double
        /// Velocity saturation: net votes / listener / minute that maps to ~0.76.
        public var velocityScale: Double
        /// Standing saturation: net vote weight that maps to ~0.76.
        public var standingScale: Double

        public init(
            wVelocity: Double = 0.40,
            wDensity: Double = 0.20,
            wRetention: Double = 0.20,
            wStanding: Double = 0.20,
            velocityScale: Double = 0.15,
            standingScale: Double = 4.0
        ) {
            self.wVelocity = wVelocity
            self.wDensity = wDensity
            self.wRetention = wRetention
            self.wStanding = wStanding
            self.velocityScale = velocityScale
            self.standingScale = standingScale
        }
    }

    /// The full reading: the composite plus each sub-component (for the readout).
    public struct Reading: Sendable, Equatable {
        public let resonance: Double  // [-1, 1]
        public let velocity: Double   // [-1, 1]
        public let density: Double    // [0, 1]
        public let retention: Double  // [0, 1] (echoed back)
    }

    public let config: Config
    public init(config: Config = Config()) { self.config = config }

    /// Score one track. `retention` is the sampled tune-out proxy in `[0, 1]`
    /// (0.5 = neutral / cold start). `velocityWindow` is the seconds the raw
    /// boost/bury counts were gathered over.
    public func score(
        signal: TrackResearchSignal,
        liveListeners: Int,
        retention: Double,
        velocityWindow: Double
    ) -> Reading {
        let L = Double(max(1, liveListeners))
        let window = max(1, velocityWindow)

        // Velocity: net votes per listener per minute → tanh to [-1, 1].
        let netRecent = Double(signal.recentBoosts - signal.recentBuries)
        let perListenerPerMin = (netRecent / window * 60.0) / L
        let velocity = tanhClamped(perListenerPerMin / config.velocityScale)

        // Density: boosts this play per listener, saturating to [0, 1).
        let d = Double(signal.boostsThisPlay) / L
        let density = d / (1.0 + d)

        // Standing: trust-weighted net tally → tanh to [-1, 1].
        let standing = tanhClamped(signal.netVoteWeight / config.standingScale)

        let ret = clamp(retention, 0, 1)
        // Density is positive-only (no boosts ≠ disliked — buries live in
        // velocity); retention & standing are centered at their neutral points.
        let composite =
            config.wVelocity * velocity
          + config.wDensity  * density
          + config.wRetention * (2.0 * ret - 1.0)
          + config.wStanding  * standing

        return Reading(
            resonance: clamp(composite, -1, 1),
            velocity: velocity,
            density: density,
            retention: ret
        )
    }

    private func tanhClamped(_ x: Double) -> Double { clamp(tanh(x), -1, 1) }
}

@inline(__always)
func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
