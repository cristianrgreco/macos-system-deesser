import Foundation

/// A point-in-time snapshot of everything shown in the Advanced/diagnostics
/// section (spec §12.2). Contains metadata only — never PCM audio (spec §19.12).
struct DiagnosticsSnapshot: Equatable {
    struct ProcessInfo: Equatable, Identifiable {
        var id: AudioObjectIDValue { objectID }
        var objectID: AudioObjectIDValue
        var pid: Int32
        var bundleID: String
        var isRunningOutput: Bool
    }

    var matchedProcesses: [ProcessInfo] = []

    var outputDeviceName: String = "—"
    var outputDeviceUID: String = "—"
    var sampleRate: Double = 0
    var outputChannelCount: Int = 0
    var usingDefaultFallback: Bool = false

    var tapObjectID: AudioObjectIDValue = 0
    var aggregateObjectID: AudioObjectIDValue = 0

    var heartbeat: UInt64 = 0
    var callbacksPerSecond: Double = 0
    var inputPeak: Float = 0
    var gainReductionDb: Float = 0

    var lastCoreAudioError: OSStatus = 0
    var lastErrorContext: String = ""

    var stateDescription: String = "Disabled"

    /// Builds a copyable plaintext diagnostic report (spec §12.2). Metadata only.
    func textReport() -> String {
        var lines: [String] = []
        lines.append("Teams De-Esser — Diagnostic Report")
        lines.append("Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("")
        lines.append("State: \(stateDescription)")
        lines.append("")
        lines.append("Matched Teams processes:")
        if matchedProcesses.isEmpty {
            lines.append("  (none)")
        } else {
            for p in matchedProcesses {
                lines.append("  • objectID=\(p.objectID) pid=\(p.pid) bundleID=\(p.bundleID) runningOutput=\(p.isRunningOutput)")
            }
        }
        lines.append("")
        lines.append("Output device:")
        lines.append("  name: \(outputDeviceName)")
        lines.append("  uid: \(outputDeviceUID)")
        lines.append("  sampleRate: \(sampleRate) Hz")
        lines.append("  outputChannels: \(outputChannelCount)")
        lines.append("  defaultFallback: \(usingDefaultFallback)")
        lines.append("")
        lines.append("Graph:")
        lines.append("  tapObjectID: \(tapObjectID)")
        lines.append("  aggregateObjectID: \(aggregateObjectID)")
        lines.append("")
        lines.append("Realtime:")
        lines.append("  heartbeat: \(heartbeat)")
        lines.append("  callbacks/sec: \(String(format: "%.1f", callbacksPerSecond))")
        lines.append("  inputPeak: \(String(format: "%.3f", inputPeak))")
        lines.append("  gainReduction: \(String(format: "%.2f", gainReductionDb)) dB")
        lines.append("")
        lines.append("Last Core Audio error: \(OSStatusFormatter.describe(lastCoreAudioError))")
        if !lastErrorContext.isEmpty {
            lines.append("  context: \(lastErrorContext)")
        }
        lines.append("")
        lines.append("This report contains metadata only. No audio is recorded or included.")
        return lines.joined(separator: "\n")
    }
}

/// Alias so model code reads clearly without importing CoreAudio everywhere.
typealias AudioObjectIDValue = UInt32
