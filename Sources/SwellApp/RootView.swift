import SwiftUI
import RadioKit

// MARK: - RADIO
// The station is a vibrating plate. Thousands of sand grains crawl across it
// and settle onto the nodal lines of a Chladni resonance figure — the shape
// a real steel plate makes when you bow it at a frequency. The figure is
// driven by the ACTUAL audio of the track (bass and treble bend the mode,
// every kick scatters the sand and it re-crystallizes), so every song has
// its own emergent shape and the whole screen breathes with the music.
//
// Flick up to boost (the plate flares the station color and the sand leaps),
// flick down to bury (it collapses), swipe to tune (the figure morphs to the
// next station's), tap to play. No cards, no panels, no buttons.

struct RootView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var player: RadioPlayer

    var body: some View {
        PlateView(stream: services.activeStream)
            .preferredColorScheme(.dark)
            .persistentSystemOverlays(.hidden)
    }
}

private struct PlateView: View {
    @ObservedObject var stream: LiveStreamService
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var player: RadioPlayer

    @State private var plate = CymaticPlate()
    @State private var showHints = true
    @State private var stationFlash: String?

    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)

    private var accentIndex: Int {
        services.streams.firstIndex(where: { $0 === stream }) ?? 0
    }
    private var accent: Color { CymaticPlate.accents[accentIndex % CymaticPlate.accents.count] }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ink.ignoresSafeArea()

                TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                    Canvas { canvas, size in
                        plate.stepAndDraw(in: canvas, size: size, date: context.date)
                    }
                    .ignoresSafeArea()
                    .drawingGroup()
                }

                // Bottom scrim so type reads over the densest sand — a wash,
                // not a card.
                LinearGradient(
                    colors: [.clear, ink.opacity(0.7), ink],
                    startPoint: .center, endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                chrome(in: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(gestures(in: geo.size))
            .onAppear {
                plate.configure(size: geo.size)
                sync()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    withAnimation(.easeOut(duration: 1.2)) { showHints = false }
                }
            }
            .onChange(of: stream.nowPlaying?.track.id) { sync() }
            .onChange(of: player.isPlaying) { plate.isPlaying = player.isPlaying }
            .onChange(of: player.levels) { _, new in plate.levels = new }
        }
    }

    private func sync() {
        plate.accentIndex = accentIndex
        plate.isPlaying = player.isPlaying
        if let title = stream.nowPlaying?.track.title { plate.setFigure(for: title) }
    }

    // Whisper-thin type at the edges. Everything else is sand.
    private func chrome(in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("RADIO")
                    .font(.custom("Gasoek One", size: 22))
                    .foregroundStyle(bone)
                Spacer()
                HStack(spacing: 6) {
                    if player.isPlaying {
                        Circle().fill(accent).frame(width: 6, height: 6)
                    }
                    Text(player.isPlaying
                         ? "LIVE · \(stream.nowPlaying?.liveListeners ?? 1)"
                         : "RESTING")
                        .font(.custom("Archivo Black", size: 12))
                        .tracking(1)
                        .foregroundStyle(bone.opacity(0.6))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)

            Spacer()

            if let np = stream.nowPlaying {
                Text(np.track.title)
                    .font(.custom("Gasoek One", size: heroSize(np.track.title)))
                    .foregroundStyle(bone)
                    .lineLimit(2)
                    .minimumScaleFactor(0.5)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: ink.opacity(0.6), radius: 12)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.5), value: np.track.id)

                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(np.track.artistName)
                        .font(.custom("Instrument Serif", size: 24))
                        .foregroundStyle(bone.opacity(0.7))
                    if np.boostScore != 0 {
                        Text(np.boostScore > 0 ? "▲ \(np.boostScore)" : "▼ \(-np.boostScore)")
                            .font(.custom("Archivo Black", size: 13))
                            .foregroundStyle(np.boostScore > 0 ? accent : bone.opacity(0.4))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.snappy, value: np.boostScore)
                    }
                }

                HStack(spacing: 8) {
                    Text(stream.station.name.uppercased())
                        .font(.custom("Archivo Black", size: 12))
                        .tracking(1.5)
                        .foregroundStyle(accent)
                    Text("· \(accentIndex + 1)/\(services.streams.count)")
                        .font(.custom("Archivo Black", size: 12))
                        .foregroundStyle(bone.opacity(0.3))
                    if let album = np.track.albumTitle {
                        Text("· \(album.uppercased())")
                            .font(.custom("Archivo Black", size: 11))
                            .foregroundStyle(bone.opacity(0.3))
                            .lineLimit(1)
                    }
                }
                .padding(.top, 2)
            }

            if showHints {
                Text("flick ↑ boost   ↓ bury   ← → tune   tap play")
                    .font(.custom("Instrument Serif", size: 18))
                    .foregroundStyle(bone.opacity(0.4))
                    .padding(.top, 10)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.bottom, 22)
        .overlay {
            if let name = stationFlash {
                Text(name.uppercased())
                    .font(.custom("Gasoek One", size: 40))
                    .foregroundStyle(accent)
                    .shadow(color: ink, radius: 20)
                    .transition(.scale(scale: 1.1).combined(with: .opacity))
                    .id(name)
            }
        }
        .allowsHitTesting(false)
    }

    private func heroSize(_ title: String) -> CGFloat {
        switch title.count {
        case 0...8: return 68
        case 9...14: return 52
        case 15...22: return 40
        default: return 32
        }
    }

    // MARK: Gestures — the whole plate is the control surface

    private func gestures(in size: CGSize) -> some Gesture {
        let swipe = DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if abs(dx) > abs(dy) {
                    tune(dx < 0 ? 1 : -1)
                } else if dy < -30 {
                    vote(.boost)
                } else if dy > 30 {
                    vote(.bury)
                }
            }
        let tap = TapGesture().onEnded {
            player.toggle()
            plate.isPlaying = player.isPlaying
            Haptics.tap()
        }
        return swipe.exclusively(before: tap)
    }

    private func vote(_ direction: VoteDirection) {
        guard let id = stream.nowPlaying?.track.id else { return }
        stream.vote(direction, on: id)
        if direction == .boost {
            plate.strike()
            Haptics.boost()
        } else {
            plate.collapse()
            Haptics.tap()
        }
    }

    private func tune(_ direction: Int) {
        let streams = services.streams
        let next = (accentIndex + direction + streams.count) % streams.count
        services.tune(to: streams[next].station)
        let name = streams[next].station.name
        withAnimation(.easeIn(duration: 0.2)) { stationFlash = name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if stationFlash == name { withAnimation(.easeOut(duration: 0.7)) { stationFlash = nil } }
        }
        Haptics.detent()
    }
}

