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

/// The RADI0 mark. "RADI" is set; the 0 is *drawn* — an ember ring that
/// reads as a zero, a record, and the plate's resonance at once, with a
/// glow pass that breathes with the live bass. Never typed, never static.
struct RadioPlusMark: View {
    var size: CGFloat = 22
    var accent: Color
    var level: Float = 0

    var body: some View {
        HStack(alignment: .center, spacing: size * 0.10) {
            Text("RADI")
                .font(.custom("Gasoek One", size: size))
                .foregroundStyle(HumanTheme.bone)
                .fixedSize()
            Canvas { ctx, sz in
                let lineW = sz.width * 0.26
                let inset = lineW / 2 + 1
                let rect = CGRect(x: inset, y: inset,
                                  width: sz.width - 2 * inset, height: sz.height - 2 * inset)
                let ring = Path(ellipseIn: rect)
                var glow = ctx
                glow.addFilter(.blur(radius: 3 + CGFloat(level) * 6))
                glow.stroke(ring, with: .color(accent.opacity(0.85)), lineWidth: lineW)
                ctx.stroke(ring, with: .color(accent), lineWidth: lineW)
                // Spindle hole: it's a record.
                ctx.fill(
                    Path(ellipseIn: CGRect(x: sz.width / 2 - 1.2, y: sz.height / 2 - 1.2,
                                           width: 2.4, height: 2.4)),
                    with: .color(accent.opacity(0.9))
                )
            }
            .frame(width: size * 0.82, height: size * 0.82)
            .scaleEffect(1 + CGFloat(level) * 0.25)
            .animation(.linear(duration: 0.09), value: Int(level * 10))
            .offset(y: size * 0.03)
        }
    }
}

/// The audience, visible: one ember per listener drifting up the edges of
/// the room. Not a number — company.
struct CrowdEmbers: View {
    let count: Int
    let accent: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let n = min(count, 40)
                for i in 0..<n {
                    var h = UInt64(i) &* 0x9E3779B97F4A7C15 &+ 0xcbf29ce484222325
                    h = (h ^ (h >> 31)) &* 0xBF58476D1CE4E5B9
                    let leftSide = i % 2 == 0
                    let speed = 14.0 + Double(h % 90) / 8
                    let phase = Double(h % 9973)
                    let rise = (t * speed + phase).truncatingRemainder(dividingBy: Double(size.height) + 80)
                    let y = size.height + 30 - rise
                    let sway = sin(t * 0.6 + phase) * 9
                    let x = leftSide ? 14 + sway : Double(size.width) - 14 + sway
                    let fade = min(1, rise / 140) * min(1, (Double(size.height) + 60 - rise) / 200)
                    canvas.fill(
                        Path(ellipseIn: CGRect(x: x - 1.4, y: y - 1.4, width: 2.8, height: 2.8)),
                        with: .color(accent.opacity(0.5 * fade))
                    )
                }
            }
        }
        .allowsHitTesting(false)
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
    var onDedicate: () -> Void = {}

    var body: some View {
        // Five stations of equal width, edge to edge — a real control row,
        // not a centered clump.
        HStack(spacing: 0) {
            deckButton(icon: "chevron.left", label: "TUNE") { onTune(-1) }
                .frame(maxWidth: .infinity)

            deckButton(icon: "arrow.down", label: "BURY", tint: HumanTheme.dim) {
                if let id = stream.nowPlaying?.track.id {
                    services.castMyVote(.bury, on: id)
                    Haptics.tap()
                }
            }
            .frame(maxWidth: .infinity)

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
                    .frame(width: 68, height: 68)
                    Text(player.isPlaying ? "ON AIR" : "TUNE IN")
                        .font(.custom("Archivo Black", size: 9))
                        .tracking(2)
                        .foregroundStyle(HumanTheme.dim)
                }
            }
            .frame(maxWidth: .infinity)

            // Tap: boost. Hold: send it out to someone — radio's oldest ritual.
            deckButton(icon: "arrow.up", label: "BOOST", tint: accent) {
                if let id = stream.nowPlaying?.track.id {
                    services.castMyVote(.boost, on: id)
                    Haptics.boost()
                }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    Haptics.detent()
                    onDedicate()
                }
            )
            .frame(maxWidth: .infinity)

            deckButton(icon: "chevron.right", label: "TUNE") { onTune(1) }
                .frame(maxWidth: .infinity)
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
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 54, height: 54)
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

                VStack(alignment: .leading, spacing: 12) {
                    RadioPlusMark(size: 30, accent: accent)
                    Text("THIS IS\nLIVE RADIO")
                        .font(.custom("Gasoek One", size: 40))
                        .foregroundStyle(HumanTheme.bone)
                        .lineSpacing(2)
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
                         body: "Flick ↑ boost · flick ↓ bury · swipe ↔ stations · double-tap marks the moment. The big button plays. Buttons do everything gestures do.")
                }

                Button(action: onStart) {
                    Text("START LISTENING")
                        .font(.custom("Archivo Black", size: 15))
                        .tracking(2)
                        .foregroundStyle(HumanTheme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 17)
                        .background(accent)
                }
                .padding(.top, 6)

                Spacer().frame(height: 20)
            }
            .padding(.horizontal, 26)
        }
    }

    private func rule(icon: String, color: Color, head: String, body text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
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
                Text("YOUR SIGNAL")
                    .font(.custom("Gasoek One", size: 30))
                    .foregroundStyle(HumanTheme.bone)
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
                Text("Vote weight grows with listening time. Bots can't fake it.")
                    .font(.system(size: 13))
                    .foregroundStyle(HumanTheme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                statRow("LISTENING TIME", hours(listener.lifetimeListeningSeconds))
                divider
                statRow("LISTENER SINCE", listener.createdAt.formatted(date: .abbreviated, time: .omitted))
                divider
                statRow("PLAYS LOGGED", "\(services.airLog.playCount)")
                divider
                statRow("BOOSTS PENDING", "\(services.airLog.wagerCount)")
                divider
                statRow("BOOSTS AIRED", "\(services.airLog.payoffCount)")
                divider
                statRow("VERIFIED", listener.isVerified ? "YES" : "NO")
            }
            .overlay(Rectangle().strokeBorder(HumanTheme.bone.opacity(0.15), lineWidth: 1))

            if !services.airLog.recentMoments.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MARKED MOMENTS")
                        .font(.custom("Archivo Black", size: 10))
                        .tracking(1.5)
                        .foregroundStyle(HumanTheme.dim)
                    ForEach(Array(services.airLog.recentMoments.enumerated()), id: \.offset) { _, m in
                        HStack {
                            Text(m.at.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(accent)
                                .monospacedDigit()
                            Text("\(m.title) — \(m.stationName)")
                                .font(.custom("Instrument Serif", size: 16))
                                .foregroundStyle(HumanTheme.bone.opacity(0.85))
                                .lineLimit(1)
                        }
                    }
                }
            }

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
