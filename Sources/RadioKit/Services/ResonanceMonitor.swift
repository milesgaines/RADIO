import Foundation
import Combine

/// The live audience-research sampler — RADI0's "PPM for music" made stateful.
/// It samples one `LiveStreamService` on each `tick()`, keeps the small amount
/// of history the retention/trend signals need, and publishes two things:
///
///  - `readout` — the ranked per-track `TrackResonance` the READ panel shows.
///  - `biasByTrack` — the per-track resonance ∈ [-1, 1] the rotation engine
///    consumes to drop records IN and OUT (wired via `stream.resonanceBias`).
///
/// It has no internal timer (the app layer calls `tick()` on a cadence), no
/// `Date()` of its own (injected `now`), and no RNG — so a fixed input series
/// asserts an exact readout in tests. It is the deterministic twin of
/// `CrowdSimulator`.
@MainActor
public final class ResonanceMonitor: ObservableObject {

    @Published public private(set) var readout: [TrackResonance] = []
    /// Market-neutral resonance per track, for rotation. The market lens is a
    /// presentation concern (it reorders the *view*, not the one real rotation).
    @Published public private(set) var biasByTrack: [UUID: Double] = [:]

    private weak var stream: LiveStreamService?
    private let engine: ResonanceEngine
    private let now: () -> Date
    private let velocityWindow: Double

    // Retention: a rolling audience sample for the ON-AIR play only.
    private struct PlayKey: Hashable { let track: UUID; let startedAt: Date }
    private struct Sample { let at: Date; let listeners: Int }
    private var samples: [PlayKey: [Sample]] = [:]
    private var currentKey: PlayKey?

    // Trend: a short resonance history per track.
    private struct ScorePoint { let at: Date; let value: Double }
    private var scoreHistory: [UUID: [ScorePoint]] = [:]

    // Status: hysteresis so a record near a boundary doesn't flap.
    private var statuses: [UUID: ResonanceStatus] = [:]

    // Pool-variety guard: never let the signal bench so many tracks that the
    // weighted pool starves (belt-and-suspenders over engine never-silent).
    private let benchFloor: Double
    private let minActive: Int

    public init(
        stream: LiveStreamService?,
        engine: ResonanceEngine = ResonanceEngine(),
        velocityWindow: Double = 90,
        benchFloor: Double = -0.6,
        minActive: Int = 3,
        now: @escaping () -> Date = { Date() }
    ) {
        self.stream = stream
        self.engine = engine
        self.velocityWindow = velocityWindow
        self.benchFloor = benchFloor
        self.minActive = minActive
        self.now = now
    }

    /// Point at a different station (station switch). Clears the per-station
    /// history so a stale curve can't bleed across the tune.
    public func retarget(to stream: LiveStreamService) {
        self.stream = stream
        samples.removeAll()
        scoreHistory.removeAll()
        statuses.removeAll()
        currentKey = nil
        readout = []
        biasByTrack = [:]
    }

    /// Sample the stream once and recompute. Called on the app's cadence and,
    /// in tests, directly with a controlled clock.
    public func tick() {
        guard let stream else { return }
        let snap = stream.researchSnapshot(velocityWindow: velocityWindow, at: now())
        let ref = snap.capturedAt

        // Extend the retention curve for the on-air track; drop stale play
        // buffers on a track change so memory stays bounded to one song.
        if let tid = snap.nowPlayingTrackID, let start = snap.nowPlayingStartedAt {
            let key = PlayKey(track: tid, startedAt: start)
            if key != currentKey {
                currentKey = key
                samples = [key: samples[key] ?? []]
            }
            samples[key, default: []].append(Sample(at: ref, listeners: snap.liveListeners))
        }

        var newReadout: [TrackResonance] = []
        var newBias: [UUID: Double] = [:]
        for (id, sig) in snap.signals {
            let retention = retentionFor(id, snap: snap)
            let reading = engine.score(
                signal: sig,
                liveListeners: snap.liveListeners,
                retention: retention,
                velocityWindow: velocityWindow
            )
            recordScore(id, reading.resonance, at: ref)
            let trend = trendFor(id)
            let status = updateStatus(id, resonance: reading.resonance, trend: trend)
            newBias[id] = reading.resonance
            newReadout.append(TrackResonance(
                trackID: id, title: sig.title, artist: sig.artist,
                resonance: reading.resonance, velocity: reading.velocity,
                density: reading.density, retention: retention,
                trend: trend, status: status
            ))
        }
        applyPoolGuard(&newBias)
        biasByTrack = newBias
        readout = newReadout.sorted { $0.resonance > $1.resonance }
    }

