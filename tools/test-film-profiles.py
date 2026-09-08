#!/usr/bin/env python3
"""Exercise default resource packaging and reject extra or altered film profiles."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify_profiles', root / 'tools/verify-film-profiles.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as temporary:
    resources = Path(temporary) / 'Resources'
    env = {k: v for k, v in os.environ.items() if not k.startswith('FOTUFILM_')}
    env['FOTUFILM_SOURCE_BUILD'] = '1'
    env['FOTUFILM_PACK_KEY_SOURCE'] = str(root / 'shared/FotufilmApp/FilmPackKeyMaterial.swift')
    subprocess.run(['bash', 'tools/copy-shipping-resources.sh', str(resources)],
                   cwd=root, env=env, check=True)
    stocks = resources / 'Stocks'
    assert len(module.STOCKS) == 40
    module.verify(stocks)
    assert not list(resources.glob('*.fotufilmpack'))
    subprocess.run(['bash', 'tools/audit-apple-bundle.sh', str(resources)],
                   cwd=root, env=env, check=True)
    original = (stocks / 'portra400.json').read_bytes()
    for name, contents in [('extra.json', b'{}'), ('portra400.json', original + b' '),
                           ('nested/trace.csv', b'1,2,3')]:
        path = stocks / name
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(contents)
        try:
            module.verify(stocks)
        except ValueError:
            pass
        else:
            raise AssertionError(f'accepted altered film profiles: {name}')
        path.unlink()
        if path.parent != stocks:
            path.parent.rmdir()
        if name == 'portra400.json':
            path.write_bytes(original)
    missing = stocks / 'superia200.json'
    original_missing = missing.read_bytes()
    missing.unlink()
    try:
        module.verify(stocks)
    except ValueError:
        pass
    else:
        raise AssertionError('accepted a missing released profile')
    missing.write_bytes(original_missing)
    module.verify(stocks)
    (resources / 'fotufilm.fotufilmpack').write_bytes(b'old catalogue pack')
    result = subprocess.run(['bash', 'tools/audit-apple-bundle.sh', str(resources)],
                            cwd=root, env=env, capture_output=True)
    assert result.returncode != 0, 'accepted a sealed catalogue in the source bundle'
print('Film profile packaging regression checks passed.')
