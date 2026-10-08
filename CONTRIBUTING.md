# Contributing to Motionpaper

Thanks for wanting to help!

## Getting set up

```bash
git clone https://github.com/Jasonilization/motionpaper.git
cd motionpaper
./Scripts/swift-build.sh
./Scripts/swift-test.sh
```

Command Line Tools are enough — no Xcode project exists or is needed. The
build scripts handle CLT-specific quirks automatically (SDK pinning and Swift
Testing plugin paths); with full Xcode installed they stay out of the way.

## Before you submit

- `./Scripts/swift-test.sh` passes (24+ tests).
- New behavior comes with tests where practical.
- No new warnings if avoidable.
- Every user-facing feature claim must be true — if macOS doesn't support
  something, say so in the UI (Settings → Capabilities) and the README.
- Keep the app offline: no analytics, no accounts, no network in core paths.

## For bigger changes

Open an issue first describing what you want to build — especially anything
that touches the wallpaper engine, display identity, or the pause policy.
Those areas are deliberately conservative: reliability beats features.
