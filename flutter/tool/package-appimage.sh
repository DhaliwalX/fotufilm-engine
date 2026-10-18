#!/bin/bash
# Packs the Linux build of Fotufilm (flutter/build/linux/x64/release/bundle, from
# `flutter build linux --release` over tools/build-desktop-engine-linux.sh's engine) into one AppImage. The
# engine picks its GPU when the app starts: CUDA on NVIDIA, Vulkan on any other GPU (AMD, Intel);
# FOTUFILM_GPU_DEVICE=cuda or vulkan chooses instead.
#   flutter/tool/package-appimage.sh [output-directory]      default build/appimage
#
# The OFX plugin (resolve/build-linux.sh) rides along when it has been built, and
# `Fotufilm.AppImage --install-ofx-plugin` puts it where DaVinci Resolve looks, /usr/OFX/Plugins.
#
# The image carries Flutter, the engine and the image libraries the engine links that a desktop may
# lack; the C and C++ runtimes, GTK and the graphics drivers are the system's.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/../.."

BUILD="flutter/build/linux/x64/release/bundle"
OUT="$(mkdir -p "${1:-build/appimage}" && cd "${1:-build/appimage}" && pwd)"
APPDIR="$OUT/Fotufilm.AppDir"
APP="$APPDIR/usr/lib/fotufilm"
LIB="$APP/lib"
source version.env
[[ -x "$BUILD/fotufilm" && -f "$BUILD/lib/libfotufilm.so" ]] || {
  echo "error: build the Linux app first (tools/build-desktop-engine-linux.sh, then flutter build linux)" >&2
  exit 1
}
readelf -d "$BUILD/lib/libfotufilm.so" | grep -q 'R.*PATH.*\[\$ORIGIN\]' || {
  echo "error: the engine does not look beside itself for its libraries (tools/build-desktop-engine-linux.sh)" >&2
  exit 1
}

rm -rf "$APPDIR"
mkdir -p "$APP"
tar -C "$BUILD" -cf - . | tar -C "$APP" -xf -
strip --strip-unneeded "$APP/fotufilm" "$LIB/libflutter_linux_gtk.so"

OFX="build/resolve/Fotufilm.ofx.bundle"
if [[ -f "$OFX/Contents/Linux-x86-64/Fotufilm.ofx" ]]; then
  mkdir -p "$APP/ofx"
  cp -R "$OFX" "$APP/ofx/"
else
  echo "warning: no OFX plugin in $OFX (resolve/build-linux.sh); the image carries none" >&2
fi

# Libraries the engine links beyond the ones every desktop has, and libheif's decoders (HEVC and
# AV1), which it loads as plug-ins; the engine's RUNPATH ($ORIGIN) reaches them. Nothing GPL is
# carried: HEIC export appears where the system has libheif's x265 plug-in, and libtiff (whose
# Debian build links GPL JBIG-KIT) is the system's, as GTK already requires it. libjpeg is
# libjpeg-turbo 3 rather than the build host's, since the system's libtiff binds to the carried
# copy (tools/build-libjpeg-turbo-linux.sh).
bundled='^lib(raw(_r)?|png16|lcms2|OpenEXR[A-Za-z]*|Imath|Iex|IlmThread|heif|de265|aom|dav1d|gomp)[-._0-9]*\.so'
bundle() {
  ldd "$1" | awk '$2 == "=>" && $3 ~ /^\// {print $1, $3}' | while read -r name path; do
    if [[ "$name" =~ $bundled && ! -e "$LIB/$name" ]]; then
      cp -L "$path" "$LIB/$name"
      echo "$path"
    fi
  done
}
bundle "$LIB/libfotufilm.so" > "$OUT/bundled.txt"
if ldd "$LIB/libfotufilm.so" | awk '$1 ~ /^libswiftCore\.so/ {found = 1} END {exit !found}'; then
  echo "error: the engine links the system's Swift runtime; build it with a toolchain that has" >&2
  echo "a static one (FOTUFILM_SWIFT_STDLIB, flutter/README.md)" >&2
  exit 1
fi
ldd "$LIB/libfotufilm.so" | grep -q '^\s*libjpeg\.so\.8 ' || {
  echo "error: the engine does not link libjpeg.so.8, the libjpeg the image carries" >&2
  exit 1
}
JPEG="$(tools/build-libjpeg-turbo-linux.sh)"
cp -L "$JPEG" "$LIB/libjpeg.so.8"
# libheif's plug-in folder, beside its library.
plugins="$(dirname "$(ldd "$LIB/libfotufilm.so" | awk '$1 ~ /^libheif\.so/ {print $3}')")/libheif/plugins"
mkdir -p "$APP/heif-plugins"
for plugin in libheif-libde265.so libheif-aomdec.so libheif-dav1d.so; do
  if [[ -f "$plugins/$plugin" ]]; then
    cp -L "$plugins/$plugin" "$APP/heif-plugins/"
    bundle "$plugins/$plugin" >> "$OUT/bundled.txt"
  fi
