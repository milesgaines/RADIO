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
        .frame(height: 30)
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
    @EnvironmentObject private var auth: AuthService
    let accent: Color
    let onTune: (Int) -> Void
    var onDedicate: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
        // Six controls of equal width, edge to edge — PREV · BURY · transport ·
        // BOOST · NEXT. A real control row, not a centered clump.
        HStack(spacing: 0) {
            deckButton(icon: "chevron.left", label: "PREV") { onTune(-1) }
                .frame(maxWidth: .infinity)

            // BURY reads at full contrast — the equal-and-opposite of BOOST, not
            // a dimmed afterthought. Up boosts, down buries; that's the whole vote.
            deckButton(icon: "arrow.down", label: "BURY", tint: HumanTheme.bone) {
                if let id = stream.nowPlaying?.track.id {
                    auth.requireSignIn(reason: "to bury this record") {
                        services.castMyVote(.bury, on: id)
                        Haptics.tap()
                    }
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                player.toggle()
                Haptics.tap()
            } label: {
                VStack(spacing: 8) {
                    ZStack {
                        // A raised orb: lit from the upper-left, dropped on its
                        // own glow + shadow so it reads as a physical button.
                        Circle().fill(
                            RadialGradient(
                                colors: player.isPlaying
                                    ? [HumanTheme.bone, Color(red: 0.78, green: 0.75, blue: 0.66)]
                                    : [Color(red: 1.0, green: 0.60, blue: 0.40), accent],
                                center: .init(x: 0.34, y: 0.30), startRadius: 3, endRadius: 66)
                        )
                        Ellipse().fill(.white.opacity(0.32))
                            .frame(width: 34, height: 18).blur(radius: 7)
                            .offset(x: -9, y: -19)
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 29, weight: .bold))
                            .foregroundStyle(HumanTheme.ink)
                            .offset(x: player.isPlaying ? 0 : 2)
                    }
                    .frame(width: 80, height: 80)
                    .shadow(color: (player.isPlaying ? HumanTheme.bone : accent).opacity(0.45), radius: 15, y: 5)
                    .shadow(color: .black.opacity(0.5), radius: 8, y: 8)
                    Text(player.isPlaying ? "ON AIR" : "TUNE IN")
                        .font(.custom("Archivo Black", size: 11))
                        .tracking(1.6)
                        .foregroundStyle(HumanTheme.bone.opacity(0.8))
                }
            }
            .buttonStyle(PressKey())
            .frame(maxWidth: .infinity)

            // Tap: boost. Hold: send it out to someone — radio's oldest ritual.
            deckButton(icon: "arrow.up", label: "BOOST", tint: accent) {
                if let id = stream.nowPlaying?.track.id {
                    auth.requireSignIn(reason: "to boost this record") {
                        services.castMyVote(.boost, on: id)
                        Haptics.boost()
                    }
                }
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    Haptics.detent()
                    onDedicate()
                }
            )
            .frame(maxWidth: .infinity)

            deckButton(icon: "chevron.right", label: "NEXT") { onTune(1) }
                .frame(maxWidth: .infinity)
        }

        // The one line that answers "what do these do?" — votes aren't skips;
        // they program the rotation. Persistent, so it survives past the tour.
        HStack(spacing: 6) {
            Image(systemName: "arrow.up").font(.system(size: 9, weight: .heavy)).foregroundStyle(accent)
            Text("BOOST").font(.custom("Archivo Black", size: 9)).tracking(1).foregroundStyle(HumanTheme.dim)
            Text("·").foregroundStyle(HumanTheme.dim)
            Image(systemName: "arrow.down").font(.system(size: 9, weight: .heavy)).foregroundStyle(HumanTheme.bone)
            Text("BURY").font(.custom("Archivo Black", size: 9)).tracking(1).foregroundStyle(HumanTheme.dim)
            Text("— YOU PROGRAM THE STATION").font(.custom("Archivo Black", size: 9)).tracking(0.6)
                .foregroundStyle(HumanTheme.dim.opacity(0.8))
        }
        .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    private func deckButton(
        icon: String, label: String,
        tint: Color = HumanTheme.bone,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 62, height: 62)
                    .background(DeckKey.raised)
                Text(label)
                    .font(.custom("Archivo Black", size: 11))
                    .tracking(1.4)
                    .foregroundStyle(HumanTheme.dim)
            }
        }
        .buttonStyle(PressKey())
    }
}

/// A raised physical key: warm dark face lit from above, hairline rim, a soft
/// top specular, dropped on a shadow. Vintage hi-fi button, modern and clean.
enum DeckKey {
    static var raised: some View {
        Circle()
            .fill(LinearGradient(
                colors: [Color(red: 0.17, green: 0.16, blue: 0.16),
                         Color(red: 0.07, green: 0.065, blue: 0.07)],
                startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(HumanTheme.bone.opacity(0.16), lineWidth: 1))
            .overlay(
                Ellipse().fill(HumanTheme.bone.opacity(0.14))
                    .frame(width: 32, height: 15).blur(radius: 6).offset(y: -15)
            )
            .shadow(color: .black.opacity(0.55), radius: 7, x: 0, y: 5)
    }
}

/// Press feedback: keys dip and settle, so the controls feel physical.
struct PressKey: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Listener profile

struct ProfileSheet: View {
    @ObservedObject var stream: LiveStreamService
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var auth: AuthService
    let accent: Color
    /// THE RING lives here now — a decisive top-bar declutter. Tapping it
    /// dismisses this sheet and opens battles.
    var onOpenRing: () -> Void = {}
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

            // Who you are on the air: signed in with Apple, or an anonymous
            // voice until the first time you act.
            HStack(spacing: 10) {
                Image(systemName: auth.isSignedIn ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(auth.isSignedIn ? accent : HumanTheme.dim)
                Text(auth.isSignedIn ? (auth.displayName.map { $0.uppercased() } ?? "SIGNED IN") : "ANONYMOUS VOICE")
                    .font(.custom("Archivo Black", size: 12))
                    .tracking(1.2)
                    .foregroundStyle(HumanTheme.bone)
                Spacer()
                if auth.isSignedIn {
                    Button { auth.signOut() } label: {
                        Text("SIGN OUT")
                            .font(.custom("Archivo Black", size: 10))
                            .tracking(1)
                            .foregroundStyle(HumanTheme.dim)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .overlay(Rectangle().strokeBorder(HumanTheme.bone.opacity(0.15), lineWidth: 1))

            // THE RING — song battles.
            Button(action: onOpenRing) {
                HStack {
                    Text("VS").font(.custom("Archivo Black", size: 16)).foregroundStyle(accent)
                    Text("THE RING · SONG BATTLES")
                        .font(.custom("Archivo Black", size: 12)).tracking(1.2)
                        .foregroundStyle(HumanTheme.bone)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(HumanTheme.dim)
                }
                .padding(.horizontal, 14).padding(.vertical, 14)
                .overlay(Rectangle().strokeBorder(HumanTheme.bone.opacity(0.15), lineWidth: 1))
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
                        .font(.custom("Archivo Black", size: 11))
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
                .font(.custom("Archivo Black", size: 11))
                .tracking(1.2)
                .foregroundStyle(HumanTheme.dim)
            Spacer()
            Text(value)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(HumanTheme.bone)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func hours(_ seconds: Double) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
