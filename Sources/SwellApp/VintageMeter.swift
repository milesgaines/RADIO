import SwiftUI

/// Vintage hardware, drawn — no assets. A brushed-metal faceplate, corner
/// screws, and a real analog VU meter whose needle swings on the live audio.
/// Vintage in the materials, modern in that every one of them is alive.

/// An analog VU meter: cream face, black scale with a red overload zone, a
/// thin needle on a brass pivot, an amber tungsten lamp that glows when the
/// signal's hot. The needle carries real ballistics (a damped follower) so it
/// swings and settles like the real thing instead of snapping.
struct VUMeter: View {
    /// Live signal, 0…1.
    var level: Double
    var accent: Color
    var label: String = "VU"

    @State private var needle: Double = 0     // smoothed, ballistic

    private let face = Color(red: 0.90, green: 0.86, blue: 0.74)   // aged cream
    private let faceEdge = Color(red: 0.74, green: 0.69, blue: 0.55)
    private let ink = Color(red: 0.10, green: 0.09, blue: 0.07)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { _ in
            Canvas { ctx, size in
                let w = size.width, h = size.height
                // Deep, wide meter well.
                let plate = Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h),
                                 cornerRadius: 7)
                ctx.fill(plate, with: .linearGradient(
                    Gradient(colors: [face, faceEdge]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: h)))
                ctx.stroke(plate, with: .color(ink.opacity(0.55)), lineWidth: 1)

                // The scale sweeps around a pivot below the bottom edge.
                let pivot = CGPoint(x: w * 0.5, y: h * 1.28)
                let radius = h * 1.06
                let span = 46.0 * .pi / 180        // ±46° sweep
                func pt(_ t: Double, _ r: Double) -> CGPoint {
                    let a = -Double.pi / 2 + (t - 0.5) * 2 * span
                    return CGPoint(x: pivot.x + sin(a) * r, y: pivot.y - cos(a) * r)
                }
                // Arc ticks; the top ~22% is the red overload zone.
                for i in 0...10 {
                    let t = Double(i) / 10
                    let major = i % 5 == 0
                    var tick = Path()
                    tick.move(to: pt(t, radius))
                    tick.addLine(to: pt(t, radius - (major ? h * 0.15 : h * 0.09)))
                    ctx.stroke(tick, with: .color(t >= 0.78 ? Color(red: 0.75, green: 0.12, blue: 0.09)
                                                             : ink.opacity(0.8)),
                               lineWidth: major ? 2 : 1)
                }
                // Red overload arc along the top.
                var red = Path()
                let steps = 16
                for k in 0...steps {
                    let t = 0.78 + 0.22 * Double(k) / Double(steps)
                    let p = pt(t, radius + 1)
                    k == 0 ? red.move(to: p) : red.addLine(to: p)
                }
                ctx.stroke(red, with: .color(Color(red: 0.75, green: 0.12, blue: 0.09)), lineWidth: 2)

                // The needle — ballistic `needle`, not raw level.
                let np = pt(needle, radius - h * 0.02)
                var arm = Path()
                arm.move(to: CGPoint(x: pivot.x, y: pivot.y))
                arm.addLine(to: np)
                ctx.stroke(arm, with: .color(ink), lineWidth: 1.6)
                // Brass pivot cap.
                let cap = CGRect(x: pivot.x - 5, y: pivot.y - 5, width: 10, height: 10)
                ctx.fill(Path(ellipseIn: cap), with: .radialGradient(
                    Gradient(colors: [Color(red: 0.85, green: 0.68, blue: 0.36),
                                      Color(red: 0.45, green: 0.34, blue: 0.14)]),
                    center: CGPoint(x: pivot.x - 1.5, y: pivot.y - 1.5),
                    startRadius: 0, endRadius: 7))

                // "VU" engraved, and a tungsten pilot lamp that warms when hot.
                ctx.draw(Text(label).font(.custom("Archivo Black", size: 9)).foregroundColor(ink.opacity(0.7)),
                         at: CGPoint(x: w * 0.5, y: h * 0.46))
                let lampHot = needle > 0.72
                let lamp = CGRect(x: w - 16, y: h - 15, width: 8, height: 8)
                ctx.fill(Path(ellipseIn: lamp), with: .color(
                    lampHot ? accent : Color(red: 0.35, green: 0.16, blue: 0.10)))
                if lampHot {
                    ctx.fill(Path(ellipseIn: lamp.insetBy(dx: -3, dy: -3)),
                             with: .color(accent.opacity(0.35)))
                }
            }
            .onChange(of: tickTarget) { _, target in
                // VU ballistics: quick rise, slower fall — the needle chases.
                let rate = target > needle ? 0.5 : 0.12
                needle += (target - needle) * rate
            }
        }
        .drawingGroup()
    }

    // A settle target the TimelineView samples each frame via onChange.
    private var tickTarget: Double { max(0, min(1, level)) }
}

/// Brushed-aluminum faceplate: a warm graphite panel with fine horizontal
/// brush lines, a top-bevel highlight, and a recessed inner edge — the front
/// of a vintage receiver.
struct BrushedFaceplate: View {
    var cornerRadius: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(LinearGradient(
                colors: [Color(red: 0.20, green: 0.195, blue: 0.185),
                         Color(red: 0.115, green: 0.11, blue: 0.10)],
                startPoint: .top, endPoint: .bottom))
            // Brushed grain.
            .overlay(Canvas { ctx, size in
                for i in stride(from: 0, to: Int(size.height), by: 2) {
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: Double(i)))
                    line.addLine(to: CGPoint(x: size.width, y: Double(i)))
                    let o = (i % 4 == 0) ? 0.05 : 0.02
                    ctx.stroke(line, with: .color(.white.opacity(o)), lineWidth: 0.5)
                }
            }.clipShape(shape))
            // Top-bevel highlight + recessed rim.
            .overlay(alignment: .top) {
                shape.inset(by: 1).stroke(
                    LinearGradient(colors: [.white.opacity(0.22), .clear],
                                   startPoint: .top, endPoint: .center),
                    lineWidth: 1.2)
            }
            .overlay(shape.strokeBorder(.black.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 12, y: 7)
    }
}

/// A tiny slotted metal screw for the faceplate corners.
struct Screw: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(
                colors: [Color(white: 0.42), Color(white: 0.13)],
                center: .init(x: 0.35, y: 0.32), startRadius: 0, endRadius: 7))
            .overlay(Circle().strokeBorder(.black.opacity(0.6), lineWidth: 0.5))
            .overlay(
                Rectangle().fill(.black.opacity(0.55))
                    .frame(width: 8, height: 1.4)
                    .rotationEffect(.degrees(35))
            )
            .frame(width: 11, height: 11)
            .shadow(color: .black.opacity(0.5), radius: 1, y: 0.5)
    }
}
