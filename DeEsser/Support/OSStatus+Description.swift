import Foundation
import CoreAudio

/// Utilities for rendering `OSStatus` Core Audio error codes in a human-friendly way.
///
/// Core Audio reports errors as four-character codes packed into an `OSStatus`.
/// The diagnostics UI shows both the decimal value and the four-character
/// representation, which is what the headers actually document.
enum OSStatusFormatter {

    /// Returns a string like `560947818 (!obj)` for a Core Audio status code.
    static func describe(_ status: OSStatus) -> String {
        guard status != noErr else { return "noErr (0)" }
        if let fourCC = fourCharCode(status) {
            return "\(status) (\(fourCC))"
        }
        return "\(status)"
    }

    /// Decodes an `OSStatus` into a printable four-character code when every byte
    /// is a printable ASCII character; otherwise returns `nil`.
    static func fourCharCode(_ status: OSStatus) -> String? {
        let value = UInt32(bitPattern: status)
        let bytes = [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return nil }
        let scalars = bytes.map { Character(UnicodeScalar($0)) }
        return "'" + String(scalars) + "'"
    }
}

extension OSStatus {
    /// Convenience accessor used throughout diagnostics.
    var coreAudioDescription: String { OSStatusFormatter.describe(self) }
}
