#!/usr/bin/env python3
"""Keep the complete AOT releases required by current main, one per Apple target."""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "DhaliwalX/fotufilm-engine"
PLATFORMS = ("device", "simulator", "macos", "macos-intel")
AOT_TAG = re.compile(r"aot-(?:device|simulator|macos|macos-intel)-[0-9a-f]{16}\Z")
ASSETS = {"aot-manifest.json", "kernels.tar.gz", "kernels.tar.gz.sha256"}


def obsolete_releases(releases, required):
    """Never prune while any replacement is absent, a draft or incomplete."""
    by_tag = {release["tag_name"]: release for release in releases}
    for tag in required:
        release = by_tag.get(tag)
        if not release or release["draft"]:
            raise ValueError(f"Current AOT release is not published: {tag}")
        assets = release.get("assets", [])
        if ({asset["name"] for asset in assets} != ASSETS
                or any(asset.get("state") != "uploaded" or asset.get("size", 0) <= 0
                       for asset in assets)):
            raise ValueError(f"Current AOT release is incomplete: {tag}")
    return sorted(tag for tag, release in by_tag.items()
                  if AOT_TAG.fullmatch(tag) and tag not in required and not release["draft"])


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Delete obsolete release entries; retain Git tags")
    args = parser.parse_args()
    # Compute expected tags from current main, never an older manual workflow run.
    run("git", "fetch", "--quiet", "origin", "main")
    if run("git", "rev-parse", "HEAD") != run("git", "rev-parse", "origin/main"):
        raise SystemExit("AOT retention must run from current engine main.")
    if run("git", "status", "--porcelain"):
        raise SystemExit("AOT retention requires a clean checkout.")
    required = {run("python3", "tools/aot-release.py", "tag", platform) for platform in PLATFORMS}
    pages = json.loads(run("gh", "api", "--paginate", "--slurp",
                           f"repos/{REPOSITORY}/releases?per_page=100"))
    try:
        obsolete = obsolete_releases([release for page in pages for release in page], required)
    except ValueError as error:
        print(f"Retention deferred: {error}")
        return
    print("Keeping " + ", ".join(sorted(required)))
    for tag in obsolete:
        print(("Deleting " if args.apply else "Would delete ") + tag, flush=True)
        if args.apply:
            subprocess.run(["gh", "release", "delete", tag, "--repo", REPOSITORY, "--yes"],
                           cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
