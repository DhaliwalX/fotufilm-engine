#!/usr/bin/env python3
"""Build Fotufilm's glyphs for every platform from one set of centre-line sources.

Sources in shared/Glyphs/sources are 24-unit SVGs whose elements name their layer (primary,
secondary, tertiary), mode (stroke or fill) and optional system colour. From them this writes:

  * shared/Glyphs/Glyphs.xcassets, custom SF Symbols in nine weights and three scales for the
    iOS and macOS apps and the Final Cut extension,
  * web/public/glyphs, outlined 24-unit SVGs and one sprite for the web and anything else that
    reads SVG,
  * shared/Glyphs/glyphs.json, the manifest naming every glyph, its rendering and the slider pairs.

It also records every glyph SVG, source and output, in SOURCE_ASSETS.json.

Needs picosvg (pip install picosvg). Run with --check to fail when the outputs are stale.
"""
import argparse
import filecmp
import hashlib
import json
import shutil
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

import pathops
from picosvg.svg_pathops import skia_path, svg_commands
from picosvg.svg_transform import Affine2D, parse_svg_transform
from picosvg.svg_types import SVGCircle, SVGEllipse, SVGLine, SVGPath, SVGRect

ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "shared/Glyphs/sources"
CATALOG = ROOT / "shared/Glyphs/Glyphs.xcassets"
MANIFEST = ROOT / "shared/Glyphs/glyphs.json"
WEB = ROOT / "web/public/glyphs"
ASSETS = ROOT / "SOURCE_ASSETS.json"
# Every output carries the glyph licence; see licenses/GLYPHS.txt.
NOTICE = "Fotufilm glyphs, Copyright 2026 MUAStudio Inc., CC BY-SA 4.0 (https://creativecommons.org/licenses/by-sa/4.0/), https://fotufilm.com, see licenses/GLYPHS.txt"
LICENSE = {"spdx": "CC-BY-SA-4.0", "url": "https://creativecommons.org/licenses/by-sa/4.0/", "attribution": "Fotufilm (https://fotufilm.com)",
           "copyright": "Copyright 2026 MUAStudio Inc.", "notice": "licenses/GLYPHS.txt"}

# Stroke width in grid units for each SF weight, measured against SF's own circle at 100 pt
# (2.25, 8.25 and 17.25 units at Ultralight, Regular and Black). Black stops short of SF's so
# perforations and the reel's spiral stay open. Sources are drawn with 1.5-unit strokes.
WEIGHTS = {"Ultralight": 0.45, "Thin": 0.7, "Light": 1.1, "Regular": 1.6, "Medium": 1.85,
           "Semibold": 2.1, "Bold": 2.4, "Heavy": 2.7, "Black": 3.0}
DRAWN = 1.5
# Template units per grid unit at medium scale (an r = 9 circle matches SF's circle, 98 units
# across at 100 pt), and the small/large ratios SF Symbols uses.
UNIT = 5.0
SCALES = {"S": 0.783, "M": 1.0, "L": 1.29}
BASELINES = {"S": 696.0, "M": 1126.0, "L": 1556.0}
CAP_HEIGHT = 70.46
COLUMN0, COLUMN_STEP = 559.711, 296.711
SYSTEM_HEX = {
    "systemRed": "#FF453A", "systemOrange": "#FF9F0A", "systemYellow": "#FFD60A", "systemGreen": "#30D158",
    "systemCyan": "#64D2FF", "systemBlue": "#0A84FF", "systemPurple": "#BF5AF2", "systemPink": "#FF375F",
}


def shape_path(el):
    a = el.attrib
    f = lambda k, d=0.0: float(a.get(k, d))
    tag = el.tag.split("}")[-1]
    if tag == "circle":
        shape = SVGCircle(cx=f("cx"), cy=f("cy"), r=f("r"))
    elif tag == "ellipse":
        shape = SVGEllipse(cx=f("cx"), cy=f("cy"), rx=f("rx"), ry=f("ry"))
    elif tag == "rect":
        rx = f("rx", a.get("ry", 0))
        shape = SVGRect(x=f("x"), y=f("y"), width=f("width"), height=f("height"), rx=rx, ry=f("ry", rx))
    elif tag == "line":
        shape = SVGLine(x1=f("x1"), y1=f("y1"), x2=f("x2"), y2=f("y2"))
    elif tag == "path":
        shape = SVGPath(d=a["d"])
    else:
        raise ValueError(f"unsupported element {tag}")
    path = shape.as_path() if not isinstance(shape, SVGPath) else shape
    if "transform" in a:
        path = path.apply_transform(parse_svg_transform(a["transform"]))
    return path.absolute().arcs_to_cubics()


