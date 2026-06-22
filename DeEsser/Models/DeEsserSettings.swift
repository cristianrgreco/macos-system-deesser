import Foundation

/// User-facing de-esser settings.
///
/// The processing is a faithful port of the Calf "Deesser" plugin — the de-esser
/// EasyEffects uses for PipeWire/PulseAudio. Every Calf control is pinned to the
/// EasyEffects/Calf default; the only thing the user adjusts is a single
/// **Strength** value that scales how hard the de-esser works by moving the
/// detection threshold and ratio together. At the midpoint (0.5) the parameters
/// equal the stock EasyEffects defaults exactly; the top of the range goes well
/// past that into deliberately heavy de-essing.
struct DeEsserSettings: Equatable, Codable {

    // MARK: Fixed Calf/EasyEffects defaults (the algorithm we replicate)
    static let f1FreqHz: Float = 6_000   // "Split" — sidechain high-pass / crossover
    static let f2FreqHz: Float = 4_500   // "Peak" — sibilance band centre
    static let f1LevelDb: Float = 0       // "Gain"  — high-pass pass-band gain (1.0 linear)
    static let f2LevelDb: Float = 12.04   // "Level" — sidechain peak boost (4.0 linear)
    static let f2Q: Float = 1.0           // "Peak Q"
    static let laxity: Float = 15         // detector laxity
    static let makeupDb: Float = 0        // no makeup gain
    static let detectionRMS: Int32 = 0    // RMS detection
    static let modeWide: Int32 = 0        // Wide mode

    // MARK: Adjustable
    static let strengthRange: ClosedRange<Float> = 0...1

    /// The strength a fresh install starts at. The mapping still anchors 0.5 to
    /// the stock EasyEffects defaults; this default just starts the user a bit
    /// heavier than that, since light de-essing is rarely enough in practice.
    static let defaultStrength: Float = 0.75

    /// 0 = barely de-essing, 0.5 = EasyEffects default, 1 = very heavy de-essing.
    var strength: Float

    init(strength: Float = DeEsserSettings.defaultStrength) {
        self.strength = strength.clamped(to: Self.strengthRange)
    }

    // Decode the current key, falling back to the legacy "aggressiveness" key so
    // settings persisted before the rename still load.
    private enum CodingKeys: String, CodingKey { case strength }
    private enum LegacyKeys: String, CodingKey { case aggressiveness }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let s = try c.decodeIfPresent(Float.self, forKey: .strength) {
            self.init(strength: s)
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            self.init(strength: try legacy.decodeIfPresent(Float.self, forKey: .aggressiveness) ?? Self.defaultStrength)
        }
    }

    /// The settings a fresh install starts with (strength = `defaultStrength`).
    static var standard: DeEsserSettings { DeEsserSettings(strength: defaultStrength) }

    // MARK: Derived Calf controls
    // The lower half (0…0.5) eases in from "off" to the EasyEffects default; the
    // upper half (0.5…1) ramps much harder so the slider's top end is a hammer —
    // threshold drops to -42 dBFS and the ratio climbs to 12:1, which squashes the
    // sibilant band by tens of dB for a very obvious drop in harsh "s"/"sh" sounds.

    var thresholdDb: Float {
        strength <= 0.5
            ? -18 + (0.5 - strength) * 24   // 0 → -6 dBFS, 0.5 → -18 dBFS
            : -18 - (strength - 0.5) * 48    // 0.5 → -18 dBFS, 1 → -42 dBFS
    }

    var ratio: Float {
        let r = strength <= 0.5
            ? 1 + strength * 4               // 0 → 1:1 (off), 0.5 → 3:1
            : 3 + (strength - 0.5) * 18      // 0.5 → 3:1, 1 → 12:1
        return r.clamped(to: 1...20)
    }

    /// Maps the settings to the C struct consumed by the real-time renderer.
    /// Bypass is supplied separately by the coordinator because it is a runtime
    /// control rather than a stored preference.
    func rendererParams(bypass: Bool) -> TDDeEsserParams {
        TDDeEsserParams(thresholdDb: thresholdDb,
                        ratio: ratio,
                        makeupDb: Self.makeupDb,
                        f1FreqHz: Self.f1FreqHz,
                        f2FreqHz: Self.f2FreqHz,
                        f1LevelDb: Self.f1LevelDb,
                        f2LevelDb: Self.f2LevelDb,
                        f2Q: Self.f2Q,
                        laxity: Self.laxity,
                        detection: Self.detectionRMS,
                        mode: Self.modeWide,
                        scListen: false,
                        bypass: bypass)
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
