# Implementation Notes — De-Esser

This document records the exact SDK-name differences encountered against the
specification, the engineering choices made where the spec left options open,
device/format observations, and the current verification status.

## 0. Scope change: Teams-only → system-wide (and rename)

`spec.md` describes a **Teams-only** utility. The product was generalised to
de-ess **all system audio**, and renamed from `TeamsDeEsser` / `local.TeamsDeEsser`
to **`DeEsser` / `local.DeEsser`** (target, scheme, directories, product name, and
bundle id). Consequences, all within the same public APIs:

- **Capture is now a global tap.** `CATapDescription(stereoGlobalTapButExcludeProcesses:)`
  replaces `stereoMixdownOfProcesses:`. Both exist in the macOS 26.5 SDK and take
  `[AudioObjectID]` process objects.
- **Self-exclusion prevents feedback.** We resolve our own HAL process object via
  `kAudioHardwarePropertyTranslatePIDToProcessObject` (qualifier = our `getpid()`)
  and pass it as the single excluded process, so the de-essed audio we replay is
  not re-captured. If the lookup returns `kAudioObjectUnknown` we fall back to a
  fully global tap (logged) — that case risks a feedback loop and is the #1 thing
  to verify by ear.
- **Tap stays unscoped (no `deviceUID`).** Scoping the tap to the aggregate's own
  output device prevents the aggregate's I/O from starting (`aggIsRunning` stayed
  0; same failure mode as §2's autostart key). An unscoped global tap captures
  audio bound for *all* devices and funnels it to the single default output
  device — a deliberate limitation for multi-output-device setups (documented, not
  fixed, for this version).
- **No process discovery.** `TeamsProcessLocator` and its tests were deleted;
  `OutputDeviceResolver` collapsed to "validate the current default output
  device"; the process-object-list and per-process property listeners and the
  1 s discovery refresh were removed; `ProcessingState.waitingForTeams` is gone.
  The output device is followed via the default-output + device-liveness/format
  listeners exactly as before.

Build environment used:

- macOS 26.3.1 (Tahoe), Darwin 25.3.0
- Xcode 26.5 (build 17F42), macOS 26.5 SDK (`MacOSX26.5.sdk`)
- Apple Swift 6.3.2
- Apple Silicon (arm64)

---

## 1. SDK API differences vs. the specification

The spec instructs (§0) to inspect the SDK and adapt when imported names differ.
The following differences were found and adapted.

### 1.1 `AudioHardwareSystem` / `AudioHardwareProcess` do not exist in this SDK

The spec (§6, §7, §21) assumes Swift overlay types `AudioHardwareSystem.shared`,
`AudioHardwareSystem.processes`, and `AudioHardwareProcess` (with `.bundleID`,
`.pid`, `.devices`, `.isRunningOutput`). **No such types ship in the macOS 26.5
SDK** — there is no CoreAudio Swift overlay providing them (verified: no
`.swiftinterface` and no symbol anywhere under `CoreAudio.framework`).

**Adaptation:** all process discovery and device resolution use the public **raw
C Core Audio property API** instead, which is fully present:

| Spec (assumed Swift) | Used instead (public C API) |
|---|---|
| `AudioHardwareSystem.processes` | `kAudioHardwarePropertyProcessObjectList` (`'prs#'`) on `kAudioObjectSystemObject` |
| `AudioHardwareProcess.bundleID` | `kAudioProcessPropertyBundleID` (`'pbid'`) |
| `AudioHardwareProcess.pid` | `kAudioProcessPropertyPID` (`'ppid'`) |
| `AudioHardwareProcess.devices` | `kAudioProcessPropertyDevices` (`'pdv#'`), scope `Output` |
| `AudioHardwareProcess.isRunningOutput` | `kAudioProcessPropertyIsRunningOutput` (`'piro'`) |
| `AudioHardwareSystem.defaultOutputDevice` | `kAudioHardwarePropertyDefaultOutputDevice` (`'dOut'`) |

This is encapsulated in `Audio/CoreAudioProperties.swift` and
`Discovery/OutputDeviceResolver.swift` (the Teams-specific `TeamsProcessLocator`
was removed — see §0). The self-process lookup that feeds the global tap's
exclude list uses `kAudioHardwarePropertyTranslatePIDToProcessObject`. The
behavior is identical to the spec's intent; only the access mechanism differs.

### 1.2 `CATapDescription` Swift names

`CATapDescription` **is** present (in `CATapDescription.h`) and the compiler-
shipped refinement provides the spec's nice Swift initializer. Confirmed by
compilation:

