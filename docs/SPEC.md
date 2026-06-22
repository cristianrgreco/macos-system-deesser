# Teams De-Esser for macOS Tahoe — Codex Implementation Specification

> ⚠️ **Superseded on scope.** This is the original v1 specification, written when
> the app de-essed **only Microsoft Teams**. The shipped app was generalised to
> de-ess **all system audio** (a global tap that excludes its own process) and was
> renamed from `TeamsDeEsser` / `local.TeamsDeEsser` to **`DeEsser` / `local.DeEsser`**.
> This document is kept because code comments reference its section numbers
> ("spec §N") and its DSP / lifecycle / fail-open design still hold. Where it says
> "Teams", read "all system audio except this app". For the current scope see
> `CLAUDE.md` and `IMPLEMENTATION_NOTES.md` (§0), which are authoritative.

**Document status:** implementation-ready specification (v1 scope; see banner above)  
**Target:** macOS Tahoe 26.0 or later, Xcode 26.x, native Microsoft Teams client  
**Primary bundle ID:** `com.microsoft.teams2`  
**Working product name:** Teams De-Esser  
**Distribution goal for v1:** locally built, signed macOS menu-bar application; no virtual audio driver and no kernel/system extension

---

## 0. Instructions to Codex

Implement the application described here; do not merely summarize the design or create placeholder files.

Work milestone by milestone. Keep the repository compiling after each milestone. Run the build and test commands after every material change, fix all compiler errors and warnings caused by the project, and record any unavoidable SDK/API discrepancy in `IMPLEMENTATION_NOTES.md`.

Use the macOS 26 SDK headers and Apple’s current “Capturing system audio with Core Audio taps” sample as the source of truth for exact imported Swift names. Do not invent replacements when an API name differs from this document: inspect the SDK, adapt the call, and document the difference.

Hard constraints:

- Use public Core Audio process-tap APIs.
- Do not use BlackHole, Soundflower, Loopback, a virtual audio driver, DriverKit, a kernel extension, ScreenCaptureKit, or microphone loopback.
- Do not use private TCC APIs or undocumented entitlements.
- Do not record, save, transmit, transcribe, or retain meeting audio.
- Do not alter the Teams microphone selection, Teams speaker selection, or the system default output device.
- Do not place Swift object allocation, locks, logging, file access, Objective-C message-heavy work, or blocking operations in the real-time audio callback.
- Do not add third-party runtime dependencies.
- Fail open: if the processing graph stops or cannot be constructed, normal unprocessed Teams audio must resume.

The implementation should begin with a native Xcode macOS App project if one does not already exist. Use SwiftUI for the menu-bar UI, Swift for orchestration, and Objective-C++/C++ for the real-time callback and DSP.

---

## 1. Feasibility and architectural basis

This application is feasible on macOS Tahoe using public APIs.

Core Audio process taps can capture outgoing audio from one process or a group of processes. A `CATapDescription` can request a stereo mixdown and use `mutedWhenTapped`, which suppresses the original hardware delivery while the tap is actively being read. The tap becomes an input of a private HAL aggregate device. That aggregate device also contains the physical Teams output device as an output subdevice. A device I/O callback reads the tapped Teams stream, applies the de-esser, and writes the processed stream to the output buffers.

Tahoe adds `isProcessRestoreEnabled` to `CATapDescription`. Enable it so Core Audio remembers the tapped process bundle IDs and restores matching processes when they restart. The app must still monitor the process list because Teams can create a new audio-producing helper with a different bundle ID after the original tap was built.

Data path:

```text
Microsoft Teams output process(es)
        │
        │  Core Audio process tap
        │  stereo mixdown, device-scoped,
        │  mutedWhenTapped
        ▼
Private aggregate-device input
        │
        │  real-time AudioDeviceIOProc
        ▼
Linked-stereo split-band de-esser
        │
        ▼
Aggregate-device output subdevice
        │
        ▼
The physical output device Teams was using
```

No audio driver is installed. No system-wide output device is changed. Other applications do not pass through this graph.

---

## 2. Product requirements

### 2.1 Primary user story

As a Mac user in a Teams meeting, I can enable a menu-bar utility that reduces painful or harsh “S”, “SH”, and similar high-frequency consonants in incoming Teams audio without affecting my microphone or audio from other applications.

### 2.2 Required behavior

1. When enabled before Teams starts, the app waits and begins processing automatically when a matching Teams audio process appears.
2. When enabled during a meeting, processing begins after the system-audio capture permission is granted.
3. Only native Teams audio is captured and processed.
4. The app routes processed Teams audio to the output device Teams is currently using when it can determine that device; otherwise it uses the current default output device.
5. The original Teams stream is muted only while the tap is actively being read.
6. Disabling the utility tears down the graph and immediately restores normal Teams playback.
7. A Teams restart, device change, sample-rate change, sleep/wake event, or AirPods profile change triggers a controlled graph rebuild.
8. Other application audio remains untouched.
9. The utility never captures the microphone.
10. The utility never writes audio to disk or sends it over a network.

