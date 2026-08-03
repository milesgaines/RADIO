import SwiftUI
import RadioKit

/// PD DESK — the Program Director's chair, in the product. Schedule a first
/// spin (the premiere lever), pull one back, arm and disarm station drops.
/// Reachable only with the operator key (staff sign-ins carry it silently);
/// listeners never see this door.
struct PDDeskSheet: View {
    @ObservedObject var stream: LiveStreamService
    @StateObject private var desk = PDService()
    let accent: Color
    var onClose: () -> Void = {}

    @State private var search = ""

    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)
    private let dim = Color(red: 0.55, green: 0.53, blue: 0.50)

    private var filtered: [PDService.CatalogTrack] {
        guard !search.isEmpty else { return desk.catalog }
        return desk.catalog.filter {
            $0.title.localizedCaseInsensitiveContains(search)
                || $0.artist.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("PD DESK")
                            .font(.custom("Gasoek One", size: 34))
                            .foregroundStyle(bone)
                        Text(stream.station.name.uppercased())
                            .font(.custom("Archivo Black", size: 11)).tracking(2)
                            .foregroundStyle(accent)
                    }
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

                if let note = desk.note {
                    Text(note)
                        .font(.custom("Archivo Black", size: 10)).tracking(1)
                        .foregroundStyle(accent)
                        .padding(.horizontal, 22).padding(.top, 8)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        // ── ON DECK ───────────────────────────────────────
                        VStack(alignment: .leading, spacing: 10) {
                            head("ON DECK")
                            if desk.pending.isEmpty {
                                Text("NOTHING SCHEDULED — THE CROWD RUNS THE ROTATION")
                                    .font(.custom("Archivo Black", size: 10)).tracking(0.8)
                                    .foregroundStyle(dim)
                            } else {
                                ForEach(desk.pending) { item in
                                    HStack(spacing: 12) {
                                        Circle().fill(accent).frame(width: 7, height: 7)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(.custom("Archivo Black", size: 13))
                                                .foregroundStyle(bone).lineLimit(1)
                                            Text("\(item.artist.uppercased()) · AIRS NEXT")
                                                .font(.custom("Archivo Black", size: 9)).tracking(1)
                                                .foregroundStyle(dim)
                                        }
                                        Spacer()
                                        chip("PULL") {
                                            Task { await desk.cancel(item, stationID: stream.station.id) }
                                        }
                                    }
                                }
                            }
                        }

                        // ── PREMIERE ──────────────────────────────────────
                        VStack(alignment: .leading, spacing: 10) {
                            head("PREMIERE A RECORD")
                            Text("First spin, scheduled — it jumps the crowd and airs next.")
                                .font(.system(size: 12)).foregroundStyle(dim)
                            TextField("", text: $search,
                                      prompt: Text("SEARCH THE CATALOG")
                                        .font(.custom("Archivo Black", size: 11)).tracking(1.5)
                                        .foregroundStyle(dim.opacity(0.7)))
                                .font(.custom("Archivo Black", size: 12))
                                .foregroundStyle(bone)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(.vertical, 8)
                            Rectangle().fill(bone.opacity(0.15)).frame(height: 1)
                            if !desk.loaded {
                                Text("PULLING THE CATALOG…")
                                    .font(.custom("Archivo Black", size: 10)).tracking(1.2)
                                    .foregroundStyle(dim)
                            } else if filtered.isEmpty {
                                Text(desk.catalog.isEmpty
                                     ? "NO SERVER CATALOG ON THIS STATION"
                                     : "NO MATCH")
                                    .font(.custom("Archivo Black", size: 10)).tracking(1)
                                    .foregroundStyle(dim)
                            } else {
                                ForEach(filtered.prefix(40)) { track in
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(track.title)
                                                .font(.custom("Archivo Black", size: 13))
                                                .foregroundStyle(bone).lineLimit(1)
                                            Text(track.artist.uppercased())
                                                .font(.custom("Archivo Black", size: 9)).tracking(1)
                                                .foregroundStyle(dim)
                                        }
                                        Spacer()
                                        chip("QUEUE", lit: true) {
                                            Task { await desk.premiere(track, stationID: stream.station.id) }
                                        }
                                    }
                                }
                                if filtered.count > 40 {
                                    Text("\(filtered.count - 40) MORE — KEEP TYPING")
                                        .font(.custom("Archivo Black", size: 9)).tracking(1)
                                        .foregroundStyle(dim.opacity(0.7))
                                }
                            }
                        }

                        // ── DROPS ─────────────────────────────────────────
                        VStack(alignment: .leading, spacing: 10) {
                            head("STATION DROPS")
                            Text("Armed drops air between records on the drop cadence.")
                                .font(.system(size: 12)).foregroundStyle(dim)
                            if desk.drops.isEmpty {
                                Text("NO DROPS CUT YET — THE STATION SPEAKS WHEN YOU GIVE IT A VOICE")
                                    .font(.custom("Archivo Black", size: 10)).tracking(0.8)
                                    .foregroundStyle(dim)
                            } else {
                                ForEach(desk.drops) { drop in
                                    HStack(spacing: 12) {
                                        Text(drop.title)
                                            .font(.custom("Archivo Black", size: 13))
                                            .foregroundStyle(drop.active ? bone : dim)
                                            .lineLimit(1)
                                        Spacer()
                                        chip(drop.active ? "ARMED" : "OFF", lit: drop.active) {
                                            Task { await desk.setDrop(drop, active: !drop.active,
                                                                      stationID: stream.station.id) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 30)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await desk.refresh(stationID: stream.station.id) }
    }

    private func head(_ title: String) -> some View {
        Text(title)
            .font(.custom("Archivo Black", size: 11)).tracking(2)
            .foregroundStyle(accent)
    }

    private func chip(_ label: String, lit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.custom("Archivo Black", size: 10)).tracking(1)
                .foregroundStyle(lit ? ink : bone.opacity(0.75))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Rectangle().fill(lit ? accent : .clear))
                .overlay(Rectangle().strokeBorder(
                    (lit ? accent : bone).opacity(lit ? 0 : 0.3), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
