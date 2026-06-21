import XCTest
@testable import TeamsDeEsser

/// Tests for the value-type orchestration logic (state text, settings clamping,
/// aggressiveness mapping). The live coordinator requires Core Audio hardware and
/// is exercised in the manual test matrix (spec §18).
final class AudioPipelineStateTests: XCTestCase {

    func testStatusTextForRunning() {
        let summary = RunningSummary(outputDeviceName: "MacBook Pro Speakers",
                                     sampleRate: 48000, outputChannelCount: 2, bypassed: false)
        XCTAssertEqual(ProcessingState.running(summary).statusText(outputDeviceName: nil),
                       "Processing Teams → MacBook Pro Speakers")
    }

    func testStatusTextForBypassed() {
        let summary = RunningSummary(outputDeviceName: "AirPods", sampleRate: 48000,
                                     outputChannelCount: 2, bypassed: true)
        XCTAssertTrue(ProcessingState.running(summary).statusText(outputDeviceName: nil).contains("bypassed"))
    }

    func testStatusTextStates() {
        XCTAssertEqual(ProcessingState.disabled.statusText(outputDeviceName: nil), "Disabled")
        XCTAssertEqual(ProcessingState.waitingForTeams.statusText(outputDeviceName: nil), "Waiting for Microsoft Teams")
        XCTAssertEqual(ProcessingState.requestingPermission.statusText(outputDeviceName: nil), "Permission required")
    }

    func testAggressivenessClampsToRange() {
        XCTAssertEqual(DeEsserSettings(aggressiveness: 5).aggressiveness, 1.0)
        XCTAssertEqual(DeEsserSettings(aggressiveness: -5).aggressiveness, 0.0)
    }

    func testDefaultMatchesEasyEffectsDefaults() {
        // At 0.5 the derived Calf controls equal the stock EasyEffects defaults.
        let s = DeEsserSettings.standard
        XCTAssertEqual(s.aggressiveness, 0.5, accuracy: 1e-6)
        XCTAssertEqual(s.thresholdDb, -18, accuracy: 1e-4)
        XCTAssertEqual(s.ratio, 3, accuracy: 1e-4)
    }

    func testAggressivenessSweepsThresholdAndRatio() {
        let gentle = DeEsserSettings(aggressiveness: 0)
        XCTAssertEqual(gentle.thresholdDb, -6, accuracy: 1e-4)
        XCTAssertEqual(gentle.ratio, 1, accuracy: 1e-4) // 3 + (-0.5)*6 = 0, clamped to 1

        let strong = DeEsserSettings(aggressiveness: 1)
        XCTAssertEqual(strong.thresholdDb, -30, accuracy: 1e-4)
        XCTAssertEqual(strong.ratio, 6, accuracy: 1e-4)
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
        let original = DeEsserSettings(aggressiveness: 0.73)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DeEsserSettings.self, from: data)
        XCTAssertEqual(decoded.aggressiveness, 0.73, accuracy: 1e-6)
    }

    func testRebuildReasonDescriptions() {
        XCTAssertFalse(RebuildReason.heartbeatStalled.description.isEmpty)
        XCTAssertFalse(RebuildReason.wakeFromSleep.description.isEmpty)
    }
}