### 2.3 Non-goals for v1

- Browser-based Teams meetings.
- System-wide DSP.
- Third-party Audio Unit hosting.
- Multiband mastering, noise suppression, echo cancellation, or automatic speech recognition.
- Per-participant processing; Teams exposes only the final application mix.
- Arbitrary multichannel home-theatre routing. v1 supports mono and the first stereo output pair; it must fail open on unsupported layouts.
- Mac App Store packaging. Developer ID distribution can be addressed after the local build is stable.

---

## 3. Platform and project configuration

- Deployment target: macOS 26.0.
- Build with the installed Xcode 26.x SDK.
- Architectures: `arm64` and `x86_64` where practical; do not assume Teams and this app run under the same architecture.
- UI: SwiftUI `MenuBarExtra` plus a Settings window.
- App role: menu-bar accessory application; set `LSUIElement` to `YES`.
- App Sandbox: disabled for the v1 local utility.
- Hardened Runtime: enabled if it does not interfere with local development.
- Required Info.plist key:

```xml
<key>NSAudioCaptureUsageDescription</key>
<string>Teams De-Esser needs access to Microsoft Teams playback so it can reduce harsh sibilance locally on this Mac.</string>
```

- Do not request microphone permission.
- Do not add `com.apple.security.system-audio-capture` or any other undocumented entitlement.
- Frameworks: SwiftUI, AppKit, Foundation, CoreAudio, AudioToolbox, OSLog. AVFoundation is optional and should not be used in the real-time path.

Suggested product bundle ID for local development: `local.TeamsDeEsser`. Keep it stable so TCC permission is not repeatedly invalidated.

---

## 4. High-level component design

### 4.1 Swift/UI layer

Responsibilities:

- User settings and persisted presets.
- Menu-bar and Settings UI.
- Teams process discovery.
- Output-device resolution.
- Core Audio property monitoring.
- Audio graph lifecycle and state machine.
- Error presentation and diagnostics.
- Polling real-time meters from atomics at a low UI rate.

### 4.2 Core Audio control layer

Responsibilities:

- Create and destroy `CATapDescription`/process tap.
- Create and destroy the private aggregate device.
- Read the tap format and aggregate stream configuration.
- Construct the real-time renderer only after formats are validated.
- Start and stop the aggregate device I/O proc.
- Perform all lifecycle operations on one serial control queue or actor.

### 4.3 Objective-C++/C++ real-time layer

Responsibilities:

- Own the `AudioDeviceIOProcID` and static C callback.
- Convert `AudioBufferList` layouts into zero-allocation channel views.
- Process mono, interleaved stereo, or non-interleaved stereo Float32 data.
- Clear unused output channels.
- Run the de-esser.
- Crossfade bypass changes.
- Update lock-free heartbeat, level, and gain-reduction meters.

The audio callback must not call into the Swift UI model.

---

## 5. Runtime state machine

Use an explicit state enum. Suggested cases:

```swift
enum ProcessingState: Equatable {
    case disabled
    case waitingForTeams
    case requestingPermission
    case starting
    case running(RunningSummary)
    case rebuilding(reason: RebuildReason)
    case recoverableError(UserFacingError)
}
```

All graph transitions are serialized by an `AudioPipelineCoordinator` actor or dedicated serial dispatch queue.

### 5.1 Enable transition

1. Set desired state to enabled.
2. Discover matching Teams audio process objects.
3. If none exist, enter `waitingForTeams` and continue monitoring.
4. Resolve the output device.
5. Build the complete graph without starting I/O.
6. Start I/O only after the tap, aggregate device, formats, renderer, and watchdog are ready.
7. Enter `running` only after at least one callback heartbeat is observed.

The `mutedWhenTapped` behavior should not mute dry Teams audio until read activity begins, so failures before `AudioDeviceStart` remain fail-open.

### 5.2 Disable transition

Teardown in this order:

1. Mark renderer stopping so it outputs silence and ceases meter updates.
2. `AudioDeviceStop`.
3. `AudioDeviceDestroyIOProcID`.
4. Destroy the private aggregate device.
5. Destroy the process tap.
6. Release renderer/DSP resources.
7. Remove graph-specific property listeners.
8. Enter `disabled`.

Stopping I/O first ends read activity, allowing the original dry Teams route to resume before the tap object is destroyed.

### 5.3 Rebuild transition

A rebuild is required when any of these changes:

- Set of target Teams `AudioObjectID`s.
- Teams output device.
- Output device UID or liveness.
- Nominal sample rate.
- Output stream configuration/channel count.
- Wake from sleep.
- Renderer heartbeat stops.

Debounce rapid events for approximately 250 ms. Tear down the old graph completely and recreate both the process tap and aggregate device. Do not attempt to mutate a live process list in place for v1.

Use a generation counter so stale asynchronous rebuilds cannot replace a newer graph.

---

## 6. Teams process discovery

### 6.1 Primary match

The current native Teams bundle ID is:

```text
com.microsoft.teams2
```

Keep a small allowlist:

```swift
let knownTeamsBundleIDs: Set<String> = [
    "com.microsoft.teams2",
    "com.microsoft.teams" // legacy fallback only
]
```

Use `AudioHardwareSystem.shared.processes` on macOS 26. `AudioHardwareProcess` provides the HAL process object, PID, bundle ID, output devices, and `isRunningOutput` state.

Select audio-process objects using this ranking:

1. Exact bundle ID in `knownTeamsBundleIDs`.
2. Bundle ID beginning with `com.microsoft.teams2.`.
3. A process whose executable path resides inside the running Microsoft Teams application bundle, used only as a fallback.
4. A process whose parent chain reaches the main Teams PID, used only in DEBUG diagnostics or after path matching fails.

Never match a process merely because its localized name contains the word “Teams”.

### 6.2 Process groups

Pass all matched HAL process object IDs to:

```swift
CATapDescription(stereoMixdownOfProcesses: targetObjectIDs)
```

This produces one linked stereo mix from all selected Teams processes.

Set:

```swift
tapDescription.uuid = UUID()
tapDescription.name = "Teams De-Esser Tap"
tapDescription.isPrivate = true
tapDescription.muteBehavior = .mutedWhenTapped
tapDescription.isProcessRestoreEnabled = true // macOS 26+
```

Set `deviceUID` to the resolved Teams output device UID so the tap affects only Teams audio intended for that device.

Do not include this utility’s own process. Since the tap is an inclusion tap for Teams processes rather than a global tap, processed playback cannot feed back into the tap.

### 6.3 Discovery refresh

Listen for changes to the system process-object list. Also run a lightweight one-second refresh while enabled, because Teams helper creation and device association may not arrive in the order expected.

Rebuild only when the normalized set of matching process object IDs or resolved output UID changes.

### 6.4 DEBUG-only target override

Add a DEBUG-only diagnostics setting allowing an arbitrary bundle ID to be selected. This is needed to test capture/replay with a deterministic tone-producing app. The Release build must default to and visibly identify Microsoft Teams only.

---

## 7. Output-device resolution

For each matching `AudioHardwareProcess`, inspect its `devices` collection. It represents output devices currently used by the process.

Selection policy:

1. If running Teams processes agree on exactly one output device, use it.
2. If one Teams process is actively running output and reports one device, use that device.
3. Otherwise use `AudioHardwareSystem.shared.defaultOutputDevice`.
4. Exclude any private aggregate device created by this app by UID prefix.
5. Reject an output device that is not alive or has no output channels.

The resolved device is both:

- the `CATapDescription.deviceUID` scope; and
- the output subdevice in the private aggregate device.

Do not change the system default output device.

Monitor:

- default output device changes;
- selected device liveness;
- nominal sample rate;
- output stream configuration;
- selected Teams process `devices` changes.

For Bluetooth devices, treat any sample-rate or stream-layout change as a full graph rebuild. This covers AirPods switching between playback profiles when Teams activates a headset microphone.

---

## 8. Process tap creation

Use the public C API or its macOS 26 Swift wrapper. The C API sequence is explicit and is acceptable:

1. Construct the `CATapDescription` as specified above.
2. Call `AudioHardwareCreateProcessTap`.
3. Read `kAudioTapPropertyFormat` from the returned tap object.
4. Validate that the tap provides linear PCM Float32 and one or two channels; a stereo mixdown should normally be two channels.
5. Retry the initial format read a small bounded number of times if the tap object exists but its format has not yet become queryable. Suggested retry: five attempts, 20 ms apart, on the control queue only.
6. On any failure, destroy the tap and remain fail-open.

Do not start I/O at this stage.

---

## 9. Private aggregate-device construction

Create a unique private aggregate device for each graph generation.

Required description values:

```swift
let description: [String: Any] = [
    kAudioAggregateDeviceNameKey: "Teams De-Esser",
    kAudioAggregateDeviceUIDKey: "local.TeamsDeEsser.aggregate.\(UUID().uuidString)",
    kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [
        [
            kAudioSubDeviceUIDKey: outputDeviceUID,
            kAudioSubDeviceInputChannelsKey: 0
        ]
    ],
    kAudioAggregateDeviceTapListKey: [
        [
            kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
            kAudioSubTapDriftCompensationKey: true
        ]
    ]
]
```

