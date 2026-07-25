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

        let stream = LiveStreamService()
        self.stream = stream
        self.player = RadioPlayer(stream: stream)
        stream.start()
        reloadCatalog()
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
