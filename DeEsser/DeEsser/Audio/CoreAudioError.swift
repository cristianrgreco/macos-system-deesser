import Foundation
import CoreAudio

/// A Core Audio failure carrying the originating `OSStatus` and a short context
/// string. Used so every graph-construction step can clean up and surface a
/// precise diagnostic (spec §13).
struct CoreAudioError: Error, Equatable, CustomStringConvertible {
    let status: OSStatus
    let context: String

    var description: String {
        "\(context): \(OSStatusFormatter.describe(status))"
    }
}

/// Throws `CoreAudioError` when `status` is not `noErr`.
@discardableResult
func checkCA(_ status: OSStatus, _ context: @autoclosure () -> String) throws -> OSStatus {
    guard status == noErr else {
        throw CoreAudioError(status: status, context: context())
    }
    return status
}
