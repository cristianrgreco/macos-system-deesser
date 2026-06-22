import Foundation
import CoreAudio
import AudioToolbox

/// RAII-style owner of a Core Audio process tap (spec §8, §13). Creating the
/// instance creates the tap and reads/validates its format; the tap is destroyed
/// in `invalidate()`/`deinit`, so a thrown initializer leaves nothing behind.
final class ProcessTapHandle {
    let tapID: AudioObjectID
    let uuid: UUID
    /// The tap's authoritative UID string (`kAudioTapPropertyUID`), which is what
    /// the aggregate device's sub-tap list must reference.
    let uid: String
    let format: AudioStreamBasicDescription
    let channelCount: Int

    private var valid = true

    /// Creates a private, `mutedWhenTapped` **global** stereo tap of all system
    /// audio *except* the given processes. We exclude our own process so the
    /// de-essed audio we replay is not re-captured into the tap (feedback).
    /// `outputDeviceUID` scopes the tap to a specific device when provided; pass
    /// `nil` for an unscoped global tap (the proven configuration — scoping the
    /// tap to the aggregate's own output device stops the aggregate's I/O).
    init(excludingProcessObjectIDs excludedProcessObjectIDs: [AudioObjectID], outputDeviceUID: String?) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcessObjectIDs)
        description.name = "De-Esser Tap"
        description.uuid = UUID() // ensure a stable, populated UUID
        description.isPrivate = true
        description.muteBehavior = CATapMuteBehavior.mutedWhenTapped
        description.isProcessRestoreEnabled = true // macOS 26+
        if let outputDeviceUID, !outputDeviceUID.isEmpty {
            description.deviceUID = outputDeviceUID
        }

        var createdTapID = AudioObjectID(kAudioObjectUnknown)
        try checkCA(AudioHardwareCreateProcessTap(description, &createdTapID),
                    "AudioHardwareCreateProcessTap")
        guard createdTapID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, context: "Tap object is null")
        }

        // Read the tap format, retrying a bounded number of times because the
        // format may not be queryable immediately after creation (spec §8.5).
        var asbd = AudioStreamBasicDescription()
        do {
            asbd = try Self.readTapFormat(createdTapID, attempts: 5, delayMs: 20)
        } catch {
            AudioHardwareDestroyProcessTap(createdTapID)
            throw error
        }

        do {
            self.channelCount = try StreamFormatValidator.validateTapFormat(asbd)
        } catch {
            AudioHardwareDestroyProcessTap(createdTapID)
            throw error
        }

        // Prefer the tap object's own UID; fall back to the description UUID.
        let tapUID = (try? CA.string(createdTapID, CA.address(kAudioTapPropertyUID))) ?? ""
        self.tapID = createdTapID
        self.uuid = description.uuid
        self.uid = tapUID.isEmpty ? description.uuid.uuidString : tapUID
        self.format = asbd

        Log.audio.notice("""
        TDDIAG tap created id=\(createdTapID) uid=\(self.uid, privacy: .public) \
        descUUID=\(description.uuid.uuidString, privacy: .public) \
        ch=\(asbd.mChannelsPerFrame) sr=\(asbd.mSampleRate) \
        flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel) \
        deviceUID=\(outputDeviceUID ?? "(global-tap)", privacy: .public) excluded=\(excludedProcessObjectIDs)
        """)
    }

    var sampleRate: Double { format.mSampleRate }

    func invalidate() {
        guard valid else { return }
        valid = false
        AudioHardwareDestroyProcessTap(tapID)
    }

    deinit { invalidate() }

    // MARK: - Helpers

    private static func readTapFormat(_ tapID: AudioObjectID, attempts: Int, delayMs: UInt32) throws -> AudioStreamBasicDescription {
        var lastError: Error = CoreAudioError(status: kAudioHardwareUnknownPropertyError, context: "Tap format unavailable")
        for attempt in 0..<attempts {
            do {
                return try CA.value(tapID,
                                    CA.address(kAudioTapPropertyFormat),
                                    default: AudioStreamBasicDescription())
            } catch {
                lastError = error
                if attempt < attempts - 1 {
                    usleep(delayMs * 1000) // control queue only (spec §8.5)
                }
            }
        }
        throw lastError
    }
}
