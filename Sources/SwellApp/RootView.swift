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
        PlateView(stream: services.activeStream, broadcast: services.broadcast)
            .preferredColorScheme(.dark)
            .persistentSystemOverlays(.hidden)
    }
}

private struct PlateView: View {
    @ObservedObject var stream: LiveStreamService
    /// Observed so the chrome flips to ON AIR the instant a host goes live.
    @ObservedObject var broadcast: BroadcastService
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var player: RadioPlayer
    @EnvironmentObject private var auth: AuthService

    @State private var plate = CymaticPlate()
    @State private var showProfile = false
    @State private var showRing = false
    @State private var showCallIn = false
    @State private var showBroadcast = false
    @State private var showSound = false
    @State private var showAircheck = false
    @State private var showRead = false
    @State private var showHostKey = false
    /// The transmit control only exists on a host device (key in Keychain).
    @State private var isHost = BroadcastService.isHost
    /// First run: the landing "opens up" into the room, then a one-time tour.
    /// The radio is already playing behind both — none of it gates sound.
    private enum FirstRun { case landing, tour, done }
    @State private var firstRun: FirstRun =
        UserDefaults.standard.bool(forKey: "swell.welcomed") ? .done : .landing
    /// A record this listener boosted is airing right now — the marquee cap
    /// flips to YOUR PICK for a beat. Cold, in-place, no takeover.
    @State private var yourPick = false
    @State private var dedicating = false
    @State private var dedicationName = ""
    @State private var momentMarked = false

    // MARK: Gesture state
    // The drag classifies itself once — vertical is a vote, horizontal is a
    // tune — and an ambiguous diagonal is NOTHING. Misfiring (boosting when
    // the user meant to tune, or worse, tuning away mid-song when they meant
    // to boost) is the cardinal sin; dropping a sloppy gesture is free.
    private enum DragAxis { case horizontal, vertical }
    private struct DragTrack {
        var axis: DragAxis?
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var armed = false // past the commit threshold — release will fire
    }
    /// @GestureState so a cancelled drag (incoming call, system gesture)
    /// always snaps the plate back — plain @State would leave it shifted.
    @GestureState private var drag = DragTrack()

    /// Distance that locks the axis, and the dominance ratio required.
    private static let lockDistance: CGFloat = 24
    private static let dominance: CGFloat = 1.5
    /// Release past these and the gesture fires.
    private static let tuneCommit: CGFloat = 80
    private static let voteCommit: CGFloat = 90

    /// This device is transmitting (starting, on air, or winding down).
    private var broadcasting: Bool {
        switch broadcast.state {
        case .starting, .onAir, .stopping: return true
        case .idle, .failed: return false
        }
    }

    private let ink = Color(red: 0.039, green: 0.039, blue: 0.047)
    private let bone = Color(red: 0.945, green: 0.925, blue: 0.878)

