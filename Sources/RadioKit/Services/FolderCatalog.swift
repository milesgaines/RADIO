import Foundation
import AVFoundation
import AudioToolbox

/// Builds a real playable catalog from a folder of audio files — the bridge
/// between "we have actual masters on disk" and the station engine.
///
/// Every file dropped in the folder is treated as **licensed for interactive
/// use**: the folder is the operator's curated staging area for the OneSync
/// opt-in catalog, so placement *is* the license assertion in this MVP. The
/// production swap replaces this with the OneSync feed, where the flag comes
/// from the actual signed opt-in.
///
/// Metadata (title/artist/album) is read from the files' own tags; filenames
/// are the fallback. Artist identity is a stable hash of the artist name so
/// the rotation engine's per-artist complement rules work across launches.
public enum FolderCatalog {

    public static let supportedExtensions: Set<String> = ["m4a", "mp3", "wav", "aiff", "aif", "flac", "caf"]

    /// Load every supported audio file in `folder` as a Track. One level of
    /// subfolders is honored as an *album* — `RealAudio/Heavy Is the Crown/x.m4a`
    /// gets that album title (embedded tags still win); loose files at the
    /// root are singles. Files that can't be opened as audio are skipped.
    public static func load(from folder: URL) -> [Track] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var tracks: [Track] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                let albumName = entry.lastPathComponent
                let albumFiles = (try? fm.contentsOfDirectory(
                    at: entry,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )) ?? []
                tracks += albumFiles
                    .filter { supportedExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    .compactMap { track(for: $0, album: albumName) }
            } else if supportedExtensions.contains(entry.pathExtension.lowercased()) {
                if let track = track(for: entry, album: nil) { tracks.append(track) }
            }
        }
        return tracks
    }

    static func track(for url: URL, album: String? = nil) -> Track? {
        // AVAudioFile gives an exact, synchronous frame count for local files
        // (metadata duration in headers can lie; frames don't).
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration > 1 else { return nil } // skip stubs/corrupt files

        let tags = infoDictionary(for: url)
        func tag(_ key: String) -> String? {
            (tags[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        }

        // Embedded tags win; otherwise the "Artist - Title.m4a" filename
        // convention; otherwise a de-slugged filename with unknown artist.
        let parsed = parseFilename(url.deletingPathExtension().lastPathComponent)
        let title = tag(kAFInfoDictionary_Title) ?? parsed.title
        let artistName = tag(kAFInfoDictionary_Artist) ?? parsed.artist ?? "Unknown Artist"

        return Track(
            id: stableID("track:\(url.lastPathComponent)"),
            title: title,
            artistID: stableID("artist:\(artistName.lowercased())"),
            artistName: artistName,
            albumTitle: tag(kAFInfoDictionary_Album) ?? album,
            durationSeconds: duration,
            assetURL: url,
            artworkURL: nil,
            interactiveLicenseGranted: true
        )
    }

    /// `"Artist - Title"` → (artist, title); anything else → de-slugged title
    /// with no artist. The separator is the spaced hyphen, so hyphenated
    /// words ("night-drive") don't get misread as an artist split.
    static func parseFilename(_ name: String) -> (artist: String?, title: String) {
        let cleaned = name.replacingOccurrences(of: "_", with: " ")
        let parts = cleaned.components(separatedBy: " - ")
        if parts.count >= 2,
           let artist = parts.first?.trimmingCharacters(in: .whitespaces).nilIfEmpty {
            let title = parts.dropFirst().joined(separator: " - ")
                .trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return (artist, title) }
        }
        let title = cleaned
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (nil, title)
    }

    /// Synchronous tag read via AudioToolbox — covers ID3 (mp3) and iTunes
    /// (m4a) metadata without the async AVAsset loading machinery.
    private static func infoDictionary(for url: URL) -> [String: Any] {
        var fileID: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &fileID) == noErr,
              let fileID else { return [:] }
        defer { AudioFileClose(fileID) }

        var dict: Unmanaged<CFDictionary>?
        var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
        guard AudioFileGetProperty(fileID, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
              let cf = dict?.takeRetainedValue() else { return [:] }
        return (cf as NSDictionary) as? [String: Any] ?? [:]
    }

    /// Deterministic UUID from a string (FNV-1a into the UUID bytes, with
    /// RFC-4122 version/variant bits so it's a well-formed v8-style UUID).
    /// Same name → same id on every launch and every device.
    public static func stableID(_ string: String) -> UUID {
        var h1: UInt64 = 0xcbf29ce484222325
        for b in string.utf8 { h1 = (h1 ^ UInt64(b)) &* 0x100000001b3 }
        var h2: UInt64 = 0x9e3779b97f4a7c15
        for b in string.utf8.reversed() { h2 = (h2 ^ UInt64(b)) &* 0x100000001b3 }

        var bytes = [UInt8]()
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((h1 >> UInt64(shift)) & 0xff)) }
        for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8((h2 >> UInt64(shift)) & 0xff)) }
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // version nibble
        bytes[8] = (bytes[8] & 0x3f) | 0x80 // RFC variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
