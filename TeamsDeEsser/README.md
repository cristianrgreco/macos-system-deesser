# Teams De-Esser

A local, on-device macOS menu-bar utility that reduces harsh sibilance (the
painful "S" / "SH" sounds) in **incoming Microsoft Teams audio** — without
touching your microphone, other apps' audio, or your system output device.

It uses public **Core Audio process-tap** APIs on macOS Tahoe (26). There is **no
audio driver, no system/kernel extension, and no virtual device**. Audio is never
recorded, saved, or sent anywhere.

> **Status:** v1, local Developer build. Builds, unit-tests, and static analysis
> pass on Xcode 26.5 / macOS 26. The live capture/replay path is implemented;
> the on-device manual test matrix should be run by an operator (see
> `IMPLEMENTATION_NOTES.md`).

---

## How it works

```
Microsoft Teams output process(es)
      │  Core Audio process tap (stereo mixdown, device-scoped, mutedWhenTapped)
      ▼
Private aggregate-device input
      │  real-time AudioDeviceIOProc
      ▼
De-esser — a faithful port of the Calf "Deesser" (the de-esser EasyEffects uses)
      ▼
The physical output device Teams was using
```

Only Teams audio passes through this graph. The original Teams stream is muted
**only while the tap is being read**, so if anything goes wrong the normal,
unprocessed Teams audio resumes automatically (fail-open).

---

## Requirements

- macOS Tahoe **26.0+**
- Xcode **26.x** (macOS 26 SDK)
- Apple Silicon or Intel Mac
- Microsoft Teams (native client, `com.microsoft.teams2`)

---

## Build

The Xcode project is generated from `project.yml` with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (a build-time tool only — not a
runtime dependency). A generated `TeamsDeEsser.xcodeproj` is included, so you can
build directly.

```bash
cd TeamsDeEsser

# (Only if you changed project.yml)
xcodegen generate

# Build (Debug)
xcodebuild \
  -project TeamsDeEsser.xcodeproj \
  -scheme TeamsDeEsser \
  -configuration Debug \
  -destination 'platform=macOS' \
  build

# Run unit tests (DSP + orchestration)
xcodebuild \
  -project TeamsDeEsser.xcodeproj \
  -scheme TeamsDeEsser \
  -destination 'platform=macOS' \
  test

# Static analysis (Release)
xcodebuild \
  -project TeamsDeEsser.xcodeproj \
  -scheme TeamsDeEsser \
  -configuration Release \
  -destination 'platform=macOS' \
  analyze
```

To run the app, open the project in Xcode and ⌘R, or launch the built
`TeamsDeEsser.app` from `~/Library/Developer/Xcode/DerivedData/.../Build/Products/`.
Because it is a menu-bar accessory (`LSUIElement`), it has **no Dock icon** — look
for the waveform icon in the menu bar.

---

## Permissions

On the **first time you enable** processing, the app explains that macOS will ask
for **system-audio recording** permission and that audio stays on this Mac. After
you tap **Continue**, macOS shows its standard prompt.

- The app requests **only** system-audio capture (`NSAudioCaptureUsageDescription`).
  It never requests microphone access.
- If you later deny or revoke permission, normal Teams audio keeps working; the
  app shows a recoverable error and offers an **Open Privacy & Security** button.
  You can also enable it manually under
  **System Settings ▸ Privacy & Security ▸ System Audio Recording**.

Keep the bundle identifier (`local.TeamsDeEsser`) stable so the granted permission
is not invalidated between builds.

---

## Operation

Click the menu-bar icon:

- **Master switch** — turns processing on/off. When off, Teams is completely
  untouched (no tap, no aggregate device).
- **Status** — Disabled · Waiting for Teams · Permission required · Starting ·
  *Processing Teams → \<device\>* · Rebuilding · Error.
- **Aggressiveness** — the single de-essing control. It scales the Calf
  de-esser's detection threshold and ratio together (0 = gentle, 0.5 = the stock
  EasyEffects default, 1 = aggressive). Everything else is pinned to the
  EasyEffects/Calf defaults.
- **Gain-reduction meter** — live, 0–12 dB.
- **Bypass for comparison** — keeps Teams captured and dry-muted but crossfades
  the de-esser to unity, for click-free A/B testing. (Different from the master
  switch, which removes the tap entirely.)
- **Rebuild audio path** — manually tears down and rebuilds the graph.
- **Settings…** — startup options, launch-at-login, the aggressiveness slider, and a
  **Diagnostics** tab (detected processes, chosen device, object IDs, heartbeat,
  meters, last Core Audio error, and a *Copy diagnostic report* button —
  **metadata only, never audio**).

The processed audio automatically follows whatever output device Teams is using.
Teams restarts, output-device changes, sample-rate/AirPods-profile changes, and
sleep/wake all trigger a controlled, debounced rebuild.

---

## Emergency disable

If audio ever sounds wrong:

1. Click the menu-bar icon and turn the **master switch off** — this immediately
   tears down the graph and restores normal Teams playback.
2. Or use **Rebuild audio path**.
3. Or **Quit** the app (menu ▸ Quit). On quit the graph is torn down; even on a
   force-quit, Core Audio reclaims the tap and the `mutedWhenTapped` behavior
   unmutes Teams, so normal audio returns within about a second.

The utility **fails open**: any failure to build or run the processing graph
results in normal, unprocessed Teams audio.

---

## Privacy

- No audio is recorded, saved, transcribed, transmitted, or retained.
- No network access. No analytics. No update framework.
- Only native Microsoft Teams playback is captured; your microphone and other
  applications are never touched.
- Diagnostic reports contain configuration/metadata only.

---

## Project layout

See `project.yml` and the source tree under `TeamsDeEsser/`:

- `App/` — SwiftUI menu-bar + Settings UI and the `AppModel`.
- `Models/` — state machine, settings, diagnostics value types.
- `Discovery/` — Teams process matching, output-device resolution, Core Audio
  property + power monitoring.
- `Audio/` — tap and aggregate RAII handles, property helpers, format validation,
  and the `AudioPipelineCoordinator` lifecycle state machine.
- `Realtime/` — Objective-C++ renderer (`TDRealtimeRenderer`) and the pure C++
  de-esser DSP (`DeEsserDSP`, `Biquad`, `AudioBufferView`).
- `TeamsDeEsserTests/` — DSP and orchestration unit tests.

`IMPLEMENTATION_NOTES.md` documents the SDK-name differences adapted during
implementation and the current verification status.
