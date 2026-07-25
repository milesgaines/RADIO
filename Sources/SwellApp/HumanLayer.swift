import SwiftUI
import RadioKit

// The human layer: everything that makes the instrument explain itself.
// First-launch instructions, always-visible controls, and the listener
// profile that shows why your vote weighs what it weighs.

enum HumanTheme {
    static let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    static let bone = Color(red: 0.945, green: 0.925, blue: 0.878)
    static let dim = Color(red: 0.945, green: 0.925, blue: 0.878).opacity(0.55)
}

// MARK: - Broadcast furniture

/// Signal-strength bars fed by the real program level — the radio-est
/// possible status indicator.
struct SignalBars: View {
    let level: Float
    let accent: Color

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(0..<5, id: \.self) { i in
                Rectangle()
                    .fill(Float(i) / 5.0 < level ? accent : HumanTheme.bone.opacity(0.15))
                    .frame(width: 4, height: CGFloat(6 + i * 3))
            }
        }
        .animation(.linear(duration: 0.12), value: Int(level * 5))
    }
}

/// An always-moving broadcast ticker — station displays never sit still.
struct Ticker: View {
    let text: String
    var font: Font
    var color: Color
    var speed: Double = 28

    @State private var textWidth: CGFloat = 0
    private let gap: CGFloat = 56

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: textWidth <= 0)) { ctx in
            let span = textWidth + gap
            let t = ctx.date.timeIntervalSinceReferenceDate
            let offset = span > 0 ? CGFloat((t * speed).truncatingRemainder(dividingBy: span)) : 0
            HStack(spacing: gap) {
                label
                label
            }
            .offset(x: -offset)
        }
        // minWidth 0 matters: without it, frame(maxWidth:) adopts the huge
        // scrolling content's width and blows up the whole layout.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .frame(height: 24)
        .clipped()
        .background(
            label.hidden().fixedSize().background(
                GeometryReader { g in
                    Color.clear
                        .onAppear { textWidth = g.size.width }
                        .onChange(of: g.size.width) { _, w in textWidth = w }
                }
            )
        )
    }

    private var label: some View {
        Text(text).font(font).foregroundStyle(color).lineLimit(1).fixedSize()
    }
}

// MARK: - Control deck
// Buttons for every gesture, so nothing about the radio is a secret.

struct ControlDeck: View {
    @ObservedObject var stream: LiveStreamService
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var player: RadioPlayer
    let accent: Color
    let onTune: (Int) -> Void

    var body: some View {
        HStack(spacing: 14) {
            deckButton(icon: "chevron.left", label: "TUNE") { onTune(-1) }

            deckButton(icon: "arrow.down", label: "BURY", tint: HumanTheme.dim) {
                if let id = stream.nowPlaying?.track.id {
                    stream.vote(.bury, on: id)
                    Haptics.tap()
                }
            }

            Button {
                player.toggle()
                Haptics.tap()
            } label: {
                VStack(spacing: 5) {
                    ZStack {
                        Circle()
                            .fill(player.isPlaying ? AnyShapeStyle(HumanTheme.bone) : AnyShapeStyle(accent))
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(HumanTheme.ink)
                            .offset(x: player.isPlaying ? 0 : 1.5)
                    }
                    .frame(width: 62, height: 62)
                    Text(player.isPlaying ? "ON AIR" : "TUNE IN")
                        .font(.custom("Archivo Black", size: 9))
                        .tracking(1.2)
                        .foregroundStyle(HumanTheme.dim)
                }
            }

            deckButton(icon: "arrow.up", label: "BOOST", tint: accent) {
                if let id = stream.nowPlaying?.track.id {
                    stream.vote(.boost, on: id)
                    Haptics.boost()
                }
            }

            deckButton(icon: "chevron.right", label: "TUNE") { onTune(1) }
        }
    }

    private func deckButton(
        icon: String, label: String,
        tint: Color = HumanTheme.bone,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 46, height: 46)
                    .background(Circle().strokeBorder(HumanTheme.bone.opacity(0.22), lineWidth: 1))
                Text(label)
                    .font(.custom("Archivo Black", size: 8))
                    .tracking(1.2)
                    .foregroundStyle(HumanTheme.dim.opacity(0.8))
            }
        }
    }
}

// MARK: - First-launch instructions

struct WelcomeOverlay: View {
    let accent: Color
    let onStart: () -> Void

