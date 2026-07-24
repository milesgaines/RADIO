import XCTest
@testable import RadioKit

final class StationAndPersistenceTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Stations

    func testEveryStationHasAPlayableCatalog() {
        for station in MockCatalog.stations {
            let catalog = MockCatalog.tracks(for: station)
            XCTAssertGreaterThanOrEqual(
                catalog.count, 4,
                "\(station.name) needs enough tracks for the complement guard to breathe"
            )
            XCTAssertGreaterThanOrEqual(
                Set(catalog.map(\.artistID)).count, 3,
                "\(station.name) needs ≥3 artists or the consecutive-artist cap starves rotation"
            )
            XCTAssertTrue(
                catalog.allSatisfy(\.interactiveLicenseGranted),
                "Every track a station can draw must carry the opt-in license"
            )
        }
    }

    func testStationCatalogsOnlyContainOptedInArtists() {
        for station in MockCatalog.stations {
            for track in MockCatalog.tracks(for: station) {
                XCTAssertTrue(
                    station.catalogArtistIDs.contains(track.artistID),
                    "\(track.title) leaked into \(station.name) without artist opt-in"
                )
            }
        }
    }

    func testStationIDsAreStableAcrossLaunches() {
        // Persisted "last tuned station" only means something if ids don't
        // regenerate per launch.
        XCTAssertEqual(
            MockCatalog.flagshipStation.id.uuidString,
            "00000000-0000-0000-0000-0000000000B1"
        )
        XCTAssertEqual(Set(MockCatalog.stations.map(\.id)).count, MockCatalog.stations.count)
    }

    // MARK: - Listener persistence

    private func freshDefaults() -> UserDefaults {
        let name = "swell-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testListenerStoreRoundTrip() {
        let store = UserDefaultsListenerStore(defaults: freshDefaults())
        let listener = Listener(
            createdAt: t0,
            isVerified: true,
            lifetimeListeningSeconds: 1234
        )
        store.save(listener)
        XCTAssertEqual(store.load(), listener)
    }

    func testLoadOrCreateReturnsTheSameIdentityNextLaunch() {
        let store = UserDefaultsListenerStore(defaults: freshDefaults())
        let first = ListenerIdentity.loadOrCreate(store: store, now: { self.t0 })
        let second = ListenerIdentity.loadOrCreate(store: store, now: { self.t0.addingTimeInterval(86_400) })
        XCTAssertEqual(first.id, second.id, "Trust is earned per identity; the identity must survive relaunch")
    }

    func testOnboardingVerifiedListenerVotesVisiblyFromDayOne() {
        let store = UserDefaultsListenerStore(defaults: freshDefaults())
        let listener = ListenerIdentity.loadOrCreate(
            store: store,
            verifiedByOnboarding: true,
            now: { self.t0 }
        )
        let weight = AntiGaming().trustWeight(for: listener, at: t0)
        XCTAssertGreaterThan(weight, 0.5, "A verified day-one listener's boost should round to a visible +1")
    }

    @MainActor
    func testListeningMeterAccruesOnlyWhilePlaying() {
        var clock = t0
        let store = UserDefaultsListenerStore(defaults: freshDefaults())
        let listener = Listener(createdAt: t0, lifetimeListeningSeconds: 100)
        let meter = ListeningMeter(listener: listener, store: store, now: { clock })

        meter.playbackStarted()
        clock = t0.addingTimeInterval(300)
        meter.playbackStopped()
        XCTAssertEqual(meter.listener.lifetimeListeningSeconds, 400, accuracy: 0.001)

        // Paused: the meter must not run.
        clock = t0.addingTimeInterval(900)
        XCTAssertEqual(meter.flush().lifetimeListeningSeconds, 400, accuracy: 0.001)
    }

    @MainActor
    func testListeningMeterFlushBanksMidSessionAndPersists() {
        var clock = t0
        let store = UserDefaultsListenerStore(defaults: freshDefaults())
        let meter = ListeningMeter(
            listener: Listener(createdAt: t0),
            store: store,
            now: { clock }
        )

        meter.playbackStarted()
        clock = t0.addingTimeInterval(60)
        meter.flush()
        clock = t0.addingTimeInterval(150)
        meter.flush()

        // Two flushes must not double-count the first minute.
        XCTAssertEqual(meter.listener.lifetimeListeningSeconds, 150, accuracy: 0.001)
        XCTAssertEqual(store.load()?.lifetimeListeningSeconds ?? 0, 150, accuracy: 0.001)
    }
}