Confirm the exact bridged key/value types against the macOS 26 SDK. If `kAudioSubDeviceInputChannelsKey: 0` is rejected for a particular device, omit it and identify the tap input stream explicitly rather than assuming every aggregate input buffer belongs to the tap.

Call `AudioHardwareCreateAggregateDevice` or `AudioHardwareSystem.makeAggregateDevice(description:)`.

After creation:

- verify the aggregate is alive;
- query its input and output stream configurations;
- verify that it exposes the tap input and at least one physical output channel;
- query the current nominal sample rate;
- verify that the tap and aggregate operate at the same rate, or fail open for v1 rather than adding an unsafe ad-hoc sample-rate converter.

Do not publish the aggregate as the system default device.

---

## 10. Real-time renderer

### 10.1 API choice

Use `AudioDeviceCreateIOProcID` with a static C/Objective-C++ callback and an opaque C++ context. This keeps the real-time path out of Swift. `AudioDeviceCreateIOProcIDWithBlock` is acceptable only if the block immediately forwards raw pointers to the same C++ renderer and performs no Swift allocation or model access.

Register the I/O proc on the aggregate device and start it with `AudioDeviceStart`.

### 10.2 Callback responsibilities

For every callback:

1. Increment an atomic heartbeat counter and store the latest host time.
2. Validate non-null input/output buffer lists.
3. Clear all output buffers first.
4. Create stack-only channel views over the tap input and physical output buffers.
5. Determine frame count from buffer byte sizes and known ASBDs; use the minimum safe frame count.
6. Read mono/stereo Float32 input.
7. Run the de-esser or bypass crossfade.
8. Write mono/stereo output:
   - mono output: average processed L/R;
   - stereo or more: write L/R to the first pair;
   - clear every unused channel.
9. Update atomic peak/input and gain-reduction meters.
10. Return `noErr`.

Supported buffer layouts:

- one interleaved Float32 buffer with one or more channels;
- two non-interleaved Float32 mono buffers;
- multiple output buffers where the first two channels form the selected stereo pair.

If an unknown format reaches the callback, output silence and set an atomic fatal-format flag. The control watchdog then stops and tears down the graph so dry Teams audio resumes. Do not throw or log from the callback.

### 10.3 Real-time safety rules

The callback must perform none of the following:

- heap allocation or deallocation;
- Swift `Array`, `String`, collection, actor, async, or notification work;
- locks, semaphores, condition variables, dispatch synchronously to another queue, or waiting;
- logging;
- Objective-C autorelease activity;
- file or network I/O;
- filter coefficient calculation using UI objects;
- graph start/stop/rebuild operations.

All buffers and DSP state are allocated before `AudioDeviceStart`.

### 10.4 Watchdog

A non-real-time timer on the control queue checks every 250 ms:

- callback heartbeat advances;
- aggregate and output devices remain alive;
- no fatal-format flag is set.

If the heartbeat does not advance for 750 ms while state is `running`, stop and fully tear down the graph. Rebuild once after a short debounce if Teams and the output device remain available.

Provide a visible “Rebuild audio path” command for manual recovery. Do not automatically infer failure solely from zero-valued audio, because legitimate meeting silence is indistinguishable from an all-zero tap stream.

---

## 11. De-esser DSP specification

### 11.1 Design

Implement an internal, linked-stereo, split-band de-esser. Do not host a third-party plug-in.

For each channel, split the input into complementary low and high bands with a fourth-order Linkwitz–Riley crossover. Implement each branch as two cascaded second-order Butterworth biquads using the same crossover frequency.

```text
input L/R
   ├── LR4 low-pass ───────────────────────┐
   └── LR4 high-pass ── gain reduction ───┤── sum → output L/R
                         ▲                 │
                         └ linked detector ┘
```

The detector reads the high bands from both channels, calculates linked power, and drives one gain value applied equally to left and right high bands. Stereo linking prevents image movement.

### 11.2 Gain detector

For each sample:

```text
power = 0.5 * (highL² + highR²)
```

Smooth the power with separate attack and release one-pole coefficients. Convert to dB with a floor that prevents `log(0)`.

Use a soft-knee compressor curve:

- threshold: configurable;
- ratio: 6:1 default;
- knee: 6 dB default;
- maximum gain reduction: configurable and hard-limited to 12 dB;
- no makeup gain.

Apply the resulting linear gain only to the high-frequency branch.

### 11.3 Default parameters

Standard preset:

