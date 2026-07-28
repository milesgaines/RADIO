import Foundation
import Combine
import RadioKit

/// One row of THE READ — a record with its market-adjusted resonance and a
/// plain-English, generated A&R note. Presentation only; the measured signal
/// lives in RadioKit's `ResonanceMonitor`.
struct TrackReadout: Identifiable {
    let id: UUID
    let rank: Int
    let title: String
    let artist: String
    let resonance01: Double      // market-adjusted, [0,1] for the meter
    let status: ResonanceStatus
    let trend: ResonanceTrend
    let velocity: Double         // [-1,1]
    let density: Double          // [0,1]
    let retention: Double        // [0,1]
    let arLine: String
}

/// THE READ — RADI0's "PPM for music" surface. Drives the RadioKit
/// `ResonanceMonitor` on a cadence, applies the selected market's lens, and
/// publishes a ranked, human-readable readout. Held on `AppServices`, mirroring
/// the `aircheck` precedent. The A&R copy is generated and clearly labeled as
/// such in the UI — it is not a human A&R and not curation/financial advice.
@MainActor
final class TheReadService: ObservableObject {

    @Published private(set) var readouts: [TrackReadout] = []
    @Published private(set) var hasBreaking = false
    @Published private(set) var updatedAt = Date()
    @Published var market: Market = .losAngeles { didSet { remap() } }

    let markets = Market.seeded

    private let monitor: ResonanceMonitor
    private let bias: MarketResonanceSource = SeededMarketBias()
    private var ticker: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(stream: LiveStreamService?) {
        monitor = ResonanceMonitor(stream: stream)
        wire(stream)
        // Re-map whenever the monitor publishes a fresh sample.
        monitor.$readout
            .sink { [weak self] _ in self?.remap() }
            .store(in: &cancellables)
        start()
    }

    private func start() {
        guard ticker == nil else { return }
        let t = Timer(timeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.monitor.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
        monitor.tick() // sample once immediately
    }

    /// Point at another station on tune, and re-arm that station's rotation
    /// hook so records drop in/out on the new stream's signal.
    func retarget(to stream: LiveStreamService) {
        monitor.retarget(to: stream)
        wire(stream)
        monitor.tick()
    }

    /// Nudge a fresh sample right after the device's own vote, so the readout
    /// reacts now instead of on the next 4 s tick.
    func noteLocalVote() { monitor.tick() }

    func select(_ m: Market) { market = m }

    /// Feed the monitor's per-track resonance into the stream's rotation gate.
    private func wire(_ stream: LiveStreamService?) {
        stream?.resonanceBias = { [weak monitor] id in monitor?.biasByTrack[id] ?? 0 }
    }

    private func remap() {
        let adjusted = monitor.readout
            .map { r -> (TrackResonance, Double) in
                let marketRes = max(-1, min(1, r.resonance * bias.bias(market: market, trackID: r.trackID)))
                return (r, marketRes)
            }
            .sorted { $0.1 > $1.1 }

        readouts = adjusted.enumerated().map { i, pair in
            let (r, marketRes) = pair
            return TrackReadout(
                id: r.trackID, rank: i + 1, title: r.title, artist: r.artist,
                resonance01: (marketRes + 1) / 2,
                status: r.status, trend: r.trend,
                velocity: r.velocity, density: r.density, retention: r.retention,
                arLine: Self.arLine(for: r, marketRes: marketRes, market: market)
            )
        }
        hasBreaking = readouts.contains { $0.status == .breaking }
        updatedAt = Date()
    }

    /// A deterministic, plain-English A&R read. Labeled GENERATED in the UI.
    private static func arLine(for r: TrackResonance, marketRes: Double, market: Market) -> String {
        let pct = Int((abs(marketRes) * 100).rounded())
        switch r.status {
        case .breaking:
            return "Breaking in \(market.code) — \(pct)% over the room. Push it."
        case .inRotation:
            return r.trend == .up
                ? "Climbing in \(market.code). Hold the slot."
                : "Holding steady in \(market.code)."
        case .cooling:
            return "Cooling in \(market.code) — the room is drifting."
        case .benched:
            return "Not landing in \(market.code) — dropped out until it recovers."
        }
    }
}
