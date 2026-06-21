import Foundation
import Observation
import SwiftUI
import AppKit
import ServiceManagement

/// Observable application model. Owns persisted settings and bridges the UI to
/// the `AudioPipelineCoordinator`. All state mutations occur on the main queue
/// (the coordinator dispatches its callbacks there).
///
/// Uses the Observation framework (`@Observable`) rather than
/// `ObservableObject`/`@Published`. Observation does not broadcast through
/// `objectWillChange`, so mutating these properties from a control's binding
/// setter — e.g. flipping a `Toggle` or `Picker` — no longer trips SwiftUI's
/// "Publishing changes from within view updates is not allowed" runtime warning.
@Observable
final class AppModel {

    private(set) var state: ProcessingState = .disabled
    private(set) var diagnostics = DiagnosticsSnapshot()

    var settings: DeEsserSettings
    var bypass: Bool = false

    var startEnabledOnLaunch: Bool
    var launchAtLogin: Bool
    var showPermissionExplainer: Bool = false

    #if DEBUG
    var debugTargetBundleID: String = "" {
        didSet { coordinator.setDebugTargetBundleID(debugTargetBundleID.isEmpty ? nil : debugTargetBundleID) }
    }
    #endif

    /// Whether the master toggle is on (mirrors the coordinator's desired state).
    var enabled: Bool = false

    @ObservationIgnored private let coordinator = AudioPipelineCoordinator()
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var hasAttemptedCapture: Bool

    // Persistence keys.
    private enum Key {
        static let settings = "deEsserSettings"
        static let startEnabled = "startEnabledOnLaunch"
        static let hasAttemptedCapture = "hasAttemptedCapture"
    }

    init() {
        // Load persisted settings (fall back to the EasyEffects default).
        if let data = defaults.data(forKey: Key.settings),
           let decoded = try? JSONDecoder().decode(DeEsserSettings.self, from: data) {
            settings = decoded
        } else {
            settings = .standard
        }
        startEnabledOnLaunch = defaults.bool(forKey: Key.startEnabled)
        hasAttemptedCapture = defaults.bool(forKey: Key.hasAttemptedCapture)
        launchAtLogin = (SMAppService.mainApp.status == .enabled)

        coordinator.onStateChange = { [weak self] newState in
            // Delivered on the main queue by the coordinator.
            self?.state = newState
            self?.syncEnabledFromState(newState)
        }
        coordinator.onDiagnostics = { [weak self] snapshot in
            self?.diagnostics = snapshot
        }

        coordinator.updateSettings(settings)

        // Best-effort synchronous teardown on graceful quit (spec §13). On a
        // force-quit, Core Audio reclaims our client resources and the
        // `mutedWhenTapped` tap unmutes, so dry Teams audio returns anyway.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.shutdown()
        }

        if startEnabledOnLaunch {
            // "Start enabled" implies the user already opted in (spec §12.3).
            requestEnable(skipExplainer: true)
        }
    }

    // MARK: - Master enable

    func setEnabled(_ on: Bool) {
        if on {
            requestEnable(skipExplainer: false)
        } else {
            enabled = false
            coordinator.setEnabled(false)
        }
    }

    private func requestEnable(skipExplainer: Bool) {
        if !skipExplainer && !hasAttemptedCapture {
            // First explicit enable: explain the system-audio prompt first.
            showPermissionExplainer = true
            return
        }
        confirmEnable()
    }

    /// Called after the permission explainer is acknowledged (or when skipping).
    func confirmEnable() {
        showPermissionExplainer = false
        if !hasAttemptedCapture {
            hasAttemptedCapture = true
            defaults.set(true, forKey: Key.hasAttemptedCapture)
        }
        enabled = true
        coordinator.setEnabled(true)
    }

    func cancelEnable() {
        showPermissionExplainer = false
        enabled = false
    }

    private func syncEnabledFromState(_ newState: ProcessingState) {
        switch newState {
        case .disabled:
            enabled = false
        default:
            break
        }
    }

    // MARK: - Aggressiveness

    /// Sets how hard the de-esser works (0 = gentle … 1 = aggressive).
    func setAggressiveness(_ value: Float) {
        settings = DeEsserSettings(aggressiveness: value)
        persistSettings()
        coordinator.updateSettings(settings)
    }

    // MARK: - Bypass / rebuild

    func setBypass(_ value: Bool) {
        bypass = value
        coordinator.setBypass(value)
    }

    func requestManualRebuild() {
        coordinator.requestManualRebuild()
    }

    // MARK: - Settings window toggles

    func setStartEnabledOnLaunch(_ value: Bool) {
        startEnabledOnLaunch = value
        defaults.set(value, forKey: Key.startEnabled)
    }

    func setLaunchAtLogin(_ value: Bool) {
        do {
            if value {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        } catch {
            Log.app.error("Launch-at-login change failed: \(error.localizedDescription)")
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    // MARK: - Diagnostics actions

    func copyDiagnosticsReport() {
        let report = diagnostics.textReport()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
    }

    func openPrivacySettings() {
        // Best-effort deep link to Privacy & Security ▸ system-audio recording.
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy"
        ]
        for string in urls {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }

    // MARK: - Termination

    func shutdown() {
        coordinator.shutdownSynchronously()
    }

    // MARK: - Persistence

    private func persistSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Key.settings)
        }
    }
}
