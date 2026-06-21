import Foundation

/// User-facing de-esser settings.
///
/// The processing is a faithful port of the Calf "Deesser" plugin — the de-esser
/// EasyEffects uses for PipeWire/PulseAudio. Every Calf control is pinned to the
/// EasyEffects/Calf default; the only thing the user adjusts is a single
/// **Aggressiveness** value that scales how hard the de-esser works by moving the
/// detection threshold and ratio together. At the default (0.5) the parameters
/// equal the stock EasyEffects defaults exactly.
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
    static let aggressivenessRange: ClosedRange<Float> = 0...1

    /// 0 = barely de-essing, 0.5 = EasyEffects default, 1 = very aggressive.
    var aggressiveness: Float

    init(aggressiveness: Float = 0.5) {
        self.aggressiveness = aggressiveness.clamped(to: Self.aggressivenessRange)
    }

    // Tolerate older/partial persisted payloads.
    private enum CodingKeys: String, CodingKey { case aggressiveness }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(aggressiveness: try c.decodeIfPresent(Float.self, forKey: .aggressiveness) ?? 0.5)
    }

    /// The default ("EasyEffects") settings.
    static var standard: DeEsserSettings { DeEsserSettings(aggressiveness: 0.5) }

    // MARK: Derived Calf controls
    // Threshold sweeps -6 dBFS (gentle) … -30 dBFS (aggressive), passing the
    // EasyEffects default of -18 dBFS at 0.5. Ratio sweeps 1:1 … 6:1, passing the
    // default 3:1 at 0.5. Everything else stays at the stock default.

    var thresholdDb: Float { -18 + (0.5 - aggressiveness) * 24 }
    var ratio: Float { max(1, 3 + (aggressiveness - 0.5) * 6) }

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