- `CATapDescription(stereoMixdownOfProcesses: [AudioObjectID])` — note the
  argument is `[AudioObjectID]` (i.e. `[UInt32]`), **not** `[NSNumber]`.
- Property is `uuid` (Swift) for the Obj-C `UUID`/`NSUUID`.
- `isPrivate`, `isProcessRestoreEnabled` (macOS 26+), `deviceUID` as specified.
- Mute behavior enum is `CATapMuteBehavior.mutedWhenTapped` (Obj-C
  `CATapMutedWhenTapped`). The spec's `tapDescription.muteBehavior = .mutedWhenTapped`
  shorthand works once the surrounding types are correct.
- The spec's `tapDescription.name`/`uuid` assignments work; the description also
  auto-generates a UUID at init, which we read back for the aggregate sub-tap list.

### 1.3 Objective-C method import rename

The Obj-C renderer method `-startOnAggregateDevice:` is imported into Swift as
`start(onAggregateDevice:)` (the Obj-C "start…" prefix is treated specially by
the Swift importer). The coordinator calls `renderer.start(onAggregateDevice:)`.

### 1.4 Tap/aggregate C functions and keys

`AudioHardwareCreateProcessTap` / `AudioHardwareDestroyProcessTap`
(`AudioHardwareTapping.h`), `AudioHardwareCreateAggregateDevice` /
`AudioHardwareDestroyAggregateDevice`, `kAudioTapPropertyFormat` (`'tfmt'`), and
all aggregate/sub-device/sub-tap dictionary keys exist exactly as named in the
spec (§9, §21) and are used directly.

`kAudioSubDeviceInputChannelsKey: 0` is **omitted** from the sub-device entry, as
the spec permits (§9), because the tap supplies the input stream and some devices
reject `channels-in: 0`.

---

## 2. Engineering choices where the spec left options open

- **Concurrency model (§5):** a dedicated serial `DispatchQueue`
  (`local.DeEsser.control`) is used rather than a Swift actor, so the same
  queue can host the Core Audio property-listener blocks (which take a
  `DispatchQueue`) and the watchdog/refresh `DispatchSourceTimer`s. All graph
  state is confined to this queue; UI callbacks hop to the main queue.

- **`kAudioAggregateDeviceTapAutoStartKey` must be `0` (CFNumber), not `true`.**
  On-device testing showed `AudioDeviceStart` returning `noErr` while the
  aggregate never actually ran (`kAudioDevicePropertyDeviceIsRunning == 0`, no
  I/O callbacks) — across Bluetooth *and* USB outputs and regardless of tap
  scoping. The header documents that a **non-zero** value makes the device's
  start *wait for the first tap audio*: `AudioDeviceStart` succeeds but the device
  stays parked until the tapped process plays audio. Since the heartbeat watchdog
  tore the graph down after ~1 s (before any app produced sound), it looked like a
  dead callback. The value is also specified as a CFNumber, but the spec's `true`
  bridges to a CFBoolean. Setting it to `Int(0)` runs the graph continuously
  (immediate I/O, steady heartbeat), which is what the watchdog/confirm logic
  assumes. Trade-off: the output device runs continuously while enabled rather
  than only when an app plays; acceptable for a menu-bar utility.

