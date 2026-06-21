import Foundation
import CoreAudio

/// Serializes every graph transition on one control queue (spec §5). Owns the
/// tap, aggregate device, renderer, property monitor, and watchdog, and drives
/// the `ProcessingState` machine. All graph mutation happens on `queue`; UI
/// callbacks are dispatched to the main queue.
final class AudioPipelineCoordinator {

    // MARK: Outputs to the UI (always delivered on the main queue)
    var onStateChange: ((ProcessingState) -> Void)?
    var onDiagnostics: ((DiagnosticsSnapshot) -> Void)?

    // MARK: Control queue and collaborators
    private let queue = DispatchQueue(label: "local.TeamsDeEsser.control")
    private var locator = TeamsProcessLocator()
    private let resolver = OutputDeviceResolver()
    private lazy var monitor = AudioEnvironmentMonitor(queue: queue)

    // MARK: Desired configuration (queue-confined)
    private var enabled = false
    private var settings = DeEsserSettings.standard
    private var bypass = false

    // MARK: Graph (queue-confined)
    private var tap: ProcessTapHandle?
    private var aggregate: AggregateDeviceHandle?
    private var renderer: TDRealtimeRenderer?
    private var state: ProcessingState = .disabled

    private var generation: UInt64 = 0
    private var currentFingerprint: EnvFingerprint?
    private var lastDiscoveredProcesses: [DiscoveredAudioProcess] = []
    private var resolvedDevice: ResolvedOutputDevice?
    private var usedDefaultFallback = false

    // MARK: Watchdog / timers
    private var watchdog: DispatchSourceTimer?
    private var refreshTimer: DispatchSourceTimer?
    private var debounceItem: DispatchWorkItem?
    private var watchdogHeartbeat: UInt64 = 0
    private var watchdogStallTicks = 0
    private var retryBackoffIndex = 0

    private var lastError: (status: OSStatus, context: String) = (0, "")

    private struct EnvFingerprint: Equatable {
        var processIDs: [AudioObjectID]
        var outputUID: String
        var sampleRate: Double
        var outputChannels: Int
    }

    // Backoff schedule in seconds (spec §13).
    private let backoffSchedule: [Double] = [0.5, 1.0, 2.0]

    init() {
        monitor.onChange = { [weak self] reason in
            // Already on the control queue (listener queue == control queue).
            self?.handleEnvironmentSignal(reason)
        }
    }

    // MARK: - Public API (thread-safe entry points)

