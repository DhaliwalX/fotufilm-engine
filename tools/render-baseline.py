#!/usr/bin/env python3
"""Compares render dumps with the committed render baseline, or records a new one.

Every backend writes its renders as `FSPY` records (tools/aot-parity.mm's layout: a name, two
integers, a status and the floats). This reduces each to a fingerprint and compares it with
Tests/RenderBaseline/references/<backend>.json.gz:

  check   fail when any case moved further than the backend's tolerance, or appeared or vanished
  update  write the fingerprints of these dumps as the new baseline, reporting what moved

A fingerprint is layout-agnostic, so a frame, a halation grid and a density buffer are treated
alike: the record's floats cut into contiguous chunks (about a third of a row of a frame), each
chunk's mean and standard deviation, and a run of raw values from the middle. The means catch a
shift in tone or colour anywhere in the frame; the deviations catch a change in grain, sharpness
or any other texture that leaves the mean alone; the raw run catches a change at single-pixel
scale, such as a grain pattern that moved.

The tolerance is absolute, in the backend's own output units, and covers the drift between two
machines running the same code: different chips, drivers and compilers. It is recorded with the
references and can be overridden for one run with --tolerance.
"""
import argparse
import base64
import gzip
import json
import math
from array import array
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parent.parent
REFERENCES = ROOT / 'Tests' / 'RenderBaseline' / 'references'
# Headroom over the drift measured between runs, for other machines' chips, drivers and OS. See
# the README beside the references for the measurements.
DEFAULT_TOLERANCE = {'cpu': 2e-5, 'metal': 1e-4, 'aot': 1e-4, 'wasm': 2e-5}
CHUNKS = 1024
SAMPLE = 256
FORMAT = 2
# The float lists stored as little-endian float32, base64: under half the size of
# decimal text once compressed.
PACKED = ('means', 'deviations', 'sample')


def read_record(path):
    data = path.read_bytes()
    if data[:4] != b'FSPY':
        raise ValueError(f'{path}: not an FSPY record')
    offset = 4
    (name_length,) = struct.unpack_from('<i', data, offset)
    offset += 4
    name = data[offset:offset + name_length].decode()
    offset += name_length
    mask, status, count = struct.unpack_from('<iii', data, offset)
    offset += 12
    values = array('f')
    values.frombytes(data[offset:offset + 4 * count])
    if sys.byteorder != 'little':
        values.byteswap()
    if len(values) != count:
        raise ValueError(f'{path}: {len(values)} of {count} floats')
    return name, mask, status, values


def as_float32(value):
    """Rounded to float32, so a fingerprint reads back exactly as it was written."""
    return struct.unpack('<f', struct.pack('<f', value))[0] if math.isfinite(value) else value


