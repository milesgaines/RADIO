import SwiftUI
import RadioKit

// SOUND — the format you're listening on, as a thing you touch. Three devices
// stacked like gear on a shelf: a record that spins, a cassette whose reels
// turn, and a clean full-range emblem. Tap one to change how the station
// actually sounds (real DSP + surface noise under the music). The selected
// device runs while the radio plays.

struct SoundModeDeck: View {
    @ObservedObject var player: RadioPlayer
    let accent: Color
    let onClose: () -> Void

    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            // Warm bass glow, same room as the marquee.
            RadialGradient(colors: [accent.opacity(0.14), .clear],
                           center: .center, startRadius: 4, endRadius: 380)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Rectangle().fill(bone.opacity(0.15)).frame(height: 1)
                Spacer(minLength: 8)
                VStack(spacing: 16) {
                    ForEach(SoundMode.allCases, id: \.self) { mode in
                        deviceRow(mode)
                    }
                }
                Spacer()
                Text("SHAPES EVERY STATION · SURFACE NOISE RIDES OVER LIVE SHOWS TOO")
                    .font(.custom("Archivo Black", size: 9))
                    .tracking(1.2)
                    .foregroundStyle(bone.opacity(0.32))
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("SOUND")
                .font(.custom("Gasoek One", size: 30))
                .foregroundStyle(bone)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(bone.opacity(0.55))
                    .frame(width: 42, height: 42)
                    .overlay(Circle().strokeBorder(bone.opacity(0.2), lineWidth: 1))
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private func deviceRow(_ mode: SoundMode) -> some View {
        let selected = player.mode == mode
        return Button {
            player.setMode(mode)
            Haptics.detent()
        } label: {
            HStack(spacing: 18) {
                SoundDevice(mode: mode, accent: accent,
                            spinning: selected && player.isPlaying,
                            level: player.levels.rms)
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 5) {
                    Text(mode.title)
                        .font(.custom("Archivo Black", size: 20))
                        .tracking(2)
                        .foregroundStyle(selected ? accent : bone)
                    Text(mode.blurb)
                        .font(.custom("Archivo Black", size: 10))
                        .tracking(1)
                        .foregroundStyle(bone.opacity(0.45))
                }
                Spacer()
                ZStack {
                    Circle().strokeBorder(selected ? accent : bone.opacity(0.25), lineWidth: 2)
                        .frame(width: 24, height: 24)
                    if selected { Circle().fill(accent).frame(width: 12, height: 12) }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(LinearGradient(colors: selected
                        ? [accent.opacity(0.14), accent.opacity(0.04)]
                        : [bone.opacity(0.05), bone.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(selected ? accent.opacity(0.6) : bone.opacity(0.12), lineWidth: 1))
            )
        }
        .buttonStyle(PressKey())
    }
}

/// A single device, drawn and animated in a Canvas. Spins/turns while the
/// station plays on it.
private struct SoundDevice: View {
    let mode: SoundMode
    let accent: Color
    let spinning: Bool
    let level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40, paused: !spinning)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            Canvas { g, size in
                switch mode {
                case .hd: drawHD(g, size, t)
                case .vinyl: drawRecord(g, size, t)
                case .cassette: drawCassette(g, size, t)
                case .spatial: drawSpatial(g, size, t)
                }
            }
        }
    }

    private var bone: Color { Color(red: 0.945, green: 0.925, blue: 0.878) }

    // HD: the master, uncoloured. A crisp full-range waveform inside a clean
    // ring — no device, no artifact. It breathes with the music's level.
    private func drawHD(_ g: GraphicsContext, _ size: CGSize, _ t: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = min(size.width, size.height) / 2 - 2
        g.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                 with: .color(bone.opacity(0.18)), lineWidth: 1)
        let amp = r * 0.55 * CGFloat(0.30 + 0.70 * min(1, level * 1.4))
        var wave = Path()
        let steps = 72
        for i in 0...steps {
            let f = Double(i) / Double(steps)
            let x = c.x - r + CGFloat(f) * r * 2
            let phase = f * .pi * 4 + (spinning ? t * 3 : 0)
            let env = sin(f * .pi)                     // fade to nothing at the disc edge
            let y = c.y + CGFloat((sin(phase) * 0.7 + sin(phase * 2) * 0.3) * env) * amp
            if i == 0 { wave.move(to: CGPoint(x: x, y: y)) } else { wave.addLine(to: CGPoint(x: x, y: y)) }
        }
        g.stroke(wave, with: .color(bone.opacity(0.9)), lineWidth: 2)
        g.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(accent))
    }

    // A record: black disc, grooves, a colored label, spindle — turning at
    // 33⅓ feel (a slow, steady spin).
    private func drawRecord(_ g: GraphicsContext, _ size: CGSize, _ t: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let r = min(size.width, size.height) / 2 - 2
        g.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
               with: .radialGradient(Gradient(colors: [Color(white: 0.14), Color(white: 0.04)]),
                                     center: c, startRadius: 0, endRadius: r))
        // grooves
        for i in stride(from: 0.42, through: 0.92, by: 0.09) {
            let gr = r * i
            g.stroke(Path(ellipseIn: CGRect(x: c.x - gr, y: c.y - gr, width: gr * 2, height: gr * 2)),
                     with: .color(.white.opacity(0.05)), lineWidth: 1)
        }
        // label + a mark that rotates so the spin is visible
        let lr = r * 0.38
        g.fill(Path(ellipseIn: CGRect(x: c.x - lr, y: c.y - lr, width: lr * 2, height: lr * 2)),
               with: .color(accent))
        let angle = spinning ? t * 2.0 : 0
        let mark = CGPoint(x: c.x + cos(angle) * lr * 0.7, y: c.y + sin(angle) * lr * 0.7)
        g.fill(Path(ellipseIn: CGRect(x: mark.x - 2, y: mark.y - 2, width: 4, height: 4)),
               with: .color(.black.opacity(0.5)))
        // spindle
        g.fill(Path(ellipseIn: CGRect(x: c.x - 2.5, y: c.y - 2.5, width: 5, height: 5)),
               with: .color(Color(white: 0.1)))
    }

    // A cassette shell with two reels that turn.
    private func drawCassette(_ g: GraphicsContext, _ size: CGSize, _ t: Double) {
        let shell = CGRect(x: 4, y: size.height * 0.18, width: size.width - 8, height: size.height * 0.64)
        g.fill(Path(roundedRect: shell, cornerRadius: 6),
               with: .linearGradient(Gradient(colors: [Color(white: 0.18), Color(white: 0.08)]),
                                     startPoint: CGPoint(x: shell.minX, y: shell.minY),
                                     endPoint: CGPoint(x: shell.minX, y: shell.maxY)))
        g.stroke(Path(roundedRect: shell, cornerRadius: 6), with: .color(accent.opacity(0.7)), lineWidth: 1.5)
        // label strip
        let strip = CGRect(x: shell.minX + 8, y: shell.minY + 7, width: shell.width - 16, height: shell.height * 0.3)
        g.fill(Path(roundedRect: strip, cornerRadius: 2), with: .color(bone.opacity(0.85)))
        // two reels
        let ry = shell.midY + shell.height * 0.14
        let reelR = shell.height * 0.19
        for (i, rx) in [shell.midX - shell.width * 0.22, shell.midX + shell.width * 0.22].enumerated() {
            g.fill(Path(ellipseIn: CGRect(x: rx - reelR, y: ry - reelR, width: reelR * 2, height: reelR * 2)),
                   with: .color(Color(white: 0.05)))
            let angle = (spinning ? t * 3.0 : 0) + Double(i)
            for spoke in 0..<6 {
                let a = angle + Double(spoke) * .pi / 3
                var p = Path()
                p.move(to: CGPoint(x: rx, y: ry))
                p.addLine(to: CGPoint(x: rx + cos(a) * reelR, y: ry + sin(a) * reelR))
                g.stroke(p, with: .color(bone.opacity(0.5)), lineWidth: 1.5)
            }
            g.fill(Path(ellipseIn: CGRect(x: rx - 2, y: ry - 2, width: 4, height: 4)), with: .color(accent))
        }
    }

    // Spatial / 3D: a sound field. Concentric rings breathe outward from a
    // point source that orbits the listener at the center — the head — so the
    // emblem reads as sound placed *around* you, not bars on a screen.
    private func drawSpatial(_ g: GraphicsContext, _ size: CGSize, _ t: Double) {
        let c = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxR = min(size.width, size.height) / 2 - 3
        // Rings expanding outward, fading as they go — wavefronts leaving the head.
        let ringCount = 4
        for i in 0..<ringCount {
            let travel = (t * 0.5 + Double(i) / Double(ringCount)).truncatingRemainder(dividingBy: 1)
            let r = maxR * CGFloat(0.28 + 0.72 * travel)
            let fade = (1 - travel) * (spinning ? 1 : 0.4)
            g.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                     with: .color(accent.opacity(0.10 + 0.5 * fade)),
                     lineWidth: 1.5)
        }
        // The listener's head at the center.
        g.fill(Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)),
               with: .color(bone.opacity(0.9)))
        // A point source orbiting the head — the thing SPATIAL places in 3D.
        let orbit = maxR * 0.62
        let a = spinning ? t * 1.4 : -0.6
        let src = CGPoint(x: c.x + cos(a) * orbit, y: c.y + sin(a) * orbit * 0.5) // ellipse: depth
        // A soft glow behind the source so it reads as near/far as it orbits.
        g.fill(Path(ellipseIn: CGRect(x: src.x - 9, y: src.y - 9, width: 18, height: 18)),
               with: .radialGradient(Gradient(colors: [accent.opacity(0.55), .clear]),
                                     center: src, startRadius: 0, endRadius: 9))
        g.fill(Path(ellipseIn: CGRect(x: src.x - 3.5, y: src.y - 3.5, width: 7, height: 7)),
               with: .color(accent))
    }
}
