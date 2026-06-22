# De-Esser

A local, on-device macOS menu-bar utility that reduces harsh sibilance (the
painful "S" / "SH" sounds) in **all of your Mac's audio** in real time — without
ever touching your microphone. Toggle it on when what you're listening to is
harsh, and off when it isn't.

It uses public **Core Audio process-tap** APIs on macOS Tahoe (26). There is **no
audio driver, no system/kernel extension, and no virtual device**. Audio is never
recorded, saved, or sent anywhere.

> **History:** this began as a Teams-only utility (the original design lives in
> `spec.md`) and was generalised to system-wide. It was renamed from
> `TeamsDeEsser` / `local.TeamsDeEsser` to **`DeEsser` / `local.DeEsser`**.

> **Status:** v1, local Developer build. Builds, unit-tests, and static analysis
> pass on Xcode 26.5 / macOS 26. The live capture/replay path is implemented; the
> on-device manual test matrix should be run by an operator (see
> `IMPLEMENTATION_NOTES.md`) — in particular, confirm there is no feedback loop.

---

## How it works

```
All system audio (every process except this app)
      │  Core Audio global tap (stereoGlobalTapButExcludeProcesses:, mutedWhenTapped)
      ▼
Private aggregate-device input
      │  real-time AudioDeviceIOProc
      ▼
De-esser — a faithful port of the Calf "Deesser" (the de-esser EasyEffects uses)
      ▼
The current default output device
```

The tap captures every process **except De-Esser itself** (excluded by PID so the
processed audio it replays is not re-captured). The original audio is muted **only
while the tap is being read**, so if anything goes wrong the normal, unprocessed
audio resumes automatically (fail-open).

**Known limitation:** the tap is global and unscoped, so all audio is routed to
the single default output device. If you split audio across two output devices at
once, both are funneled to the default while De-Esser is enabled.

---

## Requirements

- macOS Tahoe **26.0+**
- Xcode **26.x** (macOS 26 SDK)
- Apple Silicon or Intel Mac

---

## Build

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (a build-time tool only — not a
runtime dependency). A generated `DeEsser.xcodeproj` is included, so you can build
directly.

```bash
cd DeEsser

# (Only if you changed project.yml)
xcodegen generate

# Build (Debug)
xcodebuild \
  -project DeEsser.xcodeproj \
  -scheme DeEsser \
  -configuration Debug \
  -destination 'platform=macOS' \
  build

# Run unit tests (DSP + orchestration)
xcodebuild \
  -project DeEsser.xcodeproj \
  -scheme DeEsser \
  -destination 'platform=macOS' \
  test

# Static analysis (Release)
xcodebuild \
  -project DeEsser.xcodeproj \
  -scheme DeEsser \
  -configuration Release \
  -destination 'platform=macOS' \
  analyze
```

To run the app, open the project in Xcode and ⌘R, or launch the built
`DeEsser.app` from `~/Library/Developer/Xcode/DerivedData/.../Build/Products/`.
Because it is a menu-bar accessory (`LSUIElement`), it has **no Dock icon** — look
for the waveform icon in the menu bar.

---

## Permissions

On the **first time you enable** processing, the app explains that macOS will ask
for **system-audio recording** permission and that audio stays on this Mac. After
you tap **Continue**, macOS shows its standard prompt.

- The app requests **only** system-audio capture (`NSAudioCaptureUsageDescription`).
  It never requests microphone access.
- If you later deny or revoke permission, normal audio keeps working; the app
  shows a recoverable error and offers an **Open Privacy & Security** button. You
  can also enable it manually under
  **System Settings ▸ Privacy & Security ▸ System Audio Recording**.

The bundle identifier is `local.DeEsser`; the granted permission is keyed to it.

---

## Operation

Click the menu-bar icon:

- **Master switch** — turns processing on/off. When off, your audio is completely
  untouched (no tap, no aggregate device). This is the control you flip when a
  particular source sounds harsh.
- **Status** — Disabled · Permission required · Starting · *De-essing → \<device\>*
  · Rebuilding · Error.
- **Strength** — the single de-essing control. It scales the Calf de-esser's
  detection threshold and ratio together (0 = gentle, 0.5 = the stock EasyEffects
  default, 1 = deliberately heavy — threshold −42 dBFS, ratio 12:1, for a very
  obvious drop in harsh sibilance). Everything else is pinned to the
  EasyEffects/Calf defaults.
- **Gain-reduction meter** — live, 0–24 dB.
- **Bypass for comparison** — keeps audio captured and dry-muted but crossfades
  the de-esser to unity, for click-free A/B testing. (Different from the master
  switch, which removes the tap entirely.)
- **Rebuild audio path** — manually tears down and rebuilds the graph.
- **Settings…** — startup options, launch-at-login, the strength slider, and a
  **Diagnostics** tab (chosen device, object IDs, heartbeat, meters, last Core
  Audio error, and a *Copy diagnostic report* button — **metadata only, never
  audio**).

The processed audio automatically follows the current default output device.
Output-device changes, sample-rate/AirPods-profile changes, and sleep/wake all
trigger a controlled, debounced rebuild.

---

## Emergency disable

If audio ever sounds wrong:

1. Click the menu-bar icon and turn the **master switch off** — this immediately
   tears down the graph and restores normal playback.
2. Or use **Rebuild audio path**.
3. Or **Quit** the app (menu ▸ Quit). On quit the graph is torn down; even on a
   force-quit, Core Audio reclaims the tap and the `mutedWhenTapped` behavior
   unmutes, so normal audio returns within about a second.

The utility **fails open**: any failure to build or run the processing graph
results in normal, unprocessed audio.

---

## Privacy

- No audio is recorded, saved, transcribed, transmitted, or retained.
- No network access. No analytics. No update framework.
- Your **microphone is never captured** — only audio your apps are playing back.
- Diagnostic reports contain configuration/metadata only.

---

## Project layout

See `project.yml` and the source tree under `DeEsser/`:

- `App/` — SwiftUI menu-bar + Settings UI and the `AppModel`.
- `Models/` — state machine, settings, diagnostics value types.
- `Discovery/` — default-output resolution and Core Audio property + power
  monitoring.
- `Audio/` — tap and aggregate RAII handles, property helpers (including the
  self-process lookup that feeds the global tap's exclude list), format
  validation, and the `AudioPipelineCoordinator` lifecycle state machine.
- `Realtime/` — Objective-C++ renderer (`TDRealtimeRenderer`) and the pure C++
  de-esser DSP (`DeEsserDSP`, `Biquad`, `AudioBufferView`).
- `DeEsserTests/` — DSP and orchestration unit tests.

`IMPLEMENTATION_NOTES.md` documents the scope change, the SDK-name differences
adapted during implementation, and the current verification status.
