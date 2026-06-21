import XCTest
import CoreAudio
@testable import TeamsDeEsser

final class TeamsProcessLocatorTests: XCTestCase {

    private func process(_ id: AudioObjectID, _ bundleID: String,
                         running: Bool = true, path: String? = nil) -> DiscoveredAudioProcess {
        DiscoveredAudioProcess(objectID: id, pid: Int32(id), bundleID: bundleID,
                               isRunningOutput: running, outputDeviceIDs: [], executablePath: path)
    }

    func testExactBundleIDMatches() {
        let processes = [
            process(1, "com.microsoft.teams2"),
            process(2, "com.apple.Safari"),
            process(3, "com.microsoft.Word")
        ]
        let result = TeamsProcessLocator.select(from: processes)
        XCTAssertEqual(result.map { $0.objectID }, [1])
    }

    func testTeams2PrefixHelperMatches() {
        let processes = [
            process(1, "com.microsoft.teams2"),
            process(2, "com.microsoft.teams2.helper.audio")
        ]
        let result = TeamsProcessLocator.select(from: processes)
        XCTAssertEqual(Set(result.map { $0.objectID }), [1, 2], "helpers must be grouped with the main app")
    }

    func testNonTeamsMicrosoftAppNotMatched() {
        let processes = [
            process(10, "com.microsoft.Word"),
            process(11, "com.microsoft.Outlook")
        ]
        let result = TeamsProcessLocator.select(from: processes)
        XCTAssertTrue(result.isEmpty, "other Microsoft apps must not match")
    }

    func testNameContainingTeamsNotMatched() {
        // The selector keys on bundle ID, never localized name.
        let processes = [process(20, "com.example.MyTeamsViewer")]
        let result = TeamsProcessLocator.select(from: processes)
        XCTAssertTrue(result.isEmpty)
    }

    func testPathFallbackWhenNoBundleMatch() {
        let bundlePath = "/Applications/Microsoft Teams.app"
        let processes = [
            process(30, "", path: bundlePath + "/Contents/Frameworks/Helper"),
            process(31, "com.apple.WebKit.GPU", path: "/System/Library/Foo")
        ]
        let result = TeamsProcessLocator.select(from: processes, teamsBundlePath: bundlePath)
        XCTAssertEqual(result.map { $0.objectID }, [30])
    }

    func testLegacyTeamsBundleMatches() {
        let processes = [process(40, "com.microsoft.teams")]
        let result = TeamsProcessLocator.select(from: processes)
        XCTAssertEqual(result.map { $0.objectID }, [40])
    }

    #if DEBUG
    func testDebugOverrideTakesPrecedence() {
        let processes = [
            process(1, "com.microsoft.teams2"),
            process(2, "local.ToneGenerator")
        ]
        let result = TeamsProcessLocator.select(from: processes, debugTargetBundleID: "local.ToneGenerator")
        XCTAssertEqual(result.map { $0.objectID }, [2])
    }
    #endif
}
