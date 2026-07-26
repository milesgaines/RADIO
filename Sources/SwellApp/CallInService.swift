import Foundation
import AVFoundation

/// THE LINE — call-ins. Hold to talk (30s max), sign it, send it. The
/// recording lands in a server-side moderation queue (`radio_callins`,
/// status pending); the director airs APPROVED calls between songs via the
/// air queue. Nothing reaches the broadcast without approval — an open mic
/// to the air would be an open door to abuse.
@MainActor
final class CallInService: NSObject, ObservableObject {

    enum State: Equatable {
        case idle
        case recording(startedAt: Date)
        case recorded(duration: Double)
        case uploading
        case onTheLine
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    let maxSeconds: Double = 30

    private static let submitURL = URL(string: "https://tgkgdquivdoquxamtgcr.supabase.co/functions/v1/callin-submit")!
    private static let publishableKey = "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii"

    private let listenerKey: String
    private var recorder: AVAudioRecorder?
    private var takeURL: URL?
    private var stopTask: Task<Void, Never>?

    init(listenerKey: String) {
        self.listenerKey = listenerKey
    }

    // MARK: - Recording

    func beginRecording() {
        guard case .idle = state else { return }
        #if os(iOS)
        Task { @MainActor [weak self] in
            let granted = await AVAudioApplication.requestRecordPermission()
            guard let self else { return }
            guard granted else {
                self.state = .failed("MIC IS OFF — SETTINGS › RADI0")
                return
            }
            self.startRecorder()
        }
        #else
        startRecorder()
        #endif
    }

    private func startRecorder() {
        guard case .idle = state else { return }
        #if os(iOS)
        // The mic borrows the audio session; the radio's playback config is
        // restored the moment the take ends (see restorePlaybackSession).
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
            try session.setActive(true)
        } catch {
            state = .failed("MIC UNAVAILABLE")
            return
        }
        #endif
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("callin-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 96_000,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.record()
            self.recorder = recorder
            self.takeURL = url
            state = .recording(startedAt: Date())
            // Hard stop at the cap — radio calls are tight by design.
            stopTask?.cancel()
            stopTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(30 * 1_000_000_000))
                guard let self, case .recording = self.state else { return }
                self.endRecording()
            }
        } catch {
            state = .failed("MIC UNAVAILABLE")
            restorePlaybackSession()
        }
    }

    func endRecording() {
        guard case .recording(let startedAt) = state, let recorder else { return }
        stopTask?.cancel()
        recorder.stop()
        self.recorder = nil
        restorePlaybackSession()
        let duration = min(Date().timeIntervalSince(startedAt), maxSeconds)
        if duration < 1 {
            // A tap, not a take.
            scrapTake()
            state = .idle
        } else {
            state = .recorded(duration: duration)
        }
    }

    func scrap() {
        // Mid-upload the take file is already read into the request body —
        // let the send finish rather than yanking state out from under it.
        if case .uploading = state { return }
        stopTask?.cancel()
        recorder?.stop()
        recorder = nil
        restorePlaybackSession()
        scrapTake()
        state = .idle
    }

    private func scrapTake() {
        if let takeURL { try? FileManager.default.removeItem(at: takeURL) }
        takeURL = nil
    }

    /// The radio's session config must come back after the mic borrows it —
    /// otherwise the next play() runs under .playAndRecord and ducks output.
    private func restorePlaybackSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        #endif
    }

    // MARK: - Send

    func send(handle: String, stationID: String) async {
        guard case .recorded(let duration) = state, let takeURL,
              let data = try? Data(contentsOf: takeURL) else {
            state = .failed("THE TAKE IS GONE — TRY AGAIN")
            return
        }
        state = .uploading

        let boundary = "line-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("station_id", stationID.lowercased())
        field("handle", handle)
        field("listener_key", listenerKey)
        field("duration_seconds", String(duration))
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"audio\"; filename=\"call.m4a\"\r\nContent-Type: audio/mp4\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var request = URLRequest(url: Self.submitURL)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.publishableKey, forHTTPHeaderField: "apikey")

        do {
            let (_, response) = try await URLSession.shared.upload(for: request, from: body)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch code {
            case 200:
                scrapTake()
                state = .onTheLine
            case 429:
                state = .failed("LINE'S FULL TODAY — 5 CALLS A DAY")
            default:
                state = .failed("SEND FAILED — TRY AGAIN")
            }
        } catch {
            state = .failed("NO SIGNAL — TRY AGAIN")
        }
    }
}
