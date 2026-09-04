#!/usr/bin/env python3
"""Check source candidates, including untracked files, before an engine commit."""
from pathlib import Path
import hashlib
import json
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
ASSETS = json.loads((ROOT / 'SOURCE_ASSETS.json').read_text())
PUBLIC_KEY = ROOT / 'shared/FotufilmApp/FilmPackKeyMaterial.swift'
DENIED = ('stocks-private/', 'research/', 'ios/', 'ios-uikit/', 'android/',
          'license-server/', 'tools/calibration/', 'docs/calibration/', 'docs/accuracy/')
DENIED_NAMES = {'MeasuredSpectra.swift', 'CalibrationTests.swift',
                'EnduraPremierPaperSpectra.swift', 'CrystalArchivePaperSpectra.swift',
                'Vision2383PrintSpectra.swift', 'Vision2393PrintSpectra.swift',
                'EternaCPPrintSpectra.swift', 'accuracy-baseline.json'}
BINARY_SUFFIXES = {'.png', '.jpg', '.jpeg', '.heic', '.tif', '.tiff', '.exr', '.mp4',
                   '.mov', '.pdf', '.ps', '.zip', '.dmg', '.pkg', '.coeff', '.svg', '.moef',
                   '.webp', '.gif', '.avif', '.bmp', '.dng', '.cr2', '.nef', '.arw', '.raf'}
SECRET = re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----|'
                    r'\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_[A-Za-z0-9_]{30,}|'
                    r'\bAKIA[A-Z0-9]{16}\b|\bAIza[A-Za-z0-9_-]{35}\b')

def candidates():
    data = subprocess.check_output(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT)
    return sorted(set(data.decode().rstrip('\0').split('\0')))

def check():
    errors = []
    for name in candidates():
        if not name:
            continue
        path = ROOT / name
        if not path.exists():
            continue  # A deletion is safe; git diff still presents it for review.
        if name == 'third_party/Halide' and path.is_dir():
            continue  # Public upstream submodule, not vendored SDK material.
        if name.startswith(DENIED) or path.name in DENIED_NAMES:
            errors.append(f'private path: {name}')
        if path.is_symlink() or not path.is_file():
            errors.append(f'unexpected link or directory: {name}')
            continue
        raw = path.read_bytes()
        if path.suffix in {'.fotufilmpack', '.pack', '.stages', '.p12', '.mobileprovision', '.pdf', '.ps'}:
            errors.append(f'private or generated artifact: {name}')
        try:
            raw.decode('utf-8')
            is_binary = b'\0' in raw
        except UnicodeDecodeError:
            is_binary = True
        needs_provenance = (is_binary or path.suffix.lower() in BINARY_SUFFIXES
                            or name.startswith('Sources/FotufilmCore/CameraProfiles/')
                            or name.startswith('Sources/FotufilmCore/Stocks/')
                            or name.startswith('resolve/openfx/'))
        if needs_provenance:
            record = ASSETS.get(name)
            if not record or record['sha256'] != hashlib.sha256(raw).hexdigest():
                errors.append(f'asset needs provenance review: {name}')
        if name.startswith('Sources/FotufilmCore/Stocks/') and path.suffix == '.json':
            pack = json.loads(raw)
            if not pack.get('isExample') or not pack.get('id', '').startswith('example-'):
                errors.append(f'non-example stock: {name}')
        if b'\0' not in raw:
            text = raw.decode('utf-8', errors='replace')
            if SECRET.search(text):
                errors.append(f'credential signature: {name}')
            if re.search(r'/Users/(?!license-test\b)[A-Za-z0-9._-]+/', text):
                errors.append(f'personal absolute path: {name}')
            if re.search(r'\b(?:vault|community)(?:Seed|Words|A|B)\b', text):
                errors.append(f'encoded production pack material: {name}')
    key = PUBLIC_KEY.read_text()
    if 'vaultKeyID: UInt16 = 0' not in key or 'repeating: 0, count: 32' not in key:
        errors.append('public example key was replaced')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
        return 1
    print('Source boundary passed: no denied files, credential signatures, or unreviewed assets.')
    return 0

if __name__ == '__main__':
    sys.exit(check())
