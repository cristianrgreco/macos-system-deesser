import Foundation
import CoreAudio
import AudioToolbox

/// Validates the formats produced by the tap and aggregate device before any
/// I/O proc is created (spec §8, §9, §20.2). The checks are pure functions over
/// `AudioStreamBasicDescription` so they can be unit-tested.
enum StreamFormatValidator {

    struct ValidationError: Error, CustomStringConvertible {
        let reason: String
        var description: String { reason }
    }

    /// The de-esser only supports linear-PCM Float32 with 1 or 2 channels
    /// (spec §8.4, §2.3 non-goals). Returns the channel count on success.
    static func validateTapFormat(_ asbd: AudioStreamBasicDescription) throws -> Int {
        guard asbd.mFormatID == kAudioFormatLinearPCM else {
            throw ValidationError(reason: "Tap format is not linear PCM")
        }
        guard (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 else {
            throw ValidationError(reason: "Tap format is not Float")
        }
        guard asbd.mBitsPerChannel == 32 else {
            throw ValidationError(reason: "Tap format is not 32-bit")
        }
        let channels = Int(asbd.mChannelsPerFrame)
        guard channels == 1 || channels == 2 else {
            throw ValidationError(reason: "Unsupported tap channel count: \(channels)")
        }
        guard asbd.mSampleRate > 0 else {
            throw ValidationError(reason: "Tap sample rate is zero")
        }
        return channels
    }

    /// Returns the sample rate the I/O callback will run at — i.e. the aggregate
    /// device's clock. The sub-tap is drift-compensated to this clock, so the
    /// tap's own native rate may differ (e.g. a 48 kHz tap into a 44.1 kHz
    /// Bluetooth output); no ad-hoc converter is inserted by us (spec §9, §20.3).
    /// Falls back to the tap rate only if the aggregate reports an invalid rate.
    static func graphSampleRate(tap tapRate: Double, aggregate aggRate: Double) throws -> Double {
        if aggRate > 0 { return aggRate }
        if tapRate > 0 { return tapRate }
        throw ValidationError(reason: "Neither tap nor aggregate reported a valid sample rate")
    }

    static func validateOutputChannels(_ count: Int) throws {
        guard count >= 1 else {
            throw ValidationError(reason: "Aggregate device exposes no output channels")
        }
    }
}
