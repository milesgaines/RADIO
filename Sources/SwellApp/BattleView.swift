import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

// MARK: - THE RING
// Song battles. Two entries, one diagonal, the crowd on both sides.
// Artists put a song in the queue; the server pairs two into a battle;
// listeners TAP a side to hear it and HOLD a side to vote it. When the
// clock runs out the winner enters rotation on 1200 THE UNDERGROUND.
//
// Design notes, so nobody "fixes" this into a card grid later:
// - The split is a slanted hairline, not a horizontal one — a straight
//   50/50 reads as a settings screen; the diagonal reads as a fight.
// - Side A is ember, side B is ice. Those are station accents 1 and 2
//   from CymaticPlate.accents, reused verbatim: the battle borrows the
//   station's own palette instead of inventing one.
// - Votes here are BATTLE votes (which song wins entry into rotation),
//   not rotation votes. The winner still goes through the same weighted,
//   licensed, anti-gamed rotation as everything else — the crowd picks
//   who gets a seat at the table, never what plays next. That keeps this
//   feature on the right side of the Arista v. Launch Media line.

/// The palette for this surface. Ink and bone come from HumanTheme so a
/// future retune lands here too; ember and ice are the first two station
/// accents (see CymaticPlate.accents) — same values, same meaning.
private enum RingTheme {
    static let ink = HumanTheme.ink
    static let bone = HumanTheme.bone
    static let ember = Color(red: 1.00, green: 0.36, blue: 0.18)
    static let ice = Color(red: 0.30, green: 0.72, blue: 1.00)
    /// How far the dividing line tilts, as a fraction of screen height at
    /// each edge. 0.055 is enough to read as a slash without stealing
    /// vertical room from either title.
    static let tilt: CGFloat = 0.055
}

// MARK: - The battle surface

struct BattleView: View {
    @ObservedObject var service: BattleService
    /// Called before any preview audio starts — one audible source at a
    /// time is a hard rule; the station never plays under a preview.
    let pauseRadio: () -> Void
    let onClose: () -> Void

    /// Which side is currently auditioning ("a" | "b"), and the player
    /// doing it. A plain AVPlayer, not RadioPlayer: previews are private
    /// listening, so they must never touch MPNowPlayingInfoCenter or the
    /// remote commands the live station owns.
    @State private var previewSide: String?
    @State private var previewPlayer: AVPlayer?
    /// Set for ~half a second after a vote lands so the chosen side can
    /// flare. Purely cosmetic; the tally itself comes from the service.
    @State private var voteFlash: String?
    @State private var showUpload = false

    private var isSettled: Bool { service.battle?.status == "settled" }

    var body: some View {
        ZStack {
            RingTheme.ink.ignoresSafeArea()

            if let battle = service.battle {
                if battle.status == "settled" {
                    settledView(battle)
                } else {
                    openBattle(battle)
                }
            } else {
                emptyState
            }

            header
        }
        .preferredColorScheme(.dark)
        .task {
            service.startRealtime()
            await service.refresh()
        }
        .onDisappear {
            service.stopRealtime()
            stopPreview()
        }
        // A new pairing or a settle both invalidate whatever was in the
        // preview player's throat — never let the loser keep singing over
        // the winner card.
        .onChange(of: service.battle?.id) { stopPreview() }
        .onChange(of: service.battle?.status) { _, status in
            if status == "settled" { stopPreview() }
        }
        .sheet(isPresented: $showUpload) {
            BattleUploadSheet(service: service)
        }
    }

    // MARK: Header — title, clock, exit