    var body: some View {
        ZStack {
            HumanTheme.ink.opacity(0.92).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 26) {
                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    Text("THIS IS\nLIVE RADIO")
                        .font(.custom("Gasoek One", size: 40))
                        .foregroundStyle(HumanTheme.bone)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Radio didn\u{2019}t lose because of Spotify. It lost when it stopped being radio. This one never stopped.")
                        .font(.custom("Instrument Serif", size: 19))
                        .foregroundStyle(HumanTheme.bone.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 18) {
                    rule(icon: "dot.radiowaves.left.and.right", color: accent,
                         head: "One station, one moment",
                         body: "Everyone tuned in hears the same second you do. No skipping — it's radio.")
                    rule(icon: "arrow.up.circle.fill", color: accent,
                         head: "The crowd programs it",
                         body: "BOOST songs you love, BURY ones you don't. Votes shape what plays next.")
                    rule(icon: "waveform", color: accent,
                         head: "The sand is the song",
                         body: "Every track vibrates its own pattern, live from the music. Watch it move on the kicks.")
                    rule(icon: "hand.draw.fill", color: accent,
                         head: "Shortcuts",
                         body: "Flick ↑ boost · flick ↓ bury · swipe ↔ stations · tap the sand to play. Buttons below do the same.")
                }

                Button(action: onStart) {
                    Text("PUT ME ON THE AIR")
                        .font(.custom("Archivo Black", size: 15))
                        .tracking(2)
                        .foregroundStyle(HumanTheme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(accent)
                }
                .padding(.top, 6)

                Text("Live, spontaneous, human, crowd-programmed. Flagship at 105.9 — some frequencies belong to somebody.")
                    .font(.system(size: 12))
                    .foregroundStyle(HumanTheme.dim.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer().frame(height: 20)
            }
            .padding(.horizontal, 26)
        }
    }

    private func rule(icon: String, color: Color, head: String, body text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(head)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(HumanTheme.bone)
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(HumanTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Listener profile

struct ProfileSheet: View {
    @ObservedObject var stream: LiveStreamService
    @EnvironmentObject private var services: AppServices
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let listener = services.meter.listener
        let power = AntiGaming().trustWeight(for: listener, at: Date())

        VStack(alignment: .leading, spacing: 24) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PROGRAM DIRECTOR")
                        .font(.custom("Archivo Black", size: 10))
                        .tracking(2)
                        .foregroundStyle(accent)
                    Text("YOUR SIGNAL")
                        .font(.custom("Gasoek One", size: 30))
                        .foregroundStyle(HumanTheme.bone)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(HumanTheme.dim)
                        .frame(width: 38, height: 38)
                        .background(Circle().strokeBorder(HumanTheme.bone.opacity(0.2), lineWidth: 1))
                }
            }

            // Vote power is the headline: this is the anti-bot trust system
            // made visible. It grows with genuine listening, nothing else.
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(power / 1.5 * 100))%")
                        .font(.custom("Gasoek One", size: 52))
                        .foregroundStyle(accent)
                    Text("VOTE POWER")
                        .font(.custom("Archivo Black", size: 11))
                        .tracking(1.5)
                        .foregroundStyle(HumanTheme.dim)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(HumanTheme.bone.opacity(0.12))
                        Rectangle().fill(accent)
                            .frame(width: geo.size.width * min(1, power / 1.5))
                    }
                }
                .frame(height: 6)
                Text("Your vote weighs more the longer you genuinely listen. It can't be bought and bots can't fake it — that's what keeps the station honest.")
                    .font(.system(size: 13))
                    .foregroundStyle(HumanTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                statRow("LISTENING TIME", hours(listener.lifetimeListeningSeconds))
                divider
                statRow("LISTENER SINCE", listener.createdAt.formatted(date: .abbreviated, time: .omitted))
                divider
                statRow("VOTES ON \(stream.station.name.uppercased())", "\(stream.myVoteCount) this session")
                divider
                statRow("VERIFIED", listener.isVerified ? "YES" : "NOT YET")
            }
            .overlay(Rectangle().strokeBorder(HumanTheme.bone.opacity(0.15), lineWidth: 1))

            Text("Keep the radio on. Your signal strengthens with every real hour.")
                .font(.custom("Instrument Serif", size: 17))
                .foregroundStyle(HumanTheme.dim)

            Text("Build something people remember \u{2014} not something they scroll past.")
                .font(.system(size: 11.5))
                .foregroundStyle(HumanTheme.dim.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HumanTheme.ink)
        .preferredColorScheme(.dark)
    }

    private var divider: some View {
        Rectangle().fill(HumanTheme.bone.opacity(0.12)).frame(height: 1)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.custom("Archivo Black", size: 10))
                .tracking(1.2)
                .foregroundStyle(HumanTheme.dim)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HumanTheme.bone)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
    }

    private func hours(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
