#!/usr/bin/env python3
"""Export native output models as compressed differences from each browser pack."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def delta(base, target):
    header = struct.pack('<4sIII', b'FMED', 1, len(base), len(target))
    header += hashlib.sha256(base).digest() + hashlib.sha256(target).digest()
    difference = bytes(value ^ (base[i] if i < len(base) else 0)
                       for i, value in enumerate(target))
    return gzip.compress(header + difference, compresslevel=9, mtime=0)


def masks(pack):
    count, lut = struct.unpack_from('<i', pack, 24)[0], struct.unpack_from('<i', pack, 32)[0]
    values = {struct.unpack_from('<i', pack, 16)[0]}
    offset = 40 + 4 * (count + 3 * lut)
    rungs = struct.unpack_from('<i', pack, offset)[0]
    offset += 4
    for _ in range(rungs):
        _, mask, _, _, changed = struct.unpack_from('<iiIii', pack, offset)
        values.add(mask)
        offset += 20 + 8 * changed
    assert offset == len(pack)
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pack-size', default='1600x900')
    parser.add_argument('--cli', default='.build/release/fotufilm')
    parser.add_argument('--packs', type=Path, default=Path('web/public/packs'))
    args = parser.parse_args()
    cli = str(Path(args.cli).resolve())
    catalog = json.loads(subprocess.check_output([cli, '--list-web-media']))
    destination = args.packs / 'media'
    destination.mkdir(exist_ok=True)
    variants = set()
    with tempfile.TemporaryDirectory(prefix='fotufilm-media-') as temporary:
        for stock in catalog:
            stock_dir = destination / stock['id']
            stock_dir.mkdir(exist_ok=True)
            bases = {kind: (args.packs / f"{stock['id']}.{kind}").read_bytes()
                     for kind in ('pack', 'stages')}
            for medium in stock['choices']:
                if medium['id'] == stock['default']:
                    continue
                for kind in ('pack', 'stages'):
                    output = Path(temporary) / f'output.{kind}'
                    subprocess.run([cli, f'--dump-wasm-{kind}', str(output),
                                    '--stock', stock['id'], '--paper', medium['id'],
                                    '--pack-size', args.pack_size], check=True,
                                   stdout=subprocess.DEVNULL)
                    target = output.read_bytes()
                    if kind == 'pack':
                        variants.update(masks(target))
                    filename = f"{medium['id']}.{kind}.delta"
                    (stock_dir / filename).write_bytes(delta(bases[kind], target))
                    medium[kind] = f"media/{stock['id']}/{filename}"
            print(f"{stock['id']}: {len(stock['choices'])} output media", flush=True)
    # Publish the index only after every referenced asset exists.
    (args.packs / 'media.json').write_text(json.dumps(catalog, separators=(',', ':')) + '\n')
    (destination / 'masks.json').write_text(json.dumps(sorted(variants)) + '\n')


if __name__ == '__main__':
    main()
