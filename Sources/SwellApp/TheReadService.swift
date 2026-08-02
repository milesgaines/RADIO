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
    // Per-market divergence is intentionally NOT applied: a real geo split
    // needs geo-tagged votes (arrives with the A&R-brain backend). Until then
    // THE READ shows the ONE real room — no seeded/simulated market numbers.
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
        let sorted = monitor.readout.sorted { $0.resonance > $1.resonance }
        readouts = sorted.enumerated().map { i, r in
            TrackReadout(
                id: r.trackID, rank: i + 1, title: r.title, artist: r.artist,
                resonance01: (r.resonance + 1) / 2,   // REAL resonance, no market bias
                status: r.status, trend: r.trend,
                velocity: r.velocity, density: r.density, retention: r.retention,
                arLine: Self.arLine(for: r)
            )
        }
        hasBreaking = readouts.contains { $0.status == .breaking }
        updatedAt = Date()
    }

    /// A deterministic, plain-English read of the LIVE room. Labeled A&R in the
    /// UI. Describes only real status/trend — no invented percentages.
    private static func arLine(for r: TrackResonance) -> String {
        switch r.status {
        case .breaking:
            return "Breaking with the room — the momentum is real. Push it."
        case .inRotation:
            return r.trend == .up ? "Climbing. Hold the slot." : "Holding steady in rotation."
        case .cooling:
            return "Cooling — the room is drifting off it."
        case .benched:
            return "Not landing — dropped out of rotation until it recovers."
        }
    }
}
