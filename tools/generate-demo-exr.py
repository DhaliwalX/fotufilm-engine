#!/usr/bin/env python3
"""Write the browser's original scene-linear Rec.2020 chart as float32 OpenEXR.

No display image is decoded or expanded. A continuous neutral ramp spans -8 to +8
stops around 18% gray; colored patches span -4 to +6 stops and bright discs reach 64.
OpenEXR scanline/channel layout: https://openexr.com/en/latest/OpenEXRFileLayout.html
"""
import argparse
import colorsys
from pathlib import Path
import struct


def write_exr(path, width=1600, height=900):
    def attribute(name, kind, value):
        return name.encode() + b'\0' + kind.encode() + b'\0' + struct.pack('<I', len(value)) + value

    channels = b''.join(c.encode() + b'\0' + struct.pack('<iB3xii', 2, 0, 1, 1) for c in 'BGR') + b'\0'
    box = struct.pack('<4i', 0, 0, width - 1, height - 1)
    header = struct.pack('<II', 20000630, 2)
    for name, kind, value in [
        ('channels', 'chlist', channels), ('compression', 'compression', b'\0'),
        ('dataWindow', 'box2i', box), ('displayWindow', 'box2i', box),
        ('lineOrder', 'lineOrder', b'\0'), ('pixelAspectRatio', 'float', struct.pack('<f', 1)),
        ('screenWindowCenter', 'v2f', struct.pack('<2f', 0, 0)),
        ('screenWindowWidth', 'float', struct.pack('<f', 1)),
        ('chromaticities', 'chromaticities', struct.pack('<8f', .708, .292, .170, .797, .131, .046, .3127, .3290)),
        ('comments', 'string', b'Original Fotufilm scene-linear Rec.2020 chart; 18% gray, -8 to +8 stops; no display transform.'),
    ]:
        header += attribute(name, kind, value)
    header += b'\0'
    stride = width * 12 + 8
    start = len(header) + height * 8
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('wb') as file:
        file.write(header)
        file.write(struct.pack(f'<{height}Q', *(start + y * stride for y in range(height))))
        for y in range(height):
            planes = [[], [], []]
            v = (y + .5) / height
            for x in range(width):
                u = (x + .5) / width
                rgb = (.003, .003, .003)
                if .05 <= u < .95 and .06 <= v < .60:
                    col = min(7, int((u - .05) / .9 * 8))
                    row = min(3, int((v - .06) / .54 * 4))
                    if ((u - .05) / .9 * 8) % 1 < .92 and ((v - .06) / .54 * 4) % 1 < .90:
                        rgb = tuple(c * .18 * 2 ** (-4 + row * 10 / 3) for c in colorsys.hsv_to_rgb(col / 8, .85, 1))
                if .05 <= u <= .95 and .70 <= v < .84:
                    light = .18 * 2 ** (-8 + 16 * (u - .05) / .9)
                    rgb = (light, light, light)
                if .05 <= u < .55 and .90 <= v < .97:
                    light = [0, .18, 1, 4, 16][min(4, int((u - .05) * 10))]
                    rgb = (light, light, light)
                for cx, color in [(.70, (64, 8, 2)), (.80, (4, 64, 8)), (.90, (8, 4, 64))]:
                    if ((u - cx) * width) ** 2 + ((v - .935) * height) ** 2 < (height * .027) ** 2:
                        rgb = color
                for c in range(3):
                    planes[c].append(rgb[c])
            file.write(struct.pack('<iI', y, width * 12))
            for c in [2, 1, 0]:
                file.write(struct.pack(f'<{width}f', *planes[c]))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    parser.add_argument('--size', default='1600x900')
    args = parser.parse_args()
    width, height = map(int, args.size.lower().split('x'))
    if width < 1 or height < 1 or width * height > 120_000_000:
        parser.error('Size must be positive and at most 120 megapixels.')
    write_exr(args.output, width, height)
    print(f'Wrote {width}×{height} scene-linear Rec.2020 float32 EXR: {args.output}')
