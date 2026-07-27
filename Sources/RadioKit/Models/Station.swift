import Foundation

/// A single always-on live stream. Everyone tuned to a station hears the same
/// second of the same track — the "one station, everyone hears the same second"
/// architecture that structurally eliminates the "dead room" problem that
/// killed the room-based apps (Turntable.fm, Plug.dj, Dubtrack).
///
/// A station is *never* empty: when live participation is low the rotation
/// engine falls back to weighted-algorithmic programming, so a solo late-night
/// driver still hears a great station.
public struct Station: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let name: String
    public let tagline: String
    public let artworkURL: URL?
    /// The tuner number on the dial — the giant lit call on the SIGN and the
    /// badge in the car. Never a fake FM frequency: "PWR" is the flagship,
    /// "78" is the deep-crate record speed, "1200" is the Technics, "247" is
    /// around-the-clock. Kept as data so the phone and CarPlay agree.
    public let dial: String
    /// The small unit under the dial number ("RPM" for the record speeds, ""
    /// for the call-sign numbers).
    public let dialUnit: String
    /// The always-on flagship (PWR DAMIZZA). The UI frames it as a continuous
    /// 24/7 channel even while local rotation drives it between live shows.
    public let isFlagship: Bool
    /// The catalog this station may draw from — the opt-in OneSync subset.
    public let catalogArtistIDs: Set<UUID>

    public init(
        id: UUID = UUID(),
        name: String,
        tagline: String,
        dial: String = "",
        dialUnit: String = "",
        isFlagship: Bool = false,
        artworkURL: URL? = nil,
        catalogArtistIDs: Set<UUID> = []
    ) {
        self.id = id
        self.name = name
        self.tagline = tagline
        self.dial = dial
        self.dialUnit = dialUnit
        self.isFlagship = isFlagship
        self.artworkURL = artworkURL
        self.catalogArtistIDs = catalogArtistIDs
    }
}

/// A track that is currently on air, plus the live vote tally shaping what
/// comes next. This is the unit the phone UI renders and the CarPlay
/// Now Playing screen mirrors.
public struct NowPlaying: Hashable, Codable, Sendable {
    public let track: Track
    /// When playback of this track began, in stream time.
    public let startedAt: Date
    /// Net boost score from the live audience for the *current* track.
    public var boostScore: Int
    /// Number of distinct listeners currently tuned in.
    public var liveListeners: Int

    public init(track: Track, startedAt: Date, boostScore: Int = 0, liveListeners: Int = 0) {
        self.track = track
        self.startedAt = startedAt
        self.boostScore = boostScore
        self.liveListeners = liveListeners
    }

    /// How far into the track we are, given a reference "now".
    public func elapsed(at now: Date) -> Double {
        max(0, min(track.durationSeconds, now.timeIntervalSince(startedAt)))
    }
}
