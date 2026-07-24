import XCTest
@testable import RadioKit

/// Pins the crowd-simulation + audience API invariants: the stream's audience
/// APIs behave like the production wire protocol will, and the simulator is
/// fully deterministic under an injected clock + RNG.
@MainActor
final class CrowdSimulatorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// A tiny seeded LCG so simulations replay identically.
    private func seededRandom(_ seed: UInt64 = 42) -> () -> Double {
        var state = seed
        return {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64.max >> 11)
        }
    }

    private func makeStream(random: @escaping () -> Double) -> LiveStreamService {
        let stream = LiveStreamService(now: { self.t0 }, random: random)
        stream.start() // sets nowPlaying synchronously
        stream.stop()  // cancel the timer loop; tests drive everything by hand
        return stream
    }

    // MARK: - Audience API

    func testJoinAndLeaveUpdateLiveListenerCount() {
        let stream = makeStream(random: seededRandom())
        XCTAssertEqual(stream.audienceCount, 1, "The device's own listener is always tuned in")

        let visitor = Listener(createdAt: t0.addingTimeInterval(-60 * 60 * 24 * 20))
        stream.join(visitor)
        XCTAssertEqual(stream.audienceCount, 2)
        XCTAssertEqual(stream.nowPlaying?.liveListeners, 2)

        stream.leave(visitor.id)
        XCTAssertEqual(stream.audienceCount, 1)
        XCTAssertEqual(stream.nowPlaying?.liveListeners, 1)
    }

    func testDeviceListenerCanNeverLeave() {
        let stream = makeStream(random: seededRandom())
        stream.leave(stream.currentListener.id)
        XCTAssertEqual(stream.audienceCount, 1)
    }

    func testVoteFromUnknownListenerIsDropped() {
        let stream = makeStream(random: seededRandom())
        guard let np = stream.nowPlaying else { return XCTFail("no track on air") }
        let before = np.boostScore
        let stranger = UUID()
        let after = stream.castVote(.boost, on: np.track.id, by: stranger)
        XCTAssertEqual(after, before, "A vote from a listener who never joined must not count")
    }

    func testCrowdVotesMoveTheDisplayedTally() {
        let stream = makeStream(random: seededRandom())
        guard let np = stream.nowPlaying else { return XCTFail("no track on air") }

        // Ten trusted regulars each boost once — the displayed score must move.
        for _ in 0..<10 {
            let fan = Listener(
                createdAt: t0.addingTimeInterval(-60 * 60 * 24 * 30),
                isVerified: true,
                lifetimeListeningSeconds: 60 * 60 * 40
            )
            stream.join(fan)
            stream.castVote(.boost, on: np.track.id, by: fan.id)
        }
        XCTAssertGreaterThanOrEqual(stream.nowPlaying?.boostScore ?? 0, 10)
    }

    // MARK: - Simulator

    func testDesiredSizeSitsAtTargetAtEpoch() {
        let stream = makeStream(random: seededRandom())
        let sim = CrowdSimulator(
            stream: stream,
            config: .init(targetSize: 40, swing: 0.5),
            now: { self.t0 },
            random: seededRandom()
        )
        XCTAssertEqual(sim.desiredSize(at: t0), 40, "sin(0) == 0, so the wave starts at the target")
    }

    func testCrowdDriftsTowardTargetAFewListenersPerTick() {
        let stream = makeStream(random: seededRandom())
        let sim = CrowdSimulator(
            stream: stream,
            config: .init(targetSize: 38),
            now: { self.t0 },
            random: seededRandom()
        )
        sim.tick()
        XCTAssertEqual(sim.members.count, 4, "The crowd breathes in a few at a time, never teleports")

        for _ in 0..<20 { sim.tick() }
        XCTAssertEqual(sim.members.count, 38, "The crowd settles at the daypart target")
        XCTAssertEqual(stream.audienceCount, 39, "38 synthetic + the device's listener")
    }

    func testSimulatedCrowdEventuallyVotes() {
        let stream = makeStream(random: seededRandom())
        let sim = CrowdSimulator(
            stream: stream,
            config: .init(targetSize: 38, voteProbabilityPerTick: 0.3),
            now: { self.t0 },
            random: seededRandom()
        )
        for _ in 0..<20 { sim.tick() }
        let score = stream.nowPlaying?.boostScore ?? 0
        XCTAssertNotEqual(score, 0, "A live crowd should visibly move the tally")
    }

    func testSimulationReplaysIdenticallyUnderSameSeed() {
        func run() -> (members: Int, score: Int) {
            let stream = makeStream(random: seededRandom(7))
            let sim = CrowdSimulator(
                stream: stream,
                config: .init(targetSize: 25, voteProbabilityPerTick: 0.2),
                now: { self.t0 },
                random: seededRandom(7)
            )
            for _ in 0..<15 { sim.tick() }
            return (sim.members.count, stream.nowPlaying?.boostScore ?? 0)
        }
        let a = run()
        let b = run()
        XCTAssertEqual(a.members, b.members)
        XCTAssertEqual(a.score, b.score)
    }
}
