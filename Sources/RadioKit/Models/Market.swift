import Foundation

/// A radio MARKET — the geographic unit real audience research (Nielsen PPM)
/// measures in. RADI0's live votes + tune-in/tune-out are that same signal, so
/// the research readout is sliced by market.
///
/// Today the four seeded markets diverge via a deterministic seeded bias (see
/// `SeededMarketBias`); when a real geo backend lands it feeds true per-market
/// votes/presence into the same seam and this type is unchanged.
public struct Market: Identifiable, Hashable, Codable, Sendable {
    public let id: String     // "LA"
    public let code: String   // "LA"
    public let name: String   // "Los Angeles"
    public init(id: String, code: String, name: String) {
        self.id = id
        self.code = code
        self.name = name
    }
}

public extension Market {
    static let losAngeles = Market(id: "LA",  code: "LA",  name: "Los Angeles")
    static let atlanta    = Market(id: "ATL", code: "ATL", name: "Atlanta")
    static let newYork    = Market(id: "NYC", code: "NYC", name: "New York")
    static let london     = Market(id: "LDN", code: "LDN", name: "London")

    /// The dial of markets the readout offers. Backend geo replaces this list
    /// with the real markets the station is heard in.
    static let seeded: [Market] = [.losAngeles, .atlanta, .newYork, .london]
}

/// How a market colours a track's aggregate resonance. Multiplier in
/// `[0.5, 1.5]`; 1.0 = market-neutral. A `RemoteMarketSource` (measured geo
/// signal) drops into this same protocol later with zero downstream change.
public protocol MarketResonanceSource: Sendable {
    func bias(market: Market, trackID: UUID) -> Double
}

/// Deterministic local stand-in: a stable, reproducible per-(market, track)
/// bias so the demo shows plausibly-divergent markets that DON'T reshuffle
/// every launch.
///
/// Critically this uses an explicit FNV-1a hash, **not** Swift's
/// `String.hashValue` — the standard hasher is salted per process, so it would
/// re-rank the readout on every launch and flake tests. Same convention as
/// `FolderCatalog.stableID`: a pure function of the input bytes.
public struct SeededMarketBias: MarketResonanceSource {
    public init() {}

    public func bias(market: Market, trackID: UUID) -> Double {
        0.5 + Self.stableUnit("\(market.code)|\(trackID.uuidString)")  // → [0.5, 1.5)
    }

    /// FNV-1a → a stable value in `[0, 1)`. Deterministic across launches and
    /// machines; no `Date`, no RNG, no salted `Hasher`.
    static func stableUnit(_ s: String) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Double(hash % 1_000_000) / 1_000_000.0
    }
}
