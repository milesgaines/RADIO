import Foundation
import RadioKit

/// Single source of truth shared by the phone scene and the CarPlay scene.
/// Both connect to the *same* `LiveStreamService`, so the car mirrors the live
/// stream and a boost from the steering-wheel button lands in the same tally
/// as a tap in the phone app.
@MainActor
final class AppServices: ObservableObject {
    static let shared = AppServices()

    let stream: LiveStreamService
    let player: RadioPlayer

    enum CatalogSource: Equatable {
        case demo
        case navidrome(host: String)
    }

    @Published private(set) var catalogSource: CatalogSource = .demo

    private init() {
        // Builds up to 0.1.0 kept the Navidrome password in UserDefaults; move
        // any leftover plain-text copy into the keychain before the first read.
        NavidromeConfig.migrateLegacyPassword()

        let stream = LiveStreamService(scheduleSource: Self.configuredScheduleSource())
        self.stream = stream
        self.player = RadioPlayer(stream: stream)
        stream.start()
        reloadCatalog()
    }

    /// Point the station at a shared timeline when one is configured.
    ///
    /// Without this the rotation engine runs on-device: a real station, but
    /// this listener's own copy of it. With a feed URL the same UI renders the
    /// server's timeline instead, and every listener hears the same second.
    /// There's no Settings field yet — set it on the scheme's launch
    /// arguments while the backend is being built:
    ///
    ///     -StationFeedURL wss://live.example.com/station
    ///
    private static func configuredScheduleSource() -> (any StationScheduleSource)? {
        guard
            let raw = UserDefaults.standard.string(forKey: "StationFeedURL"),
            let url = URL(string: raw),
            url.scheme == "ws" || url.scheme == "wss"
        else { return nil }
        return RemoteScheduleSource(config: .init(url: url))
    }

    /// Connect to the configured Navidrome server (if any) and swap its
    /// library into the live rotation. Falls back to the demo catalog when
    /// unconfigured or unreachable — the station never goes dark.
    func reloadCatalog() {
        guard let config = NavidromeConfig.fromDefaults() else {
            catalogSource = .demo
            return
        }
        Task { [weak self] in
            do {
                let client = NavidromeClient(config: config)
                let tracks = try await client.fetchCatalog()
                guard let self, !tracks.isEmpty else { return }
                self.stream.updateCatalog(tracks)
                self.catalogSource = .navidrome(host: config.baseURL.host ?? config.baseURL.absoluteString)
            } catch {
                self?.catalogSource = .demo
            }
        }
    }
}