    private var accentIndex: Int {
        services.streams.firstIndex(where: { $0 === stream }) ?? 0
    }
    private var accent: Color { CymaticPlate.accents[accentIndex % CymaticPlate.accents.count] }
    /// No fake FM numbers — the dial speaks record culture, and it's data on
    /// the station now (Station.dial / .dialUnit): PWR is the flagship, 78 the
    /// deep-crate speed, 1200 the Technics, 247 around-the-clock.
    private var dialLabel: (number: String, unit: String) {
        let s = stream.station
        return (s.dial.isEmpty ? "808" : s.dial, s.dialUnit)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ink.ignoresSafeArea()

                // The room floods with station color on every kick.
                accent
                    .opacity(0.04 + Double(player.levels.bass) * 0.13)
                    .animation(.linear(duration: 0.1), value: Int(player.levels.bass * 8))
                    .ignoresSafeArea()

                // The on-air warmth: one broad ember glow behind the sign,
                // breathing with the low end. Bold and clean — the station is
                // the art now, not a field of sand.
                RadialGradient(
                    colors: [accent.opacity(0.30 + Double(player.levels.bass) * 0.42), .clear],
                    center: .init(x: 0.5, y: 0.36),
                    startRadius: 6,
                    endRadius: 300 + CGFloat(player.levels.bass) * 240
                )
                .ignoresSafeArea()
                .animation(.linear(duration: 0.1), value: Int(player.levels.bass * 12))
                .allowsHitTesting(false)

                // The audience, drifting up the edges — company, not a number.
                CrowdEmbers(count: stream.nowPlaying?.liveListeners ?? 1, accent: accent)
                    .ignoresSafeArea()

                // Keep the very bottom readable for the deck and the ticker.
                LinearGradient(
                    colors: [.clear, ink.opacity(0.55)],
                    startPoint: .center, endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // A warm vignette frames the sign — the nostalgia of a lit dial
                // in a dark room, and it pulls the eye to the center.
                RadialGradient(
                    colors: [.clear, Color(red: 0.02, green: 0.014, blue: 0.008).opacity(0.7)],
                    center: .center, startRadius: 170, endRadius: 480
                )
                .ignoresSafeArea()
                .blendMode(.multiply)
                .allowsHitTesting(false)

                // Fine analog grain over the whole field — the tooth of a
                // printed sleeve, the hiss of tape. Kept faint so type stays
                // crisp; it just takes the digital sheen off.
                Color.gray
                    .colorEffect(ShaderLibrary.filmGrain(.float(0.9)))
                    .blendMode(.overlay)
                    .opacity(0.07)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                // The vote meter: a vertical pull builds the arrow toward the
                // commit line; the detent haptic marks the point of no return.
                // Release past it fires, release before it cancels — the
                // gesture is inspectable mid-flight instead of a blind flick.
                if drag.axis == .vertical {
                    voteMeter
                        .allowsHitTesting(false)
                        .zIndex(1)
                }

                // The control surface lives UNDER the chrome: a gesture on
                // the ZStack itself swallows every chrome Button (VS, the
                // line, profile — all dead). This clear layer catches
                // drags anywhere the chrome isn't interactive; chrome
                // buttons above it win their own touches.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(plateGestures(in: geo.size), including: firstRun == .done ? .all : .subviews)

                chrome(in: geo.size)

                if dedicating {
                    DedicationOverlay(accent: accent, name: $dedicationName,
                        onSend: {
                            if let id = stream.nowPlaying?.track.id {
                                let n = dedicationName.trimmingCharacters(in: .whitespacesAndNewlines)
                                // Dedicating is an act — sign in to send it out.
                                auth.requireSignIn(reason: "to send it out") {
                                    services.castMyVote(.boost, on: id, dedication: n.isEmpty ? nil : n)
                                    plate.strike()
                                    Haptics.boost()
                                }
                            }
                            dedicationName = ""
                            withAnimation(.easeOut(duration: 0.25)) { dedicating = false }
                        },
                        onCancel: {
                            dedicationName = ""
                            withAnimation(.easeOut(duration: 0.25)) { dedicating = false }
                        })
                    .transition(.opacity)
                    .zIndex(4)
                }

                // First run: the branded landing irises open into the room
                // (audio already playing), then the one-time walkthrough.
                if firstRun == .landing {
                    LandingCover(accent: accent) {
                        withAnimation(.easeInOut(duration: 0.3)) { firstRun = .tour }
                    }
                    .transition(.opacity)
                    .zIndex(3)
                } else if firstRun == .tour {
                    TourOverlay(accent: accent) {
                        UserDefaults.standard.set(true, forKey: "swell.welcomed")
                        withAnimation(.easeOut(duration: 0.5)) { firstRun = .done }
                        Haptics.boost()
                    }
                    .transition(.opacity)
                    .zIndex(3)
                }
            }
            .sheet(isPresented: $showProfile) {
                ProfileSheet(stream: stream, accent: accent, onOpenRing: {
                    showProfile = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showRing = true }
                })
            }
            .fullScreenCover(isPresented: $showRing) {
                BattleView(
                    service: services.battles,
                    pauseRadio: { if player.isPlaying { player.pause() } },
                    onClose: { showRing = false }
                )
            }
            .sheet(isPresented: $showCallIn, onDismiss: { services.callIn.scrap() }) {
                CallInSheet(
                    service: services.callIn,
                    stationID: stream.station.id.uuidString,
                    accent: accent,
                    pauseRadio: { if player.isPlaying { player.pause() } },
                    onClose: { showCallIn = false }
                )
            }
            .sheet(isPresented: $showSound) {
                SoundModeDeck(player: player, accent: accent, onClose: { showSound = false })
            }
            .sheet(isPresented: $showAircheck) {
                AircheckSheet(
                    service: services.aircheck,
                    station: stream.station,
                    now: stream.nowPlaying,
                    accent: accent,
                    onClose: { showAircheck = false }
                )
            }
            .sheet(isPresented: $showRead) {
                TheReadSheet(
                    service: services.theRead,
                    station: stream.station,
                    accent: accent,
                    onClose: { showRead = false }
                )
            }
            .sheet(isPresented: $showBroadcast) {
                BroadcastConsole(
                    service: services.broadcast,
                    player: player,
                    stationID: stream.station.id.uuidString,
                    stationName: stream.station.name,
                    accent: accent,
                    onClose: { showBroadcast = false }
                )
            }
            .sheet(isPresented: $showHostKey) {
                HostKeyEntry(
                    accent: accent,
                    onSaved: { isHost = BroadcastService.isHost; showHostKey = false },
                    onClose: { showHostKey = false }
                )
            }
            .sheet(item: $auth.prompt, onDismiss: { auth.cancelPrompt() }) { prompt in
                SignInSheet(accent: accent, reason: prompt.reason, onCancel: { auth.cancelPrompt() })
            }
            .onAppear {
                plate.configure(size: geo.size)
                // Instant-on radio: sound the moment the app opens. The landing
                // and tour ride on top of live audio; they never gate it.
                if !player.isPlaying { player.play() }
                plate.isPlaying = true
                sync()
            }
            .onChange(of: stream.nowPlaying?.track.id) {
                sync()
                // Write the airplay into the ledger; if it pays off a boost
                // this listener wagered, mark it — cold, in the marquee cap,
                // not a full-screen victory lap.
                if player.isPlaying, let np = stream.nowPlaying {
                    let paidOff = services.airLog.logPlay(track: np.track, station: stream.station)
                    if paidOff {
                        plate.strike()
                        Haptics.boost()
                        withAnimation(.easeIn(duration: 0.2)) { yourPick = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                            withAnimation(.easeOut(duration: 0.6)) { yourPick = false }
                        }
                    }
                }
            }
            .onChange(of: player.isPlaying) { plate.isPlaying = player.isPlaying }
            .onChange(of: player.levels) { _, new in plate.levels = new }
            .onChange(of: stream.nowPlaying?.boostScore ?? 0) { old, new in
                // Crowd votes land as visible pulses through the figure.
                if new > old { plate.pulse() }
            }
        }
    }

    private func sync() {
        plate.accentIndex = accentIndex
        plate.isPlaying = player.isPlaying
        if let title = stream.nowPlaying?.track.title { plate.setFigure(for: title) }
    }

    // Thin type at the edges, but never below the line where it stops being
    // tappable or readable: the top bar's actions are 42pt targets with 16pt
    // glyphs, body labels sit at 11-12pt, and dim text holds ≥0.6 contrast.
    private var hairline: some View {
        Rectangle().fill(bone.opacity(0.15)).frame(height: 1)
            .allowsHitTesting(false)
    }

    /// A top-bar action: a LABELED key — a 15pt glyph over a tiny caption, so
    /// every control says what it opens instead of being a mystery glyph. The
    /// caption is the whole "UI-friendly" fix; the tap target stays a full 44pt.
    /// An inner `.font` on a Text label overrides the glyph default (VS, etc.).
    private func barButton<Label: View>(
        _ caption: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                label()
                    .font(.system(size: 15, weight: .semibold))
                    .frame(height: 19)
                Text(caption)
                    .font(.custom("Archivo Black", size: 7.5))
                    .tracking(0.4)
                    .foregroundStyle(bone.opacity(0.5))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 34, height: 44)
            .contentShape(Rectangle())
        }
    }

    /// The station call as a lit marquee number: a bone face with a top-light
    /// over a warm extruded body (stacked dark copies stepping down-right),
    /// dropped on a soft shadow. 3D and nostalgic, modern in its restraint.
    private func dimensionalNumber(_ text: String) -> some View {
        let side = Color(red: 0.17, green: 0.10, blue: 0.07) // warm amber shadow
        return ZStack {
            ForEach(1...7, id: \.self) { i in
                Text(text)
                    .foregroundStyle(side)
                    .offset(x: CGFloat(i) * 1.4, y: CGFloat(i) * 2.0)
            }
            Text(text)
                .foregroundStyle(
                    LinearGradient(
                        colors: [bone, Color(red: 0.80, green: 0.77, blue: 0.68)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
        }
        .font(.custom("Gasoek One", size: 132))
        .lineLimit(1)
        .minimumScaleFactor(0.45)
        .shadow(color: .black.opacity(0.5), radius: 16, x: 0, y: 13)
    }

    /// A marquee rule: an ember bar with a bevel undershadow that lights up
    /// with the bass, so the whole sign pulses like a real broadcast board.
    private var emberRule: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: [accent, accent.opacity(0.72)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: 3)
            Rectangle().fill(.black.opacity(0.45)).frame(height: 1.5)
        }
        .shadow(color: accent.opacity(0.4 + Double(player.levels.bass) * 0.6),
                radius: 3 + CGFloat(player.levels.bass) * 9)
        .animation(.linear(duration: 0.1), value: Int(player.levels.bass * 12))
    }

    /// The lit end-cap on the marquee — ON AIR / LIVE as a raised ember pill.
    private func marqueeCap(_ text: String) -> some View {
        Text(text)
            .font(.custom("Archivo Black", size: 13))
            .tracking(1.4)
            .foregroundStyle(ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(LinearGradient(colors: [accent, accent.opacity(0.8)],
                                              startPoint: .top, endPoint: .bottom))
            )
            .shadow(color: accent.opacity(0.5), radius: 6, y: 2)
            .fixedSize()
    }

    private func chrome(in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Chrome: wordmark + live status stacked on the left, a row of
            // LABELED keys on the right. Every top control names itself now, so
            // the bar reads as buttons, not decoration — and the caption idiom
            // ties it to the bottom deck as one instrument.
            HStack(alignment: .center, spacing: 2) {
                VStack(alignment: .leading, spacing: 3) {
                    // The wordmark doubles as the hidden host door: a long-press
                    // no ordinary listener would try opens the key entry.
                    RadioPlusMark(size: 22, accent: accent, level: player.isPlaying ? player.levels.bass : 0)
                        .contentShape(Rectangle())
                        .gesture(
                            LongPressGesture(minimumDuration: 0.9)
                                .onEnded { _ in showHostKey = true }
                        )
                    HStack(spacing: 5) {
                        if player.isPlaying || broadcasting {
                            Circle().fill(accent).frame(width: 6, height: 6)
                        }
                        Text(broadcasting ? "ON AIR"
                             : (player.isPlaying
                                ? "LIVE · \(stream.nowPlaying?.liveListeners ?? 1) TUNED IN"
                                : "OFF AIR"))
                            .font(.custom("Archivo Black", size: 11))
                            .tracking(1.2)
                            .foregroundStyle(broadcasting || player.isPlaying ? bone.opacity(0.85) : bone.opacity(0.5))
                            .monospacedDigit()
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                }
                Spacer(minLength: 6)
                // GO LIVE: the host's transmit control (host devices only).
                if isHost {
                    barButton("LIVE") { showBroadcast = true } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(broadcasting ? accent : bone.opacity(0.9))
                    }
                }
                // SOUND: HD / 3D / vinyl / cassette — how the station sounds.
                // Neutral for the uncoloured modes (HD, 3D); accent-lit when a
                // character mode (vinyl/cassette) is colouring the air.
                barButton("SOUND") { showSound = true } label: {
                    Image(systemName: "opticaldisc")
                        .foregroundStyle(player.mode == .hd || player.mode == .spatial ? bone.opacity(0.9) : accent)
                }
                // THE RING: song battles.
                barButton("RING") { showRing = true } label: {
                    Text("VS")
                        .font(.custom("Archivo Black", size: 14))
                        .foregroundStyle(bone.opacity(0.9))
                }
                // THE LINE: hold-to-talk call-ins.
                barButton("LINE") { showCallIn = true } label: {
                    Image(systemName: "phone.fill").foregroundStyle(bone.opacity(0.9))
                }
                // TAPE: hit record — tape the moment off the air (#30).
                barButton("TAPE") { showAircheck = true } label: {
                    Image(systemName: services.aircheck.isRecording ? "record.circle.fill" : "recordingtape")
                        .foregroundStyle(services.aircheck.isRecording ? Color(red: 1, green: 0.32, blue: 0.28) : bone.opacity(0.9))
                }
                // READ: live audience research — what's resonating, per market.
                barButton("READ") { showRead = true } label: {
                    Image(systemName: "chart.bar.xaxis")
                        .foregroundStyle(services.theRead.hasBreaking ? accent : bone.opacity(0.9))
                }
                barButton("YOU") { showProfile = true } label: {
                    Image(systemName: "person.fill").foregroundStyle(bone.opacity(0.9))
                }
            }
            .padding(.top, 2)

            Spacer()

            // THE SIGN — the station call, extruded like a lit marquee number,
            // breathing with the low end and sliding under the finger on a
            // tune. This is the hero; everything else frames it.
            VStack(spacing: 10) {
                dimensionalNumber(dialLabel.number)
                    .scaleEffect(1 + CGFloat(player.levels.bass) * 0.03)
                    .animation(.linear(duration: 0.08), value: Int(player.levels.bass * 10))
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.45), value: dialLabel.number)
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(stream.station.name.uppercased())
                        .font(.custom("Archivo Black", size: 24))
                        .tracking(4)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if !dialLabel.unit.isEmpty {
                        Text(dialLabel.unit)
                            .font(.custom("Archivo Black", size: 12))
                            .tracking(2)
                            .foregroundStyle(bone.opacity(0.55))
                    }
                    // The flagship reads as a continuous channel — on 24/7 even
                    // while rotation drives it between live shows.
                    if stream.station.isFlagship {
                        Text("24/7")
                            .font(.custom("Archivo Black", size: 11))
                            .tracking(1.4)
                            .foregroundStyle(ink)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(accent))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .offset(x: plateSlide)
            .opacity(1 - min(0.4, abs(plateSlide) / 500))
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.86), value: plateSlide)
            .allowsHitTesting(false)

            Spacer()

            // THE MARQUEE — bass-lit ember rules, an ON AIR cap, and the track
            // crawling between them like a theater sign. A live show owns it
            // outright (no up-next while a human's on the air).
            VStack(spacing: 0) {
                emberRule
                HStack(spacing: 12) {
                    marqueeCap(player.isLive ? "LIVE" : (yourPick ? "YOUR PICK" : "ON AIR"))
                    if player.isLive {
                        Ticker(text: player.liveTitle.isEmpty
                               ? "LIVE ON \(stream.station.name.uppercased())"
                               : player.liveTitle.uppercased(),
                               font: .custom("Archivo Black", size: 18), color: bone)
                    } else if let np = stream.nowPlaying {
                        Ticker(text: "\(np.track.title) — \(np.track.artistName)"
                               + (np.track.albumTitle.map { " — \($0)" } ?? "")
                               + (services.airLog.dedication(for: np.track.id).map { " — FOR \($0.uppercased())" } ?? ""),
                               font: .custom("Archivo Black", size: 18), color: bone)
                        if np.boostScore != 0 {
                            Text(np.boostScore > 0 ? "▲\(np.boostScore)" : "▼\(-np.boostScore)")
                                .font(.custom("Archivo Black", size: 17))
                                .foregroundStyle(np.boostScore > 0 ? accent : bone.opacity(0.7))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.snappy, value: np.boostScore)
                        }
                    }
                }
                .padding(.vertical, 14)
                emberRule
            }
            .allowsHitTesting(false)

            ControlDeck(stream: stream, accent: accent, onTune: { direction in
                tune(direction)
            }, onDedicate: {
                withAnimation(.easeIn(duration: 0.2)) { dedicating = true }
            })
            .frame(maxWidth: .infinity)
            .padding(.top, 20)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .overlay {
            if momentMarked {
                Text("MARKED")
                    .font(.custom("Archivo Black", size: 13))
                    .tracking(3)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(Rectangle().strokeBorder(accent, lineWidth: 1.5))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: Gestures — the whole plate is the control surface

    /// The plate's live horizontal displacement (0 unless a tune drag owns
    /// the gesture). Slight drag factor so the plate feels weighted.
    private var plateSlide: CGFloat {
        drag.axis == .horizontal ? drag.dx * 0.85 : 0
    }

    private func classify(dx: CGFloat, dy: CGFloat) -> DragAxis? {
        if abs(dx) > abs(dy) * Self.dominance { return .horizontal }
        if abs(dy) > abs(dx) * Self.dominance { return .vertical }
        return nil
    }

    private func plateGestures(in size: CGSize) -> some Gesture {
        let dragGesture = DragGesture(minimumDistance: 12)
            .updating($drag) { value, state, _ in
                let dx = value.translation.width, dy = value.translation.height
                // Lock the axis once the drag clearly commits to one; an
                // ambiguous diagonal stays unclassified and does nothing.
                if state.axis == nil, max(abs(dx), abs(dy)) >= Self.lockDistance {
                    state.axis = classify(dx: dx, dy: dy)
                }
                state.dx = dx
                state.dy = dy
                let nowArmed: Bool
                switch state.axis {
                case .horizontal: nowArmed = abs(dx) >= Self.tuneCommit
                case .vertical: nowArmed = abs(dy) >= Self.voteCommit
                case nil: nowArmed = false
                }
                if nowArmed != state.armed {
                    state.armed = nowArmed
                    // The detent that says "release fires now".
                    if nowArmed { Haptics.detent() }
                }
                // @GestureState drives the live feedback (plateSlide, the vote
                // meter) and nothing else — it resets on cancel automatically,
                // so no drag can leave state behind.
            }
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                let pdx = value.predictedEndTranslation.width
                let pdy = value.predictedEndTranslation.height
                // Decide from THIS gesture's own numbers — no cross-frame
                // mirror, so a prior drag (or a cancelled one) can never leak
                // in. A drag long enough to have locked is judged by where it
                // ACTUALLY went, so an ambiguous long diagonal classifies to
                // nil and is dropped even if the finger flicks sideways at the
                // very end; only a flick too short to lock is judged by its
                // predicted trajectory.
                let axis: DragAxis? = max(abs(dx), abs(dy)) >= Self.lockDistance
                    ? classify(dx: dx, dy: dy)
                    : classify(dx: pdx, dy: pdy)
                switch axis {
                case .horizontal:
                    // Commit on distance, or on a genuine flick (velocity).
                    if abs(dx) >= Self.tuneCommit || abs(pdx) >= Self.tuneCommit * 2 {
                        tune(dx < 0 ? 1 : -1)
                    }
                case .vertical:
                    if abs(dy) >= Self.voteCommit || abs(pdy) >= Self.voteCommit * 2 {
                        vote(dy < 0 ? .boost : .bury)
                    }
                case nil:
                    break // sloppy diagonal: dropped, on purpose
                }
            }
        // Double-tap pins the moment to your ledger. Single tap is
        // deliberately NOTHING — a stray tap must never silence the radio;
        // the deck's 68-point button is the transport.
        let mark = TapGesture(count: 2).onEnded {
            if let np = stream.nowPlaying {
                services.airLog.markMoment(track: np.track, station: stream.station)
                Haptics.detent()
                withAnimation(.easeIn(duration: 0.15)) { momentMarked = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
                    withAnimation(.easeOut(duration: 0.5)) { momentMarked = false }
                }
            }
        }
        return dragGesture.exclusively(before: mark)
    }

    /// The commitment meter for a vertical pull: boost fills upward in the
    /// station color, bury sinks in dimmed bone. Past the commit line the
    /// glyph locks solid — the visual twin of the detent haptic.
    private var voteMeter: some View {
        let boosting = drag.dy < 0
        let progress = min(1, abs(drag.dy) / Self.voteCommit)
        // Both directions read in full ink-contrast: boost takes the station
        // color, BURY stays full bone (not dimmed) so it never washes out over
        // the brightest sand — the center of the plate that neither page scrim
        // reaches.
        let tint = boosting ? accent : bone
        return ZStack {
            // A soft vignette darkens the sand directly under the meter as the
            // pull deepens, so the glyph reads no matter what the figure does.
            RadialGradient(
                colors: [ink.opacity(0.72 * Double(progress)), .clear],
                center: .center, startRadius: 0, endRadius: 160
            )
            .frame(width: 340, height: 340)

            VStack(spacing: 12) {
                Image(systemName: boosting ? "arrow.up" : "arrow.down")
                    .font(.system(size: 56, weight: .heavy))
                    .foregroundStyle(tint)
                    .scaleEffect(0.8 + 0.3 * progress)
                Text(boosting ? "BOOST" : "BURY")
                    .font(.custom("Archivo Black", size: 12))
                    .tracking(3)
                    .foregroundStyle(tint)
                    .opacity(progress > 0.25 ? 1 : 0)
                // The semantics, right where the thumb is: votes program the
                // rotation, they don't skip the song. Answers "what does this do?"
                Text("SHAPES WHAT'S NEXT")
                    .font(.custom("Archivo Black", size: 8))
                    .tracking(2)
                    .foregroundStyle(tint.opacity(0.7))
                    .opacity(progress > 0.5 ? 1 : 0)
            }
            // A tight ink shadow keeps the mark legible before the vignette
            // fully lands (and against a bright transient kick).
            .shadow(color: ink.opacity(0.85), radius: 7)
            .opacity(0.5 + 0.5 * Double(progress))
            .overlay(
                Circle()
                    .strokeBorder(tint, lineWidth: 2)
                    .frame(width: 140, height: 140)
                    .opacity(drag.armed ? 1 : 0)
            )
        }
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.08), value: Int(progress * 20))
        .animation(.easeOut(duration: 0.12), value: drag.armed)
    }

    private func vote(_ direction: VoteDirection) {
        guard let id = stream.nowPlaying?.track.id else { return }
        // Voting is an act: sign in with Apple the first time, then the vote
        // this listener actually meant lands (never a wasted tap).
        auth.requireSignIn(reason: direction == .boost ? "to boost this record" : "to bury this record") {
            services.castMyVote(direction, on: id)
            if direction == .boost {
                plate.strike()
                Haptics.boost()
            } else {
                plate.collapse()
                Haptics.tap()
            }
        }
    }

    private func tune(_ direction: Int) {
        let streams = services.streams
        let next = (accentIndex + direction + streams.count) % streams.count
        plate.staticBurst() // between stations there is static
        services.tune(to: streams[next].station)
        // No name flash overlay — the hero sign (the giant call-number + name)
        // already rolls to the new station and the room recolors. A second big
        // name floating on top just doubled it up.
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

    /// Your boost re-tunes the plate to a higher mode — the whole figure
    /// visibly reorganizes into something more intricate, plus a flare.
    func strike() {
        strikeUntil = Date().addingTimeInterval(0.9)
        baseN = min(9, baseN + 1)
        if abs(baseN - baseM) < 1 { baseM = max(2, baseN - 2) }
    }

    /// Bury drops it a mode and lets the sand slump to the rim for a beat.
    func collapse() {
        collapseUntil = Date().addingTimeInterval(0.8)
        baseN = max(3, baseN - 1)
        if abs(baseN - baseM) < 1 { baseM = max(2, baseN - 2) }
    }

    /// A stranger's vote out in the crowd: brief flare, no re-tune.
    func pulse() {
        strikeUntil = max(strikeUntil, Date().addingTimeInterval(0.3))
    }

    /// Between stations there is static: every grain loses the signal for a
    /// beat, then the new figure locks in.
    private var staticUntil: Date = .distantPast
    func staticBurst() {
        staticUntil = Date().addingTimeInterval(0.55)
    }
    var isStatic: Bool { Date() < staticUntil }

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
        if isStatic { excite += 3.5 } // tuning static: total signal loss
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
        // The figure runs molten by default and goes hotter on every kick.
        let accentMix = min(1, 0.35 + bass * 0.65 + (striking ? 0.5 : 0))

        // Blend a small ramp ONCE per frame — per-grain UIColor bridging at
        // 3,400 grains melts the frame budget the moment bass is audible.
        let rampSteps = 6
        let ramp: [Color] = (0..<rampSteps).map { i in
            bone.mix(with: accent, by: accentMix * Double(i) / Double(rampSteps - 1))
        }

        // Glow pass: the settled figure burns. Blurred fat accent dots under
        // the crisp sand read as neon energy, not dust.
        var glow = canvas
        glow.addFilter(.blur(radius: 7))
        let glowAlpha = 0.28 + bass * 0.45 + (striking ? 0.3 : 0)
        for g in grains where g.bright > 0.55 {
            let p = CGPoint(x: g.x * size.width, y: g.y * size.height)
            let r = 3.2 + g.bright * 2.4
            glow.fill(
                Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)),
                with: .color(accent.opacity(glowAlpha * g.bright))
            )
        }

        for g in grains {
            let p = CGPoint(x: g.x * size.width, y: g.y * size.height)
            let settled = g.bright
            let alpha = 0.35 + settled * 0.65
            let color = ramp[min(rampSteps - 1, Int(settled * Double(rampSteps)))]
            let r = 1.1 + settled * 1.4
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