| Parameter | Default | Range |
|---|---:|---:|
| Crossover frequency | 5,000 Hz | 3,500–9,000 Hz |
| Threshold | -30 dBFS | -45 to -18 dBFS |
| Ratio | 6:1 | fixed in basic UI |
| Soft knee | 6 dB | fixed in basic UI |
| Attack | 1.5 ms | 0.5–5 ms |
| Release | 90 ms | 40–200 ms |
| Maximum reduction | 7 dB | 0–12 dB |
| Output gain | 0 dB | fixed |

Presets:

- **Gentle:** 5.5 kHz, -26 dBFS, 4 dB maximum reduction.
- **Standard:** 5.0 kHz, -30 dBFS, 7 dB maximum reduction.
- **Strong:** 4.5 kHz, -34 dBFS, 10 dB maximum reduction.

These are starting points, not medical guarantees.

### 11.4 Parameter updates

- UI writes desired settings on the control thread.
- Calculate biquad coefficients off the real-time thread.
- Store two complete coefficient sets and atomically swap the active index at a block boundary.
- Keep filter state in the renderer.
- Smooth threshold/max-reduction changes over at least 20 ms.
- Crossfade bypass over 10 ms to prevent clicks.
- Reset filter/envelope state only when sample rate changes or the graph is rebuilt.

Use `std::atomic` for scalar parameters and meters. No external atomics package is needed.

### 11.5 Numerical requirements

- Use `float` sample processing.
- Denormal protection: flush very small state values to zero or enable a safe denormal strategy.
- Never emit NaN or infinity. Sanitize invalid input samples to zero.
- The processor is attenuation-only; it must not intentionally increase peak level.
- Hard clip is not part of the normal path. As a final safety guard only, clamp non-finite or out-of-range output to `[-1.0, 1.0]`.

---

## 12. User interface

### 12.1 Menu-bar popover

Show:

- Master enable toggle.
- Current status:
  - Disabled.
  - Waiting for Microsoft Teams.
  - Permission required.
  - Starting.
  - Processing Teams → `<output device name>`.
  - Recoverable error.
- Preset picker: Gentle / Standard / Strong / Custom.
- Strength slider mapped primarily to maximum reduction and secondarily to threshold.
- Live gain-reduction meter, 0–12 dB.
- Bypass-for-comparison toggle. Bypass leaves capture/replay active but crossfades the DSP to unity.
- “Rebuild audio path”.
- “Settings…” and “Quit”.

The enable control is different from bypass:

- **Disabled:** no tap or aggregate device; Teams is entirely normal.
- **Enabled + bypass:** Teams is still captured, dry-muted, and replayed at unity for A/B testing.

### 12.2 Settings window

Basic settings:

- Launch at login, implemented with `SMAppService` only after the core utility works.
- Preset and custom controls.
- Follow Teams output automatically; enabled and not user-disableable in v1.
- Start enabled on launch.

Advanced/diagnostic section:

- Detected Teams process bundle IDs and PIDs.
- Chosen output device name, UID, sample rate, and channel count.
- Tap and aggregate object IDs.
- Callback heartbeat/callbacks per second.
- Current input peak and gain reduction.
- Last Core Audio error with decimal and four-character OSStatus representation.
- Button to copy a text diagnostic report. Never include audio samples.

### 12.3 Permission UX

There is no private permission preflight. On first explicit enable:

1. Explain that macOS will ask for system-audio recording permission and that audio remains on-device.
2. Attempt tap creation, allowing macOS to show the prompt.
3. If creation fails in a way consistent with denial, show instructions to enable the app under macOS Privacy & Security’s screen/system-audio recording controls.
4. Provide a best-effort “Open Privacy & Security” button, but do not depend on a private URL scheme for correctness.

Do not prompt at app launch without user action unless the user previously chose “start enabled”.

---

## 13. Error handling and fail-open behavior

Every graph-construction function must either return a complete owned resource or clean up everything it created before throwing.

Use small RAII-style wrappers or Swift ownership types for:

- process tap;
- aggregate device;
- I/O proc;
- property-listener token;
- renderer/DSP state.

Required outcomes:

- Tap creation failure: no dry muting; show recoverable error.
- Aggregate creation failure: destroy tap; show recoverable error.
- Format mismatch: destroy aggregate and tap; show unsupported-device message.
- I/O proc creation/start failure: destroy all resources; dry Teams remains normal.
- Callback heartbeat failure: stop I/O immediately, teardown, then optionally rebuild once.
- Teams exit: teardown or wait for process restoration; never remain in a misleading “running” state.
- Output device disappears: stop/teardown, then wait for a valid output.
- App termination: synchronously perform best-effort teardown.

Do not repeatedly retry an error in a tight loop. Use exponential or bounded backoff, for example 0.5 s, 1 s, 2 s, then remain recoverable until an environment change or user action.

