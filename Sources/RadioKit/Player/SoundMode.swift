import Foundation

/// How the station sounds. DOLBY is the clean, bright, full-range signal;
/// VINYL warms it, rolls off the top, and lays crackle under it; CASSETTE
/// band-limits it and adds tape hiss. Applied live to local playback (full
/// tonal DSP) and layered as ambience over every path (streams, live shows).
public enum SoundMode: String, CaseIterable, Sendable {
    case dolby, vinyl, cassette

    public var title: String {
        switch self {
        case .dolby: return "DOLBY"
        case .vinyl: return "VINYL"
        case .cassette: return "CASSETTE"
        }
    }

    /// A cold, one-line description of the character — no poetry.
    public var blurb: String {
        switch self {
        case .dolby: return "CLEAN · BRIGHT · FULL RANGE"
        case .vinyl: return "WARM · WOW · CRACKLE · RUMBLE"
        case .cassette: return "FLUTTER · TAPE HISS · LO-FI"
        }
    }

    /// Modes that layer a surface-noise loop over every playback path.
    var hasAmbience: Bool { self != .dolby }
}