// MARK: - The Chladni plate

/// A sand-on-vibrating-plate simulation. Grains descend the gradient of the
/// mode-shape magnitude toward the nodal lines (where the plate is still) and
/// get kicked by jitter proportional to the local vibration times the live
/// audio excitation. Loud transients scatter the figure; quiet passages let
/// it crystallize. Pure function of its own state — stepped in the render
/// loop, so SwiftUI state never churns per frame.
@MainActor
final class CymaticPlate {
    static let accents: [Color] = [
        Color(red: 1.00, green: 0.36, blue: 0.18), // ember   — station 1
        Color(red: 0.30, green: 0.72, blue: 1.00), // ice     — station 2
        Color(red: 0.36, green: 0.92, blue: 0.53), // acid    — station 3
        Color(red: 0.86, green: 0.44, blue: 1.00), // orchid  — overflow
    ]

    var accentIndex = 0
    var isPlaying = false
    var levels: AudioLevels = .zero

    private struct Grain { var x: Double; var y: Double; var bright: Double }
    private var grains: [Grain] = []
    private var size: CGSize = .zero
    private var lastStep: Date?

    // Mode shape s(x,y) = cos(nπx)cos(mπy) − cos(mπx)cos(nπy). n,m ease
    // toward per-track targets, bent live by the audio bands.
    private var n = 4.0, m = 3.0
    private var targetN = 4.0, targetM = 3.0
    private var baseN = 4.0, baseM = 3.0

    private var strikeUntil: Date = .distantPast
    private var collapseUntil: Date = .distantPast

    private let grainCount = 3400

    func configure(size: CGSize) {
        self.size = size
        guard grains.isEmpty else { return }
        grains = (0..<grainCount).map { _ in
            Grain(x: Double.random(in: 0...1), y: Double.random(in: 0...1), bright: 0)
        }
    }

    /// Each track gets a signature figure from a hash of its title.
    func setFigure(for title: String) {
        var h = UInt64(0xcbf29ce484222325)
        for b in title.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        baseN = 3 + Double(h % 6)            // 3…8
        baseM = 2 + Double((h >> 8) % 6)     // 2…7
        if abs(baseN - baseM) < 1 { baseM += 2 } // avoid degenerate figures
    }

    func strike() { strikeUntil = Date().addingTimeInterval(0.9) }
    func collapse() { collapseUntil = Date().addingTimeInterval(0.8) }

