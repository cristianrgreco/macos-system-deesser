import XCTest
@testable import DeEsser

/// Tests for the value-type orchestration logic (state text, settings clamping,
/// strength mapping). The live coordinator requires Core Audio hardware and
/// is exercised in the manual test matrix (spec §18).
final class AudioPipelineStateTests: XCTestCase {

    func testStatusTextForRunning() {
        let summary = RunningSummary(outputDeviceName: "MacBook Pro Speakers",
                                     sampleRate: 48000, outputChannelCount: 2, bypassed: false)
        XCTAssertEqual(ProcessingState.running(summary).statusText(outputDeviceName: nil),
                       "De-essing → MacBook Pro Speakers")
    }

    func testStatusTextForBypassed() {
        let summary = RunningSummary(outputDeviceName: "AirPods", sampleRate: 48000,
                                     outputChannelCount: 2, bypassed: true)
        XCTAssertTrue(ProcessingState.running(summary).statusText(outputDeviceName: nil).contains("Bypassed"))
    }

    func testStatusTextStates() {
        XCTAssertEqual(ProcessingState.disabled.statusText(outputDeviceName: nil), "Disabled")
        XCTAssertEqual(ProcessingState.requestingPermission.statusText(outputDeviceName: nil), "Permission required")
    }

    func testStrengthClampsToRange() {
        XCTAssertEqual(DeEsserSettings(strength: 5).strength, 1.0)
        XCTAssertEqual(DeEsserSettings(strength: -5).strength, 0.0)
    }

    func testDefaultStartingStrength() {
        // A fresh install starts at the default strength.
        XCTAssertEqual(DeEsserSettings.standard.strength, 0.75, accuracy: 1e-6)
        XCTAssertEqual(DeEsserSettings.defaultStrength, 0.75, accuracy: 1e-6)
    }

    func testMidpointMatchesEasyEffectsDefaults() {
        // At 0.5 the derived Calf controls equal the stock EasyEffects defaults,
        // regardless of where the default starting strength sits.
        let s = DeEsserSettings(strength: 0.5)
        XCTAssertEqual(s.thresholdDb, -18, accuracy: 1e-4)
        XCTAssertEqual(s.ratio, 3, accuracy: 1e-4)
    }

    func testStrengthSweepsThresholdAndRatio() {
        let gentle = DeEsserSettings(strength: 0)
        XCTAssertEqual(gentle.thresholdDb, -6, accuracy: 1e-4)
        XCTAssertEqual(gentle.ratio, 1, accuracy: 1e-4)

        // The top end is deliberately heavy: low threshold, high ratio.
        let strong = DeEsserSettings(strength: 1)
        XCTAssertEqual(strong.thresholdDb, -42, accuracy: 1e-4)
        XCTAssertEqual(strong.ratio, 12, accuracy: 1e-4)
    }

    func testLegacyAggressivenessKeyStillDecodes() throws {
        // Settings persisted before the rename used the "aggressiveness" key.
        let json = Data(#"{"aggressiveness":0.8}"#.utf8)
        let decoded = try JSONDecoder().decode(DeEsserSettings.self, from: json)
        XCTAssertEqual(decoded.strength, 0.8, accuracy: 1e-6)
    }

    func testRendererParamsUseEasyEffectsDefaults() {
        let params = DeEsserSettings.standard.rendererParams(bypass: true)
        XCTAssertTrue(params.bypass)
        XCTAssertEqual(params.f1FreqHz, DeEsserSettings.f1FreqHz)
        XCTAssertEqual(params.f2FreqHz, DeEsserSettings.f2FreqHz)
        XCTAssertEqual(params.f2LevelDb, DeEsserSettings.f2LevelDb)
        XCTAssertEqual(params.laxity, DeEsserSettings.laxity)
        XCTAssertEqual(params.makeupDb, 0, "v1 adds no makeup gain")
        XCTAssertEqual(params.detection, DeEsserSettings.detectionRMS) // RMS
        XCTAssertEqual(params.mode, DeEsserSettings.modeWide)          // Wide
    }

    func testSettingsRoundTripThroughCodable() throws {
        let original = DeEsserSettings(strength: 0.73)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeEsserSettings.self, from: data)
        XCTAssertEqual(decoded.strength, 0.73, accuracy: 1e-6)
    }

    func testRebuildReasonDescriptions() {
        XCTAssertFalse(RebuildReason.heartbeatStalled.description.isEmpty)
        XCTAssertFalse(RebuildReason.wakeFromSleep.description.isEmpty)
    }
}
