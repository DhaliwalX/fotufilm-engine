#!/usr/bin/env python3
"""Remove local home/worktree prefixes from objects without changing their layout."""

from __future__ import annotations

import pathlib
import re
import sys


# Halide's prebuilt runtime carries __FILE__ strings from the machine that built the toolchain.
# Object/archive offsets must not move, so replacements are exactly as long as the originals.
PRIVATE_PREFIX = re.compile(
    rb"/(?:Users|home)/[^\x00\r\n]{1,768}?/(?=(?:third_party/Halide|Halide|Sources|tools)/)"
)


def replacement(length: int) -> bytes:
    marker = b"/__fotufilm_build_root__/"
    if len(marker) > length:
        marker = b"/build/"
    return marker + (b"_" * (length - len(marker)))


def redact(path: pathlib.Path) -> int:
    original = path.read_bytes()
    updated, count = PRIVATE_PREFIX.subn(lambda match: replacement(len(match.group(0))), original)
    if count:
        path.write_bytes(updated)
    return count


def main(arguments: list[str]) -> int:
    if len(arguments) < 2:
        print(f"usage: {arguments[0]} <object-or-archive> [...]", file=sys.stderr)
        return 2
    count = 0
    for argument in arguments[1:]:
        count += redact(pathlib.Path(argument))
    if count:
        print(f"Redacted {count} embedded build path{'s' if count != 1 else ''}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
