import Foundation
import UIKit
import CarPlay
import Combine
import RadioKit

/// The in-car experience. Deliberately lean-back: a station list and the system
/// Now Playing screen, plus a single "Boost" button. No voting grid, no chat,
/// no leaderboards — Apple's CarPlay App Programming Guide prohibits gaming and
/// social-networking UI and restricts audio apps to the standard templates
/// (List, Grid, Now Playing, Tab Bar, Alert). The car is a consumption
/// endpoint that keeps the stream alive between phone voting sessions.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var cancellables: Set<AnyCancellable> = []

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(makeStationsTemplate(), animated: false, completion: nil)
        configureNowPlaying()
        observeStream()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        cancellables.removeAll()
    }

    // MARK: - Station list (root)

    private func makeStationsTemplate() -> CPListTemplate {
        let station = AppServices.shared.stream.station
        let item = CPListItem(text: station.name, detailText: station.tagline)
        item.handler = { [weak self] _, completion in
            AppServices.shared.player.play()
            self?.pushNowPlaying()
            completion()
        }
        let section = CPListSection(items: [item])
        let template = CPListTemplate(title: "RADIO+", sections: [section])
        return template
    }

    private func pushNowPlaying() {
        guard let controller = interfaceController else { return }
        let np = CPNowPlayingTemplate.shared
        if controller.topTemplate !== np {
            controller.pushTemplate(np, animated: true, completion: nil)
        }
    }

    // MARK: - Now Playing + the one allowed interaction: Boost

    private func configureNowPlaying() {
        let np = CPNowPlayingTemplate.shared
        np.isUpNextButtonEnabled = false
        np.isAlbumArtistButtonEnabled = false

        let boost = CPNowPlayingImageButton(image: Self.boostImage()) { _ in
            AppServices.shared.player.play()
            AppServices.shared.stream.boostCurrent()
            AppServices.shared.player.refreshNowPlayingInfo()
        }
        np.updateNowPlayingButtons([boost])
    }

    private func observeStream() {
        // Keep the system Now Playing metadata fresh as the stream advances.
        AppServices.shared.stream.$nowPlaying
            .receive(on: RunLoop.main)
            .sink { _ in AppServices.shared.player.refreshNowPlayingInfo() }
            .store(in: &cancellables)
    }

    private static func boostImage() -> UIImage {
        UIImage(systemName: "hand.thumbsup.fill")
            ?? UIImage(systemName: "arrow.up")
            ?? UIImage()
    }
}
