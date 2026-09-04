#!/usr/bin/env python3
"""Reject AppleDouble package entries except one uniform macOS provenance marker."""

from __future__ import annotations

import gzip
from pathlib import PurePosixPath
import struct
import sys


CPIO_HEADER_SIZE = 76
PROVENANCE_NAME = b"com.apple.provenance\0"


def read_exact(stream: gzip.GzipFile, size: int) -> bytes:
    data = stream.read(size)
    if len(data) != size:
        raise ValueError(f"truncated cpio archive: expected {size} bytes, found {len(data)}")
    return data


def parse_octal(field: bytes, label: str) -> int:
    try:
        return int(field, 8)
    except ValueError as error:
        raise ValueError(f"invalid cpio {label}: {field!r}") from error


def expected_sidecar(value: bytes) -> bytes:
    total_size = 152 + len(value)
    result = bytearray(total_size)

    # AppleDouble header: one Finder-info/extended-attribute entry and an empty resource fork.
    result[0:4] = b"\x00\x05\x16\x07"
    result[4:8] = b"\x00\x02\x00\x00"
    result[8:24] = b"Mac OS X        "
    struct.pack_into(">H", result, 24, 2)
    struct.pack_into(">III", result, 26, 9, 50, total_size - 50)
    struct.pack_into(">III", result, 38, 2, total_size, 0)

    # The Finder-info portion is empty. Its extended-attribute block contains one attribute.
    result[84:88] = b"ATTR"
    struct.pack_into(">I", result, 92, total_size)
    struct.pack_into(">I", result, 96, 152)
    struct.pack_into(">I", result, 100, len(value))
    struct.pack_into(">H", result, 118, 1)
    struct.pack_into(">I", result, 120, 152)
    struct.pack_into(">I", result, 124, len(value))
    result[130] = len(PROVENANCE_NAME)
    result[131:152] = PROVENANCE_NAME
    result[152:] = value
    return bytes(result)


def audit(payload: str) -> tuple[int, bytes | None]:
    sidecar_count = 0
    provenance_value: bytes | None = None

    with gzip.open(payload, "rb") as stream:
        while True:
            header = stream.read(CPIO_HEADER_SIZE)
            if not header:
                break
            if len(header) != CPIO_HEADER_SIZE or header[:6] != b"070707":
                raise ValueError("payload is not an unaligned ASCII cpio archive")

            name_size = parse_octal(header[59:65], "name size")
            file_size = parse_octal(header[65:76], "file size")
            name_bytes = read_exact(stream, name_size)
            if not name_bytes.endswith(b"\0"):
                raise ValueError("cpio filename is not null terminated")
            name = name_bytes[:-1].decode("utf-8", errors="strict")
            if name == "TRAILER!!!":
                break

            if PurePosixPath(name).name.startswith("._"):
                sidecar = read_exact(stream, file_size)
                if len(sidecar) < 154:
                    raise ValueError(f"unexpected AppleDouble data in {name}")
                value = sidecar[152:]
                if len(value) not in (2, 11) or not value.startswith(b"\x01\x02"):
                    raise ValueError(f"unexpected provenance value in {name}: {value.hex()}")
                if sidecar != expected_sidecar(value):
                    raise ValueError(f"unsupported AppleDouble entry in {name}")
                if provenance_value is not None and value != provenance_value:
                    raise ValueError(f"multiple provenance identifiers reached the package: {name}")
                provenance_value = value
                sidecar_count += 1
            else:
                stream.seek(file_size, 1)

    return sidecar_count, provenance_value


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <package-payload>", file=sys.stderr)
        return 2
    try:
        count, value = audit(sys.argv[1])
    except (OSError, UnicodeError, ValueError) as error:
        print(f"error: {sys.argv[1]}: {error}", file=sys.stderr)
        return 1

    if count:
        print(
            f"Audited {sys.argv[1]}: {count} AppleDouble entries contain only one "
            f"macOS provenance marker ({len(value or b'')} bytes)."
        )
    else:
        print(f"Audited {sys.argv[1]}: no AppleDouble metadata is present.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
