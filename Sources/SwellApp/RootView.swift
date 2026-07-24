import SwiftUI
import RadioKit

// MARK: - RADIO
// The station is a living thing. Every listener feeds a murmuration of ink
// birds flying in bright daylight; the flock IS the crowd. It swirls to the
// music, spells the track title out of its own bodies when a song lands,
// blooms color when the crowd boosts, recoils when it buries, and migrates
// off-screen when you tune away. No cards, no panels, no buttons — flick up
// to boost, flick down to bury, swipe across to tune, tap to play.

struct RootView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var player: RadioPlayer

    var body: some View {
        AviaryView(stream: services.activeStream)
            .preferredColorScheme(.light)
            .persistentSystemOverlays(.hidden)
    }
}

// MARK: - Sky + flock + whisper-thin chrome

private struct AviaryView: View {
    @ObservedObject var stream: LiveStreamService
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var player: RadioPlayer

    @State private var flock = FlockEngine()
    @State private var showHints = true
    @State private var stationCard: String?

    /// Warm paper daylight — never pure white.
    private let sky = Color(red: 0.968, green: 0.953, blue: 0.922)
    private let ink = Color(red: 0.11, green: 0.10, blue: 0.09)

    private var accent: Color {
        FlockEngine.accents[stationIndex % FlockEngine.accents.count]
    }
    private var stationIndex: Int {
        services.streams.firstIndex(where: { $0 === stream }) ?? 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                sky.ignoresSafeArea()

                FlockCanvas(flock: flock)
                    .ignoresSafeArea()

                chrome(in: geo.size)
            }
            .contentShape(Rectangle())
            .gesture(gestures(in: geo.size))
            .onAppear {
                flock.configure(size: geo.size, listeners: stream.nowPlaying?.liveListeners ?? 8)
                syncFlock()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
                    withAnimation(.easeOut(duration: 1.2)) { showHints = false }
                }
            }
            .onChange(of: stream.nowPlaying?.track.id) { syncFlock() }
            .onChange(of: player.isPlaying) { flock.isPlaying = player.isPlaying }
            .onChange(of: stream.nowPlaying?.liveListeners ?? 1) { _, count in
                flock.setCrowd(count)
            }
            .onChange(of: stream.nowPlaying?.boostScore ?? 0) { old, new in
                flock.crowdPing(positive: new >= old)
            }
        }
    }

    private func syncFlock() {
        guard let np = stream.nowPlaying else { return }
        flock.accentIndex = stationIndex
        flock.isPlaying = player.isPlaying
        flock.setCrowd(np.liveListeners)
        flock.spell(np.track.title)
    }

    // The only fixed matter on screen: a few lines of small type at the
    // edges. Everything else is alive.
    private func chrome(in size: CGSize) -> some View {
        VStack {
            HStack(alignment: .firstTextBaseline) {
                Text("radio")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ink)
                Spacer()
                HStack(spacing: 6) {
                    if player.isPlaying {
                        Circle().fill(accent).frame(width: 6, height: 6)
                    }
                    Text(player.isPlaying
                         ? "live · \(stream.nowPlaying?.liveListeners ?? 1) flying with you"
                         : "resting — tap to fly")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ink.opacity(0.55))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 8)

            Spacer()

            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    if let np = stream.nowPlaying {
                        Text(np.track.title)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(ink)
                        Text(np.track.artistName)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(ink.opacity(0.5))
                        if np.boostScore != 0 {
                            Text(np.boostScore > 0
                                 ? "the crowd lifts it +\(np.boostScore)"
                                 : "the crowd lets it go \(np.boostScore)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(np.boostScore > 0 ? accent : ink.opacity(0.4))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                                .animation(.snappy, value: np.boostScore)
                        }
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(stream.station.name.lowercased())
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                    Text("station \(stationIndex + 1) of \(services.streams.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ink.opacity(0.35))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, showHints ? 14 : 26)

            if showHints {
                Text("flick up to boost · down to bury · swipe to tune · tap to play")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ink.opacity(0.35))
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .overlay {
            if let name = stationCard {
                Text(name.lowercased())
                    .font(.system(size: 44, weight: .heavy))
                    .foregroundStyle(ink.opacity(0.9))
                    .transition(.opacity)
                    .id(name)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Gestures — the whole sky is the control surface

    private func gestures(in size: CGSize) -> some Gesture {
        let swipe = DragGesture(minimumDistance: 24)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                if abs(dx) > abs(dy) {
                    tune(direction: dx < 0 ? 1 : -1, size: size)
                } else if dy < -30 {
                    vote(.boost)
                } else if dy > 30 {
                    vote(.bury)
                }
            }
        let tap = TapGesture().onEnded {
            player.toggle()
            flock.isPlaying = player.isPlaying
            Haptics.tap()
        }
        return swipe.exclusively(before: tap)
    }

    private func vote(_ direction: VoteDirection) {
        guard let id = stream.nowPlaying?.track.id else { return }
        stream.vote(direction, on: id)
        if direction == .boost {
            flock.surge()
            Haptics.boost()
        } else {
            flock.recoil()
            Haptics.tap()
        }
    }

    private func tune(direction: Int, size: CGSize) {
        let streams = services.streams
        let next = (stationIndex + direction + streams.count) % streams.count
        flock.migrate(toward: direction) // birds fly out the side you swiped
        services.tune(to: streams[next].station)

        let name = streams[next].station.name
        withAnimation(.easeIn(duration: 0.25)) { stationCard = name }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if stationCard == name {
                withAnimation(.easeOut(duration: 0.8)) { stationCard = nil }
            }
        }
        Haptics.detent()
    }
}

// MARK: - Canvas host

private struct FlockCanvas: View {
    let flock: FlockEngine

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 40)) { context in
            Canvas { canvas, size in
                flock.stepAndDraw(in: canvas, size: size, date: context.date)
            }
        }
    }
}

