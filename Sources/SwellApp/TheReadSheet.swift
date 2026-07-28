import SwiftUI
import RadioKit

// THE READ — the station's live audience research, made visible. RADI0's votes
// and tune-in/tune-out are a real-time resonance signal (a "PPM for music"); this
// panel ranks what's resonating right now, sliced by market, with a generated
// A&R read per record. Honest by construction: markets are seeded locally until
// the geo backend lands, and the A&R line is labeled GENERATED.

struct TheReadSheet: View {
    @ObservedObject var service: TheReadService
    let station: Station
    let accent: Color
    let onClose: () -> Void

    private let ink = HumanTheme.ink
    private let bone = HumanTheme.bone

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            RadialGradient(colors: [accent.opacity(0.14), .clear],
                           center: .top, startRadius: 4, endRadius: 420)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                marketBar
                Text("MARKETS SEEDED LOCALLY · GEO BACKEND PENDING")
                    .font(.custom("Archivo Black", size: 8))
                    .tracking(1.1)
                    .foregroundStyle(bone.opacity(0.3))
                    .padding(.top, 8).padding(.bottom, 12)
                Rectangle().fill(bone.opacity(0.15)).frame(height: 1)

                if service.readouts.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(service.readouts) { row in
                                readoutRow(row)
                            }
                        }
                        .padding(.top, 14)
                        .padding(.bottom, 28)
                    }
                }
            }
            .padding(.horizontal, 22)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("THE READ")
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
            Text("LIVE AUDIENCE RESEARCH · WHAT'S RESONATING RIGHT NOW")
                .font(.custom("Archivo Black", size: 9))
                .tracking(1.0)
                .foregroundStyle(accent.opacity(0.9))
        }
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    // MARK: Market selector

    private var marketBar: some View {
        HStack(spacing: 6) {
            ForEach(service.markets) { m in
                let selected = m == service.market
                Button {
                    service.select(m)
                    Haptics.detent()
                } label: {
                    Text(m.code)
                        .font(.custom("Archivo Black", size: 13))
                        .tracking(1)
                        .foregroundStyle(selected ? ink : bone.opacity(0.8))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(selected
                                      ? LinearGradient(colors: [accent, accent.opacity(0.85)],
                                                       startPoint: .top, endPoint: .bottom)
                                      : LinearGradient(colors: [bone.opacity(0.06), bone.opacity(0.03)],
                                                       startPoint: .top, endPoint: .bottom))
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(selected ? .clear : bone.opacity(0.14), lineWidth: 1))
                        )
                }
                .buttonStyle(PressKey())
            }
        }
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(bone.opacity(0.3))
            Text("LISTENING FOR THE ROOM")
                .font(.custom("Archivo Black", size: 12))
                .tracking(1.4)
                .foregroundStyle(bone.opacity(0.5))
            Text("As the crowd votes and tunes in, records rise and fall here.")
                .font(.custom("Archivo Black", size: 9))
                .tracking(0.4)
                .foregroundStyle(bone.opacity(0.3))
                .multilineTextAlignment(.center)
            Spacer(); Spacer()
        }
        .padding(.horizontal, 20)
    }

    // MARK: A record's row

    private func readoutRow(_ r: TrackReadout) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                Text("\(r.rank)")
                    .font(.custom("Gasoek One", size: 20))
                    .foregroundStyle(bone.opacity(0.35))
                    .frame(minWidth: 22, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.title)
                        .font(.custom("Archivo Black", size: 15))
                        .foregroundStyle(bone)
                        .lineLimit(1)
                    Text(r.artist)
                        .font(.custom("Archivo Black", size: 9))
                        .tracking(0.6)
                        .foregroundStyle(bone.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer()
                trendArrow(r.trend)
                statusChip(r.status)
            }

            resonanceMeter(r.resonance01)

            HStack(spacing: 14) {
                metric("VOTE", signed: r.velocity)
                metric("LOVE", unit: r.density)
                metric("HOLD", unit: r.retention)
            }

            HStack(alignment: .top, spacing: 6) {
                Text("A&R")
                    .font(.custom("Archivo Black", size: 8))
                    .tracking(1)
                    .foregroundStyle(accent.opacity(0.9))
                    .padding(.top, 1)
                Text(r.arLine)
                    .font(.custom("Archivo Black", size: 9))
                    .tracking(0.2)
                    .foregroundStyle(bone.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(r.status == .breaking
                      ? LinearGradient(colors: [accent.opacity(0.12), accent.opacity(0.03)],
                                       startPoint: .top, endPoint: .bottom)
                      : LinearGradient(colors: [bone.opacity(0.05), bone.opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(r.status == .breaking ? accent.opacity(0.5) : bone.opacity(0.1), lineWidth: 1))
        )
    }

    // The resonance meter: a 0…1 bar with a neutral tick at the middle, so a
    // record reads as above or below the room at a glance.
    private func resonanceMeter(_ v: Double) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(bone.opacity(0.1))
                Capsule()
                    .fill(LinearGradient(colors: [bone.opacity(0.7), accent],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(3, w * CGFloat(min(1, max(0, v)))))
                // neutral (0.5) tick
                Rectangle().fill(bone.opacity(0.3))
                    .frame(width: 1, height: 10)
                    .offset(x: w * 0.5)
            }
        }
        .frame(height: 8)
    }

    private func trendArrow(_ t: ResonanceTrend) -> some View {
        let (name, color): (String, Color) = {
            switch t {
            case .up:   return ("arrow.up.right", accent)
            case .flat: return ("minus", bone.opacity(0.4))
            case .down: return ("arrow.down.right", Color(red: 0.85, green: 0.4, blue: 0.35))
            }
        }()
        return Image(systemName: name)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(color)
    }

    private func statusChip(_ s: ResonanceStatus) -> some View {
        let (label, fg, bg): (String, Color, Color) = {
            switch s {
            case .breaking:   return ("BREAKING", ink, accent)
            case .inRotation: return ("IN ROTATION", bone.opacity(0.85), bone.opacity(0.1))
            case .cooling:    return ("COOLING", Color(red: 0.9, green: 0.6, blue: 0.3), Color(red: 0.9, green: 0.6, blue: 0.3).opacity(0.14))
            case .benched:    return ("BENCHED", bone.opacity(0.45), bone.opacity(0.06))
            }
        }()
        return Text(label)
            .font(.custom("Archivo Black", size: 8))
            .tracking(0.8)
            .foregroundStyle(fg)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(bg))
    }

    // A small labeled metric. `signed` values (velocity, [-1,1]) show +/-;
    // `unit` values ([0,1]) show a plain percent.
    private func metric(_ label: String, signed: Double? = nil, unit: Double? = nil) -> some View {
        let value: String = {
            if let s = signed { return (s >= 0 ? "+" : "") + "\(Int((s * 100).rounded()))" }
            if let u = unit { return "\(Int((u * 100).rounded()))" }
            return "—"
        }()
        return HStack(spacing: 4) {
            Text(label)
                .font(.custom("Archivo Black", size: 8))
                .tracking(0.8)
                .foregroundStyle(bone.opacity(0.4))
            Text(value)
                .font(.custom("Archivo Black", size: 10))
                .foregroundStyle(bone.opacity(0.8))
                .monospacedDigit()
        }
    }
}
