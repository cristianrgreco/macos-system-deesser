import XCTest
import CoreAudio
@testable import DeEsser

final class OutputDeviceResolverTests: XCTestCase {

    private func device(_ id: AudioObjectID, uid: String, channels: Int = 2,
                        alive: Bool = true, rate: Double = 48000) -> ResolvedOutputDevice {
        ResolvedOutputDevice(objectID: id, uid: uid, name: "Device \(id)",
                             sampleRate: rate, outputChannelCount: channels, isAlive: alive)
    }

    func testResolvesUsableDefaultDevice() {
        let speakers = device(100, uid: "BuiltInSpeaker")
        let result = OutputDeviceResolver.resolve(
            defaultOutputID: 100,
            deviceInfo: { $0 == 100 ? speakers : nil })
        XCTAssertEqual(result?.objectID, 100)
    }

    func testExcludesOwnAggregateDevice() {
        let aggregate = device(100, uid: OutputDeviceResolver.aggregateUIDPrefix + "abc")
        let result = OutputDeviceResolver.resolve(
            defaultOutputID: 100,
            deviceInfo: { $0 == 100 ? aggregate : nil })
        XCTAssertNil(result, "must never select our own aggregate device")
    }

    func testRejectsDeviceWithNoOutputChannels() {
        let noChannels = device(100, uid: "NoOut", channels: 0)
        let result = OutputDeviceResolver.resolve(
            defaultOutputID: 100,
            deviceInfo: { $0 == 100 ? noChannels : nil })
        XCTAssertNil(result)
    }

    func testRejectsDeadDevice() {
        let dead = device(100, uid: "Dead", alive: false)
        let result = OutputDeviceResolver.resolve(
            defaultOutputID: 100,
            deviceInfo: { $0 == 100 ? dead : nil })
        XCTAssertNil(result)
    }

    func testReturnsNilWhenNoDeviceInfo() {
        let result = OutputDeviceResolver.resolve(
            defaultOutputID: 100,
            deviceInfo: { _ in nil })
        XCTAssertNil(result)
    }
}
