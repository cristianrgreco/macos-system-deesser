# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A macOS Tahoe (26.0+) menu-bar utility that de-esses **all system audio** in real time. It takes a **global** Core Audio tap of every process *except itself*, runs the mix through a de-esser, and plays it back out the current default output device — without ever touching the microphone. It is a `LSUIElement` accessory (no Dock icon). Users toggle it on/off as needed.

> **History:** this started as a Teams-only utility (see `spec.md`, written for that scope) and was generalised to system-wide. The product/target/bundle id were renamed from `TeamsDeEsser`/`local.TeamsDeEsser` to **`DeEsser`/`local.DeEsser`**. Where `spec.md` says "Teams", read "all system audio except this app"; this file and `IMPLEMENTATION_NOTES.md` are authoritative on the current scope.

The Xcode project lives in the **`DeEsser/`** subdirectory; run all build commands from there. The repo root holds `spec.md`, `CLAUDE.md`, and the project folder.

## Commands

```bash
cd DeEsser

# Regenerate the .xcodeproj — REQUIRED after adding/removing/renaming any source
# file or editing project.yml. Sources are globbed by directory, so a new file is
# invisible to the build until you regenerate. The generated project is committed.
xcodegen generate

xcodebuild -project DeEsser.xcodeproj -scheme DeEsser -configuration Debug -destination 'platform=macOS' build
xcodebuild -project DeEsser.xcodeproj -scheme DeEsser -destination 'platform=macOS' test
xcodebuild -project DeEsser.xcodeproj -scheme DeEsser -configuration Release -destination 'platform=macOS' analyze

# Single test / single test case:
xcodebuild ... test -only-testing:DeEsserTests/DeEsserDSPTests
xcodebuild ... test -only-testing:DeEsserTests/DeEsserDSPTests/testReleaseRecovers
```

The bar to keep green: **Debug build with zero warnings, Release `analyze` clean, all tests pass.** Note that `analyze` flags dead stores etc. that a normal build won't.

If an incremental build/test fails with `CodeSign ... code object is not signed at all`, the ad-hoc-signed test-host bundle got into a half-signed state in DerivedData — run `xcodebuild ... clean` and retry. It is not a code problem.

The standard `Bash` shell here prints a harmless `GVM_ROOT not set` line to stderr on init; ignore it. SwiftUI/Swift files often show spurious SourceKit "Cannot find type X in scope" diagnostics because the LSP doesn't see the whole-module/bridging-header context — trust `xcodebuild`, not those.

## Architecture

Three layers, each on its own thread/queue. Control flows down; meters are polled back up. Never short-circuit a layer.

1. **UI / `AppModel`** (`App/`, main queue). `AppModel` is `@Observable` (not `ObservableObject`), owns persisted `DeEsserSettings`, and is the only thing the SwiftUI views talk to. It forwards user intent to the coordinator and mirrors the coordinator's state/diagnostics callbacks (which arrive on the main queue).

2. **`AudioPipelineCoordinator`** (`Audio/`, serial `DispatchQueue` `local.DeEsser.control`). The brain. **All Core Audio graph mutation and all `ProcessingState` transitions happen on this one queue** — default-output resolution, self-process lookup (to exclude from the global tap), tap + private aggregate-device construction, the property-change monitor, the heartbeat watchdog, and debounced rebuilds. Treat the queue confinement as invariant.

3. **`TDRealtimeRenderer`** (`Realtime/`, Objective-C++, audio I/O thread). Owns the `AudioDeviceIOProcID` (registered via `...WithBlock` on a dedicated user-interactive queue). The render block forwards raw pointers to a free C++ function operating on a plain `RenderContext*` — it **never** messages Obj-C or touches Swift.

### Audio data path

All system audio (every process **except this app**) → Core Audio **global tap** (`stereoGlobalTapButExcludeProcesses:`, `mutedWhenTapped`) → **private aggregate device** → `TDRealtimeRenderer` IOProc → `td::DeEsserDSP` → the current default output device. The design is **fail-open**: the tap mutes the original audio only while it is being read, so if any layer tears down, normal unprocessed audio resumes automatically.

