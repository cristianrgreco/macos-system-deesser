import Foundation
import CoreAudio
import AppKit

/// Registers Core Audio property listeners and power notifications, forwarding a
/// coarse change signal to the control queue (spec §14). All listener blocks do
/// minimal work; the coordinator debounces and decides whether to rebuild.
final class AudioEnvironmentMonitor {

    private let queue: DispatchQueue
    var onChange: ((RebuildReason) -> Void)?

    private struct Registration {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var registrations: [Registration] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit { stopAll() }

    // MARK: - System-object listeners (spec §14)

    func startSystemListeners() {
        addListener(object: AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyProcessObjectList,
                    reason: .teamsProcessSetChanged)
        addListener(object: AudioObjectID(kAudioObjectSystemObject),
                    selector: kAudioHardwarePropertyDefaultOutputDevice,
                    reason: .outputDeviceChanged)
    }

    // MARK: - Selected output-device listeners

    func startDeviceListeners(_ deviceID: AudioObjectID) {
        guard deviceID != AudioObjectID(kAudioObjectUnknown), deviceID != 0 else { return }
        addListener(object: deviceID, selector: kAudioDevicePropertyDeviceIsAlive, reason: .outputDeviceChanged)
        addListener(object: deviceID, selector: kAudioDevicePropertyNominalSampleRate, reason: .sampleRateChanged)
        addListener(object: deviceID,
                    selector: kAudioDevicePropertyStreamConfiguration,
                    scope: kAudioObjectPropertyScopeOutput,
                    reason: .streamLayoutChanged)
    }

    // MARK: - Target Teams process listeners

    func startProcessListeners(_ processObjectIDs: [AudioObjectID]) {
        for id in processObjectIDs {
            addListener(object: id,
                        selector: kAudioProcessPropertyDevices,
                        scope: kAudioObjectPropertyScopeOutput,
                        reason: .outputDeviceChanged)
            addListener(object: id, selector: kAudioProcessPropertyIsRunningOutput, reason: .teamsProcessSetChanged)
        }
    }

    // MARK: - Power notifications

    func startSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        let wake = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.onChange?(.wakeFromSleep) }
        }
        workspaceObservers.append(wake)
    }

    // MARK: - Teardown

    func stopAll() {
        for reg in registrations {
            var addr = reg.address
            AudioObjectRemovePropertyListenerBlock(reg.objectID, &addr, queue, reg.block)
        }
        registrations.removeAll()

        let center = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            center.removeObserver(observer)
        }
        workspaceObservers.removeAll()
    }

    // MARK: - Helpers

    private func addListener(object: AudioObjectID,
                             selector: AudioObjectPropertySelector,
                             scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                             reason: RebuildReason) {
        var address = CA.address(selector, scope: scope)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Minimal work only: hand the coarse reason to the control queue.
            self?.onChange?(reason)
        }
        let status = AudioObjectAddPropertyListenerBlock(object, &address, queue, block)
        if status == noErr {
            registrations.append(Registration(objectID: object, address: address, block: block))
        } else {
            Log.lifecycle.error("Failed to add listener \(selector) on \(object): \(OSStatusFormatter.describe(status))")
        }
    }
}
