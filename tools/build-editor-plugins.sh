#!/bin/bash
# Builds the plug-ins the desktop apps carry and install: the DaVinci Resolve OFX bundle
# (build/resolve/Fotufilm.ofx.bundle) and, where Apple's FxPlug SDK is installed, the Final Cut Pro
# wrapper (build/finalcut/Fotufilm for Final Cut Pro.app). cef/build.sh runs
# it; `--test` is forwarded to resolve/build.sh to run the OFX host harness on the same objects.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."

OFX_TEST=""
[[ " $* " == *" --test "* ]] && OFX_TEST="--test"

resolve/build.sh ${OFX_TEST:+$OFX_TEST}

# The Final Cut plug-in needs Apple's FxPlug SDK, which is a separate download and is not vendored
# here. A machine without it builds apps that say so — the Final Cut plug-in reads as not bundled
# and its install item is disabled — rather than failing a build that has nothing to do with Final
# Cut.
FXPLUG_APP="build/finalcut/Fotufilm for Final Cut Pro.app"
if [[ -d "${FXPLUG_SDK:-/Library/Developer/SDKs/FxPlug.sdk}" ]]; then
  finalcut/build.sh
else
  rm -rf "$FXPLUG_APP"
  echo "note: the FxPlug SDK is not installed; this build carries no Final Cut Pro plug-in." >&2
fi
