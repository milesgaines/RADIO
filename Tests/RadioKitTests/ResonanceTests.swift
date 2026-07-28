import XCTest
@testable import RadioKit

@MainActor
final class ResonanceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func trk(_ title: String, _ a: Int) -> Track {
        Track(title: title,
              artistID: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(a)")!,
              artistName: "A\(a)", durationSeconds: 200)
    }

    private func sig(_ id: UUID = UUID(), net: Double = 0, boosts: Int = 0,
                     buries: Int = 0, thisPlay: Int = 0) -> TrackResearchSignal {
        TrackResearchSignal(trackID: id, title: "x", artist: "a",
                            netVoteWeight: net, recentBoosts: boosts, recentBuries: buries,
                            boostsThisPlay: thisPlay, lastVoteAt: nil)
    }

    // MARK: - ResonanceEngine (pure)

    func testNeutralInputsScoreZero() {
        let r = ResonanceEngine().score(signal: sig(), liveListeners: 10,
                                        retention: 0.5, velocityWindow: 90)
        XCTAssertEqual(r.resonance, 0, accuracy: 1e-9)
        XCTAssertEqual(r.velocity, 0, accuracy: 1e-9)
        XCTAssertEqual(r.density, 0, accuracy: 1e-9)
    }

    func testBoostsRaiseResonanceBuriesLowerIt() {
        let engine = ResonanceEngine()
        let neutral = engine.score(signal: sig(), liveListeners: 10, retention: 0.5, velocityWindow: 90)
        let loved = engine.score(signal: sig(net: 6, boosts: 20, thisPlay: 8),
                                 liveListeners: 10, retention: 0.9, velocityWindow: 90)
        let hated = engine.score(signal: sig(net: -6, buries: 20),
                                 liveListeners: 10, retention: 0.3, velocityWindow: 90)
        XCTAssertGreaterThan(loved.resonance, neutral.resonance)
        XCTAssertLessThan(hated.resonance, neutral.resonance)
        XCTAssertGreaterThan(loved.resonance, 0.35, "A well-loved record clears the promote threshold")
    }

    func testBuriedSheddingRecordCrossesBenchThreshold() {
        // Buried AND shedding its room (low retention) on air → benchable.
        let hated = ResonanceEngine().score(signal: sig(net: -8, buries: 20),
                                            liveListeners: 12, retention: 0.2, velocityWindow: 90)
        XCTAssertLessThanOrEqual(hated.resonance, -0.6,
                                 "A buried, shedding record must be droppable OUT of rotation")
    }

    func testResonanceStaysClampedToUnitRange() {
        let engine = ResonanceEngine()
        let hi = engine.score(signal: sig(net: 1000, boosts: 1000, thisPlay: 1000),
                              liveListeners: 1, retention: 1, velocityWindow: 1)
        let lo = engine.score(signal: sig(net: -1000, buries: 1000),
                              liveListeners: 1, retention: 0, velocityWindow: 1)
        XCTAssertLessThanOrEqual(hi.resonance, 1)
        XCTAssertGreaterThanOrEqual(lo.resonance, -1)
    }

    // MARK: - SeededMarketBias (must be deterministic, NOT salted hashValue)

    func testSeededMarketBiasIsDeterministicAcrossInstances() {
        let a = SeededMarketBias(), b = SeededMarketBias()
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        for m in Market.seeded {
            XCTAssertEqual(a.bias(market: m, trackID: id), b.bias(market: m, trackID: id),
                           "Same (market, track) must give the same bias every time — no per-process salt")
        }
    }

    func testSeededMarketBiasIsInRangeAndDivergesByMarket() {
        let s = SeededMarketBias()
        let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let values = Market.seeded.map { s.bias(market: $0, trackID: id) }
        for v in values {
            XCTAssertGreaterThanOrEqual(v, 0.5)
            XCTAssertLessThan(v, 1.5)
        }
        XCTAssertGreaterThan(Set(values.map { Int($0 * 1000) }).count, 1,
                             "Different markets must colour the same track differently")
    }

    // MARK: - ResonanceMonitor (stateful, tick-driven)

    func testMonitorRanksLovedRecordAboveBuriedOne() {
        var clock = t0
        let hot = trk("hot", 1), cold = trk("cold", 2), mid = trk("mid", 3)
        let me = Listener(createdAt: t0.addingTimeInterval(-1_000_000),
                          isVerified: true, lifetimeListeningSeconds: 100_000)
        let stream = LiveStreamService(catalog: [hot, cold, mid],
                                       currentListener: me, now: { clock })
        // A trusted room boosts `hot`, buries `cold`.
        for _ in 0..<8 {
            let l = Listener(createdAt: t0.addingTimeInterval(-1_000_000),
                             isVerified: true, lifetimeListeningSeconds: 100_000)
            stream.join(l)
            stream.castVote(.boost, on: hot.id, by: l.id)
            stream.castVote(.bury, on: cold.id, by: l.id)
        }
        let monitor = ResonanceMonitor(stream: stream, now: { clock })
        for _ in 0..<4 { monitor.tick(); clock = clock.addingTimeInterval(5) }

        let biasHot = monitor.biasByTrack[hot.id] ?? 0
        let biasCold = monitor.biasByTrack[cold.id] ?? 0
        XCTAssertGreaterThan(biasHot, biasCold, "The loved record must out-resonate the buried one")
        XCTAssertGreaterThan(biasHot, 0, "A heavily-boosted record reads positive")
        XCTAssertLessThan(biasCold, 0, "A heavily-buried record reads negative")
        XCTAssertFalse(monitor.readout.isEmpty, "The readout must surface the measured records")
    }

    func testMonitorNoOpWithoutStream() {
        let monitor = ResonanceMonitor(stream: nil, now: { self.t0 })
        monitor.tick()
        XCTAssertTrue(monitor.biasByTrack.isEmpty)
        XCTAssertTrue(monitor.readout.isEmpty)
    }
}
