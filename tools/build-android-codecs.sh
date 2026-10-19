#!/bin/bash
# Builds the libraries behind Sources/CFotufilmCodecs and Sources/CFotufilmVideo for Android
# arm64-v8a: the same set build-desktop-engine-linux.sh takes from pkg-config on Linux (LibRaw,
# lcms2, libjpeg-turbo, libpng, libtiff, libheif with libde265, OpenEXR with Imath) and FFmpeg.
# The still codecs are static and position independent, so they link into libfotufilm.so and
# --gc-sections drops what nothing calls. FFmpeg is shared: CFotufilmVideo loads it with dlopen,
# and the app carries it in jniLibs. Zlib is the NDK's own, which every Android device has.
# Sources are downloaded once into $FOTUFILM_ANDROID_DEPS/src; a library whose stamp records the
# same version and flags is not built again (FOTUFILM_ANDROID_REBUILD=1 rebuilds everything).
# The NDK is ANDROID_NDK_HOME, or the newest under ANDROID_HOME/ndk; everything is built under
# FOTUFILM_ANDROID_DEPS (default build/android-deps), and installed in its arm64 folder.
#   ANDROID_HOME=… tools/build-android-codecs.sh [--no-video]
set -euo pipefail
cd "$(cd "$(dirname "$0")" && pwd -P)/.."

ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
NDK="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_SDK"/ndk/*/ 2>/dev/null | sort -V | tail -1)}"
NDK="${NDK%/}"
[[ -d "$NDK" ]] || { echo "error: no Android NDK (set ANDROID_NDK_HOME)" >&2; exit 1; }
DEPS="${FOTUFILM_ANDROID_DEPS:-$PWD/build/android-deps}"
SRC="$DEPS/src"
BUILD="$DEPS/build"
PREFIX="$DEPS/arm64"
API="${FOTUFILM_ANDROID_API:-28}"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || nproc)"
VIDEO=1
[[ "${1:-}" == "--no-video" ]] && VIDEO=0

JPEG_VERSION=3.2.0
PNG_VERSION=1.6.59
TIFF_VERSION=4.7.2
LCMS_VERSION=2.19.1
LIBRAW_VERSION=0.22.2
DE265_VERSION=1.1.3
HEIF_VERSION=1.23.6
IMATH_VERSION=3.2.3
EXR_VERSION=3.5.2
FFMPEG_VERSION=8.1.3

case "$(uname -s)" in
  Darwin) HOST_TAG=darwin-x86_64 ;;  # a universal build, native on Apple silicon too
  Linux) HOST_TAG=linux-x86_64 ;;
  *) echo "error: unsupported build host $(uname -s)" >&2; exit 1 ;;
esac
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/$HOST_TAG"
CC="$TOOLCHAIN/bin/aarch64-linux-android$API-clang"
CXX="$TOOLCHAIN/bin/aarch64-linux-android$API-clang++"
[[ -f "$NDK/source.properties" && -x "$CC" ]] || {
  echo "error: no Android NDK at $NDK (set ANDROID_NDK_HOME)" >&2
  exit 1
}
CMAKE="${CMAKE:-$(command -v cmake || true)}"
[[ -n "$CMAKE" ]] || CMAKE="$(ls -d "${ANDROID_HOME:-$NDK/../..}"/cmake/*/bin/cmake 2>/dev/null | tail -1)"
command -v ninja >/dev/null || { echo "error: ninja is missing" >&2; exit 1; }

mkdir -p "$SRC" "$BUILD" "$PREFIX/include" "$PREFIX/lib/pkgconfig"
# Only the prefix's own .pc files: the build host's (Homebrew's x265, aom, …) must never be seen.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

# The NDK's zlib, described for the .pc files that require it (libpng, libtiff): its header and
# libz.so are in the sysroot, so it needs no flags of its own.
ZLIB_VERSION="$(sed -n 's/^#define ZLIB_VERSION "\(.*\)"/\1/p' "$TOOLCHAIN/sysroot/usr/include/zlib.h")"
cat > "$PREFIX/lib/pkgconfig/zlib.pc" <<PC
Name: zlib
Description: The Android NDK's zlib
Version: $ZLIB_VERSION
Libs: -lz
Cflags:
PC

