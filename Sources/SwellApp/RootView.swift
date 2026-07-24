import SwiftUI
import RadioKit

/// The phone home screen: the live Now Playing card, boost/bury controls, the
/// "up next" teaser, and the live-listener count that makes votes feel
/// consequential. This is where the crowd actually programs the station.
struct RootView: View {
    @EnvironmentObject private var stream: LiveStreamService
    @EnvironmentObject private var player: RadioPlayer

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    nowPlayingCard
                    transportControls
                    upNext
                }
                .padding()
            }
            .navigationTitle(stream.station.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - Now Playing

    @ViewBuilder private var nowPlayingCard: some View {
        if let np = stream.nowPlaying {
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.ultraThinMaterial)
                    .frame(height: 220)
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: 64, weight: .thin))
                            .foregroundStyle(.secondary)
                    )

                VStack(spacing: 4) {
                    Text(np.track.title).font(.title2.bold())
                    Text(np.track.artistName).font(.headline).foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    Text("\(np.liveListeners) listening live")
                }
                .font(.footnote)
                .foregroundStyle(.secondary)

                voteControls(for: np)
            }
        } else {
            ProgressView("Tuning in…").frame(height: 320)
        }
    }

    private func voteControls(for np: NowPlaying) -> some View {
        HStack(spacing: 40) {
            Button {
                stream.vote(.bury, on: np.track.id)
            } label: {
                Label("Bury", systemImage: "hand.thumbsdown")
                    .labelStyle(.iconOnly).font(.system(size: 28))
            }
            .tint(.secondary)

            VStack {
                Text("\(np.boostScore > 0 ? "+" : "")\(np.boostScore)")
                    .font(.title3.monospacedDigit().bold())
                Text("boost").font(.caption2).foregroundStyle(.secondary)
            }

            Button {
                stream.vote(.boost, on: np.track.id)
            } label: {
                Label("Boost", systemImage: "hand.thumbsup.fill")
                    .labelStyle(.iconOnly).font(.system(size: 28))
            }
            .tint(.accentColor)
        }
        .padding(.top, 4)
    }

    // MARK: - Transport

    private var transportControls: some View {
        Button {
            player.toggle()
        } label: {
            Label(player.isPlaying ? "Pause" : "Play",
                  systemImage: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 56))
                .labelStyle(.iconOnly)
        }
    }

    // MARK: - Up next teaser (never a fixed schedule)

    @ViewBuilder private var upNext: some View {
        if !stream.upNextPreview.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Likely up next")
                    .font(.headline)
                Text("Shaped by the crowd's votes — not a fixed schedule.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(stream.upNextPreview) { track in
                    HStack {
                        Image(systemName: "music.note")
                        VStack(alignment: .leading) {
                            Text(track.title).font(.subheadline.bold())
                            Text(track.artistName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            stream.vote(.boost, on: track.id)
                        } label: {
                            Image(systemName: "hand.thumbsup")
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
