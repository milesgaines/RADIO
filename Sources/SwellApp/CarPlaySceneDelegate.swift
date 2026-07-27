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

    /// The four-station dial, in the car. Each row wears its accent-tinted dial
    /// tile so the lineup reads at a glance; the flagship is called out. Selecting
    /// tunes the shared player — the same stream the phone is showing.
    private func makeStationsTemplate() -> CPListTemplate {
        let template = CPListTemplate(title: "RADI0", sections: [makeStationSection()])
        return template
    }

    /// The four accents that tint the dial — kept in step with CymaticPlate.accents.
    private static let accents: [UIColor] = [
        UIColor(red: 1.00, green: 0.36, blue: 0.18, alpha: 1), // ember  — PWR DAMIZZA
        UIColor(red: 0.30, green: 0.72, blue: 1.00, alpha: 1), // ice    — THE VAULT
        UIColor(red: 0.36, green: 0.92, blue: 0.53, alpha: 1), // acid   — THE UNDERGROUND
        UIColor(red: 0.86, green: 0.44, blue: 1.00, alpha: 1), // orchid — THE WAVE
    ]

    private func makeStationSection() -> CPListSection {
        let items = AppServices.shared.streams.enumerated().map { idx, stream -> CPListItem in
            let station = stream.station
            let listeners = stream.nowPlaying?.liveListeners ?? 1
            let accent = Self.accents[idx % Self.accents.count]
            let detail = station.isFlagship
                ? "◉ 24/7 FLAGSHIP · \(listeners) live"
                : "\(listeners) live · \(station.tagline)"
            let title = station.dial.isEmpty ? station.name : "\(station.dial)  ·  \(station.name)"
            let item = CPListItem(text: title, detailText: detail)
            item.setImage(Self.dialTile(dial: station.dial, color: accent))
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

    /// A little dial tile — dark rounded chip, accent ring, the call number —
    /// so the four stations are instantly distinct in the car list.
    private static func dialTile(dial: String, color: UIColor) -> UIImage {
        let size = CGSize(width: 96, height: 96)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(white: 0.07, alpha: 1).setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: 20).fill()
            let ring = UIBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), cornerRadius: 17)
            color.setStroke(); ring.lineWidth = 3; ring.stroke()
            let text = (dial.isEmpty ? "808" : dial) as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: text.length > 3 ? 24 : 33, weight: .heavy),
                .foregroundColor: UIColor(white: 0.96, alpha: 1),
            ]
            let b = text.size(withAttributes: attrs)
            text.draw(at: CGPoint(x: (size.width - b.width) / 2, y: (size.height - b.height) / 2),
                      withAttributes: attrs)
        }
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

        // Both sides of the vote, same vocabulary as the phone: bury on the
        // left, boost on the right, each landing in the shared tally.
        let bury = CPNowPlayingImageButton(image: Self.icon("hand.thumbsdown.fill")) { _ in
            Self.castFromCar(.bury)
        }
        let boost = CPNowPlayingImageButton(image: Self.icon("hand.thumbsup.fill")) { _ in
            Self.castFromCar(.boost)
        }
        np.updateNowPlayingButtons([bury, boost])
    }

    /// Route a steering-wheel vote through the same path as a tap on the phone,
    /// so the car and the app move one shared tally.
    private static func castFromCar(_ direction: VoteDirection) {
        let services = AppServices.shared
        services.player.play()
        if let id = services.activeStream.nowPlaying?.track.id {
            services.castMyVote(direction, on: id)
        }
        services.player.refreshNowPlayingInfo()
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

    private static func icon(_ name: String) -> UIImage {
        UIImage(systemName: name) ?? UIImage()
    }
}
