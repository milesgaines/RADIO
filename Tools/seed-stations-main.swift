import Foundation

// Prints SQL that seeds public.radio_tracks / radio_station_tracks from the
// real RealAudio folder, using the app's own FolderCatalog logic (this file
// is compiled together with FolderCatalog.swift + models), so every UUID
// matches what every device computes locally.
//
//   swiftc -o /tmp/radioseed Tools/seed-stations-main.swift \
//     Sources/RadioKit/Services/FolderCatalog.swift \
//     Sources/RadioKit/Models/Track.swift Sources/RadioKit/Models/Station.swift
//   /tmp/radioseed /path/to/RealAudio

let folder = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1] : "RealAudio")
let tracks = FolderCatalog.load(from: folder)
guard tracks.count >= 3 else {
    FileHandle.standardError.write("no catalog at \(folder.path)\n".data(using: .utf8)!)
    exit(1)
}

// Mirror AppServices.realStations: flagship = everything, one station per
// album subfolder (>=3 tracks), singles station for the loose files.
var stations: [(id: UUID, tracks: [Track])] = [
    (FolderCatalog.stableID("station:swell"), tracks)
]
let albums = Dictionary(grouping: tracks.filter { $0.albumTitle != nil }, by: { $0.albumTitle! })
for (album, list) in albums.sorted(by: { $0.key < $1.key }) where list.count >= 3 {
    stations.append((FolderCatalog.stableID("station:\(album.lowercased())"), list))
}
let singles = tracks.filter { $0.albumTitle == nil }
if singles.count >= 3 {
    stations.append((FolderCatalog.stableID("station:singles"), singles))
}

func q(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "''") }

print("begin;")
for t in tracks {
    print("""
    insert into public.radio_tracks (track_id, title, artist, artist_id, duration_seconds)
    values ('\(t.id.uuidString)', '\(q(t.title))', '\(q(t.artistName))', '\(t.artistID.uuidString)', \(t.durationSeconds))
    on conflict (track_id) do update set title = excluded.title, artist = excluded.artist,
      artist_id = excluded.artist_id, duration_seconds = excluded.duration_seconds;
    """)
}
for s in stations {
    for t in s.tracks {
        print("insert into public.radio_station_tracks (station_id, track_id) values ('\(s.id.uuidString)', '\(t.id.uuidString)') on conflict do nothing;")
    }
}
print("commit;")