---

## 14. Core Audio monitoring

Use `AudioObjectAddPropertyListenerBlock` or the macOS 26 object wrappers where available.

At minimum monitor:

System object:

- process object list;
- default output device.

Selected output device:

- device alive;
- nominal sample rate;
- output stream configuration.

Target process objects:

- output devices;
- running-output state.

System power:

- sleep and wake notifications.

All listener callbacks must do only minimal work and enqueue a debounced environment refresh on the control queue.

Always remove listeners during teardown/deinit.

---

## 15. Suggested project structure

```text
TeamsDeEsser/
├── TeamsDeEsser.xcodeproj
├── TeamsDeEsser/
│   ├── App/
│   │   ├── TeamsDeEsserApp.swift
│   │   ├── AppModel.swift
│   │   ├── MenuBarView.swift
│   │   ├── SettingsView.swift
│   │   └── PermissionExplainerView.swift
│   ├── Models/
│   │   ├── ProcessingState.swift
│   │   ├── DeEsserSettings.swift
│   │   ├── Preset.swift
│   │   └── DiagnosticsSnapshot.swift
│   ├── Discovery/
│   │   ├── TeamsProcessLocator.swift
│   │   ├── OutputDeviceResolver.swift
│   │   └── AudioEnvironmentMonitor.swift
│   ├── Audio/
│   │   ├── AudioPipelineCoordinator.swift
│   │   ├── ProcessTapHandle.swift
│   │   ├── AggregateDeviceHandle.swift
│   │   ├── CoreAudioProperties.swift
│   │   ├── CoreAudioError.swift
│   │   └── StreamFormatValidator.swift
│   ├── Realtime/
│   │   ├── TDRealtimeRenderer.h
│   │   ├── TDRealtimeRenderer.mm
│   │   ├── DeEsserDSP.hpp
│   │   ├── DeEsserDSP.cpp
│   │   ├── Biquad.hpp
│   │   └── AudioBufferView.hpp
│   ├── Support/
│   │   ├── Logger+Categories.swift
│   │   ├── OSStatus+Description.swift
│   │   └── Info.plist
│   └── TeamsDeEsser-Bridging-Header.h
├── TeamsDeEsserTests/
│   ├── TeamsProcessLocatorTests.swift
│   ├── OutputDeviceResolverTests.swift
│   ├── AudioPipelineStateTests.swift
│   └── DeEsserDSPTests.mm
└── IMPLEMENTATION_NOTES.md
```

Keep the C++ DSP independent of Core Audio so it can be tested with ordinary arrays.

---

## 16. Implementation milestones

### Milestone 1 — App shell and Core Audio inspector

Deliver:

- Menu-bar app and Settings window.
- Stable Info.plist and permission description.
- `AudioHardwareSystem.shared.processes` inspector.
- Teams bundle-ID matching.
- Output-device resolver.
- Diagnostic UI listing process and device information.
- No tap yet.

Acceptance:

- App builds and launches on Tahoe.
- Launching/quitting Teams updates the detected state.
- During Teams output, diagnostics show at least one matching audio process and its output device or a documented fallback to default output.
- Other Microsoft apps are not matched.

### Milestone 2 — Lossless Teams capture and replay

Deliver:

- Process tap with stereo mixdown, device UID, `mutedWhenTapped`, privacy, UUID, and process restore.
- Private aggregate device with tap input and physical output subdevice.
- Objective-C++ real-time renderer.
- Unity-gain copy from tap input to aggregate output.
- Enable/disable and watchdog.
- No de-esser yet.

Acceptance:

- Teams audio is audible exactly once, with no obvious echo.
- Disabling restores the normal path immediately.
- Safari/Music audio is unaffected.
- Teams microphone operation is unaffected.
- Force-quitting the utility causes dry Teams audio to return.
- No audio file is created.

Do not proceed to DSP integration until this milestone is proven manually.

### Milestone 3 — Standalone DSP and tests

Deliver:

- C++ biquad and LR4 crossover.
- Linked detector and soft-knee gain computer.
- Presets and parameter struct.
- Bypass crossfade.
- Offline unit tests.

Required tests:

1. Hard bypass copies samples exactly when crossfade is settled.
2. A 1 kHz sine at -12 dBFS changes by less than 0.25 dB under the Standard preset.
3. A 7 kHz sine/noise burst above threshold receives measurable reduction near the configured maximum.
4. Left/right gain reduction is identical for a one-sided detector event.
5. Release returns within the expected tolerance after a burst.
6. No NaN/Inf is emitted for silence, denormals, NaN input, or maximum-amplitude input.
7. Output does not exceed input peak by more than numerical tolerance for ordinary finite input.

### Milestone 4 — DSP integration and controls

Deliver:

- DSP in the I/O callback.
- Off-thread coefficient preparation and atomic swap.
- Preset picker, strength control, bypass, input/gain-reduction meters.
- Settings persistence.

Acceptance:

- Sibilant material is audibly reduced without muting entire words at Standard settings.
- Bypass changes are click-free.
- UI interaction causes no callback stalls.
- CPU usage averages below 2% on an M1-class Mac at 48 kHz under ordinary buffer sizes.

### Milestone 5 — Lifecycle resilience

Deliver:

- Process-list, process-device, default-output, device-alive, sample-rate, stream-layout, sleep/wake monitoring.
- Debounced full rebuilds.
- Bounded retry/backoff.
- Manual rebuild command.
- Diagnostics report.

Acceptance:

- Teams quit/relaunch recovers automatically.
- Switching built-in speakers to wired headphones recovers.
- AirPods connect/disconnect and profile change do not leave Teams permanently silent.
- Sleep/wake recovers.
- Permission denial leaves Teams audio normal.
- Every failed start leaves no visible aggregate device and no stale process tap.

### Milestone 6 — Packaging and polish

Deliver:

- App icon and user-facing copy.
- Optional launch-at-login using `SMAppService`.
- Release build.
- README with build, permission, operation, and emergency-disable instructions.
- Manual test report.

Do not add update frameworks, analytics, or network access.

---

## 17. Build and test commands

Use the actual scheme name if it differs:

```bash
xcodebuild \
  -project TeamsDeEsser.xcodeproj \
  -scheme TeamsDeEsser \
  -configuration Debug \
  -destination 'platform=macOS' \
  build
```

```bash
xcodebuild \
  -project TeamsDeEsser.xcodeproj \
  -scheme TeamsDeEsser \
  -destination 'platform=macOS' \
  test
```

Run static analysis before release:

```bash
xcodebuild \
  -project TeamsDeEsser.xcodeproj \
  -scheme TeamsDeEsser \
  -configuration Release \
  -destination 'platform=macOS' \
  analyze
```

No milestone is complete while the project has newly introduced compiler warnings, failed tests, leaked Core Audio objects, or a nonfunctional disable path.

---

## 18. Manual test matrix

Test with a real Teams call or Teams test-call feature where available.

| Scenario | Expected result |
|---|---|
| Utility disabled | Teams behaves exactly as without the utility |
| Enable before Teams launch | State waits; processing starts when Teams audio appears |
| Enable during active meeting | Permission prompt if needed; then processed playback |
| Gentle/Standard/Strong | Increasing high-band attenuation without overall gain increase |
| DSP bypass | Unity replay, no click |
| Master disable | Immediate dry Teams playback |
| Safari or Music playing simultaneously | Non-Teams audio is unchanged |
| Teams microphone active | Microphone remains selected and functional |
| Teams quit/relaunch | Processing restores automatically or controlled rebuild occurs |
| Built-in speakers → wired headphones | Graph rebuilds to new device |
| AirPods connect/disconnect | No permanent silence; graph rebuilds as needed |
| AirPods profile/sample-rate change | Full rebuild; processed audio resumes |
| USB stereo headset | Tap input does not accidentally include its microphone |
| HDMI/multichannel output | First stereo pair works or utility fails open with clear message |
| Sleep/wake | Graph rebuilds and resumes |
| Revoke capture permission | Utility errors and normal Teams playback remains available |
| Force quit utility | Original Teams path returns |
| Two-hour meeting | No cumulative crackle, runaway CPU, or material memory growth |

---

## 19. Release acceptance criteria

The v1 release is acceptable only when all of the following are true:

1. Uses no installed audio driver or system extension.
2. Processes native Teams playback only.
3. Leaves Teams microphone and non-Teams playback untouched.
4. Does not change system or Teams device selections.
5. Produces no doubled/echoed Teams audio during normal operation.
6. Disable and failure paths restore normal Teams playback within one second.
7. Adds no intentional output gain.
8. Has no real-time callback allocations or locks, verified by code review and Instruments where possible.
9. Survives Teams restart and common output-device changes.
10. Creates no audio recordings and performs no network requests.
11. DSP tests pass for both architectures built by the project.
12. The diagnostic report contains metadata only, never PCM data.

Latency target: no buffering beyond the hardware/aggregate callback and filter state. Added processing latency should remain below one normal hardware buffer; subjective call audio should remain lip-sync acceptable.

---

## 20. Known risks and mitigations

### 20.1 Teams helper-process changes

Risk: Teams may move audio to a helper whose bundle ID differs from the main app.

Mitigation: enumerate HAL audio processes, exact/prefix match known Teams IDs, enable process restore, monitor changes, provide DEBUG diagnostics and path/parent fallback.

