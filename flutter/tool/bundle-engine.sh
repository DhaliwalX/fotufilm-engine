#!/bin/sh
# Xcode build phase: carries the engine into the app as the CEF host does (cef/CMakeLists.txt),
# libfotufilm.dylib in Contents/Frameworks, its resources and the editor plug-ins in
# Contents/Resources. FOTUFILM_ENGINE_BUILD names a cef/build-engine.sh output; the default is
# this checkout's build/cef-engine.
set -eu
engine="${FOTUFILM_ENGINE_BUILD:-$SRCROOT/../../build/cef-engine}"
app="$TARGET_BUILD_DIR/$WRAPPER_NAME"
if [ ! -f "$engine/libfotufilm.dylib" ]; then
  echo "error: No engine at $engine. Run cef/build-engine.sh or set FOTUFILM_ENGINE_BUILD." >&2
  exit 1
fi
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources"
rsync -a "$engine/libfotufilm.dylib" "$app/Contents/Frameworks/"
# Everything the engine carries (films, camera profiles, notices, File › Use Sample Photo's chart),
# as the CEF host copies it, but its benchmark tool.
rsync -a --exclude fotufilm-bench "$engine/Resources/" "$app/Contents/Resources/"
for directory in Stocks CameraProfiles; do
  rsync -a --delete "$engine/Resources/$directory" "$app/Contents/Resources/"
done

# The Resolve and Final Cut plug-ins, where tools/build-editor-plugins.sh built them, go where the
# Mac app keeps its own: the engine installs them from the bundle's resources. ditto keeps the
# nested bundles' signatures; a plug-in no longer built is taken out. FOTUFILM_PLUGINS_DIR set
# empty leaves them out (the Plugins menu then says none are bundled).
plugins="${FOTUFILM_PLUGINS_DIR-$SRCROOT/../../build}"
for plugin in "resolve/Fotufilm.ofx.bundle" "finalcut/Fotufilm for Final Cut Pro.app"; do
  name="${plugin##*/}"
  rm -rf "$app/Contents/Resources/$name"
  if [ -n "$plugins" ] && [ -d "$plugins/$plugin" ]; then
    ditto "$plugins/$plugin" "$app/Contents/Resources/$name"
  fi
done
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$app/Contents/Frameworks/libfotufilm.dylib"

# The CEF app's icon (cef/mac/AppIcon.icon), compiled as cef/mac/compile-icon.sh does, in place
# of the template's.
partial="$TARGET_TEMP_DIR/fotufilm-icon.plist"
"$SRCROOT/../../cef/mac/compile-icon.sh" "$SRCROOT/../../cef/mac/AppIcon.icon" \
  "$app/Contents/Resources" "$partial"