Two things are load-bearing and **cannot be verified in a headless build** — confirm them by ear on real hardware:
- **Self-exclusion prevents feedback.** We translate our own PID to a HAL process object (`kAudioHardwarePropertyTranslatePIDToProcessObject`) and exclude it, so the de-essed audio we replay is not re-captured. If that lookup returns nothing, the tap is fully global and *could* loop.
- **The tap is unscoped (no `deviceUID`).** Scoping the tap to the aggregate's own output device stopped the aggregate's I/O from starting (`aggIsRunning` stayed 0). An unscoped global tap therefore captures audio bound for *all* devices and funnels it to the one default output device — a known limitation for multi-output-device setups.

### The DSP (`Realtime/DeEsserDSP.{hpp,cpp}`, `Realtime/Biquad.hpp`)

`td::DeEsserDSP` is a **faithful port of the Calf "Deesser" plugin** (`calf-studio-gear/calf`: `deesser_audio_module` + `gain_reduction_audio_module` + the RBJ `biquad_d2`). EasyEffects has no de-esser DSP of its own — it wraps that exact Calf plugin — so "the EasyEffects de-esser" *means* this Calf port. When changing the algorithm, keep it matching Calf semantics (the `.cpp` cites the upstream files and preserves quirks deliberately, e.g. the double high-pass pass in SPLIT mode). It is pure C++ with **no Core Audio dependency**, which is why the test target compiles `DeEsserDSP.cpp/hpp` + `Biquad.hpp` directly and exercises it on plain `float` arrays.

**Real-time safety is non-negotiable in `process()`**: no heap allocation, no locks, no logging, no Obj-C/Swift, no I/O. All buffers/filter state are allocated in `prepare()`/`init`. Parameter edits compute coefficients **off-thread** in `setParameters()` and publish them via a double-buffered `CoeffSet[2]` with an atomic active index; `process()` only copies coefficients in at block boundaries. Denormals are flushed; output is NaN/Inf-guarded and clamped to [-1, 1].

### Parameter bridge

One user control. `DeEsserSettings.strength` (0…1) maps **threshold + ratio together** to the Calf controls (piecewise: 0.5 = the stock EasyEffects defaults; the upper half ramps to a deliberately heavy −42 dBFS / 12:1). Every other Calf control is pinned to its EasyEffects default. The flow is: `DeEsserSettings.rendererParams(bypass:)` → `TDDeEsserParams` (a C struct in `DeEsser-Bridging-Header.h` / `TDRealtimeRenderer.h`) → `td::DeEsserParams`, where dB fields are converted to the linear values Calf expects (mirroring EasyEffects' `BIND_LV2_PORT_DB`). If you add a tunable parameter, it must be threaded through all four representations.

## Conventions and gotchas

- **`spec.md` is the original v1 spec** (Teams-only), section-numbered; code comments reference it as "spec §N" and those references still point at the section that shaped the code. It is **superseded on scope** by this file and `IMPLEMENTATION_NOTES.md` (system-wide, renamed). **`IMPLEMENTATION_NOTES.md` records every deviation, the SDK-name differences, and the engineering rationale** — read it before changing graph lifecycle, the aggregate-device keys, the tap topology, or the DSP, and update it when you deviate further.
- **No `AudioHardwareSystem` / `AudioHardwareProcess` Swift overlay exists** in this SDK; output-device resolution and the self-process lookup use the **raw C Core Audio property API** (`Audio/CoreAudioProperties.swift`, `Discovery/`). See IMPLEMENTATION_NOTES §1.
- The app is **ad-hoc signed** (`CODE_SIGN_IDENTITY = "-"`), Hardened Runtime **off**, App Sandbox **off**, for frictionless local builds. It requests **only** system-audio capture (`NSAudioCaptureUsageDescription`), never the mic. The bundle id is **`local.DeEsser`**; the granted system-audio permission is keyed to it, so keep it stable (renaming it forces the user to re-grant permission).
- `kAudioAggregateDeviceTapAutoStartKey` must be `Int(0)` (CFNumber), not `true`; a non-zero value parks the device until the tapped process plays and the watchdog will tear the graph down. See IMPLEMENTATION_NOTES §2.
- Settings persist as JSON in `UserDefaults`; the `DeEsserSettings` decoder keeps **backward-compat for renamed keys** (e.g. legacy `aggressiveness` → `strength`). Preserve that when renaming stored fields.
- **The full audio path cannot be verified in a headless build** — it needs real audio playing plus physical device changes, and above all a listen for **feedback** (the self-exclusion path) and for **doubled audio**. Automated tests cover the DSP and the value-type orchestration only; the manual matrix lives in IMPLEMENTATION_NOTES §5 and spec §18.
