import Foundation
import CoreAudio
import AudioToolbox

/// RAII-style owner of the private aggregate device that contains the Teams tap
/// as an input and the physical output device as an output subdevice (spec §9).
/// Destroyed in `invalidate()`/`deinit` so a thrown initializer leaks nothing.
final class AggregateDeviceHandle {
    let aggregateID: AudioObjectID
    let uid: String
    let sampleRate: Double
    let outputChannelCount: Int
    let inputChannelCount: Int
    let bufferFrameSize: UInt32

    private var valid = true

    init(outputDeviceUID: String, tapUID: String) throws {
        let aggUID = OutputDeviceResolver.aggregateUIDPrefix + UUID().uuidString

        // kAudioSubDeviceInputChannelsKey is intentionally omitted; some devices
        // reject `channels-in: 0` and the tap supplies the input stream anyway
        // (spec §9).
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Teams De-Esser",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Must be a CFNumber. 0 = start I/O immediately (do NOT wait for the
            // first tap audio). With a non-zero value, AudioDeviceStart returns
            // noErr but the device stays parked until the tapped process plays
            // audio — which left us with aggIsRunning=0 and no heartbeat. We run
            // the graph continuously so the watchdog sees a steady heartbeat.
            kAudioAggregateDeviceTapAutoStartKey: Int(0),
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var deviceID = AudioObjectID(kAudioObjectUnknown)
        try checkCA(AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID),
                    "AudioHardwareCreateAggregateDevice")
        guard deviceID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, context: "Aggregate object is null")
        }

        do {
            // Verify the aggregate is alive and query its layout (spec §9).
            let alive: UInt32 = (try? CA.value(deviceID, CA.address(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0))) ?? 0
            guard alive != 0 else {
                throw CoreAudioError(status: kAudioHardwareNotRunningError, context: "Aggregate device not alive")
            }

            let outChannels = try CA.channelCount(deviceID, scope: kAudioObjectPropertyScopeOutput)
            try StreamFormatValidator.validateOutputChannels(outChannels)
            let inChannels = (try? CA.channelCount(deviceID, scope: kAudioObjectPropertyScopeInput)) ?? 0

            let rate: Float64 = try CA.value(deviceID, CA.address(kAudioDevicePropertyNominalSampleRate), default: Float64(0))
            let frames: UInt32 = (try? CA.value(deviceID, CA.address(kAudioDevicePropertyBufferFrameSize), default: UInt32(0))) ?? 0

            // Diagnostics: how many sub-devices / sub-taps the HAL actually
            // composed into the aggregate. An empty list explains a device that
            // reports alive but never drives I/O. (These selectors return
            // AudioObjectID arrays.)
            let activeSubDevices = (try? CA.array(deviceID, CA.address(kAudioAggregateDevicePropertyActiveSubDeviceList), of: AudioObjectID.self).count) ?? -1
            let subTaps = (try? CA.array(deviceID, CA.address(kAudioAggregateDevicePropertySubTapList), of: AudioObjectID.self).count) ?? -1

            self.aggregateID = deviceID
            self.uid = aggUID
            self.outputChannelCount = outChannels
            self.inputChannelCount = inChannels
            self.sampleRate = Double(rate)
            self.bufferFrameSize = frames

            Log.audio.notice("""
            TDDIAG aggregate created id=\(deviceID) uid=\(aggUID, privacy: .public) \
            alive=\(alive) outCh=\(outChannels) inCh=\(inChannels) sr=\(rate) frames=\(frames) \
            mainSub=\(outputDeviceUID, privacy: .public) subTapUID=\(tapUID, privacy: .public) \
            activeSubDevices=\(activeSubDevices) subTaps=\(subTaps)
            """)
        } catch {
            AudioHardwareDestroyAggregateDevice(deviceID)
            throw error
        }
    }

    func invalidate() {
        guard valid else { return }
        valid = false
        AudioHardwareDestroyAggregateDevice(aggregateID)
    }

    deinit { invalidate() }
}
