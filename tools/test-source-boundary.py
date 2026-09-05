#!/usr/bin/env python3
"""Exercise the source boundary against accidental files and production key material."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory() as temporary:
    fixture = Path(temporary)
    subprocess.run(['git', 'init', '-q', str(fixture)], check=True)
    for name in ['tools/check-source-boundary.py', 'shared/FotufilmApp/FilmPackKeyMaterial.swift']:
        path = fixture / name
        path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(root / name, path)
    (fixture / 'SOURCE_ASSETS.json').write_text('{}')
    def run(expected):
        result = subprocess.run(['python3', str(fixture / 'tools/check-source-boundary.py')],
                                capture_output=True, text=True)
        assert result.returncode == expected, result.stdout + result.stderr
    run(0)
    for name, contents in [('photo.jpg', b'private photograph'),
                           ('tools/calibration/fit.py', b'# calibration code'),
                           ('Sources/FotufilmCore/Stocks/extra.json', b'{}'),
                           ('unknown.dat', b'\x00\xffbinary'),
                           ('manufacturer.pdf', b'%PDF'),
                           ('stocks-private/test.json', b'{}'),
                           ('key.swift', b'let vault' + b'Seed = 12'),
                           ('credentials.txt', b'-----BEGIN ' + b'PRIVATE KEY-----')]:
        path = fixture / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(contents)
        run(1)
        path.unlink()
    link = fixture / 'linked-source.swift'
    link.symlink_to(root / 'Sources/FotufilmCore/FilmStock.swift')
    run(1)
    link.unlink()
    run(0)
print('Source-boundary regression checks passed.')