def element_outline(el, weight_width):
    """The element as a filled skia path in grid units at one stroke weight."""
    path = shape_path(el)
    rule = el.attrib.get("fill-rule", "nonzero")
    sk = skia_path(path.as_cmd_seq(), rule)
    if el.attrib["data-mode"] == "stroke":
        width = float(el.attrib.get("stroke-width", DRAWN)) * weight_width / DRAWN
        dash = el.attrib.get("stroke-dasharray")
        dashes = [max(float(v), 0.001) for v in dash.replace(",", " ").split()] if dash else None
        sk.stroke(width, pathops.LineCap.ROUND_CAP, pathops.LineJoin.ROUND_JOIN, 4,
                  dash_array=dashes, dash_offset=-float(el.attrib.get("stroke-dashoffset", 0)))
        sk.convertConicsToQuads()
    return sk


def layers(source, weight_width):
    """Consecutive elements sharing layer, colour and opacity, each unioned into one path."""
    out = []
    for el in source:
        key = (el.attrib["data-layer"], el.attrib.get("data-colour"), float(el.attrib.get("opacity", 1)))
        sk = element_outline(el, weight_width)
        if out and out[-1]["key"] == key:
            out[-1]["paths"].append(sk)
        else:
            out.append({"key": key, "paths": [sk]})
    for layer in out:
        builder = pathops.OpBuilder(fix_winding=True)
        for sk in layer["paths"]:
            builder.add(sk, pathops.PathOp.UNION)
        layer["path"] = builder.resolve()
    return out


def bounds(paths):
    xs, ys = [], []
    for p in paths:
        if not p.bounds or p.bounds == (0, 0, 0, 0):
            continue
        x0, y0, x1, y1 = p.bounds
        xs += [x0, x1]
        ys += [y0, y1]
    return min(xs), min(ys), max(xs), max(ys)


def to_d(sk, transform):
    path = SVGPath.from_commands(svg_commands(sk)).apply_transform(transform)
    return path.round_floats(3).d


def template(name, source):
    style, guides, groups, classes = [], [], [], None
    for w_index, (weight, width) in enumerate(WEIGHTS.items()):
        built = layers(source, width)
        if classes is None:
            classes = [layer["key"] for layer in built]
            for i, (level, colour, opacity) in enumerate(classes):
                o = f"opacity:{opacity:.3f};" if opacity < 1 else ""
                tint = f"{colour}Color" if colour else "labelColor"
                style.append(f".monochrome-{i} {{{o}}}")
                style.append(f".multicolor-{i}:{tint} {{{o}}}")
                style.append(f".hierarchical-{i}:{level} {{}}")
        x0, _, x1, _ = bounds([layer["path"] for layer in built])
        for scale, factor in SCALES.items():
            k = UNIT * factor
            ink = (x1 - x0) * k
            left = COLUMN0 + w_index * COLUMN_STEP - ink / 2
            # Grid centre sits on the middle of the cap height, the way SF Symbols centre on text.
            place = Affine2D(k, 0, 0, k, -x0 * k, -12 * k - CAP_HEIGHT / 2)
            paths = []
            for i, layer in enumerate(built):
                level, colour, _ = layer["key"]
                tint = f"{colour}Color" if colour else "labelColor"
                paths.append(f'   <path class="monochrome-{i} multicolor-{i}:{tint} hierarchical-{i}:{level} '
                             f'SFSymbolsPreviewWireframe" d="{to_d(layer["path"], place)}"/>')
            groups.append(f'  <g id="{weight}-{scale}" transform="matrix(1 0 0 1 {left:.3f} {BASELINES[scale]:.0f})">\n'
                          + "\n".join(paths) + "\n  </g>")
            top, bottom = BASELINES[scale] - 95, BASELINES[scale] + 25
            guides.append(f'  <line id="left-margin-{weight}-{scale}" style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;" '
                          f'x1="{left:.3f}" x2="{left:.3f}" y1="{top}" y2="{bottom}"/>')
            guides.append(f'  <line id="right-margin-{weight}-{scale}" style="fill:none;stroke:#FF3B30;stroke-width:0.5;opacity:1.0;" '
                          f'x1="{left + ink:.3f}" x2="{left + ink:.3f}" y1="{top}" y2="{bottom}"/>')
    lines = "\n".join(
        f'  <line id="Baseline-{s}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{b:.0f}" y2="{b:.0f}"/>\n'
        f'  <line id="Capline-{s}" style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;" x1="263" x2="3036" y1="{b - CAP_HEIGHT:.2f}" y2="{b - CAP_HEIGHT:.2f}"/>'
        for s, b in BASELINES.items())
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 3300 2200">
 <!--glyph: "{name}", generated by tools/build-glyphs.py. {NOTICE}-->
 <style>{chr(10).join(style)}
.SFSymbolsPreviewWireframe {{fill:none;opacity:1.0;stroke:black;stroke-width:0.5}}
</style>
 <g id="Notes">
  <rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
  <text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1933)">Template v.6.0</text>
  <text id="descriptive-name" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;text-anchor:end;" transform="matrix(1 0 0 1 3036 1969)">{name}</text>
 </g>
 <g id="Guides">
{lines}
{chr(10).join(guides)}
 </g>
 <g id="Symbols">
{chr(10).join(groups)}
 </g>