    func setEnabled(_ value: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.enabled != value else { return }
            self.enabled = value
            if value { self.enable() } else { self.disable() }
        }
    }

    func updateSettings(_ newSettings: DeEsserSettings) {
        queue.async { [weak self] in
            guard let self else { return }
            self.settings = newSettings
            self.renderer?.updateParameters(newSettings.rendererParams(bypass: self.bypass))
            self.publishDiagnostics()
        }
    }

    func setBypass(_ value: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.bypass = value
            self.renderer?.updateParameters(self.settings.rendererParams(bypass: value))
            // Reflect bypass in the running summary.
            if case .running(var summary) = self.state {
                summary.bypassed = value
                self.transition(to: .running(summary))
            }
        }
    }

    func requestManualRebuild() {
        queue.async { [weak self] in
            guard let self, self.enabled else { return }
            Log.lifecycle.notice("Manual rebuild requested")
            self.refresh(reason: .manual, force: true)
        }
    }

    func setDebugTargetBundleID(_ bundleID: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.locator.debugTargetBundleID = bundleID
            if self.enabled { self.refresh(reason: .teamsProcessSetChanged, force: true) }
        }
    }

    /// Synchronous best-effort teardown for app termination (spec §13).
    func shutdownSynchronously() {
        queue.sync { [weak self] in
            self?.enabled = false
            self?.disable()
        }
    }

    // MARK: - Enable / disable (spec §5.1, §5.2)

    private func enable() {
        Log.lifecycle.notice("Enable requested")
        retryBackoffIndex = 0
        monitor.startSystemListeners()
        monitor.startSleepWake()
        startRefreshTimer()
        refresh(reason: .teamsProcessSetChanged, force: true)
    }

    private func disable() {
        Log.lifecycle.notice("Disable requested")
        debounceItem?.cancel(); debounceItem = nil
        stopRefreshTimer()
        teardownGraph()
        monitor.stopAll()
        currentFingerprint = nil
        lastDiscoveredProcesses = []
        resolvedDevice = nil
        transition(to: .disabled)
    }

    // MARK: - Environment evaluation

    private func handleEnvironmentSignal(_ reason: RebuildReason) {
        guard enabled else { return }
        // Debounce rapid events ~250 ms (spec §5.3).
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let force = (reason == .wakeFromSleep || reason == .manual)
            self.refresh(reason: reason, force: force)
        }
        debounceItem = item
        queue.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    /// Re-discovers Teams + output device and builds/rebuilds/tears down as
    /// needed. `force` rebuilds even if the environment fingerprint is unchanged
    /// (used for wake, manual, and heartbeat recovery).
    private func refresh(reason: RebuildReason, force: Bool) {
        guard enabled else { return }

        let processes = locator.currentTeamsProcesses()
        lastDiscoveredProcesses = processes

        guard !processes.isEmpty else {
            if isGraphUp { teardownGraph() }
            currentFingerprint = nil
            resolvedDevice = nil
            transition(to: .waitingForTeams)
            return
        }

        guard let resolution = resolver.resolveLive(teamsProcesses: processes) else {
            if isGraphUp { teardownGraph() }
            currentFingerprint = nil
            resolvedDevice = nil
            recordError(status: kAudioHardwareBadDeviceError, context: "No usable output device")
            transition(to: .recoverableError(UserFacingError(kind: .noOutputDevice,
                                                             message: "No usable output device",
                                                             status: nil)))
            scheduleRetry()
            return
        }

        resolvedDevice = resolution.device
        usedDefaultFallback = resolution.usedDefaultFallback

        let fingerprint = EnvFingerprint(processIDs: processes.map { $0.objectID }.sorted(),
                                         outputUID: resolution.device.uid,
                                         sampleRate: resolution.device.sampleRate,
                                         outputChannels: resolution.device.outputChannelCount)

        if isGraphUp, !force, fingerprint == currentFingerprint {
            // Nothing material changed; keep running.
            publishDiagnostics()
            return
        }

        if isGraphUp {
            transition(to: .rebuilding(reason: reason))
            teardownGraph()
        }

        buildGraph(processes: processes, device: resolution.device, fingerprint: fingerprint)
    }

    // MARK: - Build (spec §5.1)

    private func buildGraph(processes: [DiscoveredAudioProcess], device: ResolvedOutputDevice, fingerprint: EnvFingerprint) {
        generation &+= 1
        let gen = generation
        transition(to: .starting)

        let processIDs = processes.map { $0.objectID }
        Log.audio.notice("""
        TDDIAG buildGraph gen=\(gen) device=\(device.name, privacy: .public) \
        uid=\(device.uid, privacy: .public) id=\(device.objectID) ch=\(device.outputChannelCount) \
        sr=\(device.sampleRate) procIDs=\(processIDs) fallback=\(self.usedDefaultFallback)
        """)

        do {
            // Build everything without starting read activity (fail-open).
            // Use a plain process-inclusion tap (no device scoping): scoping the
            // tap to the same device the aggregate outputs to prevents the
            // aggregate's I/O from starting (aggIsRunning stayed 0).
            let tap = try ProcessTapHandle(processObjectIDs: processIDs, outputDeviceUID: nil)
            let aggregate = try AggregateDeviceHandle(outputDeviceUID: device.uid, tapUID: tap.uid)

            // The aggregate runs at the output device's clock. The sub-tap is
            // drift-compensated to that clock, so the tap's native rate may
            // differ from the aggregate rate (common with Bluetooth devices at
            // 44.1 kHz vs a 48 kHz tap). The callback delivers both input and
            // output at the aggregate rate, so the DSP is prepared at that rate.
            let graphSampleRate = try StreamFormatValidator.graphSampleRate(tap: tap.sampleRate,
                                                                            aggregate: aggregate.sampleRate)
            if abs(tap.sampleRate - aggregate.sampleRate) >= 1 {
                Log.audio.notice("TDDIAG tap rate \(tap.sampleRate) ≠ aggregate \(aggregate.sampleRate); using sub-tap drift compensation at \(graphSampleRate) Hz")
            }

            let layout = TDStreamLayout(sampleRate: graphSampleRate,
                                        inputChannelCount: UInt32(tap.channelCount),
                                        outputChannelCount: UInt32(aggregate.outputChannelCount),
                                        maxFramesPerBuffer: aggregate.bufferFrameSize)
            let renderer = TDRealtimeRenderer(layout: layout)
            renderer.updateParameters(settings.rendererParams(bypass: bypass))

            // Start I/O only after everything is ready (spec §5.1 step 6).
            let startStatus = renderer.start(onAggregateDevice: aggregate.aggregateID)
            guard startStatus == noErr else {
                throw CoreAudioError(status: startStatus, context: "AudioDeviceStart")
            }

            // Commit the graph.
            self.tap = tap
            self.aggregate = aggregate
            self.renderer = renderer
            self.currentFingerprint = fingerprint
            self.resolvedDevice = device

            // Register graph-specific listeners.
            monitor.startDeviceListeners(device.objectID)
            monitor.startProcessListeners(processIDs)

            let summary = RunningSummary(outputDeviceName: device.name,
                                         sampleRate: graphSampleRate,
                                         outputChannelCount: aggregate.outputChannelCount,
                                         bypassed: bypass)
            // Enter running only after a heartbeat is observed (spec §5.1 step 7).
            confirmHeartbeat(generation: gen, attempt: 0, summary: summary)
        } catch let error as CoreAudioError {
            handleBuildFailure(error.status, error.context)
        } catch let error as StreamFormatValidator.ValidationError {
            handleBuildFailure(kAudioHardwareUnsupportedOperationError, error.reason, unsupported: true)
        } catch {
            handleBuildFailure(kAudioHardwareUnspecifiedError, "\(error)")
        }
    }

    private func confirmHeartbeat(generation gen: UInt64, attempt: Int, summary: RunningSummary) {
        guard enabled, gen == generation, let renderer else { return }
        let beat = renderer.meters().heartbeat
        if beat > 0 {
            watchdogHeartbeat = beat
            watchdogStallTicks = 0
            retryBackoffIndex = 0
            transition(to: .running(summary))
            startWatchdog()
            publishDiagnostics()
            return
        }
        if attempt >= 20 { // ~1s with no callback → treat as failed start.
            Log.audio.error("TDDIAG No callback heartbeat after start (beat=\(beat), \(self.aggregateRunningState())); tearing down")
            teardownGraph()
            recordError(status: kAudioHardwareNotRunningError, context: "No callback heartbeat")
            transition(to: .recoverableError(UserFacingError(kind: .ioStartFailed,
                                                             message: "Audio callback never started",
                                                             status: nil)))
            scheduleRetry()
            return
        }
        queue.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.confirmHeartbeat(generation: gen, attempt: attempt + 1, summary: summary)
        }
    }

    private func handleBuildFailure(_ status: OSStatus, _ context: String, unsupported: Bool = false) {
        Log.audio.error("Build failed: \(context) \(OSStatusFormatter.describe(status))")
        teardownGraph()
        recordError(status: status, context: context)

        let kind: UserFacingError.Kind
        let message: String
        if unsupported {
            kind = .unsupportedDevice
            message = "This output device's audio format is not supported"
        } else if isLikelyPermissionDenial(status) {
            kind = .permissionDenied
            message = "System audio recording permission is required"
        } else {
            kind = .tapCreationFailed
            message = "Could not start Teams audio processing"
        }
        transition(to: .recoverableError(UserFacingError(kind: kind, message: message, status: status)))

        if kind == .permissionDenied {
            // Don't hammer the permission path; wait for user/environment change.
            transition(to: .requestingPermission)
        } else {
            scheduleRetry()
        }
    }

    // MARK: - Teardown (spec §5.2)

    private func teardownGraph() {
        stopWatchdog()
        // 1–3. Renderer marks stopping, stops I/O, destroys the proc.
        renderer?.stop()
        renderer = nil
        // 4. Destroy the aggregate device, 5. destroy the tap (RAII invalidate).
        aggregate?.invalidate()
        aggregate = nil
        tap?.invalidate()
        tap = nil
        // 7. Remove graph-specific property listeners but keep system listeners
        // while still enabled so we notice Teams/route changes.
        monitor.stopAll()
        if enabled {
            monitor.startSystemListeners()
            monitor.startSleepWake()
        }
        currentFingerprint = nil
    }

    private var isGraphUp: Bool { renderer != nil }

    // MARK: - Watchdog (spec §10.4)

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
        timer.setEventHandler { [weak self] in self?.watchdogTick() }
        watchdog = timer
        timer.resume()
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    private func watchdogTick() {
        guard enabled, case .running = state, let renderer, let aggregate else { return }

        let meters = renderer.meters()

        if meters.fatalFormat {
            Log.audio.error("Fatal format flag set; tearing down")
            recoverFromGraphFailure(reason: .streamLayoutChanged)
            return
        }

        // Device liveness.
        let aggAlive: UInt32 = (try? CA.value(aggregate.aggregateID, CA.address(kAudioDevicePropertyDeviceIsAlive), default: UInt32(0))) ?? 0
        if aggAlive == 0 {
            Log.audio.error("Aggregate no longer alive; tearing down")
            recoverFromGraphFailure(reason: .outputDeviceChanged)
            return
        }

        // Heartbeat advance check; 750 ms with no progress ⇒ stalled.
        if meters.heartbeat == watchdogHeartbeat {
            watchdogStallTicks += 1
            if watchdogStallTicks >= 3 {
                Log.audio.error("Heartbeat stalled; tearing down")
                recoverFromGraphFailure(reason: .heartbeatStalled)
                return
            }
        } else {
            watchdogHeartbeat = meters.heartbeat
            watchdogStallTicks = 0
        }

        publishDiagnostics(meters: meters)
    }

    private func recoverFromGraphFailure(reason: RebuildReason) {
        teardownGraph()
        transition(to: .rebuilding(reason: reason))
        // Rebuild once after a short debounce if Teams + output remain available.
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refresh(reason: reason, force: true)
        }
    }

    // MARK: - Retry / backoff (spec §13)

    private func scheduleRetry() {
        guard enabled else { return }
        guard retryBackoffIndex < backoffSchedule.count else {
            // Remain recoverable until an environment change or user action.
            Log.lifecycle.notice("Retry budget exhausted; awaiting environment change")
            return
        }
        let delay = backoffSchedule[retryBackoffIndex]
        retryBackoffIndex += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.enabled, !self.isGraphUp else { return }
            self.refresh(reason: .teamsProcessSetChanged, force: true)
        }
    }

    // MARK: - Periodic discovery refresh (spec §6.3)

    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, self.enabled else { return }
            // Lightweight: only re-evaluate the matching set / output UID.
            self.refresh(reason: .teamsProcessSetChanged, force: false)
        }
        refreshTimer = timer
        timer.resume()
    }

    private func stopRefreshTimer() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    // MARK: - State + diagnostics plumbing

    private func transition(to newState: ProcessingState) {
        state = newState
        let snapshot = newState
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(snapshot)
        }
        publishDiagnostics()
    }

    private func recordError(status: OSStatus, context: String) {
        lastError = (status, context)
    }

    /// Diagnostic: whether the aggregate's HAL I/O actually started after
    /// `AudioDeviceStart` returned `noErr`.
    private func aggregateRunningState() -> String {
        guard let agg = aggregate else { return "no-aggregate" }
        let running: UInt32 = (try? CA.value(agg.aggregateID, CA.address(kAudioDevicePropertyDeviceIsRunning), default: UInt32(99))) ?? 99
        let somewhere: UInt32 = (try? CA.value(agg.aggregateID, CA.address(kAudioDevicePropertyDeviceIsRunningSomewhere), default: UInt32(99))) ?? 99
        return "aggIsRunning=\(running) aggIsRunningSomewhere=\(somewhere)"
    }

    private func publishDiagnostics(meters: TDRendererMeters? = nil) {
        var snapshot = DiagnosticsSnapshot()
        snapshot.stateDescription = state.statusText(outputDeviceName: resolvedDevice?.name)
        snapshot.matchedProcesses = lastDiscoveredProcesses.map {
            DiagnosticsSnapshot.ProcessInfo(objectID: $0.objectID,
                                            pid: $0.pid,
                                            bundleID: $0.bundleID,
                                            isRunningOutput: $0.isRunningOutput)
        }
        if let device = resolvedDevice {
            snapshot.outputDeviceName = device.name
            snapshot.outputDeviceUID = device.uid
            snapshot.sampleRate = device.sampleRate
            snapshot.outputChannelCount = device.outputChannelCount
            snapshot.usingDefaultFallback = usedDefaultFallback
        }
        snapshot.tapObjectID = tap?.tapID ?? 0
        snapshot.aggregateObjectID = aggregate?.aggregateID ?? 0

        let m = meters ?? renderer?.meters()
        if let m {
            snapshot.heartbeat = m.heartbeat
            snapshot.inputPeak = m.inputPeak
            snapshot.gainReductionDb = m.gainReductionDb
        }
        snapshot.lastCoreAudioError = lastError.status
        snapshot.lastErrorContext = lastError.context

        DispatchQueue.main.async { [weak self] in
            self?.onDiagnostics?(snapshot)
        }
    }

    // MARK: - Helpers

    /// Heuristic: tap creation under capture-permission denial typically fails
    /// without a unique public status, so we treat permission as the likely
    /// cause and steer the user to Privacy & Security (spec §12.3).
    private func isLikelyPermissionDenial(_ status: OSStatus) -> Bool {
        // `kAudioHardwareIllegalOperationError` / generic failures are the
        // common shapes; we cannot rely on a documented "denied" code.
        return status == kAudioHardwareIllegalOperationError
            || status == kAudioHardwareUnspecifiedError
            || status == kAudioHardwareBadObjectError
    }
}
