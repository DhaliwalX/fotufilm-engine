#!/usr/bin/env python3
"""Exercise default resource packaging and reject extra or altered Starter files."""
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('verify_starter', root / 'tools/verify-starter-pack.py')
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
    module.verify(stocks)
    assert not list(resources.glob('*.fotufilmpack'))
    subprocess.run(['bash', 'tools/audit-apple-bundle.sh', str(resources)],
                   cwd=root, env=env, check=True)
    original = (stocks / 'gold200.json').read_bytes()
    for name, contents in [('extra.json', b'{}'), ('gold200.json', original + b' '),
                           ('nested/trace.csv', b'1,2,3')]:
        path = stocks / name
        path.parent.mkdir(exist_ok=True)
        path.write_bytes(contents)
        try:
            module.verify(stocks)
        except ValueError:
            pass
        else:
            raise AssertionError(f'accepted altered Starter pack: {name}')
        path.unlink()
        if path.parent != stocks:
            path.parent.rmdir()
        if name == 'gold200.json':
            path.write_bytes(original)
    module.verify(stocks)
    (resources / 'fotufilm.fotufilmpack').write_bytes(b'old catalogue pack')
    result = subprocess.run(['bash', 'tools/audit-apple-bundle.sh', str(resources)],
                            cwd=root, env=env, capture_output=True)
    assert result.returncode != 0, 'accepted a sealed catalogue in the Starter bundle'
print('Starter packaging regression checks passed.')
