import Foundation

/// How the station sounds. SPATIAL renders locally-played engine audio as a
/// real HRTF binaural space (3D on headphones, a clean stereo downmix on
/// speakers); VINYL warms it, rolls off the top, and lays crackle under it;
/// CASSETTE band-limits it and adds tape hiss. Applied live to local playback
/// (full tonal DSP) and layered as ambience over every path (streams, live).
public enum SoundMode: String, CaseIterable, Sendable {
    // rawValue for SPATIAL is kept as "dolby" on purpose: it preserves the
    // persisted `swell.soundMode` value for anyone who already picked the
    // clean mode before it became real 3D. Do not "fix" it to "spatial".
    case spatial = "dolby"
    case vinyl, cassette

    public var title: String {
        switch self {
        case .spatial: return "SPATIAL"
        case .vinyl: return "VINYL"
        case .cassette: return "CASSETTE"
        }
    }

    /// A cold, one-line description of the character — no poetry.
    public var blurb: String {
        switch self {
        case .spatial: return "3D · BINAURAL · HEADPHONE SPACE"
        case .vinyl: return "WARM · WOW · CRACKLE · RUMBLE"
        case .cassette: return "FLUTTER · TAPE HISS · LO-FI"
        }
    }

    /// Modes that layer a surface-noise loop over every playback path.
    var hasAmbience: Bool { self != .spatial }
}
