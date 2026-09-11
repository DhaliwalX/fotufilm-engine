#!/usr/bin/env python3
"""Content-addressed public Apple AOT releases; no compiler or credentials needed to fetch."""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "DhaliwalX/fotufilm-engine"
TARGETS = {
    "device": "arm64-apple-ios18.0",
    "simulator": "arm64-apple-ios18.0-simulator",
    "macos": "arm64-apple-macos14.0",
    "macos-intel": "x86_64-apple-macos14.0",
}
RECIPE_FILES = (
    "tools/generate_halide_ios.cpp", "tools/generate-halide-aot.sh",
    "tools/aot-release.py", "tools/aot-toolchain.json", "tools/build-halide.sh",
    "tools/redact-binary-paths.py", "LICENSE",
)
HEADERS = {"HalideBuffer.h", "HalideRuntime.h", "HalideRuntimeMetal.h"}
NOTICES = {"LICENSE.txt", "HALIDE-LICENSE.txt"}
MANIFEST = "aot-manifest.json"
GENERATED = re.compile(r"fotufilm_halide_ios_[a-z0-9_]+\.(?:a|h)\Z")
PRIVATE_PATH = re.compile(rb"/(?:Users|home|Volumes)/[^/\s\x00]+/|/private/var/folders/")


def run(*args: str, cwd: Path = ROOT) -> str:
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def halide_revision() -> str:
    # The gitlink is available even in a shallow checkout without Halide initialized.
    return run("git", "ls-tree", "HEAD", "third_party/Halide").split()[2]


def flags() -> dict[str, str]:
    # Keep eligibility and the local cache in sync with every generator override.
    source = (ROOT / "tools/generate_halide_ios.cpp").read_text()
    source += (ROOT / "Sources/FotufilmHalide/FotufilmHalideMetal.cpp").read_text()
    names = re.findall(r'"(FOTUFILM_[A-Z_0-9]+)"', source)
    return {name: os.environ[name] for name in sorted(set(names)) if os.environ.get(name)}


def identity(platform: str) -> dict:
    paths = set(RECIPE_FILES)
    paths.update(str(p.relative_to(ROOT)) for p in (ROOT / "Sources/FotufilmHalide").rglob("*")
                 if p.suffix in {".h", ".cpp", ".mm"} and p.is_file())
    inputs = {name: digest((ROOT / name).read_bytes()) for name in sorted(paths)}
    record = {
        "schema": 1, "repository": REPOSITORY, "platform": platform,
        "target": TARGETS[platform], "halide_revision": halide_revision(),
        "toolchain": json.loads((ROOT / "tools/aot-toolchain.json").read_text()),
        "inputs": inputs,
    }
    record["key"] = digest(json.dumps(record, sort_keys=True).encode())
    return record


def tag(record: dict) -> str:
    return f'aot-{record["platform"]}-{record["key"][:16]}'


def allowed(name: str) -> bool:
    return bool(GENERATED.fullmatch(name)) or name in HEADERS | NOTICES | {MANIFEST}


def output_path(value: str) -> Path:
    original = Path(value).absolute()
    path = original.resolve()
    if (original.is_symlink() or path in {Path.home(), ROOT} or path in ROOT.parents
            or (path / ".git").exists()):
        raise ValueError("Refusing an unsafe AOT output directory")
    if path.exists():
        if not path.is_dir():
            raise ValueError("AOT output must be a directory")
        for child in path.iterdir():
            if child.is_symlink() or not child.is_file() or not (
                allowed(child.name) or child.name in {"generate-halide-aot", ".generated-from"}
            ):
                raise ValueError(f"AOT output contains an unrelated entry: {child.name}")
    return path