</svg>
'''


def web(name, source):
    """An outlined 24-unit SVG at Regular weight: currentColor, layer opacity, system colours."""
    parts = []
    for layer in layers(source, WEIGHTS["Regular"]):
        level, colour, opacity = layer["key"]
        fill = f'var(--fotu-{colour}, {SYSTEM_HEX[colour]})' if colour else "currentColor"
        o = f' opacity="{opacity:g}"' if opacity < 1 else ""
        parts.append(f'<path fill="{fill}"{o} data-layer="{level}" d="{to_d(layer["path"], Affine2D.identity())}"/>')
    return parts


def build(catalog, manifest_path, web_dir):
    catalog.mkdir(parents=True, exist_ok=True)
    web_dir.mkdir(parents=True, exist_ok=True)
    (catalog / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    manifest, sprite = {"glyphs": {}, "license": LICENSE, "sliders": {}}, []
    for file in sorted(SOURCES.glob("*.svg")):
        name = file.stem
        source = list(ET.parse(file).getroot())
        symbolset = catalog / f"{name}.symbolset"
        symbolset.mkdir(exist_ok=True)
        (symbolset / f"{name}.svg").write_text(template(name, source))
        (symbolset / "Contents.json").write_text(json.dumps({
            "info": {"author": "xcode", "version": 1},
            "symbols": [{"filename": f"{name}.svg", "idiom": "universal"}]}, indent=2) + "\n")
        parts = web(name, source)
        (web_dir / f"{name}.svg").write_text(
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24"><!-- {NOTICE} -->' + "".join(parts) + "</svg>\n")
        sprite.append(f'<symbol id="{name}" viewBox="0 0 24 24">' + "".join(parts) + "</symbol>")
        colours = sorted({el.attrib["data-colour"] for el in source if "data-colour" in el.attrib})
        manifest["glyphs"][name] = {"rendering": "multicolor" if colours else "hierarchical", "colours": colours}
        if name.startswith("fotu.slider.") and name.endswith(".low"):
            field = name[len("fotu.slider."):-len(".low")]
            manifest["sliders"][field] = {"low": name, "high": f"fotu.slider.{field}.high"}
    (web_dir / "glyphs.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" style="display:none">\n<!-- {NOTICE} -->\n' + "\n".join(sprite) + "\n</svg>\n")
    manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    return manifest


def asset_records():
    """SOURCE_ASSETS.json entries for every glyph SVG on disk, sources first."""
    provenance = {
        SOURCES: "Fotufilm glyph source, drawn for this project; CC BY-SA 4.0, see licenses/GLYPHS.txt.",
        CATALOG: "Generated by tools/build-glyphs.py from shared/Glyphs/sources; CC BY-SA 4.0, see licenses/GLYPHS.txt.",
        WEB: "Generated by tools/build-glyphs.py from shared/Glyphs/sources; CC BY-SA 4.0, see licenses/GLYPHS.txt.",
    }
    records = {}
    for folder, text in provenance.items():
        for path in sorted(folder.rglob("*.svg")):
            records[str(path.relative_to(ROOT))] = {
                "provenance": text, "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}
    return records


def is_glyph_asset(name):
    return any(name.startswith(str(folder.relative_to(ROOT)) + "/") for folder in (SOURCES, CATALOG, WEB))


def same_tree(a, b):
    compare = filecmp.dircmp(a, b)
    if compare.left_only or compare.right_only or compare.diff_files or compare.funny_files:
        return False
    return all(same_tree(a / sub, b / sub) for sub in compare.common_dirs)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="fail if the committed outputs differ from the sources")
    args = parser.parse_args()
    if args.check:
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            build(tmp / "Glyphs.xcassets", tmp / "glyphs.json", tmp / "web")
            stale = [str(path.relative_to(ROOT)) for path, fresh in
                     [(CATALOG, tmp / "Glyphs.xcassets"), (WEB, tmp / "web")] if not path.exists() or not same_tree(path, fresh)]
            if not MANIFEST.exists() or not filecmp.cmp(MANIFEST, tmp / "glyphs.json", shallow=False):
                stale.append(str(MANIFEST.relative_to(ROOT)))
        recorded = {k: v for k, v in json.loads(ASSETS.read_text()).items() if is_glyph_asset(k)}
        if recorded != asset_records():
            stale.append(str(ASSETS.relative_to(ROOT)))
        if stale:
            sys.exit("stale glyph outputs, run tools/build-glyphs.py: " + ", ".join(stale))
        print("glyph outputs are current")
        return
    for path in (CATALOG, WEB):
        shutil.rmtree(path, ignore_errors=True)
    manifest = build(CATALOG, MANIFEST, WEB)
    assets = {k: v for k, v in json.loads(ASSETS.read_text()).items() if not is_glyph_asset(k)}
    ASSETS.write_text(json.dumps(assets | asset_records(), indent=2) + "\n")
    print(f"{len(manifest['glyphs'])} glyphs, {len(manifest['sliders'])} slider pairs")


if __name__ == "__main__":
    main()
