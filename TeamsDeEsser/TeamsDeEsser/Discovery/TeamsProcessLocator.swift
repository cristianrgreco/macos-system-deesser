import Foundation
import CoreAudio
import AppKit
import Darwin

/// A HAL audio-process object with the metadata we use for matching (spec §6).
struct DiscoveredAudioProcess: Equatable {
    var objectID: AudioObjectID
    var pid: Int32
    var bundleID: String
    var isRunningOutput: Bool
    var outputDeviceIDs: [AudioObjectID]
    var executablePath: String?
}

/// Locates the HAL audio-process objects that belong to native Microsoft Teams.
/// The ranking logic is a pure function so it can be unit-tested without a live
/// Core Audio stack.
struct TeamsProcessLocator {

    /// Known native Teams bundle IDs (spec §6.1).
    static let knownTeamsBundleIDs: Set<String> = [
        "com.microsoft.teams2",
        "com.microsoft.teams" // legacy fallback only
    ]

    static let teams2Prefix = "com.microsoft.teams2."

    /// Optional DEBUG-only override (spec §6.4). Release builds ignore it.
    var debugTargetBundleID: String?

    // MARK: - Pure selection logic (unit-tested)

    /// Selects the Teams audio processes to tap, applying the priority ranking
    /// from spec §6.1. Returns all members of the highest-priority tier that has
    /// any matches, so helper processes are grouped with the main app.
    static func select(from processes: [DiscoveredAudioProcess],
                       known: Set<String> = knownTeamsBundleIDs,
                       teamsBundlePath: String? = nil,
                       debugTargetBundleID: String? = nil) -> [DiscoveredAudioProcess] {
        // DEBUG-only deterministic override takes precedence when set.
        #if DEBUG
        if let override = debugTargetBundleID, !override.isEmpty {
            return processes.filter { $0.bundleID == override }
        }
        #endif

        // Tier 1 + 2: exact known bundle IDs or the `com.microsoft.teams2.` prefix.
        let bundleMatches = processes.filter { p in
            known.contains(p.bundleID) || p.bundleID.hasPrefix(teams2Prefix)
        }
        if !bundleMatches.isEmpty { return bundleMatches }

        // Tier 3: executable path inside the running Teams application bundle.
        if let bundlePath = teamsBundlePath, !bundlePath.isEmpty {
            let pathMatches = processes.filter { p in
                guard let exe = p.executablePath else { return false }
                return exe.hasPrefix(bundlePath)
            }
            if !pathMatches.isEmpty { return pathMatches }
        }

        return []
    }

    // MARK: - Live enumeration

    /// Enumerates all HAL audio-process objects and returns Teams matches.
    func currentTeamsProcesses() -> [DiscoveredAudioProcess] {
        let all = Self.allAudioProcesses()
        let bundlePath = Self.runningTeamsBundlePath()
        return Self.select(from: all,
                           teamsBundlePath: bundlePath,
                           debugTargetBundleID: debugTargetBundleID)
    }

    /// Enumerates every HAL audio-process object (used by diagnostics too).
    static func allAudioProcesses() -> [DiscoveredAudioProcess] {
        let address = CA.address(kAudioHardwarePropertyProcessObjectList)
        let ids = (try? CA.array(AudioObjectID(kAudioObjectSystemObject), address, of: AudioObjectID.self)) ?? []
        return ids.map { describe(processObject: $0) }
    }

    private static func describe(processObject objectID: AudioObjectID) -> DiscoveredAudioProcess {
        let pid: Int32 = (try? CA.value(objectID, CA.address(kAudioProcessPropertyPID), default: pid_t(0))) ?? 0
        let bundleID = (try? CA.string(objectID, CA.address(kAudioProcessPropertyBundleID))) ?? ""
        let runningOut: UInt32 = (try? CA.value(objectID, CA.address(kAudioProcessPropertyIsRunningOutput), default: UInt32(0))) ?? 0
        let devices = (try? CA.array(objectID,
                                     CA.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput),
                                     of: AudioObjectID.self)) ?? []
        return DiscoveredAudioProcess(objectID: objectID,
                                      pid: pid,
                                      bundleID: bundleID,
                                      isRunningOutput: runningOut != 0,
                                      outputDeviceIDs: devices,
                                      executablePath: pid > 0 ? executablePath(for: pid) : nil)
    }

    /// Best-effort executable path for a PID via `proc_pidpath` (public libproc).
    static func executablePath(for pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Path of the running native Teams application bundle, if any.
    static func runningTeamsBundlePath() -> String? {
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier else { continue }
            if knownTeamsBundleIDs.contains(id) || id.hasPrefix(teams2Prefix) {
                return app.bundleURL?.path
            }
        }
        return nil
    }
}