// MARK: - The flock

/// A few hundred birds with three minds: wander the wind field, spell the
/// title, or migrate off-screen. Everything is a pure function of the sim
/// state, stepped inside the render loop — SwiftUI state never churns.
@MainActor
final class FlockEngine {
    static let accents: [Color] = [
        Color(red: 1.00, green: 0.35, blue: 0.21), // coral      — station 1
        Color(red: 0.16, green: 0.32, blue: 1.00), // cobalt     — station 2
        Color(red: 0.05, green: 0.62, blue: 0.33), // leaf green — station 3
        Color(red: 0.72, green: 0.28, blue: 0.92), // iris       — overflow
    ]

    private struct Bird {
        var x: Double, y: Double
        var vx: Double, vy: Double
        var seed: Double            // per-bird personality
        var target: Int = -1        // index into letterDots, -1 = free
        var ping: Double = 0        // accent flash amount (crowd votes)
    }

    var accentIndex = 0
    var isPlaying = false

    private var birds: [Bird] = []
    private var size: CGSize = .zero
    private var lastStep: Date?
    private var letterDots: [CGPoint] = []
    private var spellUntil: Date = .distantPast
    private var respellAt: Date = .distantFuture
    private var surgeUntil: Date = .distantPast
    private var recoilUntil: Date = .distantPast
    private var migrationX: Double = 0 // -1 left, +1 right, decays
    private var desiredCount = 220

    // MARK: Public verbs

    func configure(size: CGSize, listeners: Int) {
        self.size = size
        setCrowd(listeners)
        if birds.isEmpty {
            for _ in 0..<desiredCount { birds.append(hatch(edge: false)) }
        }
    }

    /// The flock's population tracks the live audience.
    func setCrowd(_ listeners: Int) {
        desiredCount = min(560, 150 + listeners * 9)
    }

    /// Form the title out of birds for a few seconds, then let it dissolve.
    func spell(_ title: String) {
        let text = fittedText(from: title)
        letterDots = Self.layout(text: text, in: size)
        assignTargets()
        spellUntil = Date().addingTimeInterval(6.0)
        respellAt = Date().addingTimeInterval(26.0)
    }

    /// Boost: the whole organism lifts and blooms.
    func surge() {
        surgeUntil = Date().addingTimeInterval(1.4)
        for i in birds.indices where Double.random(in: 0...1) < 0.5 {
            birds[i].ping = 1.0
        }
    }

