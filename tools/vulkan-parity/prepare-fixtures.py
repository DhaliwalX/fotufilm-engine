#!/usr/bin/env python3
"""Build current-ABI fixtures from the public stock definitions, never deployed packs."""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', type=Path, default=ROOT / '.build/release/fotufilm')
parser.add_argument('--output', type=Path, default=ROOT / 'build/vulkan-parity/fixtures')
parser.add_argument('--stocks', nargs='+')
args = parser.parse_args()
public = ROOT / 'Sources/FotufilmCore/Stocks'
stocks = sorted(json.loads(p.read_text())['id'] for p in public.glob('*.json'))
selected = args.stocks or stocks
if any(stock not in stocks for stock in selected):
    parser.error('Only public stock definitions are supported')
args.output.mkdir(parents=True, exist_ok=True)
for stock in selected:
    subprocess.run([str(args.cli.resolve()), '--dump-wasm-pack',
                    str((args.output / f'{stock}.pack').resolve()), '--stock', stock,
                    '--grain-model', 'standard', '--pack-size', '257x193'],
                   cwd=ROOT, env={**os.environ, "FOTUFILM_STOCKS": str(public)}, check=True)
(args.output / 'index.json').write_text(json.dumps([{'id': stock} for stock in selected], indent=2)+'\n')
