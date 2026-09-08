#!/usr/bin/env python3
"""Verify packaged film profiles against the explicit release manifest."""
import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STOCKS = json.loads((ROOT / 'licenses/FILM-PROFILES.json').read_text())


def verify(directory):
    expected = {f'{stock}.json': ROOT / 'Sources/FotufilmCore/Stocks' / f'{stock}.json'
                for stock in STOCKS}
    expected.update({name: ROOT / 'licenses' / name
                     for name in ('FILM-PROFILES.txt', 'CC-BY-SA-4.0.txt')})
    if not directory.is_dir() or {p.name for p in directory.iterdir()} != set(expected):
        raise ValueError(f'Stocks directory must contain exactly {len(STOCKS)} profiles and two notices')
    for name, source in expected.items():
        target = directory / name
        if target.is_symlink() or not target.is_file():
            raise ValueError(f'unexpected link or directory: {name}')
        expected_hash = STOCKS[Path(name).stem] if name.endswith('.json') else hashlib.sha256(source.read_bytes()).hexdigest()
        if hashlib.sha256(target.read_bytes()).hexdigest() != expected_hash:
            raise ValueError(f'packaged file differs from the released file: {name}')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]))
    except (ValueError, OSError) as error:
        sys.exit(str(error))
    print(f'Film profiles verified: {len(STOCKS)} profiles and license notices.')
