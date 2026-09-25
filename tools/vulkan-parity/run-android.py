#!/usr/bin/env python3
"""Run one process per case, recording quality limits and exact-byte diagnostics."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--adb', default=os.environ.get('ADB', 'adb'))
p.add_argument('--serial', required=True)
p.add_argument('--build', type=Path, default=ROOT / 'build/vulkan-parity/android')
p.add_argument('--report', type=Path, default=ROOT / 'build/vulkan-parity/report.json')
p.add_argument('--stocks', nargs='+', help='Default: every stock in the public index')
p.add_argument('--fixtures', type=Path, default=ROOT / 'build/vulkan-parity/fixtures')
p.add_argument('--fixture', type=Path, help='Prepared mode-specific FSWP fixture; requires one stock')
p.add_argument('--cases', nargs='+', help='Run only these cases at each selected size')
p.add_argument('--sizes', nargs='+', default=['65x49','257x193'])
p.add_argument('--stages', action='store_true', help='Add isolated stage cases on example stocks')
p.add_argument('--timeout', type=int, default=120)
p.add_argument('--exact', action='store_true', help='Require identical bytes instead of browser image-quality limits')
a = p.parse_args()
allowed = {'stock','plain','pointwise','all','annular','print','viewport','negative','negative-mono'}
allowed.update('stage-'+s for s in ['mtf','luma','halation','couplers','adjacency','grain',
                                   'mottle','disc','print-mtf','diffusion','flare','donor'])
if a.cases and any(case not in allowed for case in a.cases): p.error('Unknown case')
try:
    sizes = [tuple(map(int,size.split('x'))) for size in a.sizes]
    if any(len(size)!=2 or not all(1<=n<=4096 for n in size) for size in sizes): raise ValueError()
except ValueError: p.error('Sizes must be WIDTHxHEIGHT with dimensions from 1 to 4096')
adb = [a.adb, '-s', a.serial]
remote = '/data/local/tmp/fotufilm-parity'

def command(*args, **kw):
    return subprocess.run([*adb, *args], capture_output=True, text=True, check=True, **kw).stdout.strip()

command('get-state')
command('shell', 'mkdir', '-p', remote)
command('push', str(a.build / 'parity'), remote + '/parity')
index = json.loads((a.fixtures / 'index.json').read_text())
ids = a.stocks or [s['id'] for s in index]
if a.fixture and len(ids)!=1: p.error('--fixture requires exactly one --stocks entry')
if any(s not in {row['id'] for row in index} for s in ids):
    p.error('Only public index fixtures are supported')
results = []
report = {
    'schema': 1, 'target': (a.build / 'target.txt').read_text().strip(),
    'device': {k: command('shell', 'getprop', k) for k in
               ['ro.product.model', 'ro.build.version.release', 'ro.build.fingerprint']},
    'binary_sha256': hashlib.sha256((a.build / 'parity').read_bytes()).hexdigest(),
    'comparison': 'exact' if a.exact else 'browser image-quality limits',
    'completed': False,
    'quality_limits': {'linear_maximum': 0.0001, 'linear_rmse': 0.00001,
                       'rgba8_maximum': 1, 'rgba8_changed_fraction': 0.001, 'rgba16_maximum': 4},
    'unverified': ['Linux desktop runtime and packaging', 'video decode/playback/export',
                   'texture and split density/lighting variants', 'histogram/selective/lens helpers',
                   'all control combinations and sustained high-resolution rendering'],
    'cases': results,
}
a.report.parent.mkdir(parents=True, exist_ok=True)
for stock in ids:
    pack = a.fixture or a.fixtures / f'{stock}.pack'
    command('push', str(pack), remote + '/' + pack.name)
    cases = [(case,*size) for case in (a.cases or ['stock']) for size in sizes]
    if not a.cases and stock.startswith('example-'):
        cases += [(c,65,49) for c in ['plain','pointwise','all','annular','print','viewport','negative','negative-mono']]
    if a.stages and not a.cases and stock.startswith('example-'):
        cases += [('stage-'+stage,257,193) for stage in
                  ['mtf','luma','halation','couplers','adjacency','grain','mottle',
                   'print-mtf','diffusion','flare','donor']]
    for case, w, h in cases:
        row = {'stock': stock, 'width': w, 'height': h,
               'fixture_sha256': hashlib.sha256(pack.read_bytes()).hexdigest()}
        try:
            proc = subprocess.run([*adb,'shell', f'{remote}/parity', f'{remote}/{pack.name}',case,str(w),str(h),
                                   *(['--exact'] if a.exact else [])],
                                  capture_output=True,text=True,timeout=a.timeout)
            lines = [line for line in proc.stdout.splitlines() if line.startswith('{')]
            row.update(json.loads(lines[-1]) if lines else {'case':case,'exact':False})
            row['exit_code'] = proc.returncode
            if proc.returncode not in (0,1) or not lines: row['error'] = (proc.stderr+proc.stdout)[-4000:]
            if proc.returncode: row['exact'] = False
            row['passed'] = proc.returncode == 0 and bool(row.get('exact' if a.exact else 'quality_pass'))
        except subprocess.TimeoutExpired:
            # Terminate only this dedicated test executable before continuing on the same GPU.
            subprocess.run([*adb,'shell','pkill','-f',f'^{remote}/parity '],capture_output=True,check=False)
            row.update(case=case, exact=False, passed=False, error='timeout')
        results.append(row)
        report['exact_passes'] = sum(r['exact'] for r in results)
        report['passes'] = sum(r['passed'] for r in results)
        report['release_ready'] = False
        a.report.write_text(json.dumps(report,indent=2)+'\n')
        print(f"{stock} {case} {w}x{h}: {'PASS' if row['passed'] else 'FAIL'}",flush=True)
report['completed'] = True
report['release_ready'] = all(r['passed'] for r in results) and not report['unverified']
a.report.write_text(json.dumps(report,indent=2)+'\n')
print(f"{report['passes']}/{len(results)} passed ({report['exact_passes']} exact); report: {a.report}")
sys.exit(0 if all(r['passed'] for r in results) else 1)
