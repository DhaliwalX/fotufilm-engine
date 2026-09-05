#!/usr/bin/env python3
"""Verify a packaged Starter directory contains exactly the released files."""
import hashlib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STOCKS = ('gold200', 'trix400', 'provia100f')


def verify(directory):
    expected = {f'{stock}.json': ROOT / 'Sources/FotufilmCore/Stocks' / f'{stock}.json'
                for stock in STOCKS}
    expected.update({name: ROOT / 'licenses' / name
                     for name in ('STARTER-PACK.txt', 'CC-BY-ND-4.0.txt')})
    if not directory.is_dir() or {p.name for p in directory.iterdir()} != set(expected):
        raise ValueError('Starter directory must contain exactly three profiles and two notices')
    for name, source in expected.items():
        target = directory / name
        if target.is_symlink() or not target.is_file():
            raise ValueError(f'unexpected link or directory: {name}')
        if hashlib.sha256(target.read_bytes()).digest() != hashlib.sha256(source.read_bytes()).digest():
            raise ValueError(f'packaged file differs from the released Starter file: {name}')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]))
    except (ValueError, OSError) as error:
        sys.exit(str(error))
    print('Starter pack verified: three profiles and license notices.')
