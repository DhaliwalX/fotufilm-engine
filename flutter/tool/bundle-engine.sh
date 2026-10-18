#!/bin/sh
# Xcode build phase: carries the engine into the app, libfotufilm.dylib in Contents/Frameworks,
# its resources and the editor plug-ins in Contents/Resources. FOTUFILM_ENGINE_BUILD names a
# tools/build-desktop-engine.sh output; the default is this checkout's build/engine.
set -eu
engine="${FOTUFILM_ENGINE_BUILD:-$SRCROOT/../../build/engine}"
app="$TARGET_BUILD_DIR/$WRAPPER_NAME"
if [ ! -f "$engine/libfotufilm.dylib" ]; then
  echo "error: No engine at $engine. Run tools/build-desktop-engine.sh or set FOTUFILM_ENGINE_BUILD." >&2
  exit 1
fi
mkdir -p "$app/Contents/Frameworks" "$app/Contents/Resources"
rsync -a "$engine/libfotufilm.dylib" "$app/Contents/Frameworks/"
# Everything the engine carries (films, camera profiles, notices, File › Use Sample Photo's chart),
# but its benchmark tool.
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

# The app's icon, from its Icon Composer layers.
partial="$TARGET_TEMP_DIR/fotufilm-icon.plist"
"$SRCROOT/compile-icon.sh" "$SRCROOT/AppIcon.icon" \
  "$app/Contents/Resources" "$partial"
