import SwiftUI
import RadioKit

/// The phone home screen: the station dial, the live Now Playing card,
/// boost/bury controls, the "up next" teaser, and the live-listener count
/// that makes votes feel consequential. This is where the crowd actually
/// programs the station.
struct RootView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var player: RadioPlayer

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    stationDial
                    // Recreated per station switch: `activeStream` is
                    // @Published on services, and StationView observes the
                    // stream object it's handed.
                    StationView(stream: services.activeStream)
                }
                .padding()
            }
            .navigationTitle(services.activeStream.station.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// One always-on stream per station — switching is instant because every
    /// station is already running; you drop into whatever second everyone
    /// else is hearing.
    private var stationDial: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(services.streams, id: \.station.id) { stream in
                    StationChip(stream: stream, isActive: stream === services.activeStream) {
                        services.tune(to: stream.station)
                    }
                }
            }
        }
    }
}

/// One station on the dial. Observes its own stream so the live-listener
/// count keeps breathing even for stations you're not tuned to.
private struct StationChip: View {
    @ObservedObject var stream: LiveStreamService
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(stream.station.name)
                    .font(.subheadline.bold())
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                    Text("\(stream.nowPlaying?.liveListeners ?? 1) live")
                        .font(.caption2)
                        .monospacedDigit()
                }
                .foregroundStyle(isActive ? .primary : .secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                isActive ? AnyShapeStyle(.thinMaterial) : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? Color.accentColor : Color.secondary.opacity(0.3),
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
    }
}

/// Everything below the dial for one station. Split out so SwiftUI observes
/// the *active* stream object directly (nested ObservableObjects don't
/// propagate through a parent).
struct StationView: View {
    @ObservedObject var stream: LiveStreamService
    @EnvironmentObject private var player: RadioPlayer

    var body: some View {
        VStack(spacing: 28) {
            nowPlayingCard
            transportControls
            upNext
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
                    .contentTransition(.numericText())
                    .animation(.snappy, value: np.boostScore)
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
