import XCTest
import AVFoundation
@testable import RadioKit

final class FolderCatalogTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-catalog-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// Write a small real AAC file with tags so the loader has something true
    /// to chew on. 2 s of quiet sine keeps the fixture tiny and honest.
    private func writeFixture(
        named fileName: String,
        in subfolder: String? = nil,
        title: String? = nil,
        artist: String? = nil,
        seconds: Double = 2.0
    ) throws -> URL {
        var dir = folder!
        if let subfolder {
            dir = dir.appendingPathComponent(subfolder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let url = dir.appendingPathComponent(fileName)
        let sampleRate = 44_100.0
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.05
        }
        try file.write(from: buffer)

        // Tags: AVAudioFile can't write metadata; re-mux with AVAssetExportSession
        // would be heavy for a unit test, so tagged fixtures use the filename
        // fallback path unless a title/artist is provided via a sidecar remux.
        // We test tag reading separately on the metadata-free path.
        _ = title; _ = artist
        return url
    }

    func testLoadsPlayableTracksWithFilenameFallbackMetadata() throws {
        _ = try writeFixture(named: "night-drive_demo.m4a")
        _ = try writeFixture(named: "b-side.m4a")
        try "not audio".write(to: folder.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        let tracks = FolderCatalog.load(from: folder)
        XCTAssertEqual(tracks.count, 2, "Only audio files become tracks")

        let titles = Set(tracks.map(\.title))
        XCTAssertTrue(titles.contains("night drive demo"), "Filename fallback should de-slugify")
        XCTAssertTrue(tracks.allSatisfy { $0.assetURL != nil })
        XCTAssertTrue(tracks.allSatisfy(\.interactiveLicenseGranted))
        for track in tracks {
            XCTAssertEqual(track.durationSeconds, 2.0, accuracy: 0.1,
                           "Duration must come from real frame counts")
        }
    }

    func testCorruptFilesAreSkippedNotFatal() throws {
        _ = try writeFixture(named: "good.m4a")
        try Data([0x00, 0x01, 0x02]).write(to: folder.appendingPathComponent("bad.m4a"))

        let tracks = FolderCatalog.load(from: folder)
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks.first?.title, "good")
    }

    func testMissingFolderYieldsEmptyCatalogNotCrash() {
        let ghost = folder.appendingPathComponent("does-not-exist")
        XCTAssertEqual(FolderCatalog.load(from: ghost).count, 0)
    }

    func testAlbumSubfolderBecomesAlbumTitle() throws {
        _ = try writeFixture(named: "Miles Gaines - Waiting.m4a", in: "Heavy Is the Crown")
        _ = try writeFixture(named: "Miles Gaines - Loose Single.m4a")

        let tracks = FolderCatalog.load(from: folder)
        XCTAssertEqual(tracks.count, 2)
        let albumTrack = tracks.first { $0.title == "Waiting" }
        let single = tracks.first { $0.title == "Loose Single" }
        XCTAssertEqual(albumTrack?.albumTitle, "Heavy Is the Crown",
                       "A subfolder is an album; its name is the album title")
        XCTAssertNil(single?.albumTitle, "Root-level files are singles")
    }

    func testArtistDashTitleFilenameConvention() throws {
        _ = try writeFixture(named: "Miles Gaines - Ride My Wave.m4a")
        let tracks = FolderCatalog.load(from: folder)
        XCTAssertEqual(tracks.first?.artistName, "Miles Gaines")
        XCTAssertEqual(tracks.first?.title, "Ride My Wave")
    }

    func testHyphenatedWordsAreNotMistakenForArtistSplits() {
        let parsed = FolderCatalog.parseFilename("night-drive demo")
        XCTAssertNil(parsed.artist, "Only the spaced ' - ' separator denotes Artist - Title")
        XCTAssertEqual(parsed.title, "night drive demo")

        let multi = FolderCatalog.parseFilename("Miles Gaines - Laughin - to the Bank")
        XCTAssertEqual(multi.artist, "Miles Gaines")
        XCTAssertEqual(multi.title, "Laughin - to the Bank")
    }

    func testStableIDsAreDeterministicAndDistinct() {
        let a1 = FolderCatalog.stableID("artist:neon tide")
        let a2 = FolderCatalog.stableID("artist:neon tide")
        let b = FolderCatalog.stableID("artist:june motel")
        XCTAssertEqual(a1, a2, "Same artist name must map to the same id across launches")
        XCTAssertNotEqual(a1, b)
    }

    func testSameArtistFilesShareAnArtistIDSoComplementRulesApply() throws {
        // Two files, no tags → both "Unknown Artist" → same artistID; the
        // rotation engine's per-artist caps must treat them as one artist.
        _ = try writeFixture(named: "one.m4a")
        _ = try writeFixture(named: "two.m4a")
        let tracks = FolderCatalog.load(from: folder)
        XCTAssertEqual(Set(tracks.map(\.artistID)).count, 1)
        XCTAssertEqual(Set(tracks.map(\.id)).count, 2, "Track ids stay distinct per file")
    }
}