def fingerprint(mask, status, values):
    n = len(values)
    record = {'mask': mask, 'status': status, 'count': n,
              'nan': sum(1 for v in values if v != v)}
    if n == 0:
        return record
    chunks = max(1, min(CHUNKS, n // 64))
    means, deviations = [], []
    for c in range(chunks):
        chunk = values[c * n // chunks:(c + 1) * n // chunks]
        mean = sum(chunk) / len(chunk)
        variance = max(sum(v * v for v in chunk) / len(chunk) - mean * mean, 0.0)
        means.append(as_float32(mean))
        deviations.append(as_float32(math.sqrt(variance)) if mean == mean else mean)
    size = min(SAMPLE, n)
    start = n // 2 - size // 2
    finite = [v for v in values if v == v]
    record.update({
        'min': as_float32(min(finite)) if finite else None,
        'max': as_float32(max(finite)) if finite else None,
        'means': means,
        'deviations': deviations,
        'sample_start': start,
        'sample': [as_float32(v) for v in values[start:start + size]],
    })
    return record


def pack(values):
    return base64.b64encode(struct.pack(f'<{len(values)}f', *values)).decode()


def unpack(text):
    data = base64.b64decode(text)
    return list(struct.unpack(f'<{len(data) // 4}f', data))


def jsonable(value):
    """NaN and infinities as strings, since JSON has no spelling for them."""
    if isinstance(value, dict):
        return {k: pack(v) if k in PACKED else jsonable(v) for k, v in value.items()}
    if isinstance(value, float) and not math.isfinite(value):
        return repr(value)
    if isinstance(value, list):
        return [jsonable(v) for v in value]
    return value


def unjsonable(value):
    if isinstance(value, str) and value in ('nan', 'inf', '-inf'):
        return float(value)
    if isinstance(value, list):
        return [unjsonable(v) for v in value]
    if isinstance(value, dict):
        return {k: unpack(v) if k in PACKED else unjsonable(v) for k, v in value.items()}
    return value


def difference(reference, actual):
    """The largest disagreement between two fingerprints, and where it is; None if they cannot
    be compared at all, with the reason."""
    for key in ('status', 'count', 'nan'):
        if reference.get(key) != actual.get(key):
            return None, f'{key} {reference.get(key)} -> {actual.get(key)}'
    worst, where = 0.0, ''
    for key in ('means', 'deviations', 'sample'):
        for index, (a, b) in enumerate(zip(reference.get(key, []), actual.get(key, []))):
            if a != a and b != b:
                continue
            delta = abs(a - b) if a == a and b == b else math.inf
            if delta > worst:
                worst, where = delta, f'{key}[{index}] {a:.9g} -> {b:.9g}'
    return worst, where


def load(path):
    with gzip.open(path, 'rt') as handle:
        return unjsonable(json.load(handle))


def save(path, document):
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(jsonable(document), sort_keys=True, separators=(',', ':'))
    # mtime 0, so the same baseline is the same bytes and git sees no change.
    with open(path, 'wb') as raw, gzip.GzipFile(fileobj=raw, mode='wb', mtime=0) as handle:
        handle.write(text.encode())


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('mode', choices=('check', 'update'))
    parser.add_argument('--backend', required=True, choices=sorted(DEFAULT_TOLERANCE))
    parser.add_argument('dumps', type=Path, help='directory of FSPY records (*.bin)')
    parser.add_argument('--tolerance', type=float,
                        help='override the recorded tolerance for this run')
    parser.add_argument('--references', type=Path, default=REFERENCES)
    args = parser.parse_args()

    records = {}
    for path in sorted(args.dumps.glob('*.bin')):
        name, mask, status, values = read_record(path)
        if name in records:
            # aot-parity resolves variants with identical selector bits to one entry, and names
            # each by its own entry, so a duplicate name is a duplicate render: keep the first.
            continue
        records[name] = fingerprint(mask, status, values)
    if not records:
        sys.exit(f'No *.bin records in {args.dumps}.')

    path = args.references / f'{args.backend}.json.gz'
    previous = load(path) if path.exists() else None

    if args.mode == 'update':
        tolerance = args.tolerance or (previous or {}).get('tolerance') \
            or DEFAULT_TOLERANCE[args.backend]
        moved = 0
        if previous:
            for name, actual in sorted(records.items()):
                reference = previous['cases'].get(name)
                if reference is None:
                    print(f'NEW      {name}')
                    continue
                worst, where = difference(reference, actual)
                if worst is None or worst > tolerance:
                    moved += 1
                    print(f'MOVED    {name}: {where if worst is None else f"{worst:.3g} at {where}"}')
            for name in sorted(set(previous['cases']) - set(records)):
                print(f'REMOVED  {name}')
        save(path, {'format': FORMAT, 'backend': args.backend, 'tolerance': tolerance,
                    'cases': records})
        print(f'Wrote {len(records)} {args.backend} fingerprints to {path.relative_to(ROOT)}'
              + (f'; {moved} moved beyond {tolerance:g}' if previous else ''))
        return

    if previous is None:
        sys.exit(f'No {args.backend} baseline at {path}. Record one with update.')
    if previous.get('format') != FORMAT:
        sys.exit(f'{path} is format {previous.get("format")}; this script reads {FORMAT}.')
    tolerance = args.tolerance or previous['tolerance']
    failures, closest, closest_name = 0, 0.0, ''
    for name, reference in sorted(previous['cases'].items()):
        actual = records.get(name)
        if actual is None:
            print(f'MISSING  {name}')
            failures += 1
            continue
        worst, where = difference(reference, actual)
        if worst is None:
            print(f'CHANGED  {name}: {where}')
            failures += 1
        elif worst > tolerance:
            print(f'DIFFER   {name}: {worst:.3g} at {where}')
            failures += 1
        elif worst > closest:
            closest, closest_name = worst, name
    for name in sorted(set(records) - set(previous['cases'])):
        print(f'NEW      {name}: not in the baseline')
        failures += 1
    print(f'{args.backend}: {len(previous["cases"])} cases, {failures} failing; '
          f'worst agreeing difference {closest:.3g} ({closest_name or "none"}), '
          f'tolerance {tolerance:g}')
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
