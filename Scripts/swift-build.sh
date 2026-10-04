#!/bin/bash
# Wrapper around `swift build` that pins the macOS 26.5 SDK when building with
# Command Line Tools only. Rationale: the macOS 27 SDK re-implements SwiftUI's
# @State as a macro whose plugin (libSwiftUIMacros.dylib) ships with Xcode but
# not with CLT. Building against the 26.5 SDK (deployment target stays 15.0)
# keeps plain `swift build` working on CLT-only machines; on machines with
# full Xcode the default SDK already resolves this, so no pinning is applied.
set -euo pipefail

CLT_SDK_26="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
DEV_DIR="$(xcode-select -p 2>/dev/null || echo '')"
ARGS=()

if [ "$DEV_DIR" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT_SDK_26" ]; then
  export SDKROOT="$CLT_SDK_26"
fi

exec swift build "$@"
