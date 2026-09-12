#!/usr/bin/env python3
"""Run edit-state checks against the release modules and production app sources."""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
build = root / '.build/release'
with tempfile.TemporaryDirectory(prefix='fotufilm-halation-edit-') as directory:
    temporary = Path(directory)
    objects = [line for line in (build / 'fotufilm.product/Objects.LinkFileList').read_text().splitlines()
               if any(f'/{target}.build/' in line for target in
                      ['FotufilmCore', 'FotufilmImaging', 'FotufilmHalide', 'FotufilmEditModel'])]
    halide = Path(os.environ.get('HALIDE_ROOT', '/opt/homebrew'))
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    executable = temporary / 'check'
    files = ['macos/Tests/HalationReturnEdit.swift', 'shared/FotufilmApp/EditState.swift',
             'shared/FotufilmApp/EditControlAccess.swift', 'shared/FotufilmApp/EditStateCodable.swift', 'shared/FotufilmApp/FilterChoice.swift',
             'shared/FotufilmApp/ProAccess.swift', 'shared/FotufilmApp/SelectiveState.swift', 'shared/FotufilmApp/UndertoneAxis.swift']
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-sdk', sdk,
                    '-I', str(build / 'Modules'), '-I', str(root / 'Sources/FotufilmHalide/include'),
                    '-L', str(halide / 'lib'), '-lHalide', '-lc++',
                    '-Xlinker', '-rpath', '-Xlinker', str(halide / 'lib'),
                    '-framework', 'Metal', '-framework', 'Accelerate',
                    *[str(root / p) for p in files], *objects,
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
