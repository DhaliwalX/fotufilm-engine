#!/usr/bin/env python3
"""Measure unique Fotufilm OFX frames in an already prepared Resolve Fusion clip.

Run in Resolve Studio with local scripting enabled. No mock host is involved.
The current timeline must contain the named tool on its first video clip.
"""

import argparse
import importlib
import json
import math
import os
from pathlib import Path
import statistics
import sys
import time


def resolve_module():
    root = os.environ.get("RESOLVE_SCRIPT_API")
    if root:
        sys.path.insert(0, str(Path(root) / "Modules"))
    elif sys.platform == "darwin":
        sys.path.insert(0, "/Library/Application Support/Blackmagic Design/"
                       "DaVinci Resolve/Developer/Scripting/Modules")
    return importlib.import_module("DaVinciResolveScript")


def summary(values, budget_ms):
    ordered = sorted(values)
    return {
        "mean_ms": statistics.mean(values),
        "median_ms": statistics.median(values),
        "p95_ms": ordered[math.ceil(len(ordered) * 0.95) - 1],
        "max_ms": ordered[-1],
        "budget_ms": budget_ms,
        "frames_at_or_over_budget": sum(value >= budget_ms for value in values),
        "frames_over_30fps_budget": sum(value > 1000 / 30 for value in values),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", required=True, help="Exact current project name")
    parser.add_argument("--tool", default="Fotufilm1")
    parser.add_argument("--start-frame", type=int, default=30)
    parser.add_argument("--frames", type=int, default=60)
    parser.add_argument("--warmup", type=int, default=3)
    parser.add_argument("--budget-ms", type=float, default=15.0)
    parser.add_argument("--label", required=True, help="Build and test condition")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not math.isfinite(args.budget_ms) or args.budget_ms <= 0:
        parser.error("budget-ms must be finite and positive")
    if args.frames < 1 or args.warmup < 0 or args.start_frame < 0:
        parser.error("frames must be positive; warmup and start-frame must be nonnegative")
    if args.output.exists():
        parser.error("output already exists; choose a new filename to preserve the baseline")

    resolve = resolve_module().scriptapp("Resolve")
    if resolve is None:
        raise RuntimeError("Resolve scripting is unavailable; start Resolve Studio")
    project = resolve.GetProjectManager().GetCurrentProject()
    if project is None or project.GetName() != args.project:
        raise RuntimeError("The current project does not match --project")
    timeline = project.GetCurrentTimeline()
    if timeline is None:
        raise RuntimeError("The project has no current timeline")
    settings = {key: project.GetSetting(key) for key in (
        "timelineResolutionWidth", "timelineResolutionHeight", "timelineFrameRate",
        "timelinePlaybackFrameRate", "perfRenderCacheMode", "perfProxyResolutionRatio",
    )}
    if any(float(settings[key]) != value for key, value in (
        ("timelineResolutionWidth", 3840), ("timelineResolutionHeight", 2160),
        ("timelineFrameRate", 30), ("timelinePlaybackFrameRate", 30),
    )):
        raise RuntimeError(f"Expected a 3840x2160 / 30 fps project: {settings}")
    if settings["perfRenderCacheMode"] != "none":
        raise RuntimeError("Disable Resolve render cache before measuring")
    if project.IsRenderingInProgress():
        raise RuntimeError("Wait for the active delivery render before measuring")
    clips = timeline.GetItemListInTrack("video", 1)
    if not clips:
        raise RuntimeError("The current timeline has no clip in video track 1")
    comp = clips[0].GetFusionCompByIndex(1)
    if comp is None:
        raise RuntimeError("The first video clip has no Fusion composition")
    tool = comp.FindTool(args.tool)
    if tool is None or tool.GetAttrs()["TOOLS_RegID"] not in (
        "ofx.com.fotufilm", "ofx.com.fotufilm.filmsim"
    ):
        raise RuntimeError("The named tool is not the Fotufilm OFX plugin")
    if tool.GetAttrs().get("TOOLB_PassThrough"):
        raise RuntimeError("Fotufilm is bypassed")
    source = tool.Source.GetConnectedOutput()
    if source is None:
        raise RuntimeError("Fotufilm has no connected source")
    attrs = comp.GetAttrs()
    first = args.start_frame
    end = first + args.warmup + args.frames
    if first < attrs["COMPN_GlobalStart"] or end - 1 > attrs["COMPN_GlobalEnd"]:
        raise RuntimeError("Requested frames extend beyond the composition")
    if attrs.get("COMPB_Proxy"):
        raise RuntimeError("Disable Fusion proxy rendering before measuring")

    parameters = {}
    for entry in tool.GetInputList().values():
        attr = entry.GetAttrs()
        if attr["INPS_DataType"] in ("Number", "Text"):
            value = tool.GetInput(attr["INPS_ID"], first)
            if isinstance(value, (str, int, float, bool)):
                parameters[attr["INPS_ID"]] = value

    # Timeline render-cache settings do not disable Fusion's in-memory image cache.
    # Purge it before warmup so a repeat invocation cannot report stale node timings.
    resolve.Fusion().CacheManager.Purge()
    rows = []
    for frame in range(first, end):
        began = time.perf_counter()
        image = tool.Output.GetValue(frame)
        elapsed = (time.perf_counter() - began) * 1000
        attrs = tool.GetAttrs()
        if image is None or (attrs.get("TOOLI_ImageWidth"), attrs.get("TOOLI_ImageHeight")) != (3840, 2160):
            raise RuntimeError(f"Frame {frame} did not return a 3840x2160 image")
        own_ms = attrs["TOOLN_LastFrameTime"] * 1000
        if own_ms <= 0:
            raise RuntimeError(f"Frame {frame} has no measured OFX processing time")
        if own_ms > elapsed * 1.1 + 0.2:
            raise RuntimeError(f"Frame {frame} appears cached: request completed before "
                               "the reported tool processing time")
        if frame >= first + args.warmup:
            rows.append({"frame": frame, "request_ms": elapsed, "tool_ms": own_ms})
        if len(rows) and len(rows) % 10 == 0:
            print(f"{len(rows)}/{args.frames}: tool {own_ms:.2f} ms, request {elapsed:.2f} ms", flush=True)

    result = {
        "label": args.label,
        "resolve_version": resolve.GetVersionString(),
        "host_context": "Resolve Fusion OFX",
        "measurement": "Unique sequential output requests; not timeline playback fps. "
                       "Request time includes source evaluation and scripting overhead. "
                       "Tool time is Fusion's TOOLN_LastFrameTime.",
        "warmup_frames": args.warmup,
        "project_settings": settings,
        "parameters": parameters,
        "tool": summary([row["tool_ms"] for row in rows], args.budget_ms),
        "request": summary([row["request_ms"] for row in rows], args.budget_ms),
        "frames": rows,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as output:
        json.dump(result, output, indent=2)
        output.write("\n")
    print(json.dumps({"tool": result["tool"], "request": result["request"]}, indent=2))


if __name__ == "__main__":
    main()