# Unused functions and data in sections of their own, so the engine's --gc-sections can drop them.
CFLAGS_COMMON="-O2 -fPIC -ffunction-sections -fdata-sections"

# Fetches a release archive once and unpacks it beside it.
fetch() {
  local url="$1" archive="$2" dir="$3"
  if [[ ! -f "$SRC/$archive" ]]; then
    echo "== downloading $archive"
    curl -fL --retry 3 -o "$SRC/$archive.part" "$url"
    mv "$SRC/$archive.part" "$SRC/$archive"
  fi
  [[ -d "$SRC/$dir" ]] || tar -xf "$SRC/$archive" -C "$SRC"
}

# Whether a library is already built with these settings; `done_building` records it.
built() {
  local stamp="$BUILD/$1.stamp"
  [[ "${FOTUFILM_ANDROID_REBUILD:-0}" != 1 && -f "$stamp" && "$(cat "$stamp")" == "$2" ]]
}
done_building() { echo "$2" > "$BUILD/$1.stamp"; }

# One CMake project, configured for the NDK, built and installed into the prefix. The find root
# keeps package searches inside the sysroot and the prefix.
cmake_install() {
  local name="$1" source="$2"
  shift 2
  local settings="$*"
  if built "$name" "$settings"; then echo "== $name is up to date"; return; fi
  echo "== building $name"
  rm -rf "${BUILD:?}/$name"
  "$CMAKE" -S "$source" -B "$BUILD/$name" -G Ninja \
    -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM="android-$API" -DANDROID_STL=c++_shared \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_PREFIX_PATH="$PREFIX" -DCMAKE_FIND_ROOT_PATH="$PREFIX" \
    -DBUILD_SHARED_LIBS=OFF -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF \
    -DCMAKE_C_FLAGS="$CFLAGS_COMMON" -DCMAKE_CXX_FLAGS="$CFLAGS_COMMON" \
    "$@" > "$BUILD/$name.configure.log" || {
      tail -40 "$BUILD/$name.configure.log" >&2
      exit 1
    }
  "$CMAKE" --build "$BUILD/$name" --parallel "$JOBS" > "$BUILD/$name.build.log" || {
    tail -40 "$BUILD/$name.build.log" >&2
    exit 1
  }
  "$CMAKE" --install "$BUILD/$name" > "$BUILD/$name.install.log"
  done_building "$name" "$settings"
}

# libjpeg-turbo: the libjpeg (6b) API the decoders and the JPEG writer use, Neon on arm64 without
# an assembler. TurboJPEG and the tools are not needed.
fetch "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/$JPEG_VERSION/libjpeg-turbo-$JPEG_VERSION.tar.gz" \
  "libjpeg-turbo-$JPEG_VERSION.tar.gz" "libjpeg-turbo-$JPEG_VERSION"
cmake_install "libjpeg-turbo-$JPEG_VERSION" "$SRC/libjpeg-turbo-$JPEG_VERSION" \
  -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF \
  -DWITH_SIMD=ON -DREQUIRE_SIMD=ON

# libpng over the NDK's zlib.
fetch "https://download.sourceforge.net/libpng/libpng-$PNG_VERSION.tar.xz" \
  "libpng-$PNG_VERSION.tar.xz" "libpng-$PNG_VERSION"
cmake_install "libpng-$PNG_VERSION" "$SRC/libpng-$PNG_VERSION" \
  -DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF -DPNG_FRAMEWORK=OFF

# libtiff with the codecs scans and exports use: JPEG, Deflate (zlib), LZW, PackBits and the
# other internal ones. LZMA, ZSTD, WebP, LERC, JBIG and libdeflate are left out; nothing the
# engine opens needs them, and OpenEXR carries its own deflate.
fetch "https://download.osgeo.org/libtiff/tiff-$TIFF_VERSION.tar.xz" "tiff-$TIFF_VERSION.tar.xz" \
  "tiff-$TIFF_VERSION"