    /// Bury: it flinches and dims.
    func recoil() {
        recoilUntil = Date().addingTimeInterval(1.0)
    }

    /// A crowd vote lands somewhere out there — a few birds flash.
    func crowdPing(positive: Bool) {
        let count = positive ? 5 : 2
        for _ in 0..<count {
            if let i = birds.indices.randomElement() {
                birds[i].ping = positive ? 1.0 : 0.4
            }
        }
    }

    /// Tuning: current birds stream off one side; newcomers blow in.
    func migrate(toward direction: Int) {
        migrationX = Double(direction) * -1 // swipe left = birds exit left
        spellUntil = .distantPast
        for i in birds.indices {
            birds[i].vx += migrationX * Double.random(in: 260...420)
            birds[i].vy += Double.random(in: -60...60)
            birds[i].target = -1
        }
    }

    // MARK: Simulation + draw (one pass, no retained SwiftUI state)

    func stepAndDraw(in canvas: GraphicsContext, size: CGSize, date: Date) {
        if self.size != size { self.size = size }
        let dt = min(lastStep.map { date.timeIntervalSince($0) } ?? 1 / 40, 1 / 20)
        lastStep = date
        let t = date.timeIntervalSinceReferenceDate

        if date > respellAt, !letterDots.isEmpty {
            assignTargets()
            spellUntil = date.addingTimeInterval(5.0)
            respellAt = date.addingTimeInterval(26.0)
        }

        stepPopulation()
        let spelling = date < spellUntil
        let surging = date < surgeUntil
        let recoiling = date < recoilUntil
        migrationX *= pow(0.2, dt)

        let cx = size.width / 2
        let cy = size.height * 0.44
        let tempo = isPlaying ? 1.0 : 0.35
        let breathe = isPlaying ? (0.5 + 0.5 * sin(t * 0.9)) : 0.15

        for i in birds.indices {
            var b = birds[i]

            if spelling, b.target >= 0, b.target < letterDots.count {
                // Spring to the assigned letter dot.
                let dot = letterDots[b.target]
                b.vx += (dot.x - b.x) * 7.0 * dt * 60 / 12
                b.vy += (dot.y - b.y) * 7.0 * dt * 60 / 12
                b.vx *= pow(0.0018, dt) // heavy damping settles the glyphs
                b.vy *= pow(0.0018, dt)
            } else {
                // Wind field: three layered rotating currents — organic,
                // correlated motion without O(n²) neighbor math.
                let windX = sin(b.y * 0.011 + t * 0.7 * tempo + b.seed)
                    + 0.6 * sin(b.y * 0.023 - t * 0.41 * tempo + b.seed * 2)
                let windY = cos(b.x * 0.009 - t * 0.53 * tempo + b.seed)
                    + 0.6 * sin(b.x * 0.017 + t * 0.67 * tempo + b.seed * 3)
                b.vx += windX * (34 + 26 * breathe) * dt * tempo
                b.vy += windY * (30 + 22 * breathe) * dt * tempo

                // Soft gravity toward the roost keeps the flock on stage.
                b.vx += (cx - b.x) * 0.14 * dt
                b.vy += (cy - b.y) * 0.16 * dt

                if surging {
                    b.vy -= 260 * dt
                    b.vx += sin(b.seed * 7 + t * 3) * 90 * dt
                }
                if recoiling {
                    b.vx += (b.x - cx) * -0.9 * dt
                    b.vy += (b.y - cy) * -0.9 * dt
                }

                b.vx *= pow(0.28, dt)
                b.vy *= pow(0.28, dt)
            }

            b.x += b.vx * dt
            b.y += b.vy * dt
            b.ping = max(0, b.ping - dt * 1.6)

            // Migrating birds that leave get rehatched on the far edge.
            if b.x < -40 || b.x > Double(size.width) + 40 || b.y < -60 || b.y > Double(size.height) + 60 {
                b = hatch(edge: true)
            }
            birds[i] = b
        }

        draw(canvas: canvas, spelling: spelling, t: t)
    }

