import Foundation
import AVFoundation
import RadioKit

/// GO LIVE — a human takes the air. This is the producer half of the live
/// show; the listener half already exists (`radio_live` → `onLiveShow` →
/// `RadioPlayer.goLive`). Here we turn the mic into HLS on the phone
/// (`BroadcastEncoder`) and push each segment + a rolling playlist up to the
/// `live-ingest` Edge Function, which writes them to the public `radio-live`
/// bucket and flips `radio_live` so every tuned device swaps to the stream.
///
/// Gated, on purpose: seizing every listener's speaker is not an open mic.
/// Going live requires the **host key** (the same `radio_admin` key that
/// approves call-ins), kept in the Keychain and never shipped in the binary —
/// so the control is dormant for everyone who isn't the station.
@MainActor
final class BroadcastService: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case starting
        case onAir(since: Date)
        case stopping
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Mic loudness for the console meter, 0…1.
    @Published private(set) var level: Float = 0

    /// The key that gates going live. Nil ⇒ this device is not a host and the
    /// GO LIVE control stays hidden.
    static let hostKeyKeychainKey = "radi0.host.key"
    static func hostKey() -> String? {
        KeychainSecretStore.shared.secret(forKey: hostKeyKeychainKey)
    }
    static var isHost: Bool { (hostKey()?.isEmpty == false) }

    /// True from the instant we commit to going live until teardown finishes —
    /// AppServices reads this to suppress the host's *own* `goLive` (hearing
    /// your own stream is a feedback loop and 15 s of latency).
    private(set) var isBroadcasting = false
    /// The station this broadcast owns (uppercased app id form).
    private(set) var stationID: String?

    /// Pause/resume the radio around the broadcast — the mic can't share the
    /// output with the plate, and the host isn't a listener while on air.
    var pauseRadio: () -> Void = {}
    var resumeRadio: () -> Void = {}

    private static let publishableKey = "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii"
    private static let ingestURL = URL(string: "https://tgkgdquivdoquxamtgcr.supabase.co/functions/v1/live-ingest")!

    private let encoder = BroadcastEncoder(segmentSeconds: 4)
    private var sessionID = ""
    private var key = ""

    /// The rolling DVR window kept in the live playlist. Older segments stay
    /// in the bucket but drop off the playlist; media-sequence advances.
    private struct Seg { let sequence: Int; let name: String; let duration: Double }
    private var segments: [Seg] = []
    private let windowSize = 8
    private var haveInit = false

    /// Uploads run strictly in order through this drain — a playlist must
    /// never name a segment whose bytes haven't landed yet.
    private enum Job {
        case segment(name: String, data: Data, contentType: String)
        case playlist(text: String)
    }
    private var jobs: [Job] = []
    private var draining = false

    override init() { super.init() }

    func attach(stationID: String) { self.stationID = stationID }

    /// Clear a terminal failure so the console returns to its GO LIVE stage.
    func reset() {
        if case .failed = state, !isBroadcasting { state = .idle }
    }

    // MARK: - Go live

    func goLive(title: String, stationID: String) {
        guard case .idle = state else { return }
        guard let hostKey = Self.hostKey(), !hostKey.isEmpty else {
            state = .failed("NOT A HOST")
            return
        }
        self.key = hostKey
        self.stationID = stationID
        state = .starting

        Task { @MainActor in
            #if os(iOS)
            let granted = await AVAudioApplication.requestRecordPermission()
            guard granted else { self.state = .failed("MIC IS OFF — SETTINGS › RADI0"); return }
            #endif

            // Borrow the audio session and clear the radio off the output.
            self.pauseRadio()
            #if os(iOS)
            let audio = AVAudioSession.sharedInstance()
            do {
                try audio.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
                try audio.setActive(true)
            } catch {
                self.state = .failed("MIC UNAVAILABLE"); return
            }
            #endif

            self.sessionID = UUID().uuidString
            self.segments.removeAll()
            self.haveInit = false
            self.jobs.removeAll()
            self.isBroadcasting = true

            // Hand the server the show: it validates the key, writes the live
            // row (title + the playlist's public URL), and returns that URL.
            switch await self.postStart(title: title) {
            case .success:
                self.encoder.delegate = self
                self.encoder.start()
                self.state = .onAir(since: Date())
            case .failure(let message):
                self.isBroadcasting = false
                self.restoreSession()
                self.state = .failed(message)
            }
        }
    }

    func endBroadcast() {
        guard isBroadcasting else { return }
        state = .stopping
        encoder.stop { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // Close the playlist (ENDLIST) so late joiners stop cleanly,
                // then tell the server to flip the live row off.
                await self.drainNow()
                if !self.segments.isEmpty {
                    await self.perform(.playlist(text: self.buildPlaylist(ended: true)))
                }
                _ = await self.postStop()
                self.isBroadcasting = false
                self.level = 0
                self.restoreSession()
                self.resumeRadio()
                self.state = .idle
            }
        }
    }

    private func restoreSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        #endif
    }

    // MARK: - Playlist

    private func buildPlaylist(ended: Bool) -> String {
        let window = Array(segments.suffix(windowSize))
        let firstSeq = window.first?.sequence ?? 0
        let target = max(1, Int(ceil(window.map(\.duration).max() ?? encoder.segmentSeconds)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:\(firstSeq)",
            "#EXT-X-MAP:URI=\"init.mp4\"",
        ]
        for s in window {
            lines.append(String(format: "#EXTINF:%.3f,", s.duration))
            lines.append(s.name)
        }
        if ended { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Upload drain (ordered)

    private func enqueue(_ job: Job) {
        jobs.append(job)
        Task { @MainActor in await self.drainNow() }
    }

    private func drainNow() async {
        guard !draining else { return }
        draining = true
        while !jobs.isEmpty {
            let job = jobs.removeFirst()
            await perform(job)
        }
        draining = false
    }

    private func perform(_ job: Job) async {
        switch job {
        case .segment(let name, let data, let contentType):
            _ = await postSegment(name: name, data: data, contentType: contentType)
        case .playlist(let text):
            _ = await postPlaylist(text: text)
        }
    }

    // MARK: - Edge Function calls (multipart, mirrors CallInService)

    private enum StartResult { case success; case failure(String) }

    private func multipart(_ fields: [(String, String)],
                           file: (name: String, filename: String, contentType: String, data: Data)?) -> (Data, String) {
        let boundary = "live-\(UUID().uuidString)"
        var body = Data()
        for (k, v) in fields {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n".data(using: .utf8)!)
        }
        if let file {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\nContent-Type: \(file.contentType)\r\n\r\n".data(using: .utf8)!)
            body.append(file.data)
            body.append("\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return (body, boundary)
    }

    private func send(_ body: Data, boundary: String) async -> (Int, Data)? {
        var request = URLRequest(url: Self.ingestURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")
        guard let (data, response) = try? await URLSession.shared.upload(for: request, from: body) else { return nil }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func postStart(title: String) async -> StartResult {
        let (body, boundary) = multipart([
            ("action", "start"),
            ("station_id", stationID?.lowercased() ?? ""),
            ("session", sessionID),
            ("key", key),
            ("title", title),
        ], file: nil)
        guard let (code, data) = await send(body, boundary: boundary) else { return .failure("NO SIGNAL") }
        switch code {
        case 200: return .success
        case 401, 403: return .failure("KEY REJECTED")
        default:
            struct Err: Decodable { let error: String? }
            let msg = (try? JSONDecoder().decode(Err.self, from: data))?.error
            return .failure((msg ?? "START FAILED").uppercased())
        }
    }

    private func postSegment(name: String, data: Data, contentType: String) async -> Bool {
        let (body, boundary) = multipart([
            ("action", "segment"),
            ("station_id", stationID?.lowercased() ?? ""),
            ("session", sessionID),
            ("key", key),
            ("name", name),
        ], file: (name: "file", filename: name, contentType: contentType, data: data))
        let code = await send(body, boundary: boundary)?.0 ?? 0
        return code == 200
    }

    private func postPlaylist(text: String) async -> Bool {
        let (body, boundary) = multipart([
            ("action", "playlist"),
            ("station_id", stationID?.lowercased() ?? ""),
            ("session", sessionID),
            ("key", key),
            ("playlist", text),
        ], file: nil)
        let code = await send(body, boundary: boundary)?.0 ?? 0
        return code == 200
    }

    private func postStop() async -> Bool {
        let (body, boundary) = multipart([
            ("action", "stop"),
            ("station_id", stationID?.lowercased() ?? ""),
            ("session", sessionID),
            ("key", key),
        ], file: nil)
        let code = await send(body, boundary: boundary)?.0 ?? 0
        return code == 200
    }
}

// MARK: - Encoder → uploads

extension BroadcastService: BroadcastEncoderDelegate {
    func encoder(_ encoder: BroadcastEncoder, didProduceInitialization data: Data) {
        haveInit = true
        enqueue(.segment(name: "init.mp4", data: data, contentType: "video/mp4"))
    }

    func encoder(_ encoder: BroadcastEncoder, didProduceSegment data: Data, sequence: Int, duration: Double) {
        let name = String(format: "seg%05d.m4s", sequence)
        segments.append(Seg(sequence: sequence, name: name, duration: duration))
        enqueue(.segment(name: name, data: data, contentType: "video/iso.segment"))
        // Publish the playlist right after its newest segment — the drain is
        // FIFO, so the segment bytes are guaranteed up first.
        if haveInit { enqueue(.playlist(text: buildPlaylist(ended: false))) }
    }

    func encoder(_ encoder: BroadcastEncoder, micLevel level: Float) {
        self.level = level
    }

    func encoder(_ encoder: BroadcastEncoder, didFailWith message: String) {
        guard isBroadcasting || state == .starting else { return }
        isBroadcasting = false
        level = 0
        restoreSession()
        resumeRadio()
        state = .failed(message)
        // Best-effort: tell the server the show is over so no live row is left
        // stuck on with a dead stream.
        Task { @MainActor in _ = await self.postStop() }
    }
}
