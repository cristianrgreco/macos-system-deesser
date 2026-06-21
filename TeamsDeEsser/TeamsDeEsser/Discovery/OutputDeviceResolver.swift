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

/// Resolves the output device Teams is using, with a default-output fallback.
/// Resolution policy is a pure function over injected device info, so it can be
/// unit-tested without hardware.
struct OutputDeviceResolver {

    /// UID prefix used by this app's private aggregate devices, so they are
    /// never selected as a Teams output (spec §7 step 4).
    static let aggregateUIDPrefix = "local.TeamsDeEsser.aggregate."

    // MARK: - Pure policy

    static func resolve(teamsProcesses: [DiscoveredAudioProcess],
                        defaultOutputID: AudioObjectID,
                        deviceInfo: (AudioObjectID) -> ResolvedOutputDevice?,
                        aggregatePrefix: String = aggregateUIDPrefix) -> (device: ResolvedOutputDevice, usedDefaultFallback: Bool)? {

        func isAggregate(_ id: AudioObjectID) -> Bool {
            guard let info = deviceInfo(id) else { return true } // unknown → exclude
            return info.uid.hasPrefix(aggregatePrefix)
        }
        func validOutput(_ id: AudioObjectID) -> ResolvedOutputDevice? {
            guard let info = deviceInfo(id), info.isUsableOutput, !info.uid.hasPrefix(aggregatePrefix) else { return nil }
            return info
        }

        let running = teamsProcesses.filter { $0.isRunningOutput }

        // 1. Running Teams processes agree on exactly one output device.
        let runningDeviceIDs = orderedUnique(running.flatMap { $0.outputDeviceIDs }).filter { !isAggregate($0) }
        if runningDeviceIDs.count == 1, let device = validOutput(runningDeviceIDs[0]) {
            return (device, false)
        }

        // 2. Exactly one running process reporting exactly one device.
        if running.count == 1 {
            let ids = running[0].outputDeviceIDs.filter { !isAggregate($0) }
            if ids.count == 1, let device = validOutput(ids[0]) {
                return (device, false)
            }
        }

        // 3. Fall back to the current default output device.
        if let device = validOutput(defaultOutputID) {
            return (device, true)
        }

        return nil
    }

    // MARK: - Live resolution

    func resolveLive(teamsProcesses: [DiscoveredAudioProcess]) -> (device: ResolvedOutputDevice, usedDefaultFallback: Bool)? {
        let defaultID = Self.defaultOutputDeviceID()
        return Self.resolve(teamsProcesses: teamsProcesses,
                            defaultOutputID: defaultID,
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

/// Order-preserving de-duplication used by the resolver.
func orderedUnique<T: Hashable>(_ items: [T]) -> [T] {
    var seen = Set<T>()
    var result: [T] = []
    for item in items where seen.insert(item).inserted {
        result.append(item)
    }
    return result
}
