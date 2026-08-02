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
    /// True when the numbers on screen are the CROSS-DEVICE server aggregate
    /// (radio_resonance, recomputed every minute from every listener's real
    /// votes) rather than this device's local monitor alone.
    @Published private(set) var networkWide = false
    @Published var market: Market = .losAngeles { didSet { remap() } }

    let markets = Market.seeded

    private let monitor: ResonanceMonitor
    // Per-market divergence is intentionally NOT applied: a real geo split
    // needs geo-tagged votes (arrives with the A&R-brain backend). Until then
    // THE READ shows the ONE real room — no seeded/simulated market numbers.
    private var ticker: Timer?
    private var serverTicker: Timer?
    private var cancellables: Set<AnyCancellable> = []

    // MARK: Remote market source — the server's cross-device aggregate.
    // Same real votes the local monitor sees, but summed across EVERY device
    // by the radio-compute-resonance cron. When fresh rows exist for the
    // tuned station they take over the display; the local monitor remains the
    // instant-reaction layer and the offline fallback.
    private struct ServerRow: Decodable {
        let track_id: UUID
        let resonance: Double
        let velocity: Double
        let density: Double
        let retention: Double
        let computed_at: String
    }
    private var serverRows: [UUID: (row: ServerRow, at: Date)] = [:]
    private var stationID: String?
    /// Monotonic token: only the newest in-flight fetch may publish, so a slow
    /// response can't overwrite a fresher snapshot for the same station.
    private var fetchToken = 0
    private static let restBase = "https://tgkgdquivdoquxamtgcr.supabase.co/rest/v1"
    private static let publishableKey = "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii"
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    init(stream: LiveStreamService?) {
        monitor = ResonanceMonitor(stream: stream)
        stationID = stream?.station.id.uuidString.lowercased()
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

        // The server aggregate refreshes on the compute cron's own cadence
        // (once a minute) — poll a little faster than half of that.
        let s = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.fetchServerResonance() }
        }
        RunLoop.main.add(s, forMode: .common)
        serverTicker = s
        Task { @MainActor in await fetchServerResonance() }
    }

    /// Pull the tuned station's cross-device resonance rows. Rows older than
    /// 10 minutes are ignored (votes aged out server-side — the room moved on).
    private func fetchServerResonance() async {
        guard let station = stationID,
              var comps = URLComponents(string: Self.restBase + "/radio_resonance") else { return }
        comps.queryItems = [
            URLQueryItem(name: "station_id", value: "eq.\(station)"),
            URLQueryItem(name: "select", value: "track_id,resonance,velocity,density,retention,computed_at"),
            URLQueryItem(name: "order", value: "resonance.desc"),
            URLQueryItem(name: "limit", value: "40"),
        ]
        guard let url = comps.url else { return }
        fetchToken &+= 1
        let token = fetchToken
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(Self.publishableKey)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let rows = try? JSONDecoder().decode([ServerRow].self, from: data) else { return }
        // A tune — or a newer fetch — may have landed while this was in flight.
        guard station == stationID, token == fetchToken else { return }
        var fresh: [UUID: (row: ServerRow, at: Date)] = [:]
        for row in rows {
            guard let at = Self.stamp.date(from: row.computed_at)
                    ?? ISO8601DateFormatter().date(from: row.computed_at),
                  Date().timeIntervalSince(at) < 600 else { continue }
            fresh[row.track_id] = (row, at)
        }
        serverRows = fresh
        remap()
    }

    /// Point at another station on tune, and re-arm that station's rotation
    /// hook so records drop in/out on the new stream's signal.
    func retarget(to stream: LiveStreamService) {
        monitor.retarget(to: stream)
        stationID = stream.station.id.uuidString.lowercased()
        serverRows = [:]
        networkWide = false
        wire(stream)
        monitor.tick()
        Task { @MainActor in await fetchServerResonance() }
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
        // Server aggregate wins where it exists AND is still fresh — it's the
        // same real votes, summed across every device. Freshness is re-checked
        // at render time (not just at fetch): if the compute cron or the
        // network stalls, we fall back to the live local monitor rather than
        // showing an aging number under a cross-device label.
        let now = Date()
        var usedServer = 0
        let merged: [(TrackResonance, Double, Double, Double, Double, Bool)] = monitor.readout.map { r in
            if let entry = serverRows[r.trackID], now.timeIntervalSince(entry.at) < 600 {
                usedServer += 1
                return (r, entry.row.resonance, entry.row.velocity, entry.row.density, entry.row.retention, true)
            }
            return (r, r.resonance, r.velocity, r.density, r.retention, false)
        }
        let sorted = merged.sorted { $0.1 > $1.1 }
        readouts = sorted.enumerated().map { i, entry in
            let (r, resonance, velocity, density, retention, fromServer) = entry
            // When the number is the server's, the STATUS must be derived from
            // that same number — otherwise a record can rank #1 while its chip
            // says BENCHED, which is just a lie in two fonts.
            let status = fromServer ? Self.status(for: resonance) : r.status
            return TrackReadout(
                id: r.trackID, rank: i + 1, title: r.title, artist: r.artist,
                resonance01: (resonance + 1) / 2,   // REAL resonance, no market bias
                status: status, trend: r.trend,
                velocity: velocity, density: density, retention: retention,
                arLine: Self.arLine(status: status, trend: r.trend)
            )
        }
        // Only claim "every device, summed" when a displayed row actually uses
        // a server number.
        networkWide = usedServer > 0
        hasBreaking = readouts.contains { $0.status == .breaking }
        updatedAt = now
    }

    /// Same thresholds the local ResonanceMonitor uses, applied to the server
    /// aggregate so status and number always come from one source.
    private static func status(for resonance: Double) -> ResonanceStatus {
        switch resonance {
        case 0.35...:      return .breaking
        case 0.05..<0.35:  return .inRotation
        case -0.6..<0.05:  return .cooling
        default:           return .benched
        }
    }

    /// A deterministic, plain-English read of the LIVE room. Labeled A&R in the
    /// UI. Describes only real status/trend — no invented percentages. Takes
    /// the SAME status the row displays, so the copy can never contradict the
    /// chip or the meter next to it.
    private static func arLine(status: ResonanceStatus, trend: ResonanceTrend) -> String {
        switch status {
        case .breaking:
            return "Breaking with the room — the momentum is real. Push it."
        case .inRotation:
            return trend == .up ? "Climbing. Hold the slot." : "Holding steady in rotation."
        case .cooling:
            return "Cooling — the room is drifting off it."
        case .benched:
            return "Not landing — dropped out of rotation until it recovers."
        }
    }
}
