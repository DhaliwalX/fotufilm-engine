#!/bin/bash
# Compiles the app's icon from its Icon Composer layers into the bundle's resources:
#   compile-icon.sh <AppIcon.icon> <Resources directory> <partial Info.plist>
# actool needs Xcode 26; without it the app keeps the generic icon rather than failing the build.
if ! xcrun actool "$1" --compile "$2" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$3" >/dev/null 2>&1; then
  echo "warning: actool could not compile $1; the app keeps the generic icon." >&2
fi
