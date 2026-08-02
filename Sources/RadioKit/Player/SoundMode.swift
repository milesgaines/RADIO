import Foundation

/// How the station sounds.
///
/// HD is the honest baseline — clean, full-range, no coloring (a stereo master
/// heard as mastered). 3D widens the stereo bed: local records get a real HRTF
/// headphone space through the engine, streams get a mid/side widener in the
/// stream tap (they play through AVPlayer, outside the engine) — either way no
/// room reverb, no Atmos claim it can't keep. VINYL warms it and lays real
/// surface noise under it; CASSETTE band-limits it, wobbles it, and adds tape
/// hiss. VINYL/CASSETTE colour every path; HD/3D never add noise.
public enum SoundMode: String, CaseIterable, Sendable {
    // Order here is the order the deck shows them: HD → 3D → VINYL → CASSETTE.
    case hd                       // clean, full-range, honest baseline
    // rawValue for 3D is kept as "dolby" on purpose: it preserves the persisted
    // `swell.soundMode` for anyone who picked the old clean/"DOLBY" mode before
    // it became real 3D. Do not "fix" it to "spatial".
    case spatial = "dolby"
    case vinyl, cassette

    public var title: String {
        switch self {
        case .hd:       return "HD SOUND"
        case .spatial:  return "3D SOUND"
        case .vinyl:    return "VINYL"
        case .cassette: return "CASSETTE"
        }
    }

    /// A cold, one-line description of the character — no poetry.
    public var blurb: String {
        switch self {
        case .hd:       return "CLEAN · FULL-RANGE · TRUE TO MASTER"
        case .spatial:  return "WIDE · BINAURAL · HEADPHONE SPACE"
        case .vinyl:    return "WARM · WOW · CRACKLE · RUMBLE"
        case .cassette: return "FLUTTER · TAPE HISS · LO-FI"
        }
    }

    /// Modes that layer a surface-noise loop over every playback path.
    var hasAmbience: Bool { self == .vinyl || self == .cassette }
}
