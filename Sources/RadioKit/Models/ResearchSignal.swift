import Foundation

/// One track's raw research inputs at a single instant — the immutable,
/// module-crossing view of what `LiveStreamService` measured. It carries only
/// derived numbers (plus title/artist for display); the private `votes` /
/// `listeners` arrays never leave the service.
public struct TrackResearchSignal: Sendable {
    public let trackID: UUID
    public let title: String
    public let artist: String
    /// Effective, trust-weighted, 30-min-windowed net vote weight (VoteTally).
    /// Trust (account age + listening tenure) is ALREADY folded in here — do
    /// not re-weight by tenure downstream or it double-counts.
    public let netVoteWeight: Double
    /// Raw boosts / buries inside the velocity window (rate signal).
    public let recentBoosts: Int
    public let recentBuries: Int
    /// Raw boosts since this track's `startedAt` (love-intensity this play).
    public let boostsThisPlay: Int
    public let lastVoteAt: Date?

    public init(trackID: UUID, title: String, artist: String,
                netVoteWeight: Double, recentBoosts: Int, recentBuries: Int,
                boostsThisPlay: Int, lastVoteAt: Date?) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.netVoteWeight = netVoteWeight
        self.recentBoosts = recentBoosts
        self.recentBuries = recentBuries
        self.boostsThisPlay = boostsThisPlay
        self.lastVoteAt = lastVoteAt
    }
}

/// A whole-station point read: every track with a live signal, plus the
/// audience + on-air context the retention proxy needs. Sampled at the
/// monitor's tick cadence.
public struct StationResearchSnapshot: Sendable {
    public let capturedAt: Date
    public let liveListeners: Int
    public let nowPlayingTrackID: UUID?
    public let nowPlayingStartedAt: Date?
    public let signals: [UUID: TrackResearchSignal]

    public init(capturedAt: Date, liveListeners: Int, nowPlayingTrackID: UUID?,
                nowPlayingStartedAt: Date?, signals: [UUID: TrackResearchSignal]) {
        self.capturedAt = capturedAt
        self.liveListeners = liveListeners
        self.nowPlayingTrackID = nowPlayingTrackID
        self.nowPlayingStartedAt = nowPlayingStartedAt
        self.signals = signals
    }
}

/// Which way a record is moving on the research board.
public enum ResonanceTrend: String, Sendable, Codable { case up, flat, down }

/// A record's live standing in rotation, with hysteresis so it doesn't flap.
public enum ResonanceStatus: String, Sendable, Codable {
    case breaking     // hot and rising — the crowd is breaking it
    case inRotation   // healthy, holding its slot
    case cooling      // losing the room
    case benched      // dropped out until it recovers
}

/// The monitor's published per-track reading: the aggregate (market-neutral)
/// resonance plus its sub-components, trend, and status. `resonance ∈ [-1, 1]`
/// (0 = neutral); the UI meter renders `(resonance + 1) / 2`.
public struct TrackResonance: Identifiable, Sendable {
    public var id: UUID { trackID }
    public let trackID: UUID
    public let title: String
    public let artist: String
    public let resonance: Double   // [-1, 1], 0 = neutral
    public let velocity: Double    // [-1, 1] — boosts vs buries, audience-normalized
    public let density: Double     // [0, 1]  — boosts/listener this play
    public let retention: Double   // [0, 1]  — holding the room vs shedding
    public let trend: ResonanceTrend
    public let status: ResonanceStatus

    public init(trackID: UUID, title: String, artist: String, resonance: Double,
                velocity: Double, density: Double, retention: Double,
                trend: ResonanceTrend, status: ResonanceStatus) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.resonance = resonance
        self.velocity = velocity
        self.density = density
        self.retention = retention
        self.trend = trend
        self.status = status
    }
}
