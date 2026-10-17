#!/bin/sh
# Xcode build phase: carries the engine into the app as the CEF host does (cef/CMakeLists.txt),
# libfotufilm.dylib in Contents/Frameworks and its films and camera profiles in
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
rsync -a --delete "$engine/Resources/Stocks" "$engine/Resources/CameraProfiles" "$app/Contents/Resources/"
for file in rec2020-reflectance-prior.coeff LICENSE NOTICE ThirdPartyNotices.txt; do
  [ -f "$engine/Resources/$file" ] && rsync -a "$engine/Resources/$file" "$app/Contents/Resources/"
done
codesign --force --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$app/Contents/Frameworks/libfotufilm.dylib"

# The CEF app's icon (cef/mac/AppIcon.icon), compiled as cef/mac/compile-icon.sh does, in place
# of the template's.
partial="$TARGET_TEMP_DIR/fotufilm-icon.plist"
"$SRCROOT/../../cef/mac/compile-icon.sh" "$SRCROOT/../../cef/mac/AppIcon.icon" \
  "$app/Contents/Resources" "$partial"
