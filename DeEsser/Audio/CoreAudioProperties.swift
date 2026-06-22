import Foundation
import CoreAudio
import AudioToolbox

/// Thin, allocation-light helpers around the `AudioObjectGetPropertyData`
/// family. These run only on control threads, never in the audio callback.
enum CA {

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func hasProperty(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(objectID, &addr)
    }

    /// Returns the raw byte size of a property, or throws.
    static func dataSize(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> UInt32 {
        var addr = address
        var size: UInt32 = 0
        try checkCA(AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size),
                    "GetPropertyDataSize(\(OSStatusFormatter.fourCharCode(OSStatus(bitPattern: address.mSelector)) ?? "?"))")
        return size
    }

    /// Reads a single fixed-layout value (e.g. `UInt32`, `Float64`, `pid_t`).
    /// Uses raw storage to avoid forming a typed pointer to a generic value.
    static func value<T>(_ objectID: AudioObjectID,
                         _ address: AudioObjectPropertyAddress,
                         default defaultValue: T) throws -> T {
        var addr = address
        var size = UInt32(MemoryLayout<T>.size)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: MemoryLayout<T>.size,
                                                   alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        withUnsafeBytes(of: defaultValue) { raw.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
        try checkCA(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw),
                    "GetPropertyData(scalar)")
        return raw.load(as: T.self)
    }

    /// Reads an array of trivially-copyable fixed-layout elements
    /// (e.g. `[AudioObjectID]`). Element type must be zero-initializable.
    static func array<T>(_ objectID: AudioObjectID,
                         _ address: AudioObjectPropertyAddress,
                         of type: T.Type) throws -> [T] {
        var addr = address
        var size: UInt32 = 0
        guard AudioObjectHasProperty(objectID, &addr) else { return [] }
        try checkCA(AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size), "GetPropertyDataSize(array)")
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        memset(raw, 0, Int(size))
        var mutableSize = size
        try checkCA(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &mutableSize, raw),
                    "GetPropertyData(array)")
        let returned = Int(mutableSize) / MemoryLayout<T>.stride
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: min(returned, count)))
    }

    /// Translates a Unix PID to its HAL audio-process object, or nil if the
    /// system has no audio-process object for it yet. Used to find our own
    /// process so a global tap can *exclude* it — otherwise the processed audio
    /// we replay would feed straight back into the tap.
    static func translatePIDToProcessObject(_ pid: pid_t) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &addr) else { return nil }
        var inPID = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr,
                                                UInt32(MemoryLayout<pid_t>.size), &inPID,
                                                &size, &objectID)
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    /// Reads a CFString property and returns it as a Swift `String`.
    static func string(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) throws -> String {
        var addr = address
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: Unmanaged<CFString>? = nil
        try checkCA(AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, &cfStr), "GetPropertyData(string)")
        guard let value = cfStr?.takeRetainedValue() else { return "" }
        return value as String
    }

    /// Reads an `AudioBufferList`-shaped stream configuration and returns the
    /// total channel count across all buffers.
    static func channelCount(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Int {
        let addr = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var a = addr
        guard AudioObjectHasProperty(objectID, &a) else { return 0 }
        let size = try dataSize(objectID, addr)
        guard size > 0 else { return 0 }
        let ablPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ablPtr.deallocate() }
        var mutableSize = size
        var a2 = addr
        try checkCA(AudioObjectGetPropertyData(objectID, &a2, 0, nil, &mutableSize, ablPtr), "GetPropertyData(streamConfig)")
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
