import Foundation
import CoreAudio

/// A resolved output device with the attributes the graph needs (spec §7).
struct ResolvedOutputDevice: Equatable {
    var objectID: AudioObjectID
    var uid: String
    var name: String
    var sampleRate: Double
    var outputChannelCount: Int
    var isAlive: Bool

    var isUsableOutput: Bool { isAlive && outputChannelCount > 0 }
}

/// Resolves the output device the processed system audio is replayed to. Because
/// the de-esser is system-wide, this is simply the current default output device.
/// The policy is a pure function over injected device info so it can be
/// unit-tested without hardware.
struct OutputDeviceResolver {

    /// UID prefix used by this app's private aggregate devices, so we never
    /// select our own aggregate as the output (spec §7 step 4).
    static let aggregateUIDPrefix = "local.DeEsser.aggregate."

    // MARK: - Pure policy

    /// Validates the default output device: it must be alive, expose output
    /// channels, and not be one of our own private aggregate devices.
    static func resolve(defaultOutputID: AudioObjectID,
                        deviceInfo: (AudioObjectID) -> ResolvedOutputDevice?,
                        aggregatePrefix: String = aggregateUIDPrefix) -> ResolvedOutputDevice? {
        guard let info = deviceInfo(defaultOutputID),
              info.isUsableOutput,
              !info.uid.hasPrefix(aggregatePrefix) else { return nil }
        return info
    }

    // MARK: - Live resolution

    func resolveLive() -> ResolvedOutputDevice? {
        Self.resolve(defaultOutputID: Self.defaultOutputDeviceID(),
                     deviceInfo: { Self.liveDeviceInfo($0) })
    }

    static func defaultOutputDeviceID() -> AudioObjectID {
        (try? CA.value(AudioObjectID(kAudioObjectSystemObject),
                       CA.address(kAudioHardwarePropertyDefaultOutputDevice),
                       default: AudioObjectID(kAudioObjectUnknown))) ?? AudioObjectID(kAudioObjectUnknown)
    }

    /// Reads the full attribute set for a device object.
    static func liveDeviceInfo(_ id: AudioObjectID) -> ResolvedOutputDevice? {
        guard id != AudioObjectID(kAudioObjectUnknown), id != 0 else { return nil }
        let uid = (try? CA.string(id, CA.address(kAudioDevicePropertyDeviceUID))) ?? ""
        guard !uid.isEmpty else { return nil }
        let name = (try? CA.string(id, CA.address(kAudioObjectPropertyName))) ?? uid
        let alive: UInt32 = (try? CA.value(id, CA.address(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0))) ?? 0
        let sampleRate: Float64 = (try? CA.value(id, CA.address(kAudioDevicePropertyNominalSampleRate), default: Float64(0))) ?? 0
        let channels = (try? CA.channelCount(id, scope: kAudioObjectPropertyScopeOutput)) ?? 0
        return ResolvedOutputDevice(objectID: id,
                                    uid: uid,
                                    name: name,
                                    sampleRate: Double(sampleRate),
                                    outputChannelCount: channels,
                                    isAlive: alive != 0)
    }
}
