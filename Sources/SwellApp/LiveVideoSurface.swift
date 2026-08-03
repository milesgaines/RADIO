import SwiftUI
import AVKit
import RadioKit

/// The live picture. When a host's show carries video (the OBS → Mux path
/// does), this is where it lands — a raw AVPlayerLayer on the same AVPlayer
/// that's already carrying the audio, so sound and picture can never drift.
/// No system controls: it's a broadcast, not a VOD scrubber.
struct LiveVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
    }

    final class PlayerLayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// Full-screen replay theater for taped shows — VOD, so system controls are
/// right here (scrub, AirPlay, the lot).
struct ReplayTheater: View {
    let player: AVPlayer
    let title: String
    var onClose: () -> Void = {}

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            VideoPlayer(player: player)
                .ignoresSafeArea(edges: .bottom)
            HStack {
                Text(title)
                    .font(.custom("Archivo Black", size: 12)).tracking(1)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(.black.opacity(0.5)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18).padding(.top, 8)
        }
        .preferredColorScheme(.dark)
    }
}
