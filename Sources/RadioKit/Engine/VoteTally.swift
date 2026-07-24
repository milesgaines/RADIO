import Foundation

/// Aggregates raw votes into per-track net weights, applying anti-gaming
/// trust + per-listener decay. This is the bridge between `Vote`s coming off
/// the wire and the `netVoteWeight` the `WeightedRotationEngine` consumes.
public struct VoteTally: Sendable {
    private let antiGaming: AntiGaming
    /// Votes only count while they're "fresh"; older votes stop shaping
    /// rotation so the station keeps moving with the live audience.
    private let voteWindowSeconds: Double

    public init(antiGaming: AntiGaming = AntiGaming(), voteWindowSeconds: Double = 60 * 30) {
        self.antiGaming = antiGaming
        self.voteWindowSeconds = voteWindowSeconds
    }

    /// Net effective vote weight per track id.
    ///
    /// - Votes older than the window are ignored.
    /// - Each listener's votes within the window decay: 1st full, then less,
    ///   so no single superfan dominates.
    public func netWeights(
        votes: [Vote],
        listeners: [UUID: Listener],
        now: Date
    ) -> [UUID: Double] {
        let windowStart = now.addingTimeInterval(-voteWindowSeconds)
        let fresh = votes
            .filter { $0.castAt >= windowStart }
            .sorted { $0.castAt < $1.castAt } // oldest first, so decay counts up

        var priorCountByListener: [UUID: Int] = [:]
        var netByTrack: [UUID: Double] = [:]

        for vote in fresh {
            guard let listener = listeners[vote.listenerID] else { continue }
            let prior = priorCountByListener[vote.listenerID, default: 0]
            let w = antiGaming.effectiveWeight(
                listener: listener,
                priorVotesInWindow: prior,
                at: now
            )
            priorCountByListener[vote.listenerID] = prior + 1
            netByTrack[vote.trackID, default: 0] += w * Double(vote.direction.rawValue)
        }
        return netByTrack
    }
}