cmake_install "tiff-$TIFF_VERSION" "$SRC/tiff-$TIFF_VERSION" \
  -Dtiff-tools=OFF -Dtiff-tests=OFF -Dtiff-contrib=OFF -Dtiff-docs=OFF -Dtiff-cxx=OFF \
  -Dtiff-opengl=OFF -Dzlib=ON -Djpeg=ON -Dold-jpeg=ON -Djpeg12=OFF -Dpixarlog=ON \
  -Dlibdeflate=OFF -Dlzma=OFF -Dzstd=OFF -Dwebp=OFF -Dlerc=OFF -Djbig=OFF \
  -DJPEG_INCLUDE_DIR="$PREFIX/include" -DJPEG_LIBRARY="$PREFIX/lib/libjpeg.a"

# lcms2, the library alone: the tools, tests and the GPL plugins stay out.
fetch "https://github.com/mm2/Little-CMS/releases/download/lcms$LCMS_VERSION/lcms2-$LCMS_VERSION.tar.gz" \
  "lcms2-$LCMS_VERSION.tar.gz" "lcms2-$LCMS_VERSION"
cmake_install "lcms2-$LCMS_VERSION" "$SRC/lcms2-$LCMS_VERSION" \
  -DLCMS2_BUILD_SHARED=OFF -DLCMS2_BUILD_STATIC=ON -DLCMS2_BUILD_TOOLS=OFF -DLCMS2_BUILD_TESTS=OFF \
  -DLCMS2_WITH_JPEG=OFF -DLCMS2_WITH_TIFF=OFF -DLCMS2_WITH_ZLIB=OFF \
  -DLCMS2_WITH_FASTFLOAT=OFF -DLCMS2_WITH_THREADED_PLUGIN=OFF

# LibRaw has no CMake project; its sources are compiled here as its autotools build compiles
# libraw_r: thread safe (no LIBRAW_NOTHREADS), with lossy DNG through libjpeg, deflate DNG through
# zlib and lcms2 for profiles, as distributions configure it. OpenMP stays off: the decoder runs
# on the engine's own threads.
fetch "https://www.libraw.org/data/LibRaw-$LIBRAW_VERSION.tar.gz" "LibRaw-$LIBRAW_VERSION.tar.gz" \
  "LibRaw-$LIBRAW_VERSION"
LIBRAW_DEFINES="-DUSE_JPEG -DUSE_JPEG8 -DUSE_ZLIB -DUSE_LCMS2"
LIBRAW_SETTINGS="$LIBRAW_VERSION $CXX $CFLAGS_COMMON $LIBRAW_DEFINES"
if built "LibRaw-$LIBRAW_VERSION" "$LIBRAW_SETTINGS"; then
  echo "== LibRaw-$LIBRAW_VERSION is up to date"