    private var header: some View {
        // On the settled flood the whole screen is accent, so the header
        // flips to ink; everywhere else it is bone on ink.
        let fg = isSettled ? RingTheme.ink : RingTheme.bone
        return VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                Text("THE RING")
                    .font(.custom("Archivo Black", size: 13))
                    .tracking(2.5)
                    .foregroundStyle(fg)
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                if let battle = service.battle, battle.status == "open" {
                    // One tick per second is all a mm:ss clock needs; the
                    // monospaced digits keep it from wobbling as it counts.
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        Text(countdown(to: battle.endsAt, now: ctx.date))
                            .font(.custom("Archivo Black", size: 13))
                            .monospacedDigit()
                            .foregroundStyle(fg)
                            .lineLimit(1).fixedSize()
                    }
                }
                Button {
                    Haptics.tap()
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(fg.opacity(0.55))
                        .frame(width: 32, height: 32)
                }
            }
            .padding(.top, 8)

            Rectangle().fill(fg.opacity(0.15)).frame(height: 1)
                .padding(.top, 4)

            if service.battle?.status == "open" {
                Text("TAP A SIDE TO HEAR IT — HOLD TO VOTE")
                    .font(.custom("Archivo Black", size: 10))
                    .tracking(1.8)
                    .foregroundStyle(RingTheme.bone.opacity(0.28))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }

            Spacer()
        }
        .padding(.horizontal, 24)
    }

    /// mm:ss until the bell. Past zero the server hasn't flipped the
    /// status yet, so say so — never show a clock running negative.
    private func countdown(to end: Date, now: Date) -> String {
        let remaining = Int(end.timeIntervalSince(now).rounded(.down))
        guard remaining > 0 else { return "COUNTING\u{2026}" }
        return String(format: "%02d:%02d", min(remaining, 5999) / 60, remaining % 60)
    }

    // MARK: The open battle — two halves and a tally

    private func openBattle(_ battle: BattleService.Battle) -> some View {
        ZStack {
            sideView(entry: battle.a, side: "a", accent: RingTheme.ember, top: true)
            sideView(entry: battle.b, side: "b", accent: RingTheme.ice, top: false)

            // The dividing slash. A stroked path, not a rotated
            // Rectangle: the tilt is defined in the same coordinates as
            // the two half shapes, so the three can never drift apart.
            RingSlantLine(tilt: RingTheme.tilt)
                .stroke(RingTheme.bone.opacity(0.15), lineWidth: 1)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            tally(battle)
        }
    }

    private func sideView(entry: BattleService.Entry, side: String, accent: Color, top: Bool) -> some View {
        let previewing = previewSide == side
        // The TimelineView only runs while this side is auditioning —
        // paused, it costs nothing and the sine below holds at rest.
        return TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !previewing)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let wave = previewing ? (sin(t * 2.6) * 0.5 + 0.5) : 0 // 0…1 breath

            ZStack(alignment: top ? .topLeading : .bottomTrailing) {
                // The half itself. A faint accent wash claims the
                // territory; previewing floods it low and breathing, and
                // a landed vote flares it for half a beat.
                RingSlantHalf(top: top, tilt: RingTheme.tilt)
                    .fill(accent.opacity(
                        0.05
                        + (previewing ? 0.09 + 0.05 * wave : 0)
                        + (voteFlash == side ? 0.30 : 0)
                    ))
                    .ignoresSafeArea()
                    .animation(.easeOut(duration: 0.45), value: voteFlash)

                VStack(alignment: top ? .leading : .trailing, spacing: 10) {
                    if previewing {
                        Text("PREVIEW")
                            .font(.custom("Archivo Black", size: 10))
                            .tracking(1.8)
                            .foregroundStyle(accent)
                    }
                    Text(entry.title.uppercased())
                        .font(.custom("Gasoek One", size: 40))
                        .foregroundStyle(accent)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .multilineTextAlignment(top ? .leading : .trailing)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(entry.artist.uppercased())
                        .font(.custom("Archivo Black", size: 10))
                        .tracking(1.8)
                        .foregroundStyle(RingTheme.bone.opacity(0.55))
                    if service.myVote == side {
                        Text("YOUR VOTE")
                            .font(.custom("Archivo Black", size: 10))
                            .tracking(1.8)
                            .foregroundStyle(accent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .overlay(Rectangle().strokeBorder(accent, lineWidth: 1))
                    }
                }
                .padding(.horizontal, 24)
                // A clears the header block; B clears the home indicator.
                .padding(top ? .top : .bottom, top ? 108 : 56)
                .scaleEffect(previewing ? 1 + 0.02 * wave : 1,
                             anchor: top ? .topLeading : .bottomTrailing)
            }
            // Hits only land inside this half's slanted region, so the
            // two gestures can share the screen without a referee.
            .contentShape(RingSlantHalf(top: top, tilt: RingTheme.tilt))
            .gesture(
                // Hold is the commitment, tap is the audition. Exclusive
                // ordering: a completed hold swallows the tap, a quick
                // tap fails the hold and falls through to preview.
                LongPressGesture(minimumDuration: 0.4)
                    .onEnded { _ in castVote(side) }
                    .exclusively(before: TapGesture().onEnded {
                        togglePreview(side, entry: entry)
                    })
            )
        }
    }

    /// The tally: one bar at the diagonal's midpoint, ember from the
    /// left, ice from the right, a hairline of dark between them. Raw
    /// counts, no percentages — this is a scoreboard, not a poll widget.
    private func tally(_ battle: BattleService.Battle) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("\(battle.aScore)")
                    .font(.custom("Archivo Black", size: 13))
                    .monospacedDigit()
                    .foregroundStyle(RingTheme.ember)
                    .contentTransition(.numericText())
                Spacer(minLength: 8)
                Text("VS")
                    .font(.custom("Gasoek One", size: 28))
                    .foregroundStyle(RingTheme.bone)
                Spacer(minLength: 8)
                Text("\(battle.bScore)")
                    .font(.custom("Archivo Black", size: 13))
                    .monospacedDigit()
                    .foregroundStyle(RingTheme.ice)
                    .contentTransition(.numericText())
            }
            GeometryReader { g in
                let sum = battle.aScore + battle.bScore
                // No votes yet = dead level. Never show an empty bar as a
                // shutout; it would read as one side already losing.
                let aFrac: CGFloat = sum > 0
                    ? CGFloat(battle.aScore) / CGFloat(sum)
                    : 0.5
                HStack(spacing: 2) {
                    Rectangle().fill(RingTheme.ember)
                        .frame(width: max(0, (g.size.width - 2) * aFrac))
                    Rectangle().fill(RingTheme.ice)
                }
            }
            .frame(height: 6)
        }
        .padding(.horizontal, 24)
        .animation(.snappy, value: battle.aScore)
        .animation(.snappy, value: battle.bScore)
        // The tally is a readout, not a control — taps pass through to
        // whichever half is underneath.
        .allowsHitTesting(false)
    }

    // MARK: Settled — the winner takeover

    private func settledView(_ battle: BattleService.Battle) -> some View {
        // The server's word is law; the score comparison is only the
        // fallback for a settled battle that arrived without a winner id.
        let winnerIsA = battle.winner.map { $0 == battle.a.id }
            ?? (battle.aScore >= battle.bScore)
        let win = winnerIsA ? battle.a : battle.b
        let accent = winnerIsA ? RingTheme.ember : RingTheme.ice
        let high = max(battle.aScore, battle.bScore)
        let low = min(battle.aScore, battle.bScore)

        return ZStack {
            accent.ignoresSafeArea()
            VStack(spacing: 12) {
                Text("WINNER")
                    .font(.custom("Gasoek One", size: 64))
                    .foregroundStyle(RingTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(win.title.uppercased())
                    .font(.custom("Archivo Black", size: 13))
                    .tracking(2.5)
                    .foregroundStyle(RingTheme.ink)
                    .multilineTextAlignment(.center)
                Text(win.artist.uppercased())
                    .font(.custom("Archivo Black", size: 10))
                    .tracking(1.8)
                    .foregroundStyle(RingTheme.ink.opacity(0.75))
                Text("FINAL \(high)\u{2013}\(low)")
                    .font(.custom("Archivo Black", size: 13))
                    .monospacedDigit()
                    .foregroundStyle(RingTheme.ink.opacity(0.75))
                    .padding(.top, 6)
                Rectangle().fill(RingTheme.ink.opacity(0.25))
                    .frame(width: 56, height: 1)
                    .padding(.vertical, 10)
                Text("ENTERS ROTATION — 1200 THE UNDERGROUND")
                    .font(.custom("Archivo Black", size: 10))
                    .tracking(1.8)
                    .foregroundStyle(RingTheme.ink)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 24)
        }
        .transition(.opacity)
    }

    // MARK: Empty — the ring is open

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("THE RING\nIS OPEN")
                .font(.custom("Gasoek One", size: 40))
                .foregroundStyle(RingTheme.bone)
                .fixedSize(horizontal: false, vertical: true)
            Text("\(service.queueCount) IN THE QUEUE")
                .font(.custom("Archivo Black", size: 13))
                .tracking(2)
                .monospacedDigit()
                .foregroundStyle(RingTheme.bone.opacity(0.55))
                .contentTransition(.numericText())
                .animation(.snappy, value: service.queueCount)
            Text("TWO SONGS. THE CROWD DECIDES.\nWINNER ENTERS ROTATION.")
                .font(.custom("Archivo Black", size: 10))
                .tracking(1.8)
                .foregroundStyle(RingTheme.bone.opacity(0.28))
                .lineSpacing(4)
            Button {
                Haptics.tap()
                showUpload = true
            } label: {
                Text("PUT YOUR SONG IN")
                    .font(.custom("Archivo Black", size: 13))
                    .tracking(2)
                    .foregroundStyle(RingTheme.bone)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .overlay(Rectangle().strokeBorder(RingTheme.bone.opacity(0.15), lineWidth: 1))
            }
            .padding(.top, 10)
            Spacer()
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func castVote(_ side: String) {
        guard service.battle?.status == "open" else { return }
        // Switching sides is allowed and the service owns that logic —
        // this view just reports the hold.
        service.vote(side)
        Haptics.boost()
        withAnimation(.easeIn(duration: 0.12)) { voteFlash = side }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if voteFlash == side {
                withAnimation(.easeOut(duration: 0.6)) { voteFlash = nil }
            }
        }
    }

    private func togglePreview(_ side: String, entry: BattleService.Entry) {
        if previewSide == side {
            stopPreview()
            Haptics.tap()
            return
        }
        // No audio to audition — swallow the tap rather than pausing the
        // station for silence.
        guard let url = entry.audioURL else {
            Haptics.tap()
            return
        }
        pauseRadio()
        previewPlayer?.pause()
        let player = AVPlayer(url: url)
        player.play()
        previewPlayer = player
        previewSide = side
        Haptics.tap()
    }

    private func stopPreview() {
        previewPlayer?.pause()
        previewPlayer = nil
        previewSide = nil
    }
}

