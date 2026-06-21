import Foundation

/// Reasons that trigger a controlled graph rebuild (spec §5.3).
enum RebuildReason: Equatable {
    case teamsProcessSetChanged
    case outputDeviceChanged
    case sampleRateChanged
    case streamLayoutChanged
    case wakeFromSleep
    case heartbeatStalled
    case manual

    var description: String {
        switch self {
        case .teamsProcessSetChanged: return "Teams process set changed"
        case .outputDeviceChanged: return "Output device changed"
        case .sampleRateChanged: return "Sample rate changed"
        case .streamLayoutChanged: return "Output layout changed"
        case .wakeFromSleep: return "Woke from sleep"
        case .heartbeatStalled: return "Audio callback stalled"
        case .manual: return "Manual rebuild"
        }
    }
}

/// A user-facing recoverable error with optional remediation hint.
struct UserFacingError: Equatable {
    enum Kind: Equatable {
        case permissionDenied
        case tapCreationFailed
        case aggregateCreationFailed
        case unsupportedDevice
        case ioStartFailed
        case noOutputDevice
        case generic
    }

    var kind: Kind
    var message: String
    /// Optional Core Audio status that produced the error (for diagnostics).
    var status: OSStatus?

    var suggestsPrivacySettings: Bool { kind == .permissionDenied }
}

/// Summary shown while running (spec §5 `running(RunningSummary)`).
struct RunningSummary: Equatable {
    var outputDeviceName: String
    var sampleRate: Double
    var outputChannelCount: Int
    var bypassed: Bool
}

/// Explicit runtime state machine (spec §5).
enum ProcessingState: Equatable {
    case disabled
    case waitingForTeams
    case requestingPermission
    case starting
    case running(RunningSummary)
    case rebuilding(reason: RebuildReason)
    case recoverableError(UserFacingError)

    /// Short status string for the menu bar (spec §12.1).
    func statusText(outputDeviceName: String?) -> String {
        switch self {
        case .disabled:
            return "Disabled"
        case .waitingForTeams:
            return "Waiting for Microsoft Teams"
        case .requestingPermission:
            return "Permission required"
        case .starting:
            return "Starting…"
        case .running(let summary):
            let suffix = summary.bypassed ? " (bypassed)" : ""
            return "Processing Teams → \(summary.outputDeviceName)\(suffix)"
        case .rebuilding(let reason):
            return "Rebuilding (\(reason.description))…"
        case .recoverableError(let error):
            return "Error: \(error.message)"
        }
    }

    var isActiveGraph: Bool {
        switch self {
        case .running, .rebuilding, .starting: return true
        default: return false
        }
    }
}
