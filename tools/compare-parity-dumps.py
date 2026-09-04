#!/usr/bin/env python3
"""Compares two parity dumps — one from each plugin — and says whether they are the same picture.

The OFX plugin and the Final Cut plugin reach the same engine through the same bridge, so a frame
developed with the same settings should come back the same. What sits between them and the engine
does not: each has its own colour-space handling, its own idea of premultiplication, its own row
order, and its own decision about whether the engine or the host carries the output encode. A
difference here is one of those.

Produce the two dumps with:

    build/resolve/host-harness --parity-dump /tmp/parity-ofx.raw
    build/finalcut/host-harness --parity-dump /tmp/parity-fxplug.raw

then run this over them. Exits non-zero if they disagree by more than the tolerance.

The default tolerance is 0, because there is no arithmetic in either path that should differ: the
same kernel develops the same pixels from the same numbers. A tolerance is offered for the case
where one side has been asked for a half-float surface, which quantises at about 1e-3.
"""

import argparse
import array
import struct
import sys


def read_dump(path):
    with open(path, "rb") as handle:
        data = handle.read()
    if len(data) < 8:
        raise SystemExit(f"{path}: too short to be a dump")
    width, height = struct.unpack("ii", data[:8])
    pixels = array.array("f")
    pixels.frombytes(data[8:])
    expected = width * height * 4
    if len(pixels) != expected:
        raise SystemExit(
            f"{path}: says {width}x{height} ({expected} floats) but carries {len(pixels)}")
    return width, height, pixels


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("first")
    parser.add_argument("second")
    parser.add_argument("--tolerance", type=float, default=0.0,
                        help="largest absolute per-channel difference to accept (default 0)")
    arguments = parser.parse_args()

    width, height, a = read_dump(arguments.first)
    other_width, other_height, b = read_dump(arguments.second)
    if (width, height) != (other_width, other_height):
        raise SystemExit(
            f"different sizes: {width}x{height} against {other_width}x{other_height}")

    worst = 0.0
    worst_at = None
    differing = 0
    total = 0.0
    for i, (x, y) in enumerate(zip(a, b)):
        difference = abs(x - y)
        total += difference
        if difference > 0:
            differing += 1
        if difference > worst:
            worst = difference
            worst_at = i

    print(f"{width}x{height}, {len(a)} channels")
    print(f"  channels differing at all : {differing} ({100.0 * differing / len(a):.3f}%)")
    print(f"  mean absolute difference  : {total / len(a):.3e}")
    print(f"  largest difference        : {worst:.3e}")
    if worst_at is not None and worst > 0:
        pixel = worst_at // 4
        channel = "RGBA"[worst_at % 4]
        print(f"    at pixel ({pixel % width}, {pixel // width}) channel {channel}: "
              f"{a[worst_at]:.6f} against {b[worst_at]:.6f}")

    if worst > arguments.tolerance:
        print(f"DIFFERENT (tolerance {arguments.tolerance:.3e})")
        return 1
    print("SAME" if worst == 0 else f"SAME within {arguments.tolerance:.3e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