### 20.2 Device-format variation

Risk: uncommon devices expose unexpected interleaving, channel counts, or sample rates.

Mitigation: query and validate every ASBD, support mono and Float32 stereo layouts explicitly, clear unused channels, and fail open rather than guessing.

### 20.3 Bluetooth route renegotiation

Risk: AirPods may change format while the meeting is live.

Mitigation: listen for sample-rate/stream changes and perform full tap-plus-aggregate rebuild.

### 20.4 Stalled callback

Risk: dry Teams audio remains muted while no processed frames reach hardware.

Mitigation: atomic heartbeat watchdog stops I/O and tears down the tap; original route then resumes.

### 20.5 Zero-filled but still-running tap

Risk: a callback can theoretically continue while receiving silence, and legitimate silence cannot be distinguished reliably from a failed tap.

Mitigation: do not auto-diagnose solely from PCM zeros. Expose manual rebuild, rebuild on every route/format/process change, and log metadata around long zero periods in diagnostics without retaining audio.

### 20.6 Crash during active processing

Risk: temporary silence until Core Audio destroys client-owned resources.

Mitigation: keep the graph private, use `mutedWhenTapped` rather than permanent process mute, perform termination teardown, and keep the callback minimal to reduce crash risk.

---

## 21. Public API reference checklist

Codex should verify these symbols in the macOS 26 SDK and use their current imports:

- `AudioHardwareSystem.shared`
- `AudioHardwareSystem.processes`
- `AudioHardwareProcess.bundleID`
- `AudioHardwareProcess.pid`
- `AudioHardwareProcess.devices`
- `AudioHardwareProcess.isRunningOutput`
- `CATapDescription(stereoMixdownOfProcesses:)`
- `CATapDescription.deviceUID`
- `CATapDescription.isPrivate`
- `CATapDescription.muteBehavior`
- `CATapDescription.isProcessRestoreEnabled`
- `CATapMuteBehavior.mutedWhenTapped`
- `AudioHardwareCreateProcessTap`
- `AudioHardwareDestroyProcessTap`
- `kAudioTapPropertyFormat`
- `AudioHardwareCreateAggregateDevice`
- `AudioHardwareDestroyAggregateDevice`
- `kAudioAggregateDeviceNameKey`
- `kAudioAggregateDeviceUIDKey`
- `kAudioAggregateDeviceMainSubDeviceKey`
- `kAudioAggregateDeviceIsPrivateKey`
- `kAudioAggregateDeviceIsStackedKey`
- `kAudioAggregateDeviceTapAutoStartKey`
- `kAudioAggregateDeviceSubDeviceListKey`
- `kAudioAggregateDeviceTapListKey`
- `kAudioSubDeviceUIDKey`
- `kAudioSubDeviceInputChannelsKey`
- `kAudioSubTapUIDKey`
- `kAudioSubTapDriftCompensationKey`
- `AudioDeviceCreateIOProcID`
- `AudioDeviceStart`
- `AudioDeviceStop`
- `AudioDeviceDestroyIOProcID`
- `AudioObjectAddPropertyListenerBlock`
- `AudioObjectRemovePropertyListenerBlock`
- `NSAudioCaptureUsageDescription`

Useful official references:

- Apple Developer Documentation — Capturing system audio with Core Audio taps: https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps
- Apple Developer Documentation — `CATapDescription`: https://developer.apple.com/documentation/coreaudio/catapdescription
- Apple Developer Documentation — `AudioHardwareSystem`: https://developer.apple.com/documentation/coreaudio/audiohardwaresystem
- Apple Developer Documentation — `AudioHardwareProcess`: https://developer.apple.com/documentation/coreaudio/audiohardwareprocess
- Apple Developer Documentation — `NSAudioCaptureUsageDescription`: https://developer.apple.com/documentation/bundleresources/information-property-list/nsaudiocaptureusagedescription
- Microsoft Learn — Deploy the Microsoft Teams client for Mac: https://learn.microsoft.com/en-us/microsoftteams/teams-client-mac-install-prerequisites

---

## 22. Final deliverables

Codex must leave the repository with:

1. A compiling Xcode project and native app target.
2. A working menu-bar utility implementing the full data path.
3. C++ DSP unit tests and Swift orchestration tests.
4. A README containing build and permission instructions.
5. `IMPLEMENTATION_NOTES.md` documenting exact SDK-name differences, unsupported devices encountered, and manual test results.
6. No placeholder TODOs in the enable/disable, capture/replay, DSP, or teardown paths.
7. No bundled third-party binary, plug-in, driver, or network dependency.

The most important development gate is Milestone 2: demonstrate transparent, unity-gain, Teams-only capture/mute/replay and reliable fail-open teardown before adding the de-esser.