def validate_payload(record: dict, contents: dict[str, bytes]) -> dict:
    if MANIFEST not in contents:
        raise ValueError("AOT manifest is missing")
    manifest = json.loads(contents[MANIFEST])
    if any(manifest.get(k) != v for k, v in record.items()):
        raise ValueError("AOT manifest does not match this engine/platform/toolchain")
    expected = manifest.get("files", {})
    if set(contents) != set(expected) | {MANIFEST} or not HEADERS | NOTICES <= set(expected):
        raise ValueError("AOT archive is incomplete or contains unlisted files")
    archives = {name for name in expected if name.endswith(".a")}
    if not archives or len(archives) != manifest.get("archive_count"):
        raise ValueError("AOT archive count does not match its manifest")
    if any(name[:-2] + ".h" not in expected for name in archives):
        raise ValueError("An AOT archive is missing its interface header")
    for name, checksum in expected.items():
        if not allowed(name) or digest(contents[name]) != checksum:
            raise ValueError(f"AOT file checksum/allowlist failure: {name}")
    return manifest


def cache_matches(record: dict, directory: Path) -> bool:
    if not (directory / MANIFEST).is_file():
        return False
    try:
        # Do not bless a stale or partially deleted cache just because its stamp survived.
        names = json.loads((directory / MANIFEST).read_text())["files"]
        validate_payload(record, {name: (directory / name).read_bytes()
                                  for name in [*names, MANIFEST] if allowed(name)})
        return True
    except (OSError, ValueError, KeyError, TypeError):
        return False


def unpack(archive: Path, checksum: Path, record: dict, destination: Path) -> None:
    expected = checksum.read_text().strip()
    if not re.fullmatch(r"[0-9a-f]{64}  kernels\.tar\.gz", expected):
        raise ValueError("Malformed AOT archive checksum")
    if digest(archive.read_bytes()) != expected.split()[0]:
        raise ValueError("AOT archive checksum mismatch")
    contents = {}
    total_size = 0
    with tarfile.open(archive, "r:gz") as bundle:
        for member in bundle:
            # No links, paths, special files, duplicate names or automatic tar extraction.
            if not member.isfile() or not allowed(member.name) or member.name in contents:
                raise ValueError("Unsafe or unexpected AOT archive entry")
            total_size += member.size
            if (member.size > 64 * 1024 * 1024 or len(contents) >= 2048
                    or total_size > 2 * 1024 * 1024 * 1024):
                raise ValueError("AOT archive exceeds expected limits")
            contents[member.name] = bundle.extractfile(member).read()
    validate_payload(record, contents)
    destination = output_path(str(destination))
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Verify everything before replacing an existing cache. Only allowlisted generated files
    # can live there; a failed download never destroys the previous usable set.
    with tempfile.TemporaryDirectory(prefix=".aot-install-", dir=destination.parent) as temp:
        staging = Path(temp) / "new"
        staging.mkdir()
        for name, data in contents.items():
            (staging / name).write_bytes(data)
        previous = Path(temp) / "previous"
        if destination.exists():
            destination.rename(previous)
        try:
            staging.rename(destination)
        except OSError:
            if previous.exists():
                previous.rename(destination)
            raise


def fetch(record: dict, destination: Path) -> int:
    with tempfile.TemporaryDirectory(prefix="fotufilm-aot-download-") as temp:
        folder = Path(temp)
        for asset in ("kernels.tar.gz.sha256", "kernels.tar.gz"):
            # -q disables ~/.curlrc; no gh session, API token, or private release lookup.
            result = subprocess.run([
                "curl", "-q", "--location", "--silent", "--show-error", "--fail",
                "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "20",
                "--max-time", "600", "--retry", "2", "--output", str(folder / asset),
                f"https://github.com/{REPOSITORY}/releases/download/{tag(record)}/{asset}",
            ], capture_output=True, text=True)
            if result.returncode:
                print(f"Public AOT release {tag(record)} is not available: {result.stderr.strip()}",
                      file=sys.stderr)
                return 3  # Missing/offline can generate locally; corrupt bytes below cannot.
        unpack(folder / "kernels.tar.gz", folder / "kernels.tar.gz.sha256", record, destination)
    print(f"Fetched and verified {tag(record)} from {REPOSITORY}.")
    return 0