    func stepAndDraw(in canvas: GraphicsContext, size: CGSize, date: Date) {
        if self.size != size { self.size = size }
        let dt = min(lastStep.map { date.timeIntervalSince($0) } ?? 1.0 / 60, 1.0 / 24)
        lastStep = date

        let bass = Double(levels.bass), treble = Double(levels.treble), rms = Double(levels.rms)
        let striking = date < strikeUntil
        let collapsing = date < collapseUntil

        // Audio bends the mode: bass raises n, treble raises m. The figure
        // literally re-tunes to the music.
        targetN = baseN + bass * 3
        targetM = baseM + treble * 3
        let ease = 1 - pow(0.05, dt)
        n += (targetN - n) * ease
        m += (targetM - m) * ease

        // Excitation: silence freezes the figure; loudness makes it dance.
        var excite = isPlaying ? 0.10 + rms * 1.7 : 0.0
        if striking { excite += 1.4 }
        let converge = collapsing ? 0.0 : 0.0038 * (dt * 60)  // gradient pull
        let jitter = excite * 0.05 * (dt * 60)
        let crawl = 0.0022 * (dt * 60) * (isPlaying ? 1 : 0.1)

        let piN = n * .pi, piM = m * .pi
        for i in grains.indices {
            var g = grains[i]

            let cnx = cos(piN * g.x), cmx = cos(piM * g.x)
            let cny = cos(piN * g.y), cmy = cos(piM * g.y)
            let s = cnx * cny - cmx * cmy

            // Analytic gradient of s — used both to descend toward the
            // nodal line and to crawl along it.
            let snx = sin(piN * g.x), smx = sin(piM * g.x)
            let sny = sin(piN * g.y), smy = sin(piM * g.y)
            let gx = -piN * snx * cny + piM * smx * cmy
            let gy = -piM * cnx * smy + piN * cmx * sny
            let gmag = (gx * gx + gy * gy).squareRoot()

            if converge > 0, gmag > 1e-4 {
                let sign = s >= 0 ? 1.0 : -1.0
                // Overshoot guard: never step past the line in one frame.
                let step = min(converge, abs(s) / gmag)
                g.x -= step * sign * gx / gmag
                g.y -= step * sign * gy / gmag

                // Tangential crawl: sand keeps redistributing ALONG the
                // line (perpendicular to the gradient), so figures stay
                // fully traced instead of clumping into piles.
                let dir = rand(i, date, 2) < 0.5 ? 1.0 : -1.0
                g.x += dir * crawl * (-gy / gmag) * (rand(i, date, 3) * 0.8 + 0.2)
                g.y += dir * crawl * (gx / gmag) * (rand(i, date, 3) * 0.8 + 0.2)
            }

            if collapsing {
                // Bury: sand slides to the plate's rim and piles up.
                g.x += (g.x - 0.5) * 1.2 * dt
                g.y += (g.y - 0.5) * 1.2 * dt
            }

            // Vibration jitter — strongest at antinodes, but never zero:
            // even settled sand shivers, which is what keeps it alive.
            let vib = jitter * (0.18 + abs(s))
            g.x += (rand(i, date, 0) - 0.5) * vib
            g.y += (rand(i, date, 1) - 0.5) * vib

            // Reflect off the plate edges.
            if g.x < 0 { g.x = -g.x }; if g.x > 1 { g.x = 2 - g.x }
            if g.y < 0 { g.y = -g.y }; if g.y > 1 { g.y = 2 - g.y }
            g.x = min(max(g.x, 0), 1); g.y = min(max(g.y, 0), 1)

            // Settled grains (near a nodal line) shine; wandering ones fade.
            let target = 1 - min(1, abs(s) * 1.6)
            g.bright += (target - g.bright) * min(1, dt * 6)
            grains[i] = g
        }

        draw(canvas: canvas, size: size, bass: bass, striking: striking)
    }

    private func draw(canvas: GraphicsContext, size: CGSize, bass: Double, striking: Bool) {
        let bone = Color(red: 0.965, green: 0.945, blue: 0.9)
        let accent = Self.accents[accentIndex % Self.accents.count]
        // On bass hits and boosts, the settled figure glows the station color.
        let accentMix = min(1, bass * 0.7 + (striking ? 0.6 : 0))

        for g in grains {
            let p = CGPoint(x: g.x * size.width, y: g.y * size.height)
            let settled = g.bright
            let alpha = 0.22 + settled * 0.75
            let color = accentMix > 0.02
                ? bone.mix(with: accent, by: accentMix * settled)
                : bone
            let r = 0.8 + settled * 1.0
            canvas.fill(
                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                with: .color(color.opacity(alpha))
            )
        }
    }

    /// Cheap per-grain, per-frame pseudo-random in 0…1 (no allocation, no
    /// shared RNG state across the hot loop).
    private func rand(_ i: Int, _ date: Date, _ salt: Int) -> Double {
        var h = UInt64(bitPattern: Int64(i &* 2654435761))
        h ^= UInt64(bitPattern: Int64(date.timeIntervalSinceReferenceDate * 1000)) &* 0x9E3779B97F4A7C15
        h ^= UInt64(salt &* 40503)
        h = (h ^ (h >> 27)) &* 0x94D049BB133111EB
        h ^= h >> 31
        return Double(h % 100000) / 100000
    }
}

private extension Color {
    /// Linear-ish blend in sRGB — good enough for grain tinting.
    func mix(with other: Color, by t: Double) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var ar: CGFloat = 0, ag: CGFloat = 0, ab: CGFloat = 0, aa: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        a.getRed(&ar, green: &ag, blue: &ab, alpha: &aa)
        b.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        let f = CGFloat(min(max(t, 0), 1))
        return Color(red: ar + (br - ar) * f, green: ag + (bg - ag) * f, blue: ab + (bb - ab) * f)
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func boost() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func detent() { UISelectionFeedbackGenerator().selectionChanged() }
}