// MARK: - The diagonal geometry
// Both halves and the dividing stroke are cut from the same two numbers
// (0.5 ± tilt at the edges), so the seam is airtight by construction.

/// One half of the screen, cut by the slanted line. `top == true` is
/// side A's territory (upper-left heavy), `false` is side B's.
private struct RingSlantHalf: Shape {
    let top: Bool
    let tilt: CGFloat

    func path(in rect: CGRect) -> Path {
        let leftY = rect.minY + rect.height * (0.5 + tilt)
        let rightY = rect.minY + rect.height * (0.5 - tilt)
        var p = Path()
        if top {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rightY))
            p.addLine(to: CGPoint(x: rect.minX, y: leftY))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: leftY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rightY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        p.closeSubpath()
        return p
    }
}

/// The seam itself, stroked as the one hairline this surface gets.
private struct RingSlantLine: Shape {
    let tilt: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rect.height * (0.5 + tilt)))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * (0.5 - tilt)))
        return p
    }
}

// MARK: - The upload sheet

/// Where an artist puts a song into the queue. Two fields, one file, one
/// button — over hairline underlines, not rounded fields, because forms
/// on this surface dress like the rest of the broadcast chrome.
private struct BattleUploadSheet: View {
    @ObservedObject var service: BattleService
    @Environment(\.dismiss) private var dismiss

