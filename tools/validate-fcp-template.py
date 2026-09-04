#!/usr/bin/env python3
"""Reject Motion templates that can hide controls or crash Final Cut's serializer."""

from __future__ import annotations

import argparse
import re
import struct
import sys
from pathlib import Path
from xml.etree import ElementTree


PLUGIN_UUID = "C4D9D06C-A2A7-48B4-830B-9AE81B970140"
TEXTURE_STAGE_SOURCE = (
    Path(__file__).resolve().parents[1] / "Sources/FotufilmCore/PipelineStage.swift"
)
BASE_PUBLIC_PARAMETER_IDS = {
    *(str(value) for value in range(1, 26)),
    # The read-only status line. It is derived state rather than a control, but it is published
    # for the same reason every other control is: an unpublished channel is one Final Cut's
    # inspector does not draw, and a status line nobody can read is not a status line.
    "37",
    # The Lens group: three filter threads, the metering behind them, the diffusion filter, its
    # grade, and the focal length its scattering is imaged through — then the negative viewing
    # mode, which lives in Output with the rest of what happens after the film.
    *(str(value) for value in range(73, 81)),
    "10001",
}
PERSISTED_ONLY_PARAMETER_IDS = {"26", "27", "28", "29", "81", "82", "83", "84"}
BASE_PARAMETER_PATHS = {
    "1": "30/1", "2": "31/2", "3": "31/3", "5": "31/5",
    "4": "36/4", "25": "36/25", "20": "36/20", "80": "36/80",
    "6": "32/6", "7": "32/7", "8": "32/8", "9": "33/9",
    "10": "33/10", "11": "33/11", "12": "33/12", "13": "33/13",
    "14": "34/14", "15": "34/15", "16": "34/16", "17": "34/17",
    "18": "34/18", "19": "34/19", "21": "34/21", "22": "35/22",
    "23": "35/23", "24": "35/24",
    "73": "72/73", "74": "72/74", "75": "72/75", "76": "72/76",
    "77": "72/77", "78": "72/78", "79": "72/79",
    # The status line sits outside every group, because it is created before the first
    # startParameterSubGroup call: its channel path is the filter's own.
    "37": "37",
    "10001": "10001",
}


def texture_stage_count(path: Path) -> int:
    text = path.read_text(encoding="utf-8")
    ordered = re.search(
        r"public static let ordered:.*?=\s*\[(.*?)\n\s*\]", text, re.DOTALL
    )
    if ordered is None:
        raise ValueError("TextureStages.ordered was not found")
    entries = re.findall(
        r'\(\s*"[^"]+"\s*,\s*"[^"]+"\s*,\s*\.[A-Za-z][A-Za-z0-9]*\s*\)',
        ordered.group(1),
    )
    if not entries:
        raise ValueError("TextureStages.ordered contains no stages")
    return len(entries)


def png_size(path: Path) -> tuple[int, int] | None:
    try:
        data = path.read_bytes()[:24]
    except OSError:
        return None
    if len(data) != 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", data[16:24])


def validate(path: Path, require_previews: bool, texture_stages_source: Path) -> list[str]:
    failures: list[str] = []
    try:
        root = ElementTree.parse(path).getroot()
    except (OSError, ElementTree.ParseError) as error:
        return [f"cannot parse {path}: {error}"]

    try:
        stage_count = texture_stage_count(texture_stages_source)
    except (OSError, UnicodeError, ValueError) as error:
        return [f"cannot determine the engine texture stages from {texture_stages_source}: {error}"]
    if stage_count > 32:
        return ["TextureStages.ordered exceeds the reserved FxPlug parameter block 40...71"]
    texture_parameter_ids = {
        str(value) for value in range(40, 40 + stage_count)
    }
    public_parameter_ids = BASE_PUBLIC_PARAMETER_IDS | texture_parameter_ids
    serialized_parameter_ids = public_parameter_ids | PERSISTED_ONLY_PARAMETER_IDS
    parameter_paths = BASE_PARAMETER_PATHS | {
        parameter_id: f"30/{parameter_id}" for parameter_id in texture_parameter_ids
    }

    filters = [node for node in root.findall(".//filter")
               if node.get("pluginUUID") == PLUGIN_UUID]
    if len(filters) != 1:
        return [f"expected one Fotufilm filter, found {len(filters)}"]
    plugin = filters[0]

    if plugin.get("pluginDynamicParams") != "0":
        failures.append("Fotufilm filter must set pluginDynamicParams=0")
    if plugin.get("pluginName") != "FotufilmEffect":
        failures.append("Fotufilm filter must name the registered FotufilmEffect class")

    parameters = plugin.findall(".//parameter")
    parameter_ids = [node.get("id", "") for node in parameters]
    duplicates = sorted({value for value in parameter_ids if parameter_ids.count(value) > 1})
    if duplicates:
        failures.append(f"duplicate parameter ids: {', '.join(duplicates)}")
    parameter_id_set = set(parameter_ids)
    missing_parameters = sorted(serialized_parameter_ids - parameter_id_set, key=int)
    if missing_parameters:
        failures.append(f"missing serialized parameters: {', '.join(missing_parameters)}")
    serialized_texture_ids = {
        value for value in parameter_id_set
        if value.isdigit() and 40 <= int(value) < 72
    }
    extra_texture_ids = sorted(serialized_texture_ids - texture_parameter_ids, key=int)
    if extra_texture_ids:
        failures.append(
            "serialized texture parameters not present in TextureStages.ordered: "
            + ", ".join(extra_texture_ids)
        )

    plugin_id = plugin.get("id")
    targets = root.findall(".//publishSettings/target")
    published_paths = {
        node.get("channel", "").removeprefix("./")
        for node in targets
        if node.get("object") == plugin_id
    }
    published = {path.rsplit("/", 1)[-1] for path in published_paths}
    missing_targets = sorted(public_parameter_ids - published, key=int)
    if missing_targets:
        failures.append(f"unpublished parameters: {', '.join(missing_targets)}")
    published_persisted = sorted(PERSISTED_ONLY_PARAMETER_IDS & published, key=int)
    if published_persisted:
        failures.append(
            "hidden identity parameters must not be published: "
            + ", ".join(published_persisted)
        )
    unknown_targets = sorted(published - parameter_id_set, key=int)
    if unknown_targets:
        failures.append(f"published parameters have no serialized state: {', '.join(unknown_targets)}")
    wrong_paths = sorted(
        f"{parameter_id} (expected ./{expected}, found "
        + (f"./{next((path for path in published_paths if path.rsplit('/', 1)[-1] == parameter_id), '')}"
           if parameter_id in published else "no target")
        + ")"
        for parameter_id, expected in parameter_paths.items()
        if expected not in published_paths
    )
    if wrong_paths:
        failures.append("published parameter paths do not match FxPlug groups: "
                        + ", ".join(wrong_paths))

    if require_previews:
        expected = {"small.png": (192, 108), "large.png": (640, 360)}
        for name, size in expected.items():
            actual = png_size(path.with_name(name))
            if actual != size:
                failures.append(f"{name} must be a {size[0]}x{size[1]} PNG (found {actual})")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("template", type=Path)
    parser.add_argument("--require-previews", action="store_true")
    parser.add_argument("--texture-stages-source", type=Path, default=TEXTURE_STAGE_SOURCE)
    arguments = parser.parse_args()
    failures = validate(
        arguments.template, arguments.require_previews, arguments.texture_stages_source
    )
    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1
    print(f"Validated {arguments.template}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