- **DSP: faithful port of the Calf "Deesser" (the EasyEffects de-esser), replacing
  the spec §11 split-band design.** EasyEffects (PipeWire/PulseAudio) does not
  implement its own de-esser DSP — it wraps the **Calf** `Deesser` LV2 plugin
  (`http://calf.sourceforge.net/plugins/Deesser`) and only applies input/output
  gain around it. So "use the EasyEffects de-esser" means reproducing Calf's
  `deesser_audio_module` + `gain_reduction_audio_module`. Both were ported from
  `calf-studio-gear/calf` (`src/modules_comp.cpp`, `src/calf/biquad.h`,
  `src/calf/primitives.h`) into `DeEsserDSP`/`Biquad`:
  - A sidechain detector built from an RBJ high-pass (`f1_freq·0.83`) followed by a
    peaking EQ (`f2_freq`, boosted `f2_level`) feeds **Thor's compressor** (the
    `gain_reduction` module): RMS or peak detection, laxity-derived attack/release
    (`attack = laxity`, `release = laxity·1.33`, `coeff = min(1, 1/(t·sr/4000))`),
    a soft-knee (knee fixed at 2.8) gain computer with Hermite-interpolated knee,
    and makeup. Defaults are the exact Calf metadata defaults (= EasyEffects
    defaults): threshold 0.125 lin (−18 dBFS), ratio 3:1, makeup 0 dB, split
    6 kHz, peak 4.5 kHz / +12 dB, laxity 15, RMS, **Wide** mode.
  - **Wide** mode scales the whole band by the computed gain; **Split** mode
    compresses only the high half of an `f1`-crossover and recombines (the same
    RBJ high-pass object is deliberately processed twice per sample, exactly as in
    Calf — preserved verbatim). The RBJ coefficient math and the Direct-Form-II
    `biquad_d2` topology (double-precision state) are reproduced exactly.
  - Coefficients and the compressor curve are computed off the audio thread in
    `setParameters` and published via the existing double-buffered atomic-index
    swap; the per-sample loop only copies coefficients in at each block boundary.
    Linked (averaged) stereo detection, the click-free bypass crossfade, and
    denormal/NaN safety are retained.
  - **UI/controls reduced to on/off + one slider.** Per the product direction the
    only exposed control is **Strength** (`DeEsserSettings.strength`, 0…1): a
    piecewise map of threshold and ratio that eases from "off" up to the stock
    EasyEffects default (−18 dBFS, 3:1) at the 0.5 midpoint, then ramps hard over
    the upper half to −42 dBFS / 12:1 so the top of the slider is a deliberately
    heavy de-ess. Every other Calf control is pinned to its EasyEffects default.
    The old Preset picker, Type (Broadband/Notch) switch, Frequency / Threshold /
    Max-reduction / Sharpness sliders and the Solo "listen to band" toggle were
    removed. (The control was briefly named "Aggressiveness"; the persisted
    settings decoder still accepts that legacy key.)

