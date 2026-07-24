import Foundation
import RadioKit

/// Single source of truth shared by the phone scene and the CarPlay scene.
/// Both connect to the *same* `LiveStreamService`, so the car mirrors the live
/// stream and a boost from the steering-wheel button lands in the same tally
/// as a tap in the phone app.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let stream: LiveStreamService
    let player: RadioPlayer

    private init() {
        let stream = LiveStreamService()
        self.stream = stream
        self.player = RadioPlayer(stream: stream)
        stream.start()
    }
}
