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
    private var stationsTemplate: CPListTemplate?
    private var cancellables: Set<AnyCancellable> = []

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        let template = makeStationsTemplate()
        self.stationsTemplate = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
        configureNowPlaying()
        observeStreams()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
        self.stationsTemplate = nil
        cancellables.removeAll()
    }

    // MARK: - Station list (root)

    /// Every always-on station, selectable from the car. Selecting tunes the
    /// shared player — the same stream the phone is showing.
    private func makeStationsTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "Swell", sections: [makeStationSection()])
        return template
    }

    private func makeStationSection() -> CPListSection {
        let items = AppServices.shared.streams.map { stream -> CPListItem in
            let station = stream.station
            let listeners = stream.nowPlaying?.liveListeners ?? 1
            let item = CPListItem(
                text: station.name,
                detailText: "\(listeners) listening live — \(station.tagline)"
            )
            item.handler = { [weak self] _, completion in
                AppServices.shared.tune(to: station)
                AppServices.shared.player.play()
                self?.pushNowPlaying()
                completion()
            }
            return item
        }
        return CPListSection(items: items)
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
            AppServices.shared.activeStream.boostCurrent()
            AppServices.shared.player.refreshNowPlayingInfo()
        }
        np.updateNowPlayingButtons([boost])
    }

    private func observeStreams() {
        // Keep the system Now Playing metadata fresh as the *active* stream
        // advances, and keep the station list's live counts current.
        AppServices.shared.$activeStream
            .map { $0.$nowPlaying }
            .switchToLatest()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                AppServices.shared.player.refreshNowPlayingInfo()
                self?.stationsTemplate?.updateSections([self?.makeStationSection()].compactMap { $0 })
            }
            .store(in: &cancellables)
    }

    private static func boostImage() -> UIImage {
        UIImage(systemName: "hand.thumbsup.fill")
            ?? UIImage(systemName: "arrow.up")
            ?? UIImage()
    }
}
