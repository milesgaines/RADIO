import Foundation
import AVFoundation
import Combine
import RadioKit

/// An AIRCHECK — the radio term for a tape of your own show off the air. HIT
/// RECORD taps the program straight off the main mix (no mic, no permission)
/// and keeps a card of the moment: the station, the dial, the record that was
/// on, the time, how long you rolled. The clip is a bonus when there's live
/// engine audio; the card is always real and always shareable.
struct Aircheck: Identifiable, Codable, Equatable {
    let id: UUID
    let stationName: String
    let dial: String
    let trackTitle: String
    let artistName: String
    let at: Date
    var duration: Double
    /// File name (relative to the airchecks directory) of the captured clip,
    /// or nil for a metadata-only aircheck (remote stream / no engine audio).
    var fileName: String?

    init(id: UUID = UUID(), stationName: String, dial: String, trackTitle: String,
         artistName: String, at: Date, duration: Double = 0, fileName: String? = nil) {
        self.id = id; self.stationName = stationName; self.dial = dial
        self.trackTitle = trackTitle; self.artistName = artistName
        self.at = at; self.duration = duration; self.fileName = fileName
    }
}

@MainActor
final class AircheckService: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var airchecks: [Aircheck] = []

    private weak var player: RadioPlayer?
    private var file: AVAudioFile?
    private var startedAt: Date?
    private var pending: Aircheck?
    private var ticker: Timer?
    private var preview: AVAudioPlayer?

    private let dir: URL
    private let indexKey = "swell.airchecks.index.v1"

    /// A soft cap so a forgotten record button can't fill the disk.
    private let maxClipSeconds: Double = 90

    init(player: RadioPlayer) {
        self.player = player
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        dir = docs.appendingPathComponent("airchecks", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        load()
    }

    var count: Int { airchecks.count }

    func url(for aircheck: Aircheck) -> URL? {
        aircheck.fileName.map { dir.appendingPathComponent($0) }
    }

    // MARK: - Record

    func toggle(station: Station, now: NowPlaying?) {
        isRecording ? stop() : start(station: station, now: now)
    }

    func start(station: Station, now: NowPlaying?) {
        guard !isRecording else { return }
        // The broadcast owns the main-mix tap while a show is on the air —
        // one tap per bus, so rolling tape would tear the transmitter out and
        // freeze every listener's playlist. Refuse rather than kill the show.
        if player?.djModeActive == true { return }
        let name = "aircheck-\(UUID().uuidString).caf"
        let clipURL = dir.appendingPathComponent(name)

        // Roll tape off the main mix. A nil format means the engine isn't up
        // (a remote stream on a clean route) — we still keep the card.
        var savedFileName: String? = nil
        if let format = player?.installAircheckTap({ [weak self] buffer, _ in
            guard let self, let f = self.file else { return }
            try? f.write(from: buffer)
        }) {
            if let f = try? AVAudioFile(forWriting: clipURL, settings: format.settings) {
                file = f
                savedFileName = name
            } else {
                player?.removeAircheckTap()
            }
        }

        pending = Aircheck(
            stationName: station.name, dial: station.dial,
            trackTitle: now?.track.title ?? "—",
            artistName: now?.track.artistName ?? "",
            at: Date(), duration: 0, fileName: savedFileName
        )
        startedAt = Date()
        elapsed = 0
        isRecording = true
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        Haptics.boost()
    }

    private func tick() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= maxClipSeconds { stop() }
    }

    func stop() {
        guard isRecording else { return }
        ticker?.invalidate(); ticker = nil
        if file != nil { player?.removeAircheckTap() }
        file = nil
        isRecording = false
        guard var done = pending else { return }
        done.duration = elapsed
        startedAt = nil
        pending = nil
        airchecks.insert(done, at: 0)
        save()
        Haptics.detent()
    }

    // MARK: - Preview playback

    func play(_ aircheck: Aircheck) {
        guard let u = url(for: aircheck), FileManager.default.fileExists(atPath: u.path) else { return }
        preview = try? AVAudioPlayer(contentsOf: u)
        preview?.play()
    }

    func stopPreview() { preview?.stop(); preview = nil }

    func delete(_ aircheck: Aircheck) {
        if let u = url(for: aircheck) { try? FileManager.default.removeItem(at: u) }
        airchecks.removeAll { $0.id == aircheck.id }
        save()
    }

    // MARK: - Persistence (metadata only; clips live as files)

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: indexKey),
              let decoded = try? JSONDecoder().decode([Aircheck].self, from: data) else { return }
        // Drop entries whose clip file vanished but keep metadata-only cards
        // (those never wrote a file, so there's nothing to go missing).
        airchecks = decoded.filter { ac in
            guard let u = url(for: ac) else { return true }
            return FileManager.default.fileExists(atPath: u.path)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(airchecks) {
            UserDefaults.standard.set(data, forKey: indexKey)
        }
    }
}
