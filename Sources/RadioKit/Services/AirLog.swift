import Foundation

/// The station's memory. Every airplay this device witnesses and every
/// boost this listener casts is written down from day one — memories can't
/// be backfilled, and everything warm the product will ever do (\u{201C}your
/// record is on\u{201D}, anniversaries, first-spin receipts) draws from this
/// ledger later.
@MainActor
public final class AirLog: ObservableObject {

    public struct Play: Codable, Equatable {
        public let trackID: UUID
        public let title: String
        public let artist: String
        public let stationName: String
        public let at: Date
    }

    private struct State: Codable {
        var plays: [Play] = []
        var wagers: Set<UUID> = []      // tracks this listener boosted
        var payoffs: Int = 0            // times a wagered record hit the air
    }

    @Published private var state = State()
    private let fileURL: URL
    private let now: () -> Date

    public init(directory: URL? = nil, now: @escaping () -> Date = { Date() }) {
        let dir = directory ?? FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        )[0]
        self.fileURL = dir.appendingPathComponent("airlog.json")
        self.now = now
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(State.self, from: data) {
            state = saved
        }
    }

    // MARK: Reads

    public var playCount: Int { state.plays.count }
    public var wagerCount: Int { state.wagers.count }
    public var payoffCount: Int { state.payoffs }

    /// Has this listener boosted this track before — is a wager riding on it?
    public func isWagered(_ trackID: UUID) -> Bool {
        state.wagers.contains(trackID)
    }

    // MARK: Writes

    /// A track hit the air while this device was listening. Returns true if
    /// it pays off a standing wager (caller shows the moment; the payoff is
    /// consumed so each boost earns one flash, then re-arms on next boost).
    @discardableResult
    public func logPlay(track: Track, station: Station) -> Bool {
        state.plays.append(Play(
            trackID: track.id, title: track.title, artist: track.artistName,
            stationName: station.name, at: now()
        ))
        if state.plays.count > 5000 {
            state.plays.removeFirst(state.plays.count - 5000)
        }
        var paidOff = false
        if state.wagers.remove(track.id) != nil {
            state.payoffs += 1
            paidOff = true
        }
        save()
        return paidOff
    }

    /// This listener boosted a track — a bet that the station will play it.
    public func logBoost(trackID: UUID) {
        state.wagers.insert(trackID)
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