    // MARK: - Retention proxy

    /// Only the ON-AIR track has a live tune-out curve; every other track reads
    /// neutral. Cold start (<20 s or <2 samples) is neutral too, so a fresh
    /// record isn't punished before its room has formed.
    private func retentionFor(_ id: UUID, snap: StationResearchSnapshot) -> Double {
        guard id == snap.nowPlayingTrackID, let start = snap.nowPlayingStartedAt else { return 0.5 }
        let key = PlayKey(track: id, startedAt: start)
        guard let buf = samples[key], buf.count >= 2 else { return 0.5 }
        guard snap.capturedAt.timeIntervalSince(start) >= 20 else { return 0.5 }
        let peak = buf.map(\.listeners).max() ?? 1
        let nowL = buf.last!.listeners
        let churn = clamp(Double(peak - nowL) / Double(max(peak, 1)), 0, 1)
        let engaged = clamp(Double(snap.signals[id]?.boostsThisPlay ?? 0) / Double(max(nowL, 1)), 0, 1)
        return clamp(0.85 * (1 - churn) + 0.15 * engaged, 0, 1)
    }

    // MARK: - Trend

    private func recordScore(_ id: UUID, _ value: Double, at t: Date) {
        var h = scoreHistory[id] ?? []
        h.append(ScorePoint(at: t, value: value))
        if h.count > 10 { h.removeFirst(h.count - 10) }
        scoreHistory[id] = h
    }

    private func trendFor(_ id: UUID) -> ResonanceTrend {
        guard let h = scoreHistory[id], h.count >= 3 else { return .flat }
        let recent = h.suffix(5)
        let delta = recent.last!.value - recent.first!.value
        if delta > 0.08 { return .up }
        if delta < -0.08 { return .down }
        return .flat
    }

    // MARK: - Status (hysteresis)

    private func updateStatus(_ id: UUID, resonance r: Double, trend: ResonanceTrend) -> ResonanceStatus {
        let prev = statuses[id] ?? .inRotation
        var next = prev
        switch prev {
        case .breaking:
            if r < 0.30 { next = (trend == .down ? .cooling : .inRotation) }
        case .inRotation:
            if r >= 0.45 { next = .breaking }
            else if r <= benchFloor { next = .benched }
            else if trend == .down && r < 0 { next = .cooling }
        case .cooling:
            if r <= benchFloor { next = .benched }
            else if r >= 0.20 && trend != .down { next = .inRotation }
        case .benched:
            if r >= benchFloor + 0.15 { next = .inRotation }
        }
        statuses[id] = next
        return next
    }

    // MARK: - Pool guard

    private func applyPoolGuard(_ bias: inout [UUID: Double]) {
        let benched = bias.filter { $0.value <= benchFloor }
        let activeCount = bias.count - benched.count
        guard activeCount < minActive, !benched.isEmpty else { return }
        // Lift the least-cold benched records (highest resonance) just back into
        // the pool until `minActive` remain eligible.
        let lift = benched.sorted { $0.value > $1.value }.prefix(minActive - activeCount)
        for (id, _) in lift { bias[id] = benchFloor + 0.01 }
    }
}
