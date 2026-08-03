import SwiftUI
import RadioKit

/// BACKSTAGE — every door in the station, one obvious place. The top bar
/// stays four clean keys; everything else lives here with its real name and
/// one cold line about what it does. No mystery glyphs, no hidden long-press
/// rituals (the founder door still exists for the initiated — this is the
/// findable path).
struct BackstageSheet: View {
    enum Door {
        case dial, ring, line, aircheck, read, sleep, host, live, pd
    }

    let accent: Color
    let isHost: Bool
    let broadcasting: Bool
    var onOpen: (Door) -> Void = { _ in }
    var onClose: () -> Void = {}

    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)
    private let dim = Color(red: 0.55, green: 0.53, blue: 0.50)

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("BACKSTAGE")
                        .font(.custom("Gasoek One", size: 34))
                        .foregroundStyle(bone)
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(bone.opacity(0.7))
                            .frame(width: 40, height: 40)
                            .background(Circle().strokeBorder(bone.opacity(0.2), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 22).padding(.top, 20)

                ScrollView {
                    VStack(spacing: 10) {
                        if isHost {
                            row(.live, icon: "antenna.radiowaves.left.and.right",
                                name: broadcasting ? "ON AIR — CONSOLE" : "GO LIVE",
                                blurb: "Take the air. Camera or mic — every radio flips to you.",
                                lit: true)
                            row(.pd, icon: "slider.horizontal.3", name: "PD DESK",
                                blurb: "Premieres, drops, the schedule — the programmer's chair.")
                        }
                        row(.dial, icon: "dial.high.fill", name: "THE DIAL",
                            blurb: "Four stations. Swipe the room or pick one here.")
                        row(.ring, icon: "bolt.fill", name: "THE RING",
                            blurb: "Song battles. The crowd votes; the winner enters rotation.")
                        row(.line, icon: "phone.fill", name: "THE LINE",
                            blurb: "Call the station. Hold to talk — the host can put you on air.")
                        row(.aircheck, icon: "recordingtape", name: "HIT RECORD",
                            blurb: "Tape the moment off the air. Keep it, share it.")
                        row(.read, icon: "chart.bar.xaxis", name: "THE READ",
                            blurb: "What the room is feeling, record by record.")
                        row(.sleep, icon: "moon.fill", name: "SLEEP",
                            blurb: "Bedside clock, low ember, off-air timer.")
                        if !isHost {
                            row(.host, icon: "key.fill", name: "HOST ACCESS",
                                blurb: "Operators only. A key opens the console.")
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 30)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ door: Door, icon: String, name: String, blurb: String,
                     lit: Bool = false) -> some View {
        Button { onOpen(door) } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(lit ? ink : accent)
                    .frame(width: 46, height: 46)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(lit
                                  ? AnyShapeStyle(accent)
                                  : AnyShapeStyle(LinearGradient(
                                        colors: [Color(red: 0.17, green: 0.16, blue: 0.16),
                                                 Color(red: 0.07, green: 0.065, blue: 0.07)],
                                        startPoint: .top, endPoint: .bottom)))
                    )
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(bone.opacity(lit ? 0 : 0.14), lineWidth: 1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(name)
                        .font(.custom("Archivo Black", size: 14)).tracking(1)
                        .foregroundStyle(bone)
                    Text(blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(dim)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(dim.opacity(0.7))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 16).fill(.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .strokeBorder(bone.opacity(0.08), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
    }
}
