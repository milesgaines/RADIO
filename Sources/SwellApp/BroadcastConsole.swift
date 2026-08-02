import SwiftUI
import RadioKit

// MARK: - GO LIVE
// The host console. A station operator names the show, takes the air, and
// the mic becomes an HLS stream every tuned device swaps to. The listener
// side is the exact mirror of a call-in airing — but here the human owns the
// air for the whole show, not one 30-second take.
//
// Same cold furniture as THE LINE and THE RING: ink and bone, square borders,
// tracked caps. On air, the whole console floods the station color — there is
// no mistaking that you are transmitting.
//
// This sheet is only ever reachable on a host device (a key sits in the
// Keychain); nothing here is shipped live to ordinary listeners.

struct BroadcastConsole: View {
    @ObservedObject var service: BroadcastService
    let stationID: String
    let stationName: String
    let accent: Color
    let onClose: () -> Void

    @State private var title = ""
    @StateObject private var board = CallBoardService()
    @State private var showBoard = false

    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)
    private let ember = Color(red: 1.00, green: 0.36, blue: 0.18)

    private var onAir: Bool {
        if case .onAir = service.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            (onAir ? accent : ink).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                hairline
                if showBoard {
                    boardView
                } else {
                    Spacer()
                    stage
                    Spacer()
                }
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
        .task { await board.refresh() }
        // On air, a stray swipe must not drop the sheet — the host ends the
        // show with the button, deliberately.
        .interactiveDismissDisabled(onAir || service.state == .starting || service.state == .stopping)
        .onChange(of: service.state) { _, newState in
            switch newState {
            case .onAir: Haptics.boost()
            case .failed: Haptics.tap()
            case .idle, .starting, .stopping: break
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .center) {
            Text(showBoard ? "THE BOARD" : "GO LIVE")
                .font(.custom("Archivo Black", size: 13))
                .tracking(2.5)
                .foregroundStyle(onAir ? ink : bone)
            Spacer()
            Button {
                // On the board, step back to the console; otherwise close.
                // Closing does NOT end a live show — the host may keep talking
                // while the sheet is down; the chrome carries the LIVE banner.
                if showBoard { withAnimation { showBoard = false } } else { onClose() }
            } label: {
                Image(systemName: showBoard ? "chevron.left" : "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle((onAir ? ink : bone).opacity(0.55))
                    .frame(width: 36, height: 36)
                    .overlay(Circle().strokeBorder((onAir ? ink : bone).opacity(0.2), lineWidth: 1))
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var hairline: some View {
        Rectangle().fill((onAir ? ink : bone).opacity(0.15)).frame(height: 1)
    }

    // MARK: Stages

    @ViewBuilder
    private var stage: some View {
        switch service.state {
        case .idle:
            idleStage
        case .starting:
            waiting("GOING LIVE\u{2026}")
        case .onAir(let since):
            onAirStage(since: since)
        case .stopping:
            waiting("ENDING\u{2026}")
        case .failed(let message):
            failedStage(message)
        }
    }

    private var idleStage: some View {
        VStack(spacing: 30) {
            VStack(spacing: 8) {
                TextField(
                    "",
                    text: $title,
                    prompt: Text("NAME THE SHOW (OPTIONAL)")
                        .font(.custom("Archivo Black", size: 13))
                        .tracking(2)
                        .foregroundStyle(bone.opacity(0.28))
                )
                .font(.custom("Archivo Black", size: 13))
                .foregroundStyle(bone)
                .multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .submitLabel(.done)
                Rectangle().fill(bone.opacity(0.15)).frame(height: 1)
            }
            .frame(maxWidth: 280)

            borderedButton("GO LIVE", tint: accent) {
                let show = title.trimmingCharacters(in: .whitespacesAndNewlines)
                service.goLive(title: show, stationID: stationID)
            }

            Text("YOU TAKE THE AIR ON \(stationName.uppercased()) \u{2014} EVERYONE TUNED IN HEARS YOU LIVE")
                .font(.custom("Archivo Black", size: 10))
                .tracking(1.6)
                .foregroundStyle(bone.opacity(0.28))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 280)

            boardButton
        }
    }

    /// Into the screener's queue — pending call-ins waiting to be aired.
    private var boardButton: some View {
        Button {
            Task { await board.refresh() }
            withAnimation { showBoard = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "phone.badge.waveform.fill")
                Text(board.pending.isEmpty ? "THE BOARD" : "THE BOARD \u{00B7} \(board.pending.count) WAITING")
            }
            .font(.custom("Archivo Black", size: 12))
            .tracking(1.4)
            .foregroundStyle((onAir ? ink : bone).opacity(0.75))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .overlay(Rectangle().strokeBorder((onAir ? ink : bone).opacity(0.35), lineWidth: 1))
        }
    }

    private func onAirStage(since: Date) -> some View {
        VStack(spacing: 26) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Text(clock(ctx.date.timeIntervalSince(since)))
                    .font(.custom("Gasoek One", size: 40))
                    .monospacedDigit()
                    .foregroundStyle(ink)
            }

            Text("ON AIR")
                .font(.custom("Gasoek One", size: 64))
                .foregroundStyle(ink)

            if !title.isEmpty {
                Text(title.uppercased())
                    .font(.custom("Archivo Black", size: 12))
                    .tracking(2)
                    .foregroundStyle(ink.opacity(0.75))
            }

            // Live mic level — proof the air is hot, drawn in ink over the
            // flooded station color.
            meter(level: service.level)
                .frame(width: 200, height: 30)

            boardButton

            borderedButton("END BROADCAST", tint: ink) {
                service.endBroadcast()
            }
            .padding(.top, 4)
        }
    }

    private func failedStage(_ message: String) -> some View {
        VStack(spacing: 28) {
            Text(message.uppercased())
                .font(.custom("Archivo Black", size: 13))
                .tracking(1.8)
                .foregroundStyle(ember)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
            borderedButton("TRY AGAIN", tint: bone) { service.reset() }
        }
    }

    private func waiting(_ text: String) -> some View {
        Text(text)
            .font(.custom("Archivo Black", size: 13))
            .tracking(2)
            .foregroundStyle((onAir ? ink : bone).opacity(0.55))
    }

    // MARK: THE BOARD — the screener's queue

    private var boardView: some View {
        let fg = onAir ? ink : bone
        return VStack(spacing: 0) {
            if let note = board.note {
                Text(note)
                    .font(.custom("Archivo Black", size: 11)).tracking(1.4)
                    .foregroundStyle(fg.opacity(0.75))
                    .padding(.vertical, 10)
            }
            if board.pending.isEmpty {
                Spacer()
                Text("NO CALLS WAITING")
                    .font(.custom("Archivo Black", size: 14)).tracking(2)
                    .foregroundStyle(fg.opacity(0.55))
                Text("HOLD-TO-TALK CALLS LAND HERE FOR YOU TO AUDITION AND AIR")
                    .font(.custom("Archivo Black", size: 10)).tracking(1.2)
                    .foregroundStyle(fg.opacity(0.3))
                    .multilineTextAlignment(.center).lineSpacing(3)
                    .frame(maxWidth: 260).padding(.top, 8)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(board.pending) { callRow($0, fg: fg) }
                    }
                    .padding(.vertical, 14)
                }
            }
        }
    }

    private func callRow(_ call: CallBoardService.Call, fg: Color) -> some View {
        HStack(spacing: 12) {
            Button { board.toggleAudition(call) } label: {
                Image(systemName: board.auditioning == call.id ? "stop.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(fg)
                    .frame(width: 44, height: 44)
                    .overlay(Circle().strokeBorder(fg.opacity(0.3), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(call.handle.isEmpty ? "ANON" : call.handle.uppercased())
                    .font(.custom("Archivo Black", size: 14)).foregroundStyle(fg)
                Text("\(Int(call.duration.rounded()))S ON TAPE")
                    .font(.custom("Archivo Black", size: 10)).tracking(1)
                    .foregroundStyle(fg.opacity(0.5)).monospacedDigit()
            }
            Spacer()
            Button { Task { await board.air(call) } } label: {
                Text("AIR").font(.custom("Archivo Black", size: 12)).tracking(1.5)
                    .foregroundStyle(onAir ? accent : ink)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(onAir ? ink : accent)
            }
            Button { Task { await board.drop(call) } } label: {
                Text("DROP").font(.custom("Archivo Black", size: 12)).tracking(1.5)
                    .foregroundStyle(fg.opacity(0.55))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(Rectangle().strokeBorder(fg.opacity(0.4), lineWidth: 1))
            }
        }
        .padding(12)
        .background(Rectangle().fill(fg.opacity(0.06)))
        .disabled(board.busy)
    }

    // MARK: Furniture

    /// A row of bars that lights up to the live mic level — ink on the
    /// flooded color, so it reads as a real VU on air.
    private func meter(level: Float) -> some View {
        GeometryReader { geo in
            let bars = 16
            let lit = Int((Float(bars) * min(1, max(0, level))).rounded())
            HStack(spacing: 3) {
                ForEach(0..<bars, id: \.self) { i in
                    Rectangle()
                        .fill(ink.opacity(i < lit ? 0.9 : 0.18))
                        .frame(maxWidth: .infinity)
                        .frame(height: CGFloat(10 + i))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .bottom)
            .animation(.linear(duration: 0.08), value: lit)
        }
    }

    private func borderedButton(
        _ title: String, tint: Color, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Archivo Black", size: 13))
                .tracking(2)
                .foregroundStyle(tint)
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .overlay(Rectangle().strokeBorder(tint, lineWidth: 1.5))
        }
    }

    private func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Founder key entry

/// The host key is never shipped in the binary — a station operator sets it
/// once, by hand, and it lands in the Keychain. This tiny sheet is the only
/// way in, reached by a long-press no ordinary listener would find. With the
/// key present, the transmit control appears in the chrome; without it, GO
/// LIVE does not exist on the device.
struct HostKeyEntry: View {
    let accent: Color
    let onSaved: () -> Void
    let onClose: () -> Void

    @State private var key = ""
    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)

    var body: some View {
        ZStack {
            ink.ignoresSafeArea()
            VStack(spacing: 24) {
                Text("HOST KEY")
                    .font(.custom("Archivo Black", size: 13))
                    .tracking(2.5)
                    .foregroundStyle(bone)
                SecureField(
                    "",
                    text: $key,
                    prompt: Text("PASTE THE STATION KEY")
                        .font(.custom("Archivo Black", size: 12))
                        .foregroundStyle(bone.opacity(0.28))
                )
                .font(.custom("Archivo Black", size: 13))
                .foregroundStyle(bone)
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 300)
                Rectangle().fill(bone.opacity(0.15)).frame(height: 1).frame(maxWidth: 300)

                HStack(spacing: 12) {
                    button("SAVE", tint: accent) {
                        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        try? KeychainSecretStore.shared.setSecret(
                            trimmed, forKey: BroadcastService.hostKeyKeychainKey
                        )
                        BroadcastService.invalidateHostKeyCache()
                        onSaved()
                    }
                    button("CLEAR", tint: bone.opacity(0.55)) {
                        try? KeychainSecretStore.shared.removeSecret(
                            forKey: BroadcastService.hostKeyKeychainKey
                        )
                        BroadcastService.invalidateHostKeyCache()
                        onSaved()
                    }
                    button("CLOSE", tint: bone.opacity(0.55)) { onClose() }
                }
            }
            .padding(24)
        }
        .preferredColorScheme(.dark)
    }

    private func button(_ title: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.custom("Archivo Black", size: 12))
                .tracking(1.6)
                .foregroundStyle(tint)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .overlay(Rectangle().strokeBorder(tint, lineWidth: 1.5))
        }
    }
}
