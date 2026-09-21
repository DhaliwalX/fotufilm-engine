#!/usr/bin/env python3
"""Refresh the editor's offline Material Symbols SVG paths from a pinned Google commit."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import urllib.request
import xml.etree.ElementTree as ET

REVISION = '27e9ef1dbeedc13d682fece4a58e1eda4cb0961a'
BASE = f'https://raw.githubusercontent.com/google/material-design-icons/{REVISION}'
SYMBOLS = {
    'film': 'camera_roll', 'develop': 'science', 'print': 'print',
    'selective': 'select_all', 'expose': 'exposure', 'open': 'add_photo_alternate',
    'minus': 'remove', 'plus': 'add', 'fit': 'fit_screen', 'undo': 'undo',
    'redo': 'redo', 'reset': 'restart_alt', 'export': 'file_export',
    'histogram': 'bar_chart', 'adjustments': 'tune', 'crop': 'crop',
    'compare': 'compare', 'sidebar': 'left_panel_open', 'inspector': 'right_panel_open',
    'more': 'more_horiz', 'close': 'close', 'search': 'search',
    'rotate': 'rotate_left', 'flip': 'flip', 'check': 'check',
    'chevronDown': 'expand_more', 'chevronLeft': 'chevron_left',
    'chevronRight': 'chevron_right', 'success': 'check_circle',
    'error': 'error', 'warning': 'warning', 'info': 'info', 'help': 'help',
}
ROOT = Path(__file__).resolve().parents[1]

def read(path):
    with urllib.request.urlopen(f'{BASE}/{path}', timeout=30) as response:
        return response.read()

def symbol(item):
    key, name = item
    root = ET.fromstring(read(f'symbols/web/{name}/materialsymbolsoutlined/{name}_24px.svg'))
    paths = []
    for element in root:
        if element.tag != '{http://www.w3.org/2000/svg}path' or set(element.attrib) != {'d'}:
            raise ValueError(f'Unexpected SVG element in {name}')
        paths.append(element.attrib['d'])
    if not paths or not root.get('viewBox'):
        raise ValueError(f'Empty symbol: {name}')
    return key, {'name': name, 'viewBox': root.get('viewBox'), 'paths': paths}

with ThreadPoolExecutor(max_workers=6) as pool:
    icons = dict(pool.map(symbol, SYMBOLS.items()))
(ROOT / 'web/src/material-symbols.json').write_text(json.dumps(icons, indent=2) + '\n')
(ROOT / 'licenses/MATERIAL-SYMBOLS-APACHE-2.0.txt').write_bytes(read('LICENSE'))
print(f'Updated {len(icons)} Material Symbols from {REVISION}')
