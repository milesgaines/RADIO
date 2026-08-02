import SwiftUI
import RadioKit

/// THE DIAL — the whole lineup on one card. Every station: its call, its name,
/// what it's for, and what's on it right now. Tap a row to tune. This is the
/// map the swipe gesture never gave newcomers: before this sheet the only way
/// to learn the dial was to blind-swipe through it.
struct TheDialSheet: View {
    /// All four always-on streams, in dial order.
    let streams: [LiveStreamService]
    let activeID: UUID
    let accent: Color
    var onTune: (Station) -> Void = { _ in }
    var onClose: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Text("THE DIAL")
                    .font(.custom("Gasoek One", size: 30))
                    .foregroundStyle(bone)
                Spacer()
                Button { dismiss(); onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(bone.opacity(0.55))
                        .frame(width: 38, height: 38)
                        .background(Circle().strokeBorder(bone.opacity(0.2), lineWidth: 1))
                }
            }

            Text("FOUR STATIONS · ALWAYS ON · TAP TO TUNE")
                .font(.custom("Archivo Black", size: 12)).tracking(1.4)
                .foregroundStyle(bone.opacity(0.55))

            VStack(spacing: 12) {
                ForEach(Array(streams.enumerated()), id: \.element.station.id) { index, stream in
                    row(stream, accent: Self.accentFor(index))
                }
            }

            Spacer()

            Text("◂ ▸ SWIPING THE BIG NUMBER TUNES TOO")
                .font(.custom("Archivo Black", size: 10)).tracking(1.2)
                .foregroundStyle(bone.opacity(0.35))
                .frame(maxWidth: .infinity)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    /// One station on the card: call number in its room color, name, tagline,
    /// and the record on it right now. The tuned row carries the needle.
    private func row(_ stream: LiveStreamService, accent rowAccent: Color) -> some View {
        let station = stream.station
        let tuned = station.id == activeID
        return Button {
            onTune(station)
            dismiss(); onClose()
        } label: {
            HStack(spacing: 16) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(station.dial)
                        .font(.custom("Gasoek One", size: 30))
                        .foregroundStyle(rowAccent)
                        .lineLimit(1).minimumScaleFactor(0.6)
                    if !station.dialUnit.isEmpty {
                        Text(station.dialUnit)
                            .font(.custom("Archivo Black", size: 9)).tracking(1.2)
                            .foregroundStyle(bone.opacity(0.45))
                    }
                }
                .frame(width: 84, alignment: .trailing)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(station.name.uppercased())
                            .font(.custom("Archivo Black", size: 15)).tracking(1.2)
                            .foregroundStyle(bone)
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if station.isFlagship {
                            Text("24/7")
                                .font(.custom("Archivo Black", size: 9)).tracking(1)
                                .foregroundStyle(ink)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(rowAccent))
                        }
                    }
                    if let np = stream.nowPlaying {
                        Text("● \(np.track.title) — \(np.track.artistName)")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(rowAccent.opacity(0.9))
                            .lineLimit(1)
                    } else {
                        Text(station.tagline)
                            .font(.system(size: 12))
                            .foregroundStyle(bone.opacity(0.5))
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if tuned {
                    Text("TUNED")
                        .font(.custom("Archivo Black", size: 10)).tracking(1.2)
                        .foregroundStyle(rowAccent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(bone.opacity(0.3))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(tuned ? rowAccent.opacity(0.10) : bone.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(tuned ? rowAccent.opacity(0.7) : bone.opacity(0.10),
                                  lineWidth: tuned ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Room colors, in dial order — the same accents the plate recolors with,
    /// so the card and the room always agree.
    private static func accentFor(_ index: Int) -> Color {
        CymaticPlate.accents[index % CymaticPlate.accents.count]
    }
}