    private func draw(canvas: GraphicsContext, spelling: Bool, t: Double) {
        let ink = Color(red: 0.11, green: 0.10, blue: 0.09)
        let accent = Self.accents[accentIndex % Self.accents.count]

        for (i, b) in birds.enumerated() {
            // A bird is a short stroke along its heading — a brushmark, not
            // a circle. Size varies by personality; a handful wear the
            // station's color even at rest.
            let speed = max(18, min(240, (b.vx * b.vx + b.vy * b.vy).squareRoot()))
            let nx = b.vx / speed, ny = b.vy / speed
            let len = 2.6 + b.seed.truncatingRemainder(dividingBy: 1) * 3.4 + speed * 0.012
            let wingbeat = spelling ? 1.0 : (0.75 + 0.25 * sin(t * 9 + b.seed * 20))

            var path = Path()
            path.move(to: CGPoint(x: b.x - nx * len * wingbeat, y: b.y - ny * len * wingbeat))
            path.addLine(to: CGPoint(x: b.x + nx * len * wingbeat, y: b.y + ny * len * wingbeat))

            let isAccentBird = i % 17 == 0
            let color: Color
            if b.ping > 0 {
                color = accent.opacity(0.35 + 0.65 * b.ping)
            } else if isAccentBird {
                color = accent.opacity(0.85)
            } else {
                color = ink.opacity(isPlaying ? 0.82 : 0.5)
            }
            canvas.stroke(path, with: .color(color),
                          style: StrokeStyle(lineWidth: 1.9, lineCap: .round))
        }
    }

    // MARK: Internals

    private func stepPopulation() {
        while birds.count < desiredCount { birds.append(hatch(edge: true)) }
        if birds.count > desiredCount { birds.removeLast(birds.count - desiredCount) }
    }

    private func hatch(edge: Bool) -> Bird {
        let w = Double(size.width), h = Double(size.height)
        let entering = migrationX != 0
        let x: Double
        let y: Double
        if edge {
            // Newcomers blow in from the side opposite the migration, or a
            // random edge when the flock is simply growing.
            let side = entering ? (migrationX < 0 ? w + 30 : -30) : (Bool.random() ? -30 : w + 30)
            x = side
            y = Double.random(in: h * 0.1...h * 0.75)
        } else {
            x = Double.random(in: w * 0.2...w * 0.8)
            y = Double.random(in: h * 0.2...h * 0.6)
        }
        return Bird(
            x: x, y: y,
            vx: Double.random(in: -40...40) + (entering ? migrationX * 220 : 0),
            vy: Double.random(in: -30...30),
            seed: Double.random(in: 0...100)
        )
    }

    private func assignTargets() {
        guard !letterDots.isEmpty else { return }
        var order = Array(birds.indices).shuffled()
        // The nearest ~N birds take the letters; the rest keep flying as a
        // halo around the words.
        order = Array(order.prefix(letterDots.count * 2))
        for (slot, birdIndex) in order.enumerated() {
            birds[birdIndex].target = slot % 2 == 0 ? (slot / 2) % letterDots.count : -1
        }
        for i in birds.indices where !order.contains(i) {
            birds[i].target = -1
        }
    }

    private func fittedText(from title: String) -> String {
        let clean = title.uppercased()
        if clean.count <= 12 { return clean }
        // Prefer the first word if the full title won't read at flock scale.
        let first = clean.split(separator: " ").first.map(String.init) ?? clean
        return String(first.prefix(12))
    }

    private static func layout(text: String, in size: CGSize) -> [CGPoint] {
        let grid = DotMatrixFont.dotPositions(for: text)
        guard let maxX = grid.map(\.x).max() else { return [] }
        let columns = maxX + 1
        let pitch = min(14, (size.width * 0.86) / columns)
        let originX = (size.width - columns * pitch) / 2
        let originY = size.height * 0.40 - 3.5 * pitch
        return grid.map {
            CGPoint(x: originX + $0.x * pitch + pitch / 2,
                    y: originY + $0.y * pitch + pitch / 2)
        }
    }
}

// MARK: - Haptics

enum Haptics {
    static func tap() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    static func boost() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func detent() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
