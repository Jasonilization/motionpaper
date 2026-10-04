#!/bin/bash
# Wrapper around `swift test` that adapts to Command Line Tools-only machines.
# On CLT-only setups three fixes are applied:
#   1. SDKROOT pins the macOS 26.5 SDK (the 27 SDK's SwiftUI @State macro plugin
#      ships with Xcode only — see swift-build.sh).
#   2. -plugin-path adds the Swift Testing macro plugin directory.
#   3. An extra -rpath points at CLT's Testing.framework location.
# With full Xcode installed none of these are needed and none are applied.
set -euo pipefail

CLT_SDK_26="/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk"
CLT_TESTING_PLUGINS="/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing"
CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
CLT_DEV_USR_LIB="/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
DEV_DIR="$(xcode-select -p 2>/dev/null || echo '')"
ARGS=()

if [ "$DEV_DIR" = "/Library/Developer/CommandLineTools" ] && [ -d "$CLT_SDK_26" ]; then
  export SDKROOT="$CLT_SDK_26"
  ARGS+=(
    -Xswiftc -plugin-path -Xswiftc "$CLT_TESTING_PLUGINS"
    -Xswiftc -Xlinker -Xswiftc -rpath -Xswiftc -Xlinker -Xswiftc "$CLT_FRAMEWORKS"
    -Xswiftc -Xlinker -Xswiftc -rpath -Xswiftc -Xlinker -Xswiftc "$CLT_DEV_USR_LIB"
  )
fi

exec swift test "$@" "${ARGS[@]}"
