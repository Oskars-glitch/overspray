# Overspray

**Native iOS augmented-reality spray paint.** Point your iPhone at a real wall
and paint it — with real spray-can physics, metric distances, drips, and
in-app video recording.

> **Version: Alpha 11.0** — pre-release. Expect rough edges; see
> [Known limitations](#known-limitations).

---

## Overview

Overspray turns any wall around you into a canvas. It uses ARKit world
tracking (camera + gyroscope fusion) with automatic vertical-plane detection,
so paint attaches directly to the detected wall and stays there — you can walk
away, come back, and your piece is still on the wall where you left it.

Distance is real and metric: step closer and the spray tightens and gets
denser, step back and it widens and fades — exactly like a physical can. Stand
too close for too long and it drips.

Works on **all ARKit-capable iPhones** — no LiDAR required. Requires iOS 16+.

## Features

### Painting
- **Real spray physics** — spray cone, droplet scatter, splatter, and paint
  buildup all driven by the true metric distance between phone and wall
- **Drips** — linger close to the wall and paint accumulates until it runs,
  wobbles, and ends in a blob, pulled by real-world gravity regardless of how
  the wall is oriented
- **Can pressure** — output fades the longer you spray; physically shake the
  phone to restore pressure. A freshly shaken can sprays *dirty* for a few
  seconds — a looser cone, more paint, spatter flecks, heavier drips —
  relaxing back to a clean spray as the charge settles
- **Wet paint that dries** — fresh paint carries a glossy sheen (optionally
  mirroring a scanned snapshot of the room) and dries to matte over ~25
  seconds. A stroke stays fully wet until you release the trigger, then dries
  as one piece
- **Six caps** — fine dot, ring (Cyclops), standard (Beef), chisel bar that
  rotates with the phone, a "dirty" fire-extinguisher blast, and a
  **user-drawn custom cap** with live tuning sliders
- **Pressure boost** (×1 / ×5 / ×10) and a motorised **dotted-line mode**
- **Color** — black and white by default; long-press a swatch to pick any
  color from the camera image

### The wall
- **One deliberate wall** — plane detection helps you aim, but *you* designate
  the wall (tap flat spots, then *Set Wall*). Painting raycasts against that
  frozen plane, so ARKit re-fitting its anchors can never fragment, move, or
  delete your paint
- **Lasso editing** — extend or cut the paintable area Photoshop-style: start
  a stroke inside the area to add, outside to cut
- **Depth nudge** — slide the wall along its normal for fine alignment
- **High resolution** — the canvas resolves 4096 pixels per metre, allocated
  lazily in tiles so memory is only spent where paint actually lands

### Capture
- **In-app recording** — camera + paint at 30 fps, without the UI, saved
  straight to Photos. The microphone records ambient sound on its own capture
  session, so starting a recording never disturbs the AR camera
- **PNG export** — full-resolution composite of everything painted, on a
  transparent background, via the share sheet

### Controls
- **Volume buttons as triggers** — hold volume-down to spray black, volume-up
  to spray white (uses the iOS 17.2+ camera-button API with a classic
  volume-observation fallback; the on-screen cap always works)
- **Sound** — looping spray hiss and shake rattle with multiple randomised
  variants, plus a fading echo tail when you stop shaking (see
  [Custom sounds](#custom-sounds))
- Flashlight toggle for dark walls

## How to use it

1. **Scan** — open the app and sweep the phone slowly across a wall. Yellow
   feature dots mean it is scanning; textured walls in decent light scan
   fastest.
2. **Set the wall** — tap three or more flat spots on the wall, then tap
   **Set Wall**. The plane is now yours.
3. **Spray** — aim the crosshair and hold the on-screen cap or a volume
   button. Walk closer or further; it is real tracking.
4. **Switch caps and colors** at the bottom-left. Long-press a swatch to
   sample a color from the camera.
5. **Record** — top-left button captures camera + paint (no UI) and saves to
   Photos when stopped.
6. **Reshape** — use the lasso to grow or cut the paintable area; **Clear**
   wipes the paint.

## Building

There is no Xcode project checked in — it is generated from `project.yml`
with [XcodeGen](https://github.com/yonaskolb/XcodeGen).

### Option A — build locally (Mac with Xcode 15+)

```bash
brew install xcodegen
xcodegen generate
open Overspray.xcodeproj
```

Then in Xcode: select the *Overspray* target → *Signing & Capabilities* → set
your team and a unique bundle identifier → run on a device. On the iPhone,
enable *Settings → Privacy & Security → Developer Mode*, and trust your
certificate under *Settings → General → VPN & Device Management* on first
launch.

With a free Apple ID the install expires after **7 days** — press Run again
to refresh.

### Option B — build in the cloud, no modern Mac required

The repository includes a GitHub Actions workflow
(`.github/workflows/build.yml`) that compiles an **unsigned IPA** on every
push:

1. Push this repository to GitHub and open the *Actions* tab.
2. Download the `Overspray-unsigned-ipa` artifact from the finished run.
3. Sign and install it with [Sideloadly](https://sideloadly.io) (runs on
   macOS back to Big Sur, and on Windows): connect the iPhone, drag the IPA
   in, sign in with a free Apple ID, press *Start*.
4. Enable Developer Mode and trust the certificate as above. Re-sideload
   every 7 days — Sideloadly remembers the setup.

### How long the app stays on the phone

The limit is Apple's signing policy, not the app:

| Signing | App runs for | Cost |
|---|---|---|
| Free Apple ID (Sideloadly/Xcode) | **7 days**, then it stops launching until re-signed | free |
| Apple Developer Program | **1 year** per install; TestFlight builds 90 days | $99/year |
| App Store release | permanent | $99/year + App Review |

Ways to make the 7-day cycle painless or remove it:

- **AltStore / SideStore** can re-sign automatically in the background
  whenever the phone shares Wi-Fi with a computer running AltServer — the
  7-day limit still exists but you stop noticing it.
- **A paid developer account** is the clean fix: sign with it in Sideloadly
  and each install lasts a year.
- Re-running Sideloadly manually is two clicks; it remembers everything.

## Custom sounds

Drop MP3s into `Sources/` next to the Swift files; missing files simply mean
silence. A random variant is chosen each time so nothing sounds looped:

| Files | Played when |
|---|---|
| `spray_01.mp3` … `spray_03.mp3` (or `spray.mp3`) | loops while spraying |
| `shake_01.mp3` … `shake_03.mp3` (or `shake.mp3`) | the phone is physically shaken |
| `shake_echo_01.mp3` … `shake_echo_03.mp3` (or `shake_echo.mp3`) | shaking stops — a fading rattle tail |

## Project structure

```
Sources/
  OversprayApp.swift   app entry; SprayCap and the shared PaintState
  ARSprayView.swift    AR session, wall designation, per-frame loop, PaintSurface
  PaintCanvas.swift    tiled GPU-backed canvas, wet/dry map, PNG export
  SprayEngine.swift    spray, pressure, and drip physics
  Recorder.swift       in-app video recording; volume-button trigger
  SoundKit.swift       can sounds and shake detection
  ContentView.swift    SwiftUI control overlay
docs/                  architecture, working rules, and change specs
project.yml            XcodeGen project definition
```

Development process, evaluation criteria, and per-change specifications live
in [`docs/`](docs/).

## Known limitations

- **Painted area is capped at roughly 4 m²** per session (a fixed tile
  budget); paint stops appearing past the cap. Raising it is planned work —
  see `docs/specs/`.
- Free-Apple-ID installs expire after 7 days and must be re-sideloaded.
- Colors picked from the camera are session-only; restarting the app resets
  the palette.
- Like all ARKit apps, featureless walls in dim light scan slowly.

## Requirements

- iPhone with ARKit support (A12 or newer recommended), iOS 16 or later
- Camera, microphone (recording only), and Photos-add permissions
- No LiDAR needed
