import UIKit
import SwiftUI

/// Hosts the SwiftUI phone experience — the full voting UI. All the rich
/// interaction (boost/bury, up-next preview, station dial) lives here, on the
/// phone, where Apple permits it.
final class PhoneSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let root = RootView()
            .environmentObject(AppServices.shared)
            .environmentObject(AppServices.shared.player)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: root)
        self.window = window
        window.makeKeyAndVisible()

        // Demo/automation hook: `-SwellAutoPlay YES` as a launch argument
        // starts playback immediately (simulator runs, screenshots, demos).
        if UserDefaults.standard.bool(forKey: "SwellAutoPlay") {
            AppServices.shared.player.play()
        }
    }

    /// Bank listening tenure whenever the app leaves the foreground, so a
    /// later force-quit can't erase the trust this session earned.
    func sceneDidEnterBackground(_ scene: UIScene) {
        AppServices.shared.persistListeningProgress()
    }
}
