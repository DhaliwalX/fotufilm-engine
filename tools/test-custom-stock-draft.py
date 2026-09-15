#!/usr/bin/env python3
"""Compile the shared app draft with the release engine and check spectral round trips.

Run after swift build -c release on macOS with Halide installed. This compiles the
same shared source used by the native apps, which is outside the SwiftPM library.
"""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--halide-root', type=Path, default=Path('/opt/homebrew'))
args = parser.parse_args()
build = ROOT / '.build/release'
commands = json.loads((build / 'description.json').read_text())['swiftCommands']
command = next(v for v in commands.values() if v.get('moduleName') == 'FotufilmCore')
flags = command['otherArguments']
target = []
for i, flag in enumerate(flags):
    if flag in ('-sdk', '-target'):
        target.extend(flags[i:i + 2])
objects = [p for p in (build / 'fotufilm.product/Objects.LinkFileList').read_text().splitlines()
           if '/fotufilm.build/' not in p]
output = ROOT / 'build/custom-stock-draft-check'
output.parent.mkdir(parents=True, exist_ok=True)
library = str(args.halide_root / 'lib')
subprocess.run(['swiftc', '-O', *target, '-I', str(build / 'Modules'),
    '-I', str(ROOT / 'Sources/FotufilmHalide/include'), '-L', library,
    '-lHalide', '-lc++', '-framework', 'Metal', '-framework', 'Accelerate',
    '-Xlinker', '-rpath', '-Xlinker', library, '-Xlinker', '-dead_strip',
    str(ROOT / 'shared/FotufilmApp/CustomStockDraft.swift'),
    str(ROOT / 'tools/CustomStockDraftCheck.swift'), *objects, '-o', str(output)], check=True)
subprocess.run([str(output)], check=True)
