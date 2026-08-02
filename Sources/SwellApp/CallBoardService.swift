import Foundation
import AVFoundation
import Supabase

/// THE BOARD — the screener's desk. Pending call-ins land in a moderation
/// queue (radio_callins, status='pending'); until a host approves one, it
/// never airs. This is that missing surface: list the queue, audition a take,
/// and AIR it (into the rotation's air queue) or DROP it.
///
/// Approval is gated by the host key — the same radio_admin key that gates
/// GO LIVE, held only in this device's Keychain. The SECURITY DEFINER RPCs
/// (radio_approve_callin / radio_reject_callin) re-check it server-side, so
/// the key never leaves the host's phone except to the function that verifies
/// it. No admin secret is ever shipped in the binary.
@MainActor
final class CallBoardService: NSObject, ObservableObject {

    struct Call: Identifiable, Equatable {
        let id: UUID
        let handle: String
        let stationID: String
        let audioURL: URL?
        let duration: Double
        let createdAt: Date
    }

    @Published private(set) var pending: [Call] = []
    @Published private(set) var busy = false
    @Published private(set) var auditioning: UUID?
    @Published private(set) var note: String?

    private static let projectURL = URL(string: "https://tgkgdquivdoquxamtgcr.supabase.co")!
    private static let publishableKey = "sb_publishable_JYYXKdhcGnEP5curdG_pLg_XVcy9-ii"
    private let client = SupabaseClient(supabaseURL: CallBoardService.projectURL,
                                        supabaseKey: CallBoardService.publishableKey)
    private var audition: AVPlayer?
    private var auditionEndObserver: NSObjectProtocol?

    /// A host device has the key; a listener never sees THE BOARD.
    var isHost: Bool { BroadcastService.isHost }

    private struct Row: Decodable {
        let id: UUID
        let handle: String
        let station_id: UUID
        let audio_url: String
        let duration_seconds: Double
        let created_at: Date
    }

    func refresh() async {
        guard isHost else { pending = []; return }
        let rows: [Row]? = try? await client
            .from("radio_callins")
            .select("id,handle,station_id,audio_url,duration_seconds,created_at")
            .eq("status", value: "pending")
            .order("created_at", ascending: true)
            .limit(50)
            .execute()
            .value
        pending = (rows ?? []).map {
            Call(id: $0.id, handle: $0.handle, stationID: $0.station_id.uuidString,
                 audioURL: URL(string: $0.audio_url), duration: $0.duration_seconds,
                 createdAt: $0.created_at)
        }
    }

    /// Audition a take through the earpiece-agnostic playback session. Tapping
    /// the same call again stops it.
    func toggleAudition(_ call: Call) {
        if auditioning == call.id { stopAudition(); return }
        guard let url = call.audioURL else { return }
        stopAudition()   // tear down any in-flight audition AND its end-observer
        let player = AVPlayer(url: url)
        audition = player
        auditioning = call.id
        player.play()
        // Keep the token so stopAudition can unregister it. A block observer
        // added per audition and never removed piles up for the service's
        // lifetime, leaving stale registrations on deallocated player items.
        auditionEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.stopAudition() }
        }
    }

    func stopAudition() {
        if let token = auditionEndObserver {
            NotificationCenter.default.removeObserver(token)
            auditionEndObserver = nil
        }
        audition?.pause()
        audition = nil
        auditioning = nil
    }

    func air(_ call: Call) async { await moderate(call, approve: true) }
    func drop(_ call: Call) async { await moderate(call, approve: false) }

    private func moderate(_ call: Call, approve: Bool) async {
        guard let key = BroadcastService.hostKey(), !key.isEmpty else { note = "NOT A HOST"; return }
        busy = true
        defer { busy = false }
        stopAudition()
        struct P: Encodable { let p_id: UUID; let p_key: String }
        let ok: Bool? = try? await client
            .rpc(approve ? "radio_approve_callin" : "radio_reject_callin",
                 params: P(p_id: call.id, p_key: key))
            .execute()
            .value
        if ok == true {
            pending.removeAll { $0.id == call.id }
            note = approve ? "ON AIR — AIRS BETWEEN RECORDS" : "DROPPED"
        } else {
            note = "KEY REJECTED"
        }
    }
}
