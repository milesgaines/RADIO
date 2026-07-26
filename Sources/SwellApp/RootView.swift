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

    @State private var plate = CymaticPlate()
    @State private var stationFlash: String?
    @State private var showProfile = false
    @State private var showRing = false
    @State private var showCallIn = false
    @State private var showBroadcast = false
    @State private var showHostKey = false
    /// The transmit control only exists on a host device (key in Keychain).
    @State private var isHost = BroadcastService.isHost
    @State private var showWelcome = !UserDefaults.standard.bool(forKey: "swell.welcomed")
    @State private var recordIsOn = false
    @State private var dedicating = false
    @State private var dedicationName = ""
    @State private var momentMarked = false

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
    /// No fake FM numbers — the dial speaks record culture, and every
    /// number is literally true: 33⅓ is what an album spins at, 45 is what
    /// a single IS, 78 is the deep-crate speed, and 808 is the machine the
    /// whole genre is built on.
    private var dialLabel: (number: String, unit: String) {
        let name = stream.station.name.lowercased()
        if name == "singles" { return ("45", "RPM") }
        if name == "the underground" { return ("1200", "") }
        if name == "the wave" { return ("247", "") }
        if name == "the vault" { return ("78", "RPM") }
        if accentIndex == 0 { return ("808", "") }
        return ("33\u{2153}", "RPM") // the album station
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

                TimelineView(.animation(minimumInterval: 1.0 / 60)) { context in
                    Canvas { canvas, size in
                        plate.stepAndDraw(in: canvas, size: size, date: context.date)
                    }
                    .ignoresSafeArea()
                    .drawingGroup()
                }
                // Print texture, not screen polish: bass physically smears
                // the color registration; static grain reads as paper tooth.
                .layerEffect(
                    ShaderLibrary.aberration(
                        .float2(geo.size),
                        .float(1.5 + player.levels.bass * 7)
                    ),
                    maxSampleOffset: CGSize(width: 11, height: 11)
                )
                .colorEffect(ShaderLibrary.filmGrain(.float(0.09)))
                // The whole plate pounds with the kick.
                .scaleEffect(1 + CGFloat(player.levels.bass) * 0.022)
                .animation(.linear(duration: 0.09), value: Int(player.levels.bass * 10))

                // Scrims so type reads over the densest sand — washes,
                // not cards. Top third and bottom half get backing.
                LinearGradient(
                    colors: [.clear, ink.opacity(0.7), ink],
                    startPoint: .center, endPoint: .bottom
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)
                LinearGradient(
                    colors: [ink.opacity(0.92), ink.opacity(0.55), .clear],
                    startPoint: .top, endPoint: .init(x: 0.5, y: 0.45)
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                CrowdEmbers(count: stream.nowPlaying?.liveListeners ?? 1, accent: accent)
                    .ignoresSafeArea()

                // The control surface lives UNDER the chrome: a gesture on
                // the ZStack itself swallows every chrome Button (VS, the
                // line, profile — all dead). This clear layer catches
                // tap/flick/swipe anywhere the chrome isn't interactive;
                // chrome buttons above it win their own touches.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .gesture(gestures(in: geo.size), including: showWelcome ? .subviews : .all)

                chrome(in: geo.size)

                if recordIsOn, let np = stream.nowPlaying {
                    VStack(spacing: 10) {
                        Text("YOUR RECORD\nIS ON")
                            .font(.custom("Gasoek One", size: 52))
                            .multilineTextAlignment(.center)
                            .foregroundStyle(ink)
                        Text(np.track.title.uppercased())
                            .font(.custom("Archivo Black", size: 14))
                            .tracking(2)
                            .foregroundStyle(ink.opacity(0.75))
                        if let name = services.airLog.lastPayoffDedication {
                            Text("this one goes out to \(name)")
                                .font(.custom("Instrument Serif", size: 24))
                                .foregroundStyle(ink)
                                .padding(.top, 6)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(accent.opacity(0.96))
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(3)
                    .allowsHitTesting(false)
                }

                if showWelcome {
                    WelcomeOverlay(accent: accent) {
                        UserDefaults.standard.set(true, forKey: "swell.welcomed")
                        withAnimation(.easeOut(duration: 0.5)) { showWelcome = false }
                        player.play()
                        plate.isPlaying = true
                        Haptics.boost()
                    }
                    .transition(.opacity)
                    .zIndex(2)
                }
            }
            .sheet(isPresented: $showProfile) {
                ProfileSheet(stream: stream, accent: accent)
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
            .sheet(isPresented: $showBroadcast) {
                BroadcastConsole(
                    service: services.broadcast,
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
            .alert("Send it out", isPresented: $dedicating) {
                TextField("who's it for", text: $dedicationName)
                Button("SEND IT") {
                    if let id = stream.nowPlaying?.track.id {
                        services.castMyVote(.boost, on: id, dedication: dedicationName)
                        plate.strike()
                        Haptics.boost()
                    }
                    dedicationName = ""
                }
                Button("Cancel", role: .cancel) { dedicationName = "" }
            } message: {
                Text("Boosts this record and puts their name on it when it airs.")
            }
            .onAppear {
                plate.configure(size: geo.size)
                sync()
            }
            .onChange(of: stream.nowPlaying?.track.id) {
                sync()
                // Write the airplay into the ledger; if it pays off a boost
                // this listener wagered, deliver the oldest thrill radio has:
                // they finally played your record.
                if player.isPlaying, let np = stream.nowPlaying {
                    let paidOff = services.airLog.logPlay(track: np.track, station: stream.station)
                    if paidOff {
                        plate.strike()
                        Haptics.boost()
                        withAnimation(.easeIn(duration: 0.25)) { recordIsOn = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
                            withAnimation(.easeOut(duration: 0.9)) { recordIsOn = false }
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

    // Whisper-thin type at the edges. Everything else is sand.
    // Craft rules: one 24pt margin, one hairline (bone 15%), three ink
    // levels only (1.0 / 0.55 / 0.28), Gasoek for the dial number alone,
    // Archivo Black for everything else at exactly two sizes (10 / 13).
    private var hairline: some View {
        Rectangle().fill(bone.opacity(0.15)).frame(height: 1)
            .allowsHitTesting(false)
    }

    private func chrome(in size: CGSize) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Status bar: one line, baseline-locked, ruled underneath.
            HStack(alignment: .center, spacing: 8) {
                RadioPlusMark(size: 19, accent: accent, level: player.isPlaying ? player.levels.bass : 0)
                // No clock here — the status bar already tells the time, and
                // the row must fit VS + phone + person + help on one line.
                Text("LOS ANGELES")
                    .font(.custom("Archivo Black", size: 10))
                    .tracking(1.8)
                    .foregroundStyle(bone.opacity(0.28))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    // The only door to the host key: a long-press an ordinary
                    // listener never discovers. Full-height touch target and
                    // the explicit gesture form — the same combination the
                    // Ring's hold-to-vote uses (onLongPressGesture on a
                    // 12-pt text proved unreliable).
                    .frame(height: 32)
                    .contentShape(Rectangle())
                    .gesture(
                        LongPressGesture(minimumDuration: 0.9)
                            .onEnded { _ in showHostKey = true }
                    )
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    if player.isPlaying || broadcasting {
                        Circle().fill(accent).frame(width: 5, height: 5)
                    }
                    Text(broadcasting ? "ON AIR"
                         : (player.isPlaying
                            ? "LIVE \(stream.nowPlaying?.liveListeners ?? 1)"
                            : "OFF AIR"))
                        .font(.custom("Archivo Black", size: 10))
                        .tracking(1.8)
                        .foregroundStyle(broadcasting || player.isPlaying ? bone : bone.opacity(0.55))
                        .monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
                // GO LIVE: the host's transmit control. Only on a host device;
                // ordinary listeners never see it.
                if isHost {
                    Button { showBroadcast = true } label: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(broadcasting ? accent : bone.opacity(0.55))
                            .frame(width: 28, height: 32)
                    }
                }
                // THE RING: song battles — upload, vote, winner enters
                // rotation. The one place "VS" appears, so it reads as a door.
                Button { showRing = true } label: {
                    Text("VS")
                        .font(.custom("Archivo Black", size: 11))
                        .foregroundStyle(bone.opacity(0.55))
                        .frame(width: 28, height: 32)
                }
                // THE LINE: hold-to-talk call-ins.
                Button { showCallIn = true } label: {
                    Image(systemName: "phone.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(bone.opacity(0.55))
                        .frame(width: 28, height: 32)
                }
                Button { showProfile = true } label: {
                    Image(systemName: "person.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(bone.opacity(0.55))
                        .frame(width: 28, height: 32)
                }
                Button {
                    withAnimation(.easeIn(duration: 0.3)) { showWelcome = true }
                } label: {
                    Image(systemName: "questionmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(bone.opacity(0.55))
                        .frame(width: 28, height: 32)
                }
            }
            .padding(.top, 2)
            hairline.padding(.top, 4)

            // The dial. One hero, one supporting line, same left edge.
            // Display-only chrome must not eat touches — taps and flicks
            // here belong to the plate's gesture layer underneath.
            Text(dialLabel.number)
                .font(.custom("Gasoek One", size: 118))
                .foregroundStyle(bone)
                .monospacedDigit()
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.5), value: dialLabel.number)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 10)
                .allowsHitTesting(false)
            HStack(alignment: .center, spacing: 10) {
                Text(stream.station.name.uppercased())
                    .font(.custom("Archivo Black", size: 16))
                    .tracking(2.5)
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !dialLabel.unit.isEmpty {
                    Text(dialLabel.unit)
                        .font(.custom("Archivo Black", size: 10))
                        .tracking(1.8)
                        .foregroundStyle(bone.opacity(0.55))
                }
                SignalBars(level: player.isPlaying ? player.levels.rms : 0, accent: accent)
            }
            .padding(.top, -14)
            .allowsHitTesting(false)

            Spacer()

            // The chyron block: ruled top and bottom, two crawls, no serif.
            // A live show takes the chyron over — no up-next while a human
            // owns the air (there genuinely is no next; that's the point).
            if player.isLive {
                hairline
                HStack(spacing: 10) {
                    Text("LIVE")
                        .font(.custom("Archivo Black", size: 10))
                        .tracking(1.8)
                        .foregroundStyle(ink)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(accent)
                    Ticker(text: player.liveTitle.isEmpty
                           ? "LIVE ON \(stream.station.name.uppercased())"
                           : player.liveTitle.uppercased(),
                           font: .custom("Archivo Black", size: 13),
                           color: bone)
                }
                .padding(.vertical, 12)
                .allowsHitTesting(false)
                hairline
            } else if let np = stream.nowPlaying {
                hairline
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        Text("ON AIR")
                            .font(.custom("Archivo Black", size: 10))
                            .tracking(1.8)
                            .foregroundStyle(accent)
                            .frame(width: 64, alignment: .leading)
                        Ticker(text: "\(np.track.title) — \(np.track.artistName)"
                               + (np.track.albumTitle.map { " — \($0)" } ?? "")
                               + (services.airLog.dedication(for: np.track.id).map { " — FOR \($0.uppercased())" } ?? ""),
                               font: .custom("Archivo Black", size: 13),
                               color: bone)
                        if np.boostScore != 0 {
                            Text(np.boostScore > 0 ? "▲\(np.boostScore)" : "▼\(-np.boostScore)")
                                .font(.custom("Archivo Black", size: 13))
                                .foregroundStyle(np.boostScore > 0 ? accent : bone.opacity(0.55))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.snappy, value: np.boostScore)
                        }
                    }
                    if !stream.upNextPreview.isEmpty {
                        HStack(spacing: 10) {
                            Text("NEXT")
                                .font(.custom("Archivo Black", size: 10))
                                .tracking(1.8)
                                .foregroundStyle(bone.opacity(0.28))
                                .frame(width: 64, alignment: .leading)
                            Ticker(text: stream.upNextPreview.map(\.title).joined(separator: "   /   ")
                                   + "   /   CROWD-PROGRAMMED",
                                   font: .custom("Archivo Black", size: 13),
                                   color: bone.opacity(0.55), speed: 20)
                        }
                    }
                }
                .padding(.vertical, 12)
                .allowsHitTesting(false)
                hairline
            }

            ControlDeck(stream: stream, accent: accent, onTune: { direction in
                tune(direction)
            }, onDedicate: {
                dedicating = true
            })
            .frame(maxWidth: .infinity)
            .padding(.top, 14)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .overlay {
            if let name = stationFlash {
                Text(name.uppercased())
                    .font(.custom("Gasoek One", size: 40))
                    .foregroundStyle(accent)
                    .shadow(color: ink, radius: 20)
                    .transition(.scale(scale: 1.1).combined(with: .opacity))
                    .id(name)
                    .allowsHitTesting(false)
            }
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

    private func gestures(in size: CGSize) -> some Gesture {
        let swipe = DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                if abs(dx) > abs(dy) {
                    tune(dx < 0 ? 1 : -1)
                } else if dy < -30 {
                    vote(.boost)
                } else if dy > 30 {
                    vote(.bury)
                }
            }
        // Double-tap pins the moment to your ledger; single tap is power.
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
        let tap = TapGesture().onEnded {
            player.toggle()
            plate.isPlaying = player.isPlaying
            Haptics.tap()
        }
        return swipe.exclusively(before: mark.exclusively(before: tap))
    }

    private func vote(_ direction: VoteDirection) {
        guard let id = stream.nowPlaying?.track.id else { return }
        services.castMyVote(direction, on: id)
        if direction == .boost {
            plate.strike()
            Haptics.boost()
        } else {
            plate.collapse()
            Haptics.tap()
        }
    }

    private func tune(_ direction: Int) {
        let streams = services.streams
        let next = (accentIndex + direction + streams.count) % streams.count
        plate.staticBurst() // between stations there is static
        services.tune(to: streams[next].station)
        let name = streams[next].station.name
        withAnimation(.easeIn(duration: 0.2)) { stationFlash = name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            if stationFlash == name { withAnimation(.easeOut(duration: 0.7)) { stationFlash = nil } }
        }
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
