#!/usr/bin/env python3
"""Check CMY persistence and reset against production app sources after a release build."""
from pathlib import Path
import os
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
build = root / ".build/out/Products/Release"
targets = ["FotufilmCore", "FotufilmImaging", "FotufilmHalide", "FotufilmEditModel"]
if build.is_dir():
    modules = build
    objects = [str(build / (target + ".o")) for target in targets]
else:
    build = root / ".build/release"
    modules = build / "Modules"
    objects = [path for path in shlex.split((build / "fotufilm.product/Objects.LinkFileList").read_text())
               if any(f"/{target}.build/" in path for target in targets)]
halide = Path(os.environ.get("HALIDE_ROOT", "/opt/homebrew"))
sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
files = ["macos/Tests/ScreenCMYEdit.swift", "shared/FotufilmApp/EditState.swift",
         "shared/FotufilmApp/EditControlAccess.swift", "shared/FotufilmApp/EditStateCodable.swift",
         "shared/FotufilmApp/FilterChoice.swift", "shared/FotufilmApp/SelectiveState.swift",
         "shared/FotufilmApp/UndertoneAxis.swift"]
with tempfile.TemporaryDirectory(prefix="fotufilm-cmy-edit-") as directory:
    executable = Path(directory) / "check"
    for bundle in build.glob("*.bundle"):
        (Path(directory) / bundle.name).symlink_to(bundle.resolve())
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-sdk", sdk,
                    "-I", str(modules), "-I", str(root / "Sources/FotufilmHalide/include"),
                    "-L", str(halide / "lib"), "-lHalide", "-lc++",
                    "-Xlinker", "-rpath", "-Xlinker", str(halide / "lib"),
                    "-framework", "Metal", "-framework", "Accelerate",
                    *[str(root / path) for path in files], *objects, "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
