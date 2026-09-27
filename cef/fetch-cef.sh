#!/usr/bin/env bash
# Downloads the pinned CEF minimal distribution for this machine into build/cef and prints its
# path. Reuses an existing unpacked copy.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/.." && pwd)"
source "$here/cef-version.env"

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) platform=macosarm64 ;;
  Darwin-x86_64) platform=macosx64 ;;
  Linux-x86_64) platform=linux64 ;;
  Linux-aarch64) platform=linuxarm64 ;;
  MINGW*-x86_64 | MSYS*-x86_64) platform=windows64 ;;
  MINGW*-aarch64 | MSYS*-aarch64) platform=windowsarm64 ;;
  *) echo "Unsupported platform $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

name="cef_binary_${CEF_VERSION}_${platform}_minimal"
dest="${FOTUFILM_CEF_CACHE:-$root/build/cef}"
if [[ -f "$dest/$name/cmake/FindCEF.cmake" ]]; then
  echo "$dest/$name"
  exit 0
fi

mkdir -p "$dest"
url="https://cef-builds.spotifycdn.com/${name//+/%2B}.tar.bz2"
curl -sfL --retry 3 -o "$dest/$name.tar.bz2" "$url"
expected="$(curl -sfL --retry 3 "$url.sha1")"
actual="$(shasum -a 1 "$dest/$name.tar.bz2" | cut -d' ' -f1)"
if [[ "$expected" != "$actual" ]]; then
  echo "CEF checksum mismatch: expected $expected, got $actual" >&2
  rm -f "$dest/$name.tar.bz2"
  exit 1
fi
tar -xjf "$dest/$name.tar.bz2" -C "$dest"
rm -f "$dest/$name.tar.bz2"
echo "$dest/$name"
