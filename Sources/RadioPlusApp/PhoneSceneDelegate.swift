import UIKit
import SwiftUI

/// Hosts the SwiftUI phone experience — the full voting UI. All the rich
/// interaction (boost/bury, up-next preview, artist detail) lives here, on the
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
            .environmentObject(AppServices.shared.stream)
            .environmentObject(AppServices.shared.player)
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UIHostingController(rootView: root)
        self.window = window
        window.makeKeyAndVisible()
    }
}
