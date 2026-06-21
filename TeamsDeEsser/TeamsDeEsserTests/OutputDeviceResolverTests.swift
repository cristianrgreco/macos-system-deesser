import XCTest
import CoreAudio
@testable import TeamsDeEsser

final class OutputDeviceResolverTests: XCTestCase {

    private func device(_ id: AudioObjectID, uid: String, channels: Int = 2,
                        alive: Bool = true, rate: Double = 48000) -> ResolvedOutputDevice {
        ResolvedOutputDevice(objectID: id, uid: uid, name: "Device \(id)",
                             sampleRate: rate, outputChannelCount: channels, isAlive: alive)
    }

    private func teamsProcess(_ id: AudioObjectID, devices: [AudioObjectID], running: Bool) -> DiscoveredAudioProcess {
        DiscoveredAudioProcess(objectID: id, pid: Int32(id), bundleID: "com.microsoft.teams2",
                               isRunningOutput: running, outputDeviceIDs: devices, executablePath: nil)
    }

    func testRunningProcessesAgreeOnOneDevice() {
        let speakers = device(100, uid: "BuiltInSpeaker")
        let result = OutputDeviceResolver.resolve(
            teamsProcesses: [teamsProcess(1, devices: [100], running: true),
                             teamsProcess(2, devices: [100], running: true)],
            defaultOutputID: 999,
            deviceInfo: { $0 == 100 ? speakers : nil })
        XCTAssertEqual(result?.device.objectID, 100)
        XCTAssertEqual(result?.usedDefaultFallback, false)
    }

    func testFallsBackToDefaultWhenDisagreement() {
        let a = device(100, uid: "A")
        let b = device(200, uid: "B")
        let def = device(999, uid: "Default")
        let result = OutputDeviceResolver.resolve(
            teamsProcesses: [teamsProcess(1, devices: [100], running: true),
                             teamsProcess(2, devices: [200], running: true)],
            defaultOutputID: 999,
            deviceInfo: { id in [100: a, 200: b, 999: def][id] })
        XCTAssertEqual(result?.device.objectID, 999)
        XCTAssertEqual(result?.usedDefaultFallback, true)
    }

    func testExcludesOwnAggregateDevice() {
        let aggregate = device(100, uid: OutputDeviceResolver.aggregateUIDPrefix + "abc")
        let def = device(999, uid: "Default")
        let result = OutputDeviceResolver.resolve(
            teamsProcesses: [teamsProcess(1, devices: [100], running: true)],
            defaultOutputID: 999,
            deviceInfo: { id in [100: aggregate, 999: def][id] })
        XCTAssertEqual(result?.device.objectID, 999, "must never select our own aggregate device")
        XCTAssertEqual(result?.usedDefaultFallback, true)
    }

    func testRejectsDeviceWithNoOutputChannels() {
        let noChannels = device(100, uid: "NoOut", channels: 0)
        let def = device(999, uid: "Default")
        let result = OutputDeviceResolver.resolve(
            teamsProcesses: [teamsProcess(1, devices: [100], running: true)],
            defaultOutputID: 999,
            deviceInfo: { id in [100: noChannels, 999: def][id] })
        XCTAssertEqual(result?.device.objectID, 999)
    }

    func testRejectsDeadDevice() {
        let dead = device(100, uid: "Dead", alive: false)
        let def = device(999, uid: "Default")
        let result = OutputDeviceResolver.resolve(
            teamsProcesses: [teamsProcess(1, devices: [100], running: true)],
            defaultOutputID: 999,
            deviceInfo: { id in [100: dead, 999: def][id] })
        XCTAssertEqual(result?.device.objectID, 999)
    }

    func testReturnsNilWhenNothingUsable() {
        let result = OutputDeviceResolver.resolve(
            teamsProcesses: [teamsProcess(1, devices: [100], running: true)],
            defaultOutputID: 999,
            deviceInfo: { _ in nil })
        XCTAssertNil(result)
    }

    func testSingleRunningProcessSingleDevice() {
        let head = device(50, uid: "USB Headset")
        let result = OutputDeviceResolver.resolve(
            teamsProcesses: [teamsProcess(1, devices: [50], running: true)],
            defaultOutputID: 999,
            deviceInfo: { $0 == 50 ? head : nil })
        XCTAssertEqual(result?.device.objectID, 50)
        XCTAssertEqual(result?.usedDefaultFallback, false)
    }
}
