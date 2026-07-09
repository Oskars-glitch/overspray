# OVERSPRAY — native iOS AR spray paint

Spray paint on real walls in AR. ARKit world tracking (camera + gyroscope
fusion — the stable tracking), automatic vertical-plane detection (paint
attaches straight to the detected wall, no manual wall placement), real
metric distances driving spray size / density / drips, volume-button
spraying, and in-app recording (camera + paint, no UI) saved to Photos.

Works on all ARKit iPhones — no LiDAR needed. Plane detection runs on the
rear camera.

## How to use the app

1. Open it and sweep the phone slowly across a wall. Yellow feature dots =
   scanning. When ARKit finds the wall you get "Wall found".
2. Aim the crosshair at the wall and hold the on-screen cap **or hold
   volume-down** to spray. Walk closer/further — it's real tracking.
3. Bottom-left: black/white + three nozzle caps (skinny / standard / fat).
4. Record button top-left: captures camera + paint (no buttons) and saves
   to Photos when stopped.

Tip: like all ARKit apps, it wants a wall with some visual texture and
decent light. A featureless white wall in dim light scans slowly.

---

## Building it — your situation: 2014 Mac, no Xcode

A 2014 Mac officially maxes out at macOS Big Sur → Xcode 13.2, which
**cannot install apps onto iPhones running iOS 17+** (Apple requires
Xcode 15+ for modern iPhones). Two working routes:

### Route A — upgrade the 2014 Mac (best if you'll keep iterating)

1. Install **OpenCore Legacy Patcher** (free, well-documented:
   dortania.github.io/OpenCore-Legacy-Patcher) and use it to install
   macOS Sonoma on the 2014 Mac. Back up first. This is a common,
   well-supported path for 2014 MacBooks/iMacs.
2. Install **Xcode** from the Mac App Store (large download; the old Mac
   will be slow but it works — 8 GB RAM minimum, ~50 GB free disk).
3. Install XcodeGen: `brew install xcodegen`, then in this folder run
   `xcodegen generate` and open `Overspray.xcodeproj`.
   (No Homebrew? You can instead make a new empty iOS App project in
   Xcode named Overspray, delete its template files, and drag the
   `Sources` folder in — then add the three Info.plist privacy keys
   listed in project.yml.)
4. In Xcode: select the Overspray target → Signing & Capabilities → set
   Team to your (free) Apple ID → change the bundle id to something
   unique like `com.yourname.overspray`.
5. On the iPhone: Settings → Privacy & Security → **Developer Mode** → on
   (restarts the phone).
6. Plug in the phone, pick it as the run destination, press Run. First
   launch: Settings → General → VPN & Device Management → trust your
   developer certificate.
7. Free-account apps expire after **7 days** — just press Run again to
   refresh.

### Route B — keep the Mac as it is, build in the cloud

GitHub compiles the app for free on their Mac servers; you install the
result from your Big Sur Mac with Sideloadly.

1. Make a free GitHub account, create a new repository, upload this whole
   folder (including the hidden `.github` folder).
2. The included workflow runs automatically (Actions tab). When it
   finishes, download the `Overspray-unsigned-ipa` artifact and unzip it
   to get `Overspray-unsigned.ipa`.
3. On the 2014 Mac install **Sideloadly** (sideloadly.io — runs fine on
   Big Sur). Connect the iPhone, drag the IPA in, sign in with a free
   Apple ID, press Start.
4. Same as above: enable Developer Mode, trust the certificate in
   Settings. Re-sideload every 7 days (Sideloadly remembers everything —
   it's two clicks).

### Notes

- The volume-button spray uses Apple's camera-button API on iOS 17.2+
  plus a classic volume-observation fallback. If a future iOS build
  changes behaviour, the on-screen cap always works.
- Recording captures the AR view (camera + paint) at 30 fps without the
  UI, and saves to Photos on stop.
- Every detected wall gets its own 4 m × 4 m paint canvas glued to it —
  you can paint several walls in one session. "Clear wall" clears all.

## Sounds (optional)

Drop your MP3s straight into the `Sources` folder next to the Swift files:

- `spray_01.mp3`, `spray_02.mp3`, `spray_03.mp3` (or a single `spray.mp3`)
  — a random one loops while you hold the cap or volume-down
- `shake_01.mp3`, `shake_02.mp3`, `shake_03.mp3` (or `shake.mp3`)
  — a random one plays when you physically shake the phone (works
  mid-spray too)

A different variant is picked each time so it never sounds looped/fake.
Missing files are fine — the app simply stays silent.

## Recording with sound

Recordings now include the microphone (ambient room sound). The mic only
switches on while you're recording; iOS will ask permission the first
time you press record.
