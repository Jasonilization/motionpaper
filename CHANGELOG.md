# Changelog

## Unreleased

### Added

- Desktop video wallpaper engine: borderless window at the macOS desktop window level, hardware-decoded `AVQueuePlayer` looping playback behind desktop icons across all Spaces.
- Multi-display support with per-display wallpapers, scaling (Fill/Fit/Stretch), mute, and persistent assignments keyed by display name + native resolution + IOKit identity.
- Library with drag-and-drop / file-picker / recursive folder import, SHA-256 de-duplication, AVFoundation metadata probing (resolution, FPS, duration, codec, container, size), and asynchronous cached thumbnails.
- Preview sheet: looping playback, scrubbing, mute, playback speed, full-screen preview window, info panel, rename, reveal-in-Finder, per-display apply.
- Favorites, custom metadata-only collections, search, resolution/orientation/source filters, and sorting.
- Playlists with sequential/random order and every-N-minutes auto-change, plus **day-cycle mode** (equal 24-hour segments — day/midday/night).
- Menu-bar quick controls: per-display current wallpaper, pause/resume, next/previous, reapply, favorites, recents.
- Performance modes (Maximum Battery / Balanced / Maximum Quality) with battery, Low Power Mode, lock, display-sleep, system-sleep, and fullscreen-coverage policies. Motionpaper never prevents system sleep.
- Lock Screen matching: still-frame sync to the system wallpaper (the public-API mechanism Wallspace Pro uses), full sync of the Lock Screen's own wallpaper slot (the same store System Settings writes, with renderer-extension reload), and optional pre-login window matching.
- Sprite-sheet animated wallpapers: PNG frame grids played as GPU-composited Core Animation loops, with a live grid editor.
- Wallspace migration: read-only discovery of Wallspace's local downloads, per-file status reporting, title/favorite/recents carry-over, and a catalog-title fallback from Wallspace's cached API responses.
- Settings window: General, Playback, Lock Screen, Storage, Migration, Capabilities (feature detection with technical reasons), Advanced.
- Opt-in online gallery: NASA (keyless), Pixabay & Pexels (user's own local API keys) with search, streaming download, and the standard import pipeline. Only active while the Gallery section is used.
- Launch watchdog that force-presents hidden windows and hosts a recovery window if the SwiftUI WindowGroup fails to create one (macOS beta robustness).

### Fixed

- Library files written before the sprite-sheet feature keep loading (tolerant `Wallpaper` decoding, regression-tested).
- Quitting with a hidden window no longer restores as a zero-window launch.
- Dock icon, menu bar, and watchdog restores now deminiaturize minimized windows (previously a minimized library window stayed buried).
- Batch migrations flush to disk immediately instead of relying on the debounced save.
