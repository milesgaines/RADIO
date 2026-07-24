import Foundation

/// Picks the next track for a station from **weighted-probabilistic** rotation.
///
/// Design principles, straight from the research:
///
///  - Votes shape *rotation weight*, they never *select* the literal next
///    track. This keeps the stream listenable lean-back and, as a bonus, keeps
///    us on the safe side of the `Arista v. Launch Media` predictability test
///    even if we ever fell back to the statutory license.
///  - There is always something good to play. If nobody is voting, weights
///    collapse toward a base "editorial" weight and the station keeps
///    programming itself — no dead room, ever.
///  - A lightweight **performance-complement guard** prevents one artist or
///    album from dominating a listening window, mirroring the DMCA
///    complement (≤4 tracks/artist, ≤3 consecutive) as a *product* rule for
///    balance, independent of which license we're under.
public struct WeightedRotationEngine: Sendable {

    public struct Config: Sendable {
        /// Base weight every eligible track gets before votes are applied.
        public var editorialWeight: Double
        /// How strongly net votes move a track's weight. Higher = more reactive.
        public var voteSensitivity: Double
        /// A track cannot be scheduled if it played within this many seconds.
        public var minRepeatGapSeconds: Double
        /// No more than this many tracks by one artist per rolling window.
        public var maxTracksPerArtistPerWindow: Int
        /// No more than this many *consecutive* tracks by one artist.
        public var maxConsecutivePerArtist: Int
        /// Rolling window used by the two limits above.
        public var windowSeconds: Double

        public init(
            editorialWeight: Double = 1.0,
            voteSensitivity: Double = 0.15,
            minRepeatGapSeconds: Double = 60 * 45,
            maxTracksPerArtistPerWindow: Int = 4,
            maxConsecutivePerArtist: Int = 2,
            windowSeconds: Double = 60 * 60 * 3 // three hours
        ) {
            self.editorialWeight = editorialWeight
            self.voteSensitivity = voteSensitivity
            self.minRepeatGapSeconds = minRepeatGapSeconds
            self.maxTracksPerArtistPerWindow = maxTracksPerArtistPerWindow
            self.maxConsecutivePerArtist = maxConsecutivePerArtist
            self.windowSeconds = windowSeconds
        }

        /// Defaults sized for a full production catalog, scaled down so a
        /// small catalog (an MVP folder of a dozen masters) doesn't slam
        /// every track into the repeat gap and live off the dead-air
        /// fallback. Rule of thumb: you can't demand a 45-minute gap from a
        /// 20-minute catalog.
        public static func adaptive(to catalog: [Track]) -> Config {
            let totalSeconds = catalog.reduce(0) { $0 + $1.durationSeconds }
            var config = Config()
            config.minRepeatGapSeconds = min(config.minRepeatGapSeconds, totalSeconds * 0.5)
            config.windowSeconds = min(config.windowSeconds, totalSeconds * 1.5)

            let artistCount = Set(catalog.map(\.artistID)).count
            if artistCount <= 1 {
                // The complement is a *diversity* rule; with one artist there
                // is no diversity to protect. Leaving it on would force every
                // selection into the dead-air fallback — which ignores votes —
                // and silently turn the station into a shuffle.
                config.maxTracksPerArtistPerWindow = Int.max
                config.maxConsecutivePerArtist = Int.max
            } else if artistCount < 4 {
                // Small roster: give each artist a proportional share of the
                // window instead of the big-catalog constant.
                config.maxTracksPerArtistPerWindow = max(
                    config.maxTracksPerArtistPerWindow,
                    catalog.count / artistCount + 1
                )
            }
            return config
        }
    }

    /// One entry in the recent play history, used to enforce the complement.
    public struct PlayRecord: Sendable {
        public let trackID: UUID
        public let artistID: UUID
        public let playedAt: Date
        public init(trackID: UUID, artistID: UUID, playedAt: Date) {
            self.trackID = trackID
            self.artistID = artistID
            self.playedAt = playedAt
        }
    }

    public let config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Compute the (non-negative) selection weight of a single candidate.
    /// `netVoteWeight` is the summed effective vote weight for the track
    /// (boosts positive, buries negative) — typically from `VoteTally`.
    public func weight(
        for track: Track,
        netVoteWeight: Double,
        history: [PlayRecord],
        now: Date
    ) -> Double {
        guard track.interactiveLicenseGranted else { return 0 }
        guard isEligible(track, history: history, now: now) else { return 0 }

        // A soft, monotonic response: boosts raise weight, buries lower it, but
        // weight can never go negative and a heavily-buried track still has a
        // whisper of a chance (nothing is ever hard-banned by the crowd).
        let raw = config.editorialWeight * (1.0 + config.voteSensitivity * netVoteWeight)
        return max(0.01, raw)
    }

    /// Enforce repeat-gap + performance-complement rules.
    func isEligible(_ track: Track, history: [PlayRecord], now: Date) -> Bool {
        let windowStart = now.addingTimeInterval(-config.windowSeconds)
        let recent = history.filter { $0.playedAt >= windowStart }

        // Repeat gap for this exact track.
        if let last = recent.last(where: { $0.trackID == track.id }) {
            if now.timeIntervalSince(last.playedAt) < config.minRepeatGapSeconds {
                return false
            }
        }

        // Per-artist cap within the window.
        let artistCountInWindow = recent.filter { $0.artistID == track.artistID }.count
        if artistCountInWindow >= config.maxTracksPerArtistPerWindow {
            return false
        }

        // Consecutive-artist cap (look at the tail of history).
        let trailingSameArtist = history
            .suffix(config.maxConsecutivePerArtist)
            .allSatisfy { $0.artistID == track.artistID }
        if history.count >= config.maxConsecutivePerArtist && trailingSameArtist {
            return false
        }

        return true
    }

    /// Select the next track. `random` is injected so selection is
    /// deterministic in tests. Returns `nil` only if nothing is eligible.
    public func selectNext(
        candidates: [Track],
        netVoteWeight: (Track) -> Double,
        history: [PlayRecord],
        now: Date,
        random: () -> Double = { Double.random(in: 0..<1) }
    ) -> Track? {
        let weighted = candidates.compactMap { track -> (Track, Double)? in
            let w = weight(for: track, netVoteWeight: netVoteWeight(track), history: history, now: now)
            return w > 0 ? (track, w) : nil
        }

        guard !weighted.isEmpty else {
            // No eligible candidate under the complement — relax so the
            // station never goes silent. Dead air is worse than a
            // slightly-too-soon repeat, but a *loop of one track* is worse
            // still, so fall back to the least-recently-played licensed
            // track (never-played first) instead of an arbitrary constant.
            var lastPlayed: [UUID: Date] = [:]
            for record in history {
                lastPlayed[record.trackID] = max(record.playedAt, lastPlayed[record.trackID] ?? .distantPast)
            }
            return candidates
                .filter(\.interactiveLicenseGranted)
                .min { (lastPlayed[$0.id] ?? .distantPast) < (lastPlayed[$1.id] ?? .distantPast) }
        }

        let total = weighted.reduce(0) { $0 + $1.1 }
        var threshold = random() * total
        for (track, w) in weighted {
            threshold -= w
            if threshold <= 0 { return track }
        }
        return weighted.last?.0
    }
}
