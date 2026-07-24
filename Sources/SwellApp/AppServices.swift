import Foundation
import Combine
import RadioKit

/// Single source of truth shared by the phone scene and the CarPlay scene.
/// Both connect to the *same* per-station `LiveStreamService`s, so the car
/// mirrors the live stream and a boost from the steering-wheel button lands
/// in the same tally as a tap in the phone app.
///
/// Every station runs always-on — exactly like production, where the streams
/// exist server-side whether or not this device is listening. Tuning just
/// points the player at a different one.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    /// One always-on stream per station.
    let streams: [LiveStreamService]
    let player: RadioPlayer
    let meter: ListeningMeter

    @Published private(set) var activeStream: LiveStreamService

    private let crowds: [CrowdSimulator]
    private let listenerStore = UserDefaultsListenerStore()
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        // The same identity comes back every launch, so trust (account age +
        // listening tenure) actually accrues. `verifiedByOnboarding` stands in
        // for the sign-in/human check a real onboarding flow would do.
        let listener = ListenerIdentity.loadOrCreate(
            store: listenerStore,
            verifiedByOnboarding: true
        )
        self.meter = ListeningMeter(listener: listener, store: listenerStore)

        let streams = MockCatalog.stations.map { station in
            LiveStreamService(
                station: station,
                catalog: MockCatalog.tracks(for: station),
                currentListener: listener
            )
        }
        self.streams = streams

        // Each station gets its own crowd with a different size, so flipping
        // between them feels like flipping between real rooms of people.
        let crowdSizes = [38, 17, 26]
        self.crowds = zip(streams, crowdSizes).map { stream, size in
            CrowdSimulator(stream: stream, config: .init(targetSize: size))
        }

        let active = streams[0]
        self.activeStream = active
        self.player = RadioPlayer(stream: active)

        streams.forEach { $0.start() }
        crowds.forEach { $0.start() }

        // Listening tenure accrues while playback runs...
        player.$isPlaying
            .removeDuplicates()
            .sink { [weak self] playing in
                guard let self else { return }
                playing ? self.meter.playbackStarted() : self.meter.playbackStopped()
                self.pushListenerToTallies()
            }
            .store(in: &cancellables)

        // ...and banks once a minute so a force-quit can't erase a session.
        Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.meter.flush()
                self?.pushListenerToTallies()
            }
            .store(in: &cancellables)
    }

    /// Point the player (and both UIs) at another always-on station.
    func tune(to station: Station) {
        guard let stream = streams.first(where: { $0.station.id == station.id }),
              stream !== activeStream else { return }
        activeStream = stream
        player.attach(to: stream)
        player.refreshNowPlayingInfo()
    }

    /// Bank accrued tenure now (scene background, termination).
    func persistListeningProgress() {
        meter.flush()
        pushListenerToTallies()
    }

    private func pushListenerToTallies() {
        let updated = meter.listener
        streams.forEach { $0.refreshCurrentListener(updated) }
    }
}
