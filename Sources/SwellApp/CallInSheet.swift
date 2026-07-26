import SwiftUI

// MARK: - THE LINE
// Radio call-ins. A listener holds the circle, talks (30 seconds max),
// releases, optionally signs a name, and sends the take. Nothing recorded
// here goes to air directly — every take lands in a moderation queue and
// the server director decides what plays between songs. Same seam as the
// rest of the product: the client captures, the server programs.
//
// The copy is deliberately cold broadcast furniture. "ON TAPE", "SEND IT",
// "SCRAP" — a call-in line, not a social feature.
//
// Why the radio pauses on press-down: the program feed would bleed straight
// into the open mic, and an aired call would carry a ghost of the song
// underneath it. The presenter hands us pauseRadio() and owns resuming
// playback after the sheet is dismissed.

struct CallInSheet: View {
    @ObservedObject var service: CallInService
    let stationID: String
    let accent: Color
    /// Fired the instant the hold begins, before the recorder spins up —
    /// the radio must not bleed into the mic.
    let pauseRadio: () -> Void
    let onClose: () -> Void

    @State private var handle = ""
    /// DragGesture(minimumDistance: 0).onChanged fires on every touch move,
    /// not once — this debounces so beginRecording runs exactly once per
    /// hold. It is re-armed on release and whenever the service leaves
    /// `.recording` on its own (the 30-second auto-stop swaps the view
    /// branch, which cancels the gesture without ever calling onEnded).
    @State private var holdActive = false

    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)
    private let ember = Color(red: 1.00, green: 0.36, blue: 0.18)

    private var isRecording: Bool {
        if case .recording = service.state { return true }
        return false
    }

    /// The takeover moment floods the whole sheet, header included, so
    /// every foreground element flips to ink while it is up.
    private var flooded: Bool {
        if case .onTheLine = service.state { return true }
        return false
    }

    var body: some View {
        ZStack {
            (flooded ? accent : ink).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                hairline
                Spacer()
                stage
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .preferredColorScheme(.dark)
        // Mid-recording, a stray drag must not dismiss the sheet with the
        // radio paused and the mic open.
        .interactiveDismissDisabled(isRecording)
        .onChange(of: service.state) { _, newState in
            switch newState {
            case .recording:
                break // the hold is live; leave the debounce armed
            case .recorded:
                holdActive = false
                Haptics.detent()
            case .onTheLine:
                holdActive = false
                Haptics.boost()
            case .failed:
                holdActive = false
                Haptics.tap()
            case .idle, .uploading:
                holdActive = false
            }
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .center) {
            Text("THE LINE")
                .font(.custom("Archivo Black", size: 13))
                .tracking(2.5)
                .foregroundStyle(flooded ? ink : bone)
            Spacer()
            Button {
                // Never leave a live mic behind: kill the take before
                // handing control back to the presenter.
                if case .recording = service.state {
                    service.endRecording()
                    service.scrap()
                }
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle((flooded ? ink : bone).opacity(0.55))
                    .frame(width: 36, height: 36)
                    .overlay(Circle().strokeBorder((flooded ? ink : bone).opacity(0.2), lineWidth: 1))
            }
        }
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private var hairline: some View {
        Rectangle().fill((flooded ? ink : bone).opacity(0.15)).frame(height: 1)
    }

    // MARK: Stages

    @ViewBuilder
    private var stage: some View {
        switch service.state {
        // idle and recording share ONE branch on purpose: the hold gesture
        // lives on this view, and splitting the states into separate
        // branches would tear the view down mid-hold and cancel the
        // gesture the moment recording began.
        case .idle, .recording:
            holdStage
        case .recorded(let duration):
            recordedStage(duration: duration)
        case .uploading:
            Text("SENDING\u{2026}")
                .font(.custom("Archivo Black", size: 13))
                .tracking(2)
                .foregroundStyle(bone.opacity(0.55))
        case .onTheLine:
            onTheLineStage
        case .failed(let message):
            failedStage(message)
        }
    }

    /// The circle is both the instruction and the instrument: hairline ring
    /// at rest, solid accent while the tape rolls, with a countdown ring
    /// that is full at press-down and empty at exactly maxSeconds.
    private var holdStage: some View {
        VStack(spacing: 28) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !isRecording)) { ctx in
                let elapsed: Double = {
                    if case .recording(let startedAt) = service.state {
                        return min(service.maxSeconds, max(0, ctx.date.timeIntervalSince(startedAt)))
                    }
                    return 0
                }()
                let remaining = service.maxSeconds > 0
                    ? max(0, 1 - elapsed / service.maxSeconds)
                    : 0
                let pulse = isRecording
                    ? 1 + 0.035 * sin(ctx.date.timeIntervalSinceReferenceDate * 2 * .pi * 1.3)
                    : 1.0

                ZStack {
                    // The tape counter, draining. Trim retreats toward
                    // 12 o'clock as the 30 seconds run out.
                    Circle()
                        .trim(from: 0, to: remaining)
                        .stroke(accent, lineWidth: 2)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 208, height: 208)
                        .opacity(isRecording ? 1 : 0)

                    Circle()
                        .strokeBorder(bone.opacity(0.15), lineWidth: 1)
                        .frame(width: 180, height: 180)

                    if isRecording {
                        Circle()
                            .fill(accent)
                            .frame(width: 180, height: 180)
                            .scaleEffect(pulse)
                        Text(clock(elapsed))
                            .font(.custom("Archivo Black", size: 13))
                            .tracking(2)
                            .monospacedDigit()
                            .foregroundStyle(ink)
                    } else {
                        Text("HOLD\nTO TALK")
                            .font(.custom("Archivo Black", size: 13))
                            .tracking(2)
                            .foregroundStyle(bone)
                            .multilineTextAlignment(.center)
                            .lineSpacing(4)
                    }
                }
            }
            .frame(width: 208, height: 208)
            .contentShape(Circle())
            .gesture(holdGesture)

            // Fixed-height caption slot so the swap doesn't shift the circle.
            Group {
                if isRecording {
                    HStack(spacing: 8) {
                        Circle().fill(ember).frame(width: 5, height: 5)
                        Text("RECORDING")
                            .font(.custom("Archivo Black", size: 10))
                            .tracking(1.8)
                            .foregroundStyle(ember)
                    }
                } else {
                    Text("0:30 MAX \u{2014} AIRS BETWEEN RECORDS")
                        .font(.custom("Archivo Black", size: 10))
                        .tracking(1.8)
                        .foregroundStyle(bone.opacity(0.28))
                }
            }
            .frame(height: 14)
        }
    }

    /// A plain long-press API can miss the press-down instant; a zero-
    /// distance drag reports both edges of the touch reliably, which is
    /// what a push-to-talk button needs.
    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !holdActive else { return }
                holdActive = true
                guard case .idle = service.state else { return }
                pauseRadio()
                service.beginRecording()
                Haptics.boost()
            }
            .onEnded { _ in
                holdActive = false
                // The service may already have auto-stopped at maxSeconds;
                // only end a take that is actually rolling.
                if case .recording = service.state {
                    service.endRecording()
                }
            }
    }

    private func recordedStage(duration: Double) -> some View {
        VStack(spacing: 32) {
            Text("\(Int(duration.rounded()))S ON TAPE")
                .font(.custom("Archivo Black", size: 13))
                .tracking(2)
                .monospacedDigit()
                .foregroundStyle(bone)

            VStack(spacing: 8) {
                TextField(
                    "",
                    text: $handle,
                    prompt: Text("SIGN IT (OPTIONAL)")
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
            .frame(maxWidth: 260)

            HStack(spacing: 12) {
                borderedButton("SEND IT", tint: accent) {
                    let signed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { await service.send(handle: signed, stationID: stationID) }
                }
                borderedButton("SCRAP", tint: bone.opacity(0.55)) {
                    handle = ""
                    service.scrap()
                    Haptics.tap()
                }
            }
        }
    }

    private var onTheLineStage: some View {
        VStack(spacing: 16) {
            Text("YOU'RE ON\nTHE LINE")
                .font(.custom("Gasoek One", size: 52))
                .foregroundStyle(ink)
                .multilineTextAlignment(.center)
                .lineSpacing(2)
            // The honest promise: being on the line is not being on the
            // air. Moderation stands between the two, and saying so up
            // front is what keeps the feature safe to run.
            Text("THE DIRECTOR DECIDES WHAT AIRS")
                .font(.custom("Archivo Black", size: 10))
                .tracking(1.8)
                .foregroundStyle(ink.opacity(0.75))
            borderedButton("DONE", tint: ink) { onClose() }
                .padding(.top, 28)
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
            borderedButton("TRY AGAIN", tint: bone) {
                service.scrap()
            }
        }
    }

    // MARK: Furniture

    /// The one button shape this sheet uses: square, hairline-adjacent
    /// border, tracked caps. Matches the "MARKED" chip in RootView — no
    /// rounded cards anywhere in this app.
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
