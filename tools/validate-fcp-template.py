#!/usr/bin/env python3
"""Reject Motion templates that can hide controls or crash Final Cut's serializer."""

from __future__ import annotations

import argparse
import json
import struct
import sys
from pathlib import Path
from xml.etree import ElementTree


PLUGIN_UUID = "C4D9D06C-A2A7-48B4-830B-9AE81B970140"
GENERATED = Path(__file__).resolve().parents[1] / "finalcut/Generated/fxplug-parameters.json"


def generated_parameters(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def png_size(path: Path) -> tuple[int, int] | None:
    try:
        data = path.read_bytes()[:24]
    except OSError:
        return None
    if len(data) != 24 or data[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return struct.unpack(">II", data[16:24])


def validate(path: Path, require_previews: bool, generated_source: Path) -> list[str]:
    failures: list[str] = []
    try:
        root = ElementTree.parse(path).getroot()
    except (OSError, ElementTree.ParseError) as error:
        return [f"cannot parse {path}: {error}"]

    try:
        generated = generated_parameters(generated_source)
    except (OSError, UnicodeError, ValueError) as error:
        return [f"cannot read the generated parameter table {generated_source}: {error}"]
    stage_count = int(generated["textureStageCount"])
    first = int(generated["textureStageFirst"])
    limit = int(generated["textureStageLimit"])
    if first + stage_count > limit:
        return ["the texture stages exceed the reserved FxPlug parameter block"]
    texture_parameter_ids = {str(value) for value in range(first, first + stage_count)}
    public_parameter_ids = {str(value) for value in generated["public"]}
    serialized_parameter_ids = public_parameter_ids | {str(value) for value in generated["persistedOnly"]}
    parameter_paths = dict(generated["paths"])

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
        if value.isdigit() and first <= int(value) < limit
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
    published_persisted = sorted({str(value) for value in generated["persistedOnly"]} & published, key=int)
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
    parser.add_argument("--generated", type=Path, default=GENERATED)
    arguments = parser.parse_args()
    failures = validate(arguments.template, arguments.require_previews, arguments.generated)
    if failures:
        for failure in failures:
            print(f"error: {failure}", file=sys.stderr)
        return 1
    print(f"Validated {arguments.template}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
