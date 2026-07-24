import Foundation

/// The direction of a listener's influence on a track.
public enum VoteDirection: Int, Codable, Sendable {
    case boost = 1
    case bury = -1
}

/// A single vote cast by one listener on one track in one station.
///
/// Votes never *select* the literal next track. They adjust the rotation
/// *weight* of a track/artist — a deliberately probabilistic model (à la
/// LAUNCHcast). Even though the direct OneSync license would permit literal
/// selection, weighting is what keeps the stream listenable lean-back, blunts
/// the "passionate few" domination that hurt Jelli, and denies bot farms a
/// deterministic lever.
public struct Vote: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let listenerID: UUID
    public let trackID: UUID
    public let stationID: UUID
    public let direction: VoteDirection
    public let castAt: Date

    public init(
        id: UUID = UUID(),
        listenerID: UUID,
        trackID: UUID,
        stationID: UUID,
        direction: VoteDirection,
        castAt: Date
    ) {
        self.id = id
        self.listenerID = listenerID
        self.trackID = trackID
        self.stationID = stationID
        self.direction = direction
        self.castAt = castAt
    }
}

/// What we know about a listener for the purposes of weighting their vote.
/// Trust is earned through account age and real listening time, not bought.
public struct Listener: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let isVerified: Bool
    /// Cumulative seconds this listener has actually spent listening.
    public var lifetimeListeningSeconds: Double

    public init(
        id: UUID = UUID(),
        createdAt: Date,
        isVerified: Bool = false,
        lifetimeListeningSeconds: Double = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.isVerified = isVerified
        self.lifetimeListeningSeconds = lifetimeListeningSeconds
    }
}
