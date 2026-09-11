#!/usr/bin/env python3
"""Generate the browser camera gamut catalog and decode reference vectors from Swift."""
import json, re, subprocess, tempfile, sys
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/FotufilmCore/CameraSourceDecode.swift').read_text()
# Compile the actual curve and matrix implementations without app/framework dependencies.
source = source[:source.index('/// The camera log encodings')]
mac = (root / 'shared/FotufilmApp/LogVideo.swift').read_text()
encodings = (root / 'Sources/FotufilmCore/CameraSourceDecode.swift').read_text().split('public enum CameraLogEncoding:')[1]
def body(name):
    return encodings.split('public var ' + name + ':')[1].split('\n    }', 1)[0]
def lookup(name):
    result = {}
    for cases, value in re.findall(r'case ([^:]+): return \.(\w+)', body(name)):
        for case in cases.split(','): result[case.strip().lstrip('.')] = value
    return result
curves, gamuts = lookup('curve'), lookup('gamut')
labels = dict(re.findall(r'case \.(\w+): return "([^"]+)"', mac.split('var title:')[1].split('var requiresExplicitDecode')[0]))
expressions=[]
for key, curve in curves.items():
    expressions.append(f'"{key}": ["curve": "{curve}", "matrix": CameraGamut.{gamuts[key]}.toRec2020, "reference": codes.map {{ CameraLogCurve.{curve}.linear($0) }}]')
source += '\nlet codes: [Float] = [-0.02, 0, 0.05, 0.092864, 0.10053777, 0.10068668, 0.16736099, 0.20855531, 0.3, 0.41, 0.5, 0.75, 0.9, 1, 1.05]\n'
source += 'let rows: [String: Any] = [' + ',\n'.join(expressions) + ']\n'
source += 'let data = try JSONSerialization.data(withJSONObject: ["codes": codes, "encodings": rows], options: [.sortedKeys])\nprint(String(data: data, encoding: .utf8)!)\n'
with tempfile.TemporaryDirectory() as tmp:
    path = Path(tmp) / 'main.swift'; path.write_text(source)
    data = json.loads(subprocess.check_output(['swift', str(path)], text=True))
for key,row in data['encodings'].items(): row['label']=labels[key]
target = root / 'web/src/generated/video-color.json'
text = json.dumps(data, indent=2, sort_keys=True)+'\n'
if '--check' in sys.argv:
    if target.read_text()!=text: sys.exit('Video color definitions are stale. Run tools/export-web-video.py.')
else: target.write_text(text)