- **Real-time path (§10.1):** the render body is a free C++ function
  (`TDRenderProcess`) operating on an opaque `RenderContext`; it never messages
  Objective-C or touches Swift. On-device testing showed the function-pointer
  `AudioDeviceCreateIOProcID` returned `noErr` for the private tap-backed
  aggregate but its callback was **never driven** (heartbeat stayed 0). Switching
  to **`AudioDeviceCreateIOProcIDWithBlock`** with a dedicated user-interactive
  serial dispatch queue (the configuration used by Apple's "Capturing system
  audio" sample) makes the I/O proc fire. The block only forwards raw pointers to
  `TDRenderProcess`, which spec §10.1 explicitly permits. The block captures the
  raw `RenderContext*` (never `self`), so no Obj-C/Swift work occurs on the audio
  queue.

- **Project generation:** the Xcode project is generated by
  [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml`. XcodeGen is
  a build-time developer tool, **not** a runtime dependency, so the "no
  third-party runtime dependencies" constraint (§0) holds. The generated
  `DeEsser.xcodeproj` is committed so the spec's `xcodebuild` commands work
  without XcodeGen installed. Regenerate with `xcodegen generate` after editing
  `project.yml`.

- **Swift language mode:** `SWIFT_VERSION = 5.0`. The model is a plain
  `ObservableObject` (not `@MainActor`); the coordinator already marshals its
  callbacks to the main queue.

- **Hardened Runtime / App Sandbox:** Hardened Runtime is **disabled** and the app
  is **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`) for frictionless local builds,
  which the spec allows (§3: "enabled if it does not interfere with local
  development"; sandbox disabled for v1). App Sandbox is off (no entitlements
  file). No private TCC APIs or undocumented entitlements are used; the
  system-audio prompt is driven solely by `NSAudioCaptureUsageDescription`.

- **Sample-rate handling (§9, §20.3):** a process tap reports its own native rate
  (commonly 48 kHz) which **need not equal** the output device's rate. The
  aggregate device runs at the output device's clock, and the sub-tap is created
  with **drift compensation enabled**, so the HAL resamples the tap to the
  aggregate clock; the I/O callback therefore delivers both input and output at
  the aggregate rate, and the DSP is prepared at that rate. An earlier, literal
  reading of §9 enforced tap == aggregate equality and failed open — this broke
  the very common Bluetooth case (e.g. a Jabra headset at 44.1 kHz with a 48 kHz
  tap). The equality gate was removed; we still fail open only if *neither* the
  tap nor the aggregate reports a valid (>0) rate. No ad-hoc converter is added by
  the app.

- **Permission-denial heuristic (§12.3):** Core Audio does not expose a documented
  "permission denied" `OSStatus` for tap creation, so denial is inferred
  heuristically from generic failure codes and steers the user to Privacy &
  Security. There is no private permission preflight.

---

## 3. Real-time safety (§10.3, §19.8)

The audio callback (`Realtime/TDRealtimeRenderer.mm` → `td::DeEsserDSP::process`)
performs no heap allocation, no locks/semaphores, no Swift/Obj-C runtime work, no
logging, and no file/network I/O. All buffers (the deinterleave scratch and all
filter/DSP state) are allocated in `initWithLayout:` / `prepare()` before
`AudioDeviceStart`. Parameter updates compute coefficients off-thread and publish
them via a double-buffered set with an atomic active index. Denormals are flushed;
output is guarded against NaN/Inf and clamped to `[-1, 1]` only as a final safety
net. These properties are asserted by the offline DSP tests and by code review;
Instruments verification on a live graph is part of the manual matrix.

---

## 4. Device / format observations

No unusual output devices were exercised in this build environment (headless CI-
style build/test only). The renderer's `AudioBufferView` handles the three
supported layouts (§10.2): one interleaved Float32 buffer with N channels; two
non-interleaved mono buffers; and multi-buffer outputs where the first two
channels form the stereo pair. Unused output channels are cleared. Unsupported
tap formats (non-PCM, non-Float32, or >2 channels) fail open at setup via
`StreamFormatValidator`.

No unsupported device has yet been observed to require omitting additional
aggregate keys beyond `kAudioSubDeviceInputChannelsKey`.

---

## 5. Verification status

### Automated (performed in this environment) ✅

- `xcodebuild … build` (Debug): **succeeds, zero warnings**.
- `xcodebuild … test`: **24/24 tests pass** — 9 DSP tests (`DeEsserDSPTests.mm`,
  exercising the Calf de-esser port: bypass, low-band pass-through, sibilant-band
  reduction, wide/split behaviour, linked-stereo symmetry, release, NaN safety,
  peak bound), plus Swift orchestration tests for the default-output resolution
  policy and state/settings logic. (The Teams process-ranking tests were removed
  with the locator — see §0.)
- `xcodebuild … -configuration Release … analyze`: **ANALYZE SUCCEEDED**, no
  findings.

Architectures: built and tested on `arm64`. The DSP is architecture-independent
plain C++/IEEE-754 float; `x86_64` was not executed at runtime on this Apple
Silicon machine (release gate §19.11 should be re-checked on / with an Intel
slice before shipping).

### Manual (requires real audio playing on-device) ⏳

The capture/replay graph and lifecycle resilience **cannot be exercised in this
build-only environment**. The full data path is implemented end-to-end (global
tap → private aggregate → real-time renderer → output) with fail-open teardown,
but the matrix below must be run by an operator on-device. The two **bold** rows
are new with the system-wide design and are the highest-risk: they verify there
is no feedback loop and no doubled audio with a global tap. Record results below.

| Scenario | Result | Notes |
|---|---|---|
| Utility disabled — audio is exactly as without it | _pending_ | |
| Enable while audio is playing → de-essed playback | _pending_ | |
| **No feedback / runaway loop while enabled** | _pending_ | self-exclusion working |
| **Audio audible exactly once (no echo/doubling)** | _pending_ | mutedWhenTapped + replay |
| Gentle/Standard/Strong strength sweep | _pending_ | |
| DSP bypass (click-free) | _pending_ | |
| Master disable restores dry audio < 1 s | _pending_ | |
| Microphone never captured (mic apps unaffected) | _pending_ | |
| Speakers → wired headphones (default-output change) | _pending_ | rebuilds to new device |
| AirPods connect/disconnect | _pending_ | |
| AirPods profile/sample-rate change | _pending_ | |
| Multi-device: audio on a non-default device | _pending_ | known funnel-to-default limitation |
| HDMI/multichannel output | _pending_ | |
| Sleep/wake | _pending_ | |
| Revoke capture permission | _pending_ | normal audio remains |
| Force-quit utility | _pending_ | original path returns |
| Two-hour session | _pending_ | no crackle/CPU/memory growth |

---

## 6. Known omissions / follow-ups

- **No custom app icon asset.** The menu-bar item uses the SF Symbol
  `waveform.badge.mic`; an `.icns`/asset catalog can be added for Developer ID
  distribution (Milestone 6 polish). LSUIElement apps show no Dock icon.
- **Developer ID signing & notarization** are out of scope for the local v1 build
  (spec §2.3) and would replace the ad-hoc signing identity.
