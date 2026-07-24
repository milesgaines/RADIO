import XCTest
@testable import RadioKit

final class EngineTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func artist(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-00000000000\(n)")!
    }

    private func track(_ title: String, artist a: Int, dur: Double = 200) -> Track {
        Track(title: title, artistID: artist(a), artistName: "A\(a)", durationSeconds: dur)
    }

    // MARK: - AntiGaming

    func testFreshAccountVoteIsHeavilyDiscounted() {
        let ag = AntiGaming()
        let newbie = Listener(createdAt: now.addingTimeInterval(-60), isVerified: false)
        let regular = Listener(
            createdAt: now.addingTimeInterval(-60 * 60 * 24 * 30),
            isVerified: true,
            lifetimeListeningSeconds: 60 * 60 * 40
        )
        let wNew = ag.trustWeight(for: newbie, at: now)
        let wReg = ag.trustWeight(for: regular, at: now)
        XCTAssertLessThan(wNew, 0.2, "A brand-new unverified account should barely count")
        XCTAssertGreaterThan(wReg, wNew * 3, "An established verified regular should far outweigh a newbie")
    }

    func testPerListenerVoteDecayStopsSuperfanDomination() {
        let ag = AntiGaming(config: .init(perVoteDecay: 0.5))
        let first = ag.decayFactor(priorVotesInWindow: 0)
        let fifth = ag.decayFactor(priorVotesInWindow: 4)
        XCTAssertEqual(first, 1.0, accuracy: 1e-9)
        XCTAssertLessThan(fifth, 0.1, "The fifth vote in a window should be a fraction of the first")
    }

    func testVoteTallyDecaysRepeatedBoostsFromOneListener() {
        let tally = VoteTally(antiGaming: AntiGaming(config: .init(perVoteDecay: 0.5)))
        let fan = Listener(
            createdAt: now.addingTimeInterval(-60 * 60 * 24 * 30),
            isVerified: true,
            lifetimeListeningSeconds: 60 * 60 * 40
        )
        let t = track("x", artist: 1)
        let spam = (0..<10).map {
            Vote(listenerID: fan.id, trackID: t.id, stationID: UUID(),
                 direction: .boost, castAt: now.addingTimeInterval(Double(-$0)))
        }
        let net = tally.netWeights(votes: spam, listeners: [fan.id: fan], now: now)
        // Ten spammed boosts must sum to well under ten full votes because of decay.
        XCTAssertLessThan(net[t.id] ?? 0, 3.0)
        XCTAssertGreaterThan(net[t.id] ?? 0, 1.0)
    }

    // MARK: - Rotation engine

    func testBoostedTrackWinsMoreOften() {
        let engine = WeightedRotationEngine(config: .init(voteSensitivity: 1.0))
        let boosted = track("boosted", artist: 1)
        let plain = track("plain", artist: 2)
        let candidates = [boosted, plain]

        // Deterministic "random": always pick the midpoint of the weight range.
        var wins = 0
        let trials = 1000
        for i in 0..<trials {
            let r = Double(i) / Double(trials)
            let pick = engine.selectNext(
                candidates: candidates,
                netVoteWeight: { $0.id == boosted.id ? 5.0 : 0.0 },
                history: [],
                now: now,
                random: { r }
            )
            if pick?.id == boosted.id { wins += 1 }
        }
        XCTAssertGreaterThan(wins, trials / 2, "A boosted track should be selected more than half the time")
    }

    func testConsecutiveArtistCapEnforced() {
        let engine = WeightedRotationEngine(config: .init(maxConsecutivePerArtist: 2))
        let a1t1 = track("a1t1", artist: 1)
        let a1t2 = track("a1t2", artist: 1)
        let history = [
            WeightedRotationEngine.PlayRecord(trackID: a1t1.id, artistID: artist(1), playedAt: now.addingTimeInterval(-400)),
            WeightedRotationEngine.PlayRecord(trackID: a1t2.id, artistID: artist(1), playedAt: now.addingTimeInterval(-200)),
        ]
        // A third consecutive track by artist 1 must be ineligible.
        let another = track("a1t3", artist: 1)
        XCTAssertFalse(engine.isEligible(another, history: history, now: now))
    }

    func testNeverReturnsNilWhenSomethingIsLicensed() {
        let engine = WeightedRotationEngine()
        // History makes everything "recently played", tripping the repeat gap,
        // but the station must still hand back a track — no dead air.
        let t = track("only", artist: 1)
        let history = [WeightedRotationEngine.PlayRecord(trackID: t.id, artistID: artist(1), playedAt: now)]
        let pick = engine.selectNext(
            candidates: [t],
            netVoteWeight: { _ in 0 },
            history: history,
            now: now,
            random: { 0.5 }
        )
        XCTAssertNotNil(pick, "The station must never go silent when a licensed track exists")
    }

    func testDeadAirFallbackRotatesInsteadOfLoopingOneTrack() {
        // Small catalog + long repeat gap = everything blocked. The fallback
        // must cycle through the catalog (least-recently-played first), not
        // pin the station to a single track forever.
        let engine = WeightedRotationEngine(config: .init(minRepeatGapSeconds: 60 * 60 * 24))
        let a = track("a", artist: 1)
        let b = track("b", artist: 2)
        var history = [
            WeightedRotationEngine.PlayRecord(trackID: a.id, artistID: a.artistID, playedAt: now.addingTimeInterval(-400)),
            WeightedRotationEngine.PlayRecord(trackID: b.id, artistID: b.artistID, playedAt: now.addingTimeInterval(-200)),
        ]
        var played: [UUID] = []
        for step in 0..<4 {
            let when = now.addingTimeInterval(Double(step) * 200)
            let pick = engine.selectNext(
                candidates: [a, b],
                netVoteWeight: { _ in 0 },
                history: history,
                now: when,
                random: { 0.5 }
            )!
            played.append(pick.id)
            history.append(.init(trackID: pick.id, artistID: pick.artistID, playedAt: when))
        }
        XCTAssertEqual(played, [a.id, b.id, a.id, b.id], "Fallback must alternate, never loop one track")
    }

    // MARK: - Adaptive config

    func testAdaptiveConfigShrinksRepeatGapForSmallCatalogs() {
        let smallCatalog = (0..<6).map { track("t\($0)", artist: $0 % 3 + 1, dur: 200) }
        let config = WeightedRotationEngine.Config.adaptive(to: smallCatalog)
        XCTAssertEqual(config.minRepeatGapSeconds, 600, accuracy: 0.001,
                       "Gap must scale to half the 1200 s catalog, not demand 45 minutes")

        let bigCatalog = (0..<200).map { n in
            Track(title: "t\(n)", artistID: FolderCatalog.stableID("artist:\(n % 40)"),
                  artistName: "A\(n % 40)", durationSeconds: 200)
        }
        let bigConfig = WeightedRotationEngine.Config.adaptive(to: bigCatalog)
        XCTAssertEqual(bigConfig.minRepeatGapSeconds, 60 * 45, accuracy: 0.001,
                       "A big catalog keeps the production defaults")
    }

    func testSingleArtistCatalogKeepsVotingAliveInsteadOfFallbackShuffle() {
        // One artist (a folder of one act's masters): with the complement
        // relaxed, selection must stay in the *weighted* path, so a boosted
        // track still wins more often — votes keep mattering.
        let catalog = (0..<5).map { track("t\($0)", artist: 1, dur: 200) }
        let config = WeightedRotationEngine.Config.adaptive(to: catalog)
        let engine = WeightedRotationEngine(config: .init(
            voteSensitivity: 1.0,
            minRepeatGapSeconds: config.minRepeatGapSeconds,
            maxTracksPerArtistPerWindow: config.maxTracksPerArtistPerWindow,
            maxConsecutivePerArtist: config.maxConsecutivePerArtist,
            windowSeconds: config.windowSeconds
        ))
        let history = (0..<4).map { i in
            WeightedRotationEngine.PlayRecord(
                trackID: catalog[i].id, artistID: catalog[i].artistID,
                playedAt: now.addingTimeInterval(Double(i - 4) * 200)
            )
        }
        let boosted = catalog[4]
        var wins = 0
        let trials = 1000
        for i in 0..<trials {
            let pick = engine.selectNext(
                candidates: catalog,
                netVoteWeight: { $0.id == boosted.id ? 5.0 : 0.0 },
                history: history,
                now: now.addingTimeInterval(700), // past the scaled repeat gap
                random: { Double(i) / Double(trials) }
            )
            if pick?.id == boosted.id { wins += 1 }
        }
        XCTAssertGreaterThan(wins, trials / 2,
                             "Single-artist catalogs must not silently degrade into an unvoted shuffle")
    }

    func testUnlicensedTrackIsNeverScheduled() {
        let engine = WeightedRotationEngine()
        let unlicensed = Track(title: "no", artistID: artist(9), artistName: "A9",
                               durationSeconds: 200, interactiveLicenseGranted: false)
        let w = engine.weight(for: unlicensed, netVoteWeight: 99, history: [], now: now)
        XCTAssertEqual(w, 0, "A track without an interactive license must have zero weight")
    }
}
