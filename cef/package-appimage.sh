#!/bin/bash
# Packs the Linux build of Fotufilm Desktop (build/cef-host/Release, from cef/build.sh) into
# one AppImage. The engine picks its GPU when the app starts: CUDA on NVIDIA, Vulkan on any other
# GPU (AMD, Intel), the CPU otherwise; FOTUFILM_GPU_DEVICE=cuda, vulkan or cpu chooses instead.
#   cef/package-appimage.sh [output-directory]      default build/appimage
#
# The image carries CEF, the engine and the image libraries the engine links that a desktop may
# lack; the C and C++ runtimes, GTK, NSS and the graphics drivers are the system's.
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."

BUILD="build/cef-host/Release"
OUT="$(mkdir -p "${1:-build/appimage}" && cd "${1:-build/appimage}" && pwd)"
APPDIR="$OUT/Fotufilm.AppDir"
LIB="$APPDIR/usr/lib/fotufilm"
source version.env
[[ -x "$BUILD/fotufilm" && -f "$BUILD/libfotufilm.so" ]] || {
  echo "error: build the Linux app first (cef/build.sh)" >&2
  exit 1
}

rm -rf "$APPDIR"
mkdir -p "$LIB"
# Chromium's setuid sandbox helper cannot work from an AppImage; the build runs without it.
tar -C "$BUILD" --exclude=chrome-sandbox -cf - . | tar -C "$LIB" -xf -
strip --strip-unneeded "$LIB/fotufilm" "$LIB/libcef.so" "$LIB/libvk_swiftshader.so"

# Libraries the engine links beyond the ones every desktop has. The executable's RPATH ($ORIGIN)
# reaches them for the engine too.
bundled='^lib(raw(_r)?|jpeg|png16|tiff|lcms2|OpenEXR[A-Za-z]*|Imath|Iex|IlmThread|heif|de265|x265|aom|dav1d|webp|webpdemux|webpmux|sharpyuv|deflate|jbig|Lerc|gomp|jxl[a-z_]*|hwy|brotlienc)[-.0-9]*\.so'
ldd "$LIB/libfotufilm.so" | awk '$2 == "=>" && $3 ~ /^\// {print $1, $3}' | while read -r name path; do
  if [[ "$name" =~ $bundled ]]; then cp -L "$path" "$LIB/$name"; fi
done

install -m 0644 "$LIB/fotufilm.png" "$APPDIR/fotufilm.png"
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