    @State private var songTitle = ""
    @State private var artist = ""
    /// Our sandbox-local copy of the picked file. The picker's URL is
    /// security-scoped and can die the moment the picker's grant lapses;
    /// service.submit gets this stable copy instead.
    @State private var pickedURL: URL?
    @State private var pickedName: String?
    @State private var showImporter = false
    @State private var pickError: String?

    private var canSubmit: Bool {
        pickedURL != nil
        && !songTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && !artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        && service.submitState != .uploading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack {
                Text("PUT YOUR SONG IN")
                    .font(.custom("Gasoek One", size: 30))
                    .foregroundStyle(RingTheme.bone)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Spacer()
                Button {
                    Haptics.tap()
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(RingTheme.bone.opacity(0.55))
                        .frame(width: 32, height: 32)
                }
            }

            field("SONG TITLE", text: $songTitle)
            field("ARTIST", text: $artist)

            VStack(alignment: .leading, spacing: 8) {
                Text("THE FILE")
                    .font(.custom("Archivo Black", size: 10))
                    .tracking(1.8)
                    .foregroundStyle(RingTheme.bone.opacity(0.55))
                Button {
                    Haptics.tap()
                    showImporter = true
                } label: {
                    Text(pickedName?.uppercased() ?? "PICK THE FILE")
                        .font(.custom("Archivo Black", size: 13))
                        .tracking(2)
                        .foregroundStyle(pickedName == nil ? RingTheme.bone : RingTheme.ice)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .overlay(Rectangle().strokeBorder(RingTheme.bone.opacity(0.15), lineWidth: 1))
                }
                if let pickError {
                    Text(pickError)
                        .font(.custom("Archivo Black", size: 10))
                        .tracking(1.8)
                        .foregroundStyle(RingTheme.ember)
                }
            }

            Button {
                guard let url = pickedURL else { return }
                Haptics.boost()
                let title = songTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = artist.trimmingCharacters(in: .whitespacesAndNewlines)
                Task { await service.submit(fileURL: url, title: title, artist: name) }
            } label: {
                Text("SUBMIT")
                    .font(.custom("Archivo Black", size: 13))
                    .tracking(2)
                    .foregroundStyle(canSubmit ? RingTheme.ink : RingTheme.bone.opacity(0.28))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(canSubmit ? RingTheme.ember : .clear)
                    .overlay(Rectangle().strokeBorder(
                        RingTheme.bone.opacity(canSubmit ? 0 : 0.15), lineWidth: 1))
            }
            .disabled(!canSubmit)

            stateLine

            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RingTheme.ink)
        .preferredColorScheme(.dark)
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.audio]
        ) { result in
            handlePickedFile(result)
        }
    }

    @ViewBuilder
    private var stateLine: some View {
        switch service.submitState {
        case .idle:
            EmptyView()
        case .uploading:
            Text("SENDING\u{2026}")
                .font(.custom("Archivo Black", size: 10))
                .tracking(1.8)
                .foregroundStyle(RingTheme.bone.opacity(0.55))
        case .queued:
            Text("IN THE QUEUE — THE RING CALLS WHEN IT'S TIME")
                .font(.custom("Archivo Black", size: 10))
                .tracking(1.8)
                .foregroundStyle(RingTheme.bone)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message):
            Text(message.uppercased())
                .font(.custom("Archivo Black", size: 10))
                .tracking(1.8)
                .foregroundStyle(RingTheme.ember)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.custom("Archivo Black", size: 10))
                .tracking(1.8)
                .foregroundStyle(RingTheme.bone.opacity(0.55))
            TextField("", text: text)
                .font(.custom("Archivo Black", size: 13))
                .foregroundStyle(RingTheme.bone)
                .tint(RingTheme.ember)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Rectangle().fill(RingTheme.bone.opacity(0.15)).frame(height: 1)
        }
    }

    /// The picker hands back a security-scoped URL that is only readable
    /// between start/stopAccessing — and often only while the picker's
    /// grant is alive. Copy it into our own tmp immediately; the service
    /// gets a URL it can read whenever the upload actually runs.
    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let secured = url.startAccessingSecurityScopedResource()
            defer { if secured { url.stopAccessingSecurityScopedResource() } }
            var dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("ring-\(UUID().uuidString)")
            if !url.pathExtension.isEmpty {
                dest.appendPathExtension(url.pathExtension)
            }
            do {
                try FileManager.default.copyItem(at: url, to: dest)
                pickedURL = dest
                pickedName = url.lastPathComponent
                pickError = nil
                Haptics.detent()
            } catch {
                pickedURL = nil
                pickedName = nil
                pickError = "COULDN'T READ THAT FILE"
            }
        case .failure:
            // Cancelled or the picker itself failed — leave whatever was
            // already picked in place and say nothing.
            break
        }
    }
}