def package(record: dict, source: Path, directory: Path) -> None:
    if flags():
        raise ValueError("Cannot publish AOTs with generator overrides")
    prefix = Path(os.environ["HALIDE_ROOT"])
    provenance = json.loads((prefix / "fotufilm-toolchain.json").read_text())
    recipe = record["toolchain"]
    if provenance != {"halide_revision": record["halide_revision"], "llvm": recipe["llvm"],
                      "build_script": digest((ROOT / "tools/build-halide.sh").read_bytes())}:
        raise ValueError("Build the pinned compiler with tools/build-halide.sh before publishing")
    if run("xcodebuild", "-version").split()[-1] != recipe["xcode_build"]:
        raise ValueError("Xcode does not match tools/aot-toolchain.json")
    sdk = {"device": "iphoneos", "simulator": "iphonesimulator"}.get(record["platform"], "macosx")
    metal = run("xcrun", "--sdk", sdk, "metal", "--version")
    if not metal.startswith(f'Apple metal version {recipe["metal_version"]} '):
        raise ValueError("Metal compiler does not match tools/aot-toolchain.json")
    contents = {p.name: p.read_bytes() for p in source.iterdir()
                if p.is_file() and (GENERATED.fullmatch(p.name) or p.name in HEADERS)}
    contents["LICENSE.txt"] = (ROOT / "LICENSE").read_bytes()
    contents["HALIDE-LICENSE.txt"] = (ROOT / "third_party/Halide/LICENSE.txt").read_bytes()
    count = int(run(str(source.resolve() / "generate-halide-aot"), str(source), "--count")) + 6
    if sum(name.endswith(".a") for name in contents) != count:
        raise ValueError("Generated AOT set is incomplete")
    for name, data in contents.items():
        if PRIVATE_PATH.search(data):
            raise ValueError(f"AOT privacy audit found a local build path in {name}")
    manifest = {**record, "source_commit": run("git", "rev-parse", "HEAD"),
                "archive_count": count, "files": {n: digest(d) for n, d in sorted(contents.items())}}
    contents[MANIFEST] = (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode()
    validate_payload(record, contents)
    directory.mkdir(parents=True, exist_ok=True)
    archive = directory / "kernels.tar.gz"
    with tarfile.open(archive, "w:gz") as bundle:
        for name, data in sorted(contents.items()):
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode, entry.mtime = len(data), 0o644, 0
            bundle.addfile(entry, io.BytesIO(data))
    (directory / "kernels.tar.gz.sha256").write_text(f"{digest(archive.read_bytes())}  kernels.tar.gz\n")
    (directory / MANIFEST).write_bytes(contents[MANIFEST])
    print(f"Packaged and audited {count} archives for {tag(record)}.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("key", "tag", "flags", "output", "cache", "fetch", "package"))
    parser.add_argument("platform", choices=TARGETS)
    parser.add_argument("path", nargs="?")
    parser.add_argument("destination", nargs="?")
    args = parser.parse_args()
    record = identity(args.platform)
    if args.command in {"key", "tag", "flags"}:
        print(record["key"] if args.command == "key" else tag(record) if args.command == "tag"
              else json.dumps(flags(), sort_keys=True))
    elif args.command == "output":
        print(output_path(args.path))
    elif args.command == "cache":
        return 0 if cache_matches(record, output_path(args.path)) else 3
    elif args.command == "fetch":
        if flags():
            raise ValueError("Prebuilt AOTs cannot substitute generator overrides")
        return fetch(record, output_path(args.path))
    elif args.command == "package":
        package(record, output_path(args.path), Path(args.destination))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, tarfile.TarError, subprocess.CalledProcessError) as error:
        print(f"AOT error: {error}", file=sys.stderr)
        sys.exit(1)
