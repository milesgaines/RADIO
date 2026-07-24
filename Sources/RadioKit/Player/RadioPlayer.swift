#if canImport(AVFoundation)
import Foundation
import AVFoundation
import MediaPlayer
import Combine

/// Wraps `AVPlayer` and keeps the system Now Playing surfaces — lock screen,
/// Control Center, and the **CarPlay Now Playing template** — in sync with the
/// live stream.
///
/// The one interactive affordance we expose in-car is the system
/// `likeCommand`, surfaced by CarPlay as a Now Playing button and reachable by
/// Siri ("I like this"). We map it to **boost current track**. This is the
/// maximum viable in-car interaction under Apple's CarPlay App Programming
/// Guide, which forbids gaming/social UI and restricts audio apps to the
/// standard templates. All richer voting stays on the phone.
@MainActor
public final class RadioPlayer: ObservableObject {

    @Published public private(set) var isPlaying = false

    private let player = AVPlayer()
    private let stream: LiveStreamService
    private var cancellables: Set<AnyCancellable> = []

    public init(stream: LiveStreamService) {
        self.stream = stream
        configureAudioSession()
        configureRemoteCommands()

        // Whenever the live stream advances, swap the asset + refresh metadata.
        stream.$nowPlaying
            .compactMap { $0 }
            .sink { [weak self] np in self?.load(np) }
            .store(in: &cancellables)
    }

    public func play() {
        stream.start()
        player.play()
        isPlaying = true
        refreshNowPlayingInfo()
    }

    public func pause() {
        player.pause()
        isPlaying = false
        refreshNowPlayingInfo()
    }

    public func toggle() { isPlaying ? pause() : play() }

    // MARK: - Asset loading

    private func load(_ np: NowPlaying) {
        if let url = np.track.assetURL {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            // Everyone hears the same second: join the track already in
            // progress rather than starting it from zero.
            let elapsed = np.elapsed(at: Date())
            if elapsed > 1 {
                player.seek(to: CMTime(seconds: elapsed, preferredTimescale: 600))
            }
            if isPlaying { player.play() }
        }
        refreshNowPlayingInfo()
    }

    // MARK: - System integration

    private func configureAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
    }

    private func configureRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.addTarget { [weak self] _ in
            self?.play(); return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            self?.pause(); return .success
        }
        // Skip is intentionally *not* wired to a user "next" — this is radio,
        // not on-demand. We leave nextTrackCommand disabled so listeners can't
        // hand-pick the next song (which would make the stream interactive
        // under the statutory license). Boost is the lever instead.
        center.nextTrackCommand.isEnabled = false
        center.previousTrackCommand.isEnabled = false

        // The in-car "boost" affordance.
        center.likeCommand.isEnabled = true
        center.likeCommand.localizedTitle = "Boost"
        center.likeCommand.addTarget { [weak self] _ in
            self?.stream.boostCurrent()
            self?.refreshNowPlayingInfo()
            return .success
        }
    }

    /// Push current-track metadata (and live boost score) to the system.
    public func refreshNowPlayingInfo() {
        guard let np = stream.nowPlaying else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: np.track.title,
            MPMediaItemPropertyArtist: np.track.artistName,
            MPMediaItemPropertyPlaybackDuration: np.track.durationSeconds,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: np.elapsed(at: Date()),
            MPNowPlayingInfoPropertyIsLiveStream: true,
        ]
        if let album = np.track.albumTitle {
            info[MPMediaItemPropertyAlbumTitle] = album
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}
#endif
