# Motionpaper

<h3 align="center">Live video wallpapers for macOS — free, fast, and honest about what macOS allows.</h3>

<p align="center">
  <a href="https://github.com/Jasonilization/motionpaper/releases"><img src="https://img.shields.io/badge/platform-macOS%2015%2B-333333?style=flat-square&logo=apple&logoColor=white" alt="macOS 15+"></a>
  <a href="https://github.com/Jasonilization/motionpaper/actions"><img src="https://img.shields.io/github/actions/workflow/status/Jasonilization/motionpaper/ci.yml?branch=main&style=flat-square&label=CI" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-000000?style=flat-square" alt="MIT"></a>
  <img src="https://img.shields.io/badge/price-free-34C759?style=flat-square" alt="Free">
</p>

---

Motionpaper plays videos and sprite-sheet animations as your desktop wallpaper. It runs independently on every connected display, remembers your setup per display, and keeps its resource usage low with hardware decoding and sensible power modes. No account, no ads, no subscriptions, no telemetry — everything lives on your Mac.

## What it does

- **Plays videos behind your desktop icons** — an `AVQueuePlayer`-driven surface at the macOS desktop window level, across all Spaces, never stealing focus. Hardware-decoded on Apple Silicon (≈1% CPU for 720p playback in testing).
- **Animated sprite-sheet wallpapers** — import a PNG frame grid (the Undertale/Deltarune-style sheets work great), adjust columns/rows/FPS with a live preview, and it plays as a GPU-composited Core Animation loop at effectively zero CPU.
- **Independent wallpaper per display** — assignments persist per display using name + native resolution + IOKit identity, so replugging the same monitor restores its wallpaper.
- **Day-cycle playlists** — day, midday, and night wallpapers each get an equal share of 24 hours (or classic every-N-minutes playlists, sequential or random). Boundaries are event-driven — no polling.
- **Lock Screen matching** — Motionpaper exports a still frame of your active wallpaper and installs it as the system wallpaper, so your lock screen shows the same scene your desktop is playing. Optionally matches the pre-login screen too (one admin prompt). This is the same mechanism Wallspace Pro ships — see [macOS limitations](#-macos-limitations).
- **Migrates from Wallspace** — finds wallpapers Wallspace already downloaded to your Mac (read-only), reports what's new, and imports them with titles, favorites, and recents — without touching the Wallspace installation.
- **Smart power behavior** — three modes (Maximum Battery / Balanced / Maximum Quality) pause playback on battery, Low Power Mode, display sleep, system sleep, lock, and fullscreen-app coverage, according to your settings. Motionpaper never prevents system sleep.
- **Menu-bar controls** — current wallpapers per display, pause/resume, next/previous, reapply, favorites, and recents, one click deep.
- **A real library** — search, resolution/orientation/source filters, sorting, favorites, custom metadata-only collections, preview with scrubbing/speed/mute, and SHA-256 de-duplication so re-imports never duplicate files.
- **Opt-in online gallery** — search NASA (no key), or Pixabay/Pexels with your own free API keys (stored locally, only ever sent to their service). Downloads flow through the same import pipeline. The gallery only touches the network while you're actively using it.
- **Offline-first** — zero network activity anywhere else. No analytics, no "anonymous usage data," nothing. The core app never makes a connection.

## Screenshots

TODO — real screenshots before the 1.0 release.

## 📦 Requirements

| | |
|---|---|
| **OS** | macOS 15 (Sequoia) or newer |
| **Arch** | Apple Silicon (tested on M5) and Intel |
| **Build** | Swift 6 toolchain — Command Line Tools are enough, no Xcode required |
| **Perms** | none for core use; optional admin prompt if you enable pre-login screen matching |

## 🚀 Installation

Right now Motionpaper installs from source (a signed release build is on the roadmap):

```bash
git clone https://github.com/Jasonilization/motionpaper.git
cd motionpaper
./Scripts/bundle.sh release   # → Motionpaper.app, ad-hoc signed
open Motionpaper.app
```

First launch: right-click → **Open** (the app is ad-hoc signed, not notarized).

## 🎞️ Importing wallpapers

- **Drag videos** onto the library window (MP4/MOV/M4V — anything AVFoundation plays), or use **Import → Import Videos…**. Files are copied into `~/Library/Application Support/Motionpaper/Videos/`; your originals are never touched. "Import Without Copying" references files in place instead.
- **Import a folder** recursively (Import → Import Folder…).
- **Sprite sheets**: Import → Import Sprite Sheet… picks a PNG grid; adjust the frame layout in the editor that opens.
- Thumbnails are generated asynchronously (one representative frame, wide seek tolerance) and cached in `Thumbnails/`.

## 🔄 Wallspace migration

Settings → **Migration** scans Wallspace's locally accessible storage (`~/Library/Caches/Wallspace` + its preferences), reports **Found / Already imported / Unsupported** with reasons, and copies the new wallpapers into Motionpaper's library with titles, categories, favorites, and recently-used state. Wallspace's files and installation are never modified. If Wallspace's preferences were deleted, titles fall back to its cached API catalog; metadata that no longer exists on the Mac can't be recovered. Only content already downloaded to your Mac is found — nothing is fetched from Wallspace's servers.

## 🖥️ Multi-display

Every connected display gets its own player, wallpaper, scaling (Fill / Fit / Stretch), and mute state. Assignments persist via a stable composite key (localized name + native pixel resolution + IOKit vendor/serial), so reconnecting a display restores its wallpaper. Two identical monitors that don't report serial numbers get an index suffix whose order isn't guaranteed across replugs — an inherent macOS identity limitation. "Apply to All Displays" mirrors one wallpaper everywhere.

## ⚡ Performance

- **Maximum Battery** — pauses when on battery, in Low Power Mode, locked, behind fullscreen apps, or while displays sleep.
- **Balanced** (default) — plays normally; pauses on display sleep, system sleep, and lock.
- **Maximum Quality** — keeps playing whenever practical, including on battery.

Video decode uses the hardware decoder; sprite-sheet wallpapers run as GPU-composited keyframe animations (≈0% CPU). Playback pauses during display/system sleep automatically, and AVPlayer's display-sleep prevention is explicitly disabled — Motionpaper never keeps your Mac awake.

## 🔒 macOS limitations

Honest table, because this app refuses to fake features:

- **Live video on the Lock Screen** — experimental and off by default. macOS renders the Lock Screen with no third-party API for app content; Motionpaper's experimental mode hosts the wallpaper in a separate helper process that places a window Space one level below the lock UI (the same undocumented SkyLight technique public notch-overlay apps use), so the video plays behind the password field/Touch ID. It re-syncs on every lock and tears down on unlock. On the macOS 27 beta this machine runs, lock transitions also expose an OS-level crash: system frameworks (SwiftUI responders, the menu-bar client) run synchronous MainActor executor checks that can segfault during the transition — Motionpaper ships mitigations (async actor hops everywhere, library-window responder detach while locked), but a beta fix may land before every corner is closed. The default, fully-stable path remains still-frame matching: your live wallpaper's best frame is synced to the system wallpaper and the Lock Screen's own picture file, so locking shows the same scene, frozen.
- **Login window (pre-login screen)** — same story; Motionpaper can write the documented `com.apple.loginwindow DesktopPicture` preference (with your admin approval) so the pre-login screen matches too.
- **macOS 26 wallpaper extension** — exists, but is backed by a private framework (`WallpaperExtensionKit`) and isn't in the Command Line Tools SDK. Motionpaper deliberately avoids private frameworks.
- **Screen Saver module** — planned: a Motionpaper-powered `.saver` is a legitimate public path, but a separate plug-in target.
- **Global hotkeys** — planned via public Carbon `RegisterEventHotKey` (no Accessibility permission needed).
- **Spaces/Mission Control** — supported via the wallpaper window joining all Spaces (`.canJoinAllSpaces` + `.stationary`).

The full, always-current version lives in **Settings → Capabilities** inside the app, with the technical reason for every entry.

## 🛠️ Development

Pure SwiftPM — no Xcode project:

```bash
git clone https://github.com/Jasonilization/motionpaper.git
cd motionpaper
./Scripts/swift-build.sh        # debug build (CLT-friendly; see below)
./Scripts/swift-test.sh        # 24 tests
./Scripts/bundle.sh release    # → Motionpaper.app
```

**CLT-only machines note:** the macOS 27 SDK re-implements SwiftUI's `@State` as a macro whose plugin ships with Xcode only. The build scripts pin `SDKROOT` to the macOS 26.5 SDK (deployment target stays macOS 15) and add the Swift Testing plugin paths when only Command Line Tools are installed. With full Xcode, none of that is applied.

```
Sources/
├── Motionpaper/            app target: SwiftUI UI, menu bar, settings
│   └── UI/                 library, home, displays, playlists, preview,
│                           sprite editor, settings tabs
└── MotionpaperKit/         the engine (testable, UI-free)
    ├── Display/            display identity + topology
    ├── Library/            store, import, metadata, thumbnails, migration
    ├── Model/              wallpaper/playlist/assignment models
    ├── Performance/        power monitor, fullscreen detector, policy
    ├── Settings/           persisted preferences
    ├── Support/            paths, logging, hashing, capabilities
    └── Wallpaper/          engine, window controller, looper, sprite
                            renderer, lock-screen matcher, advancer
Tests/                      24 Swift Testing suites + a guarded
                            real-Wallspace acceptance test
```

## 🗺️ Roadmap

- [x] Core wallpaper engine (desktop-level window, hardware decode)
- [x] Multi-display with persistent assignments
- [x] Library, favorites, collections, search/filter/sort
- [x] Playlists: interval + day-cycle
- [x] Wallspace migration
- [x] Menu-bar controls + performance modes
- [x] Sprite-sheet wallpapers
- [ ] Screen Saver module (public `.saver` target)
- [ ] Global hotkeys
- [ ] Notarized release builds + DMG
- [x] Online gallery (NASA keyless; Pixabay/Pexels with your own local keys)

No timelines. It ships when it ships.

## 🤝 Contributing

PRs welcome — for non-trivial changes, open an issue first. Run `./Scripts/swift-test.sh` before submitting; don't break the existing tests. See [CONTRIBUTING.md](CONTRIBUTING.md).

## 📜 License

MIT — see [LICENSE](LICENSE). Free forever, in the plain sense: the license grants everyone the right to use, study, modify, and redistribute.

## ⚠️ Disclaimer

Motionpaper is an independent, clean-room project. It is not affiliated with, endorsed by, or connected to Wallspace. "Wallspace" is that app's own trademark; migration support exists only to import content the user already has on their Mac through normal filesystem access.