done

# The licences of what the image carries beside the app's own (THIRD_PARTY_NOTICES.md).
mkdir -p "$APPDIR/usr/share/doc"
install -D -m 0644 -t "$APPDIR/usr/share/doc/libjpeg-turbo" \
  "$(dirname "$JPEG")/../LICENSE.md" "$(dirname "$JPEG")/../README.ijg"
if command -v dpkg >/dev/null; then
  # dpkg knows merged-/usr paths by their /usr spelling.
  sed 's#^/lib/#/usr/lib/#' "$OUT/bundled.txt" | sort -u | xargs -r dpkg -S 2>/dev/null |
    cut -d: -f1 | sort -u | while read -r package; do
      if [[ -f "/usr/share/doc/$package/copyright" ]]; then
        install -D -m 0644 "/usr/share/doc/$package/copyright" \
          "$APPDIR/usr/share/doc/$package/copyright"
      fi
    done
fi

install -m 0644 web/public/app-icon.png "$APPDIR/fotufilm.png"
ln -s fotufilm.png "$APPDIR/.DirIcon"
cat > "$APPDIR/fotufilm.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Fotufilm
Comment=Develop photographs through real film
Exec=fotufilm %F
Icon=fotufilm
Categories=Graphics;Photography;
MimeType=image/jpeg;image/png;image/tiff;image/heic;image/x-exr;image/x-adobe-dng;image/x-canon-cr2;image/x-canon-cr3;image/x-nikon-nef;image/x-sony-arw;image/x-fuji-raf;image/x-olympus-orf;image/x-panasonic-rw2;
X-AppImage-Version=${MARKETING_VERSION}
DESKTOP
cat > "$APPDIR/AppRun" <<'APPRUN'
#!/bin/sh
HERE="$(dirname "$(readlink -f "$0")")"
# The carried HEIF decoders first, then the system's plug-ins (its HEVC encoder among them).
LIBHEIF_PLUGIN_PATH="$HERE/usr/lib/fotufilm/heif-plugins${LIBHEIF_PLUGIN_PATH:+:$LIBHEIF_PLUGIN_PATH}"
for system in /usr/lib/x86_64-linux-gnu/libheif/plugins /usr/lib64/libheif/plugins /usr/lib/libheif/plugins; do
  [ -d "$system" ] && LIBHEIF_PLUGIN_PATH="$LIBHEIF_PLUGIN_PATH:$system"
done
export LIBHEIF_PLUGIN_PATH

# The OFX plugin into the folder Resolve reads. The image's mount is the user's alone, so the
# bundle is copied out as the user first and only then, with root's rights, into place.
if [ "$1" = "--install-ofx-plugin" ]; then
  SOURCE="$HERE/usr/lib/fotufilm/ofx/Fotufilm.ofx.bundle"
  TARGET="${FOTUFILM_OFX_DIR:-/usr/OFX/Plugins}"
  [ -d "$SOURCE" ] || { echo "This Fotufilm carries no OFX plugin." >&2; exit 1; }
  STAGE="$(mktemp -d)" && cp -R "$SOURCE" "$STAGE/" && chmod -R a+rX "$STAGE" || exit 1
  INSTALL="mkdir -p '$TARGET' && rm -rf '$TARGET/Fotufilm.ofx.bundle' && cp -R '$STAGE/Fotufilm.ofx.bundle' '$TARGET/'"
  if mkdir -p "$TARGET" 2>/dev/null && [ -w "$TARGET" ]; then
    sh -c "$INSTALL"
  elif [ -t 0 ]; then
    sudo sh -c "$INSTALL"
  else
    pkexec sh -c "$INSTALL"
  fi
  STATUS=$?
  rm -rf "$STAGE"
  [ $STATUS -eq 0 ] && echo "Installed $TARGET/Fotufilm.ofx.bundle. Restart DaVinci Resolve to load it."
  exit $STATUS
fi
exec "$HERE/usr/lib/fotufilm/fotufilm" "$@"
APPRUN
chmod +x "$APPDIR/AppRun"

TOOL="$OUT/appimagetool-x86_64.AppImage"
if [[ ! -x "$TOOL" ]]; then
  curl -sfL --retry 3 -o "$TOOL" \
    https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x "$TOOL"
fi
IMAGE="$OUT/Fotufilm-${MARKETING_VERSION}-x86_64.AppImage"
# Without FUSE (containers, CI) the tool runs from its own extracted copy.
ARCH=x86_64 APPIMAGE_EXTRACT_AND_RUN=1 "$TOOL" --comp zstd --no-appstream "$APPDIR" "$IMAGE" >/dev/null
sha256sum "$IMAGE" | tee "$IMAGE.sha256"
