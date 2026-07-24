import SwiftUI
import RadioKit

/// The main stage: animated aurora background, glowing artwork, a living
/// waveform, and the boost/bury controls that let the crowd program the
/// station. Haptics on every vote so it *feels* consequential.
struct LiveView: View {
    @EnvironmentObject private var stream: LiveStreamService
    @EnvironmentObject private var player: RadioPlayer
    @ObservedObject private var services = AppServices.shared

    @State private var boostPulse = 0

    var body: some View {
        ZStack {
            AuroraBackground()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 24) {
                    header
                    if let np = stream.nowPlaying {
                        artwork(for: np)
                        trackInfo(for: np)
                        WaveformView(playing: player.isPlaying)
                            .frame(height: 44)
                            .padding(.horizontal, 40)
                        voteBar(for: np)
                        transport
                        upNext
                    } else {
                        ProgressView("Tuning in…")
                            .frame(maxWidth: .infinity, minHeight: 400)
                    }
                }
                .padding()
                .padding(.bottom, 24)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 10) {
            Text("RADIO+")
                .font(.system(size: 40, weight: .black, design: .rounded))
                .kerning(4)
                .foregroundStyle(
                    LinearGradient(colors: [.pink, .orange],
                                   startPoint: .leading, endPoint: .trailing)
                )
            HStack(spacing: 8) {
                liveBadge
                if let np = stream.nowPlaying {
                    Text("\(np.liveListeners) listening")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if case .navidrome(let host) = services.catalogSource {
                    Text("· \(host)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.top, 8)
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(.red).frame(width: 7, height: 7)
                .opacity(player.isPlaying ? 1 : 0.35)
            Text("LIVE").font(.caption.weight(.black)).kerning(1.5)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.red.opacity(0.18), in: Capsule())
        .foregroundStyle(.red)
    }

    // MARK: - Artwork

    private func artwork(for np: NowPlaying) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(
                    LinearGradient(colors: [.pink.opacity(0.55), .indigo.opacity(0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            if let url = np.track.artworkURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        artworkFallback
                    }
                }
            } else {
                artworkFallback
            }
        }
        .frame(width: 280, height: 280)
        .clipShape(RoundedRectangle(cornerRadius: 28))
        .shadow(color: .pink.opacity(0.45), radius: 40, y: 12)
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(.white.opacity(0.15), lineWidth: 1)
        )
    }

    private var artworkFallback: some View {
        Image(systemName: "waveform")
            .font(.system(size: 80, weight: .thin))
            .foregroundStyle(.white.opacity(0.85))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Track info

    private func trackInfo(for np: NowPlaying) -> some View {
        VStack(spacing: 4) {
            Text(np.track.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text(np.track.artistName)
                .font(.headline)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Voting

    private func voteBar(for np: NowPlaying) -> some View {
        HStack(spacing: 44) {
            Button {
                haptic(.light)
                stream.vote(.bury, on: np.track.id)
            } label: {
                Image(systemName: "hand.thumbsdown")
                    .font(.system(size: 26))
                    .frame(width: 60, height: 60)
                    .background(.white.opacity(0.08), in: Circle())
            }
            .tint(.secondary)

            VStack(spacing: 2) {
                Text("\(np.boostScore > 0 ? "+" : "")\(np.boostScore)")
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: np.boostScore)
                Text("BOOST").font(.caption2.weight(.bold)).kerning(1.5)
                    .foregroundStyle(.secondary)
            }

            Button {
                haptic(.medium)
                boostPulse += 1
                stream.vote(.boost, on: np.track.id)
            } label: {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 26))
                    .symbolEffect(.bounce, value: boostPulse)
                    .frame(width: 60, height: 60)
                    .background(
                        LinearGradient(colors: [.pink, .orange],
                                       startPoint: .top, endPoint: .bottom),
                        in: Circle()
                    )
                    .foregroundStyle(.white)
                    .shadow(color: .pink.opacity(0.6), radius: 14)
            }
        }
    }

    // MARK: - Transport

    private var transport: some View {
        Button {
            haptic(.light)
            player.toggle()
        } label: {
            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                .font(.system(size: 62))
                .symbolRenderingMode(.hierarchical)
        }
        .tint(.white)
    }

    // MARK: - Up next teaser (never a fixed schedule)

    @ViewBuilder private var upNext: some View {
        if !stream.upNextPreview.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Likely up next").font(.headline)
                Text("Shaped by the crowd — not a fixed schedule.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(stream.upNextPreview) { track in
                    HStack(spacing: 12) {
                        Image(systemName: "music.note")
                            .foregroundStyle(.pink)
                        VStack(alignment: .leading) {
                            Text(track.title).font(.subheadline.bold())
                            Text(track.artistName).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            haptic(.light)
                            stream.vote(.boost, on: track.id)
                        } label: {
                            Image(systemName: "bolt")
                        }
                        .tint(.pink)
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private func haptic(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        UIImpactFeedbackGenerator(style: style).impactOccurred()
    }
}

// MARK: - Aurora background

/// Slowly drifting color field behind everything — cheap to render (three
/// blurred circles on a timeline) but reads as alive.
struct AuroraBackground: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate / 6
            ZStack {
                Color.black
                Circle()
                    .fill(.pink.opacity(0.28))
                    .frame(width: 420)
                    .blur(radius: 90)
                    .offset(x: CGFloat(cos(t)) * 110, y: CGFloat(sin(t * 0.8)) * -170)
                Circle()
                    .fill(.indigo.opacity(0.30))
                    .frame(width: 460)
                    .blur(radius: 100)
                    .offset(x: CGFloat(sin(t * 0.7)) * -120, y: CGFloat(cos(t * 0.5)) * 150)
                Circle()
                    .fill(.orange.opacity(0.16))
                    .frame(width: 380)
                    .blur(radius: 90)
                    .offset(x: CGFloat(sin(t * 1.1)) * 90, y: 260)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Waveform

/// A living bar waveform — pure Canvas, no audio tap needed. Freezes politely
/// when paused.
struct WaveformView: View {
    let playing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !playing)) { context in
            Canvas { canvas, size in
                let t = context.date.timeIntervalSinceReferenceDate
                let barCount = 36
                let spacing: CGFloat = 3
                let barWidth = (size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
                for i in 0..<barCount {
                    let phase = Double(i) * 0.55
                    let wobble = sin(t * 5 + phase) * 0.5 + sin(t * 2.3 + phase * 1.7) * 0.5
                    let level = playing ? (0.25 + 0.75 * abs(wobble)) : 0.12
                    let h = size.height * CGFloat(level)
                    let x = CGFloat(i) * (barWidth + spacing)
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                    canvas.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .linearGradient(
                            Gradient(colors: [.pink, .orange]),
                            startPoint: CGPoint(x: rect.midX, y: rect.minY),
                            endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                        )
                    )
                }
            }
        }
    }
}
