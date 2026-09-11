#!/usr/bin/env python3
"""Reject WebGPU compilers built without the current strict-float implementation."""

import argparse
import hashlib
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("write", "verify"))
    parser.add_argument("prefix", type=Path)
    args = parser.parse_args()
    tools = Path(__file__).resolve().parent.parent
    sources = [tools / "halide-webgpu-strict-float.patch",
               tools / "webgpu-parity/reference-math.wgsl"]
    expected = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}
    stamp = args.prefix / "share/fotufilm/strict-float.json"
    if args.mode == "write":
        stamp.parent.mkdir(parents=True, exist_ok=True)
        stamp.write_text(json.dumps(expected, indent=2) + "\n")
        return
    try:
        matches = json.loads(stamp.read_text()) == expected
    except (OSError, ValueError):
        matches = False
    if not matches:
        parser.exit(1, "WebGPU Halide lacks the current strict-float implementation. "
                    "Rebuild it with tools/build-halide.sh --webgpu.\n")


if __name__ == "__main__":
    main()