else
  echo "== building LibRaw-$LIBRAW_VERSION"
  LIBRAW_SRC="$SRC/LibRaw-$LIBRAW_VERSION"
  LIBRAW_OBJ="$BUILD/LibRaw-$LIBRAW_VERSION"
  rm -rf "$LIBRAW_OBJ"
  mkdir -p "$LIBRAW_OBJ"
  # The library's sources as Makefile.am lists them (lib_libraw_a_SOURCES).
  LIBRAW_SOURCES=$(sed -n '/^lib_libraw_a_SOURCES/,/^$/p' "$LIBRAW_SRC/Makefile.am" \
    | tr -d '\\' | tr ' \t' '\n\n' | grep '\.cpp$')
  # shellcheck disable=SC2086
  printf '%s\n' $LIBRAW_SOURCES | xargs -P "$JOBS" -I{} sh -c '
    object="$2/$(echo "$1" | tr / _ | sed "s/\.cpp$/.o/")"
    "$3" -std=c++17 -w $4 $5 -I"$6" -I"$7/include" -c "$6/$1" -o "$object"
  ' _ {} "$LIBRAW_OBJ" "$CXX" "$CFLAGS_COMMON" "$LIBRAW_DEFINES" "$LIBRAW_SRC" "$PREFIX"
  rm -f "$PREFIX/lib/libraw_r.a"
  "$TOOLCHAIN/bin/llvm-ar" rcs "$PREFIX/lib/libraw_r.a" "$LIBRAW_OBJ"/*.o
  mkdir -p "$PREFIX/include/libraw"
  cp "$LIBRAW_SRC"/libraw/*.h "$PREFIX/include/libraw/"
  cat > "$PREFIX/lib/pkgconfig/libraw_r.pc" <<PC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: libraw
Description: Raw image decoder library (thread-safe)
Requires: lcms2
Version: $LIBRAW_VERSION
Libs: -L\${libdir} -lraw_r
Libs.private: -ljpeg -lz -lm
Cflags: -I\${includedir}/libraw -I\${includedir}
PC
  done_building "LibRaw-$LIBRAW_VERSION" "$LIBRAW_SETTINGS"
fi

# libde265, the HEVC decoder libheif opens HEIC photographs with; Neon kernels, no tools.
fetch "https://github.com/strukturag/libde265/releases/download/v$DE265_VERSION/libde265-$DE265_VERSION.tar.gz" \
  "libde265-$DE265_VERSION.tar.gz" "libde265-$DE265_VERSION"
cmake_install "libde265-$DE265_VERSION" "$SRC/libde265-$DE265_VERSION" \
  -DENABLE_SDL=OFF -DENABLE_DECODER=OFF -DENABLE_ENCODER=OFF -DENABLE_SIMD=ON

# libheif decodes HEIC through libde265, built in rather than as a plugin. It has no HEVC encoder
# (x265 is GPL), so ffc_can_encode_heic answers no on Android; every other codec is off.
fetch "https://github.com/strukturag/libheif/releases/download/v$HEIF_VERSION/libheif-$HEIF_VERSION.tar.gz" \
  "libheif-$HEIF_VERSION.tar.gz" "libheif-$HEIF_VERSION"
cmake_install "libheif-$HEIF_VERSION" "$SRC/libheif-$HEIF_VERSION" \
  -DENABLE_PLUGIN_LOADING=OFF -DWITH_LIBDE265=ON -DWITH_LIBDE265_PLUGIN=OFF \
  -DWITH_X265=OFF -DWITH_X264=OFF -DWITH_KVAZAAR=OFF -DWITH_UVG266=OFF -DWITH_VVDEC=OFF \
  -DWITH_VVENC=OFF -DWITH_OpenH264_DECODER=OFF -DWITH_DAV1D=OFF -DWITH_AOM_DECODER=OFF \
  -DWITH_AOM_ENCODER=OFF -DWITH_SvtEnc=OFF -DWITH_RAV1E=OFF -DWITH_JPEG_DECODER=OFF \
  -DWITH_JPEG_ENCODER=OFF -DWITH_OpenJPEG_DECODER=OFF -DWITH_OpenJPEG_ENCODER=OFF \
  -DWITH_FFMPEG_DECODER=OFF -DWITH_OPENJPH_ENCODER=OFF -DWITH_UNCOMPRESSED_CODEC=OFF \
  -DWITH_LIBSHARPYUV=OFF -DWITH_HEADER_COMPRESSION=OFF -DWITH_EXAMPLES=OFF \
  -DWITH_EXAMPLE_HEIF_THUMB=OFF -DWITH_EXAMPLE_HEIF_VIEW=OFF -DWITH_GDK_PIXBUF=OFF \
  -DBUILD_DOCUMENTATION=OFF -DWITH_FUZZERS=OFF \
  -DLIBDE265_INCLUDE_DIR="$PREFIX/include" -DLIBDE265_LIBRARY="$PREFIX/lib/libde265.a"

# Imath, then OpenEXR with the deflate, zstd and OpenJPH sources it vendors (no download at
# configure time). Libraries only.
fetch "https://github.com/AcademySoftwareFoundation/Imath/archive/refs/tags/v$IMATH_VERSION.tar.gz" \
  "Imath-$IMATH_VERSION.tar.gz" "Imath-$IMATH_VERSION"
cmake_install "Imath-$IMATH_VERSION" "$SRC/Imath-$IMATH_VERSION" \
  -DPYTHON=OFF -DPYBIND11=OFF -DIMATH_INSTALL_PKG_CONFIG=ON
fetch "https://github.com/AcademySoftwareFoundation/openexr/archive/refs/tags/v$EXR_VERSION.tar.gz" \
  "openexr-$EXR_VERSION.tar.gz" "openexr-$EXR_VERSION"
cmake_install "openexr-$EXR_VERSION" "$SRC/openexr-$EXR_VERSION" \
  -DOPENEXR_BUILD_TOOLS=OFF -DOPENEXR_INSTALL_TOOLS=OFF -DOPENEXR_BUILD_EXAMPLES=OFF \
  -DOPENEXR_INSTALL_DOCS=OFF -DOPENEXR_BUILD_PYTHON=OFF -DOPENEXR_TEST_LIBRARIES=OFF \
  -DOPENEXR_TEST_TOOLS=OFF -DOPENEXR_TEST_PYTHON=OFF -DOPENEXR_FORCE_INTERNAL_IMATH=OFF \
  -DOPENEXR_FORCE_INTERNAL_DEFLATE=ON -DOPENEXR_FORCE_INTERNAL_ZSTD=ON \
  -DOPENEXR_FORCE_INTERNAL_OPENJPH=ON -DImath_DIR="$PREFIX/lib/cmake/Imath"

[[ "$VIDEO" == 1 ]] || { echo "Built the codec libraries into $PREFIX"; exit 0; }

# FFmpeg, shared and LGPL (no --enable-gpl, so no x264 or x265). Every native decoder, demuxer
# and parser stays in, since a phone's library holds movies from anywhere; Android's MediaCodec
# adds the hardware decoders and the H.264/HEVC encoders. Encoding and muxing are limited to what
# CFotufilmVideo writes: ProRes and AAC in MOV/MP4. FFmpeg names Android libraries without a
# version (libavcodec.so), the only names an APK's jniLibs carry.
fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION.tar.xz" \
  "ffmpeg-$FFMPEG_VERSION"
# shellcheck disable=SC2054 # the commas separate FFmpeg's own lists
FFMPEG_OPTIONS=(
  --prefix="$PREFIX" --target-os=android --arch=aarch64 --cpu=armv8-a --enable-cross-compile
  --cc="$CC" --cxx="$CXX" --ar="$TOOLCHAIN/bin/llvm-ar" --nm="$TOOLCHAIN/bin/llvm-nm"
  --ranlib="$TOOLCHAIN/bin/llvm-ranlib" --strip="$TOOLCHAIN/bin/llvm-strip"
  --sysroot="$TOOLCHAIN/sysroot" --pkg-config="$(command -v pkg-config)"
  --enable-shared --disable-static --enable-pic --disable-programs --disable-doc
  --disable-avdevice --disable-avfilter --disable-network --disable-autodetect
  --enable-zlib --enable-jni --enable-mediacodec --enable-neon
  --disable-encoders --enable-encoder=prores_aw,prores_ks,aac,h264_mediacodec,hevc_mediacodec
  --disable-muxers --enable-muxer=mov,mp4
  --extra-cflags="-O2 -fPIC" --extra-ldflags="-Wl,-z,max-page-size=16384"
)
FFMPEG_SETTINGS="$FFMPEG_VERSION ${FFMPEG_OPTIONS[*]}"
if built "ffmpeg-$FFMPEG_VERSION" "$FFMPEG_SETTINGS"; then
  echo "== ffmpeg-$FFMPEG_VERSION is up to date"
else
  echo "== building ffmpeg-$FFMPEG_VERSION"
  rm -rf "$BUILD/ffmpeg-$FFMPEG_VERSION"
  mkdir -p "$BUILD/ffmpeg-$FFMPEG_VERSION"
  (
    cd "$BUILD/ffmpeg-$FFMPEG_VERSION"
    "$SRC/ffmpeg-$FFMPEG_VERSION/configure" "${FFMPEG_OPTIONS[@]}" > ../ffmpeg.configure.log || {
      tail -40 ../ffmpeg.configure.log >&2
      tail -40 ffbuild/config.log >&2
      exit 1
    }
    make -j"$JOBS" > ../ffmpeg.build.log 2>&1 || { tail -40 ../ffmpeg.build.log >&2; exit 1; }
    make install > ../ffmpeg.install.log 2>&1
  )
  done_building "ffmpeg-$FFMPEG_VERSION" "$FFMPEG_SETTINGS"
fi
echo "Built the codec libraries and FFmpeg into $PREFIX"
