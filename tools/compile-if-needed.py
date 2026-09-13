#!/usr/bin/env python3
"""Reuse a desktop object only when its command, inputs and contents still match.

Usage: python3 tools/compile-if-needed.py xcrun swiftc ... -emit-object ... -o file.o
       python3 tools/compile-if-needed.py xcrun clang++ ... -c ... -o file.o

The compiler supplies transitive dependencies, including SDK headers. Local include
directory inventories also invalidate a hit when a new header shadows an old one.
Only compilation is cached; callers still link, assemble, audit, sign and test.
Set FOTUFILM_BUILD_CACHE=0 to force compilation, or remove the object directory.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def dependencies(path):
    # Both drivers emit Make syntax: escaped spaces, continuation lines and $$.
    result = set()
    for line in path.read_text().replace("\\\n", "").splitlines():
        if " : " in line:
            _, values = line.split(" : ", 1)
        else:
            _, values = line.split(": ", 1)
        words, word, escaped = [], [], False
        for char in values.replace("$$", "$"):
            if escaped:
                word.append(char)
                escaped = False
            elif char == "\\":
                escaped = True
            elif char.isspace():
                if word:
                    words.append("".join(word))
                    word = []
            else:
                word.append(char)
        if escaped:
            raise ValueError("incomplete dependency escape")
        if word:
            words.append("".join(word))
        result.update(words)
    if not result:
        raise ValueError("compiler emitted no dependencies")
    return sorted(result)


def inventory(command):
    directories = set()
    for index, value in enumerate(command):
        if value in ("-I", "-F"):
            directories.add(command[index + 1])
        elif value.startswith(("-I", "-F")) and len(value) > 2:
            directories.add(value[2:])
        elif Path(value).suffix in (".c", ".cpp", ".m", ".mm", ".swift"):
            directories.add(str(Path(value).parent))
    result = {}
    for name in directories:
        root = Path(name).resolve()
        result[name] = sorted(str(p.relative_to(root)) for p in root.rglob("*") if p.is_file())
    return result


def fingerprint(command, environment):
    compiler = Path(subprocess.check_output(
        ["xcrun", "--find", command[1]], env=environment, text=True).strip())
    executables = [compiler]
    if command[1] == "swiftc":
        executables.append(compiler.parent / "swift-frontend")
    compiler_identity = [[str(path.resolve()), path.stat().st_size, path.stat().st_mtime_ns]
                         for path in executables]
    # Never store environment values (which can contain credentials) in the stamp.
    env = {key: value for key, value in environment.items()
           if key not in ("_", "SHLVL", "OLDPWD", "FOTUFILM_BUILD_CACHE")}
    value = {"helper": digest(__file__), "cwd": str(Path.cwd()), "command": command,
             "compiler": compiler_identity,
             "environment": env, "includes": inventory(command)}
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def run(command):
    if len(command) < 3 or command[:1] != ["xcrun"] or command[1] not in ("swiftc", "clang", "clang++"):
        raise ValueError("expected xcrun swiftc, clang or clang++")
    swift = command[1] == "swiftc"
    if ("-emit-object" if swift else "-c") not in command:
        raise ValueError("only object compilation can be cached")
    output = Path(command[command.index("-o") + 1])
    depfile = output.with_suffix(".d")
    stamp = output.with_suffix(".compile.json")
    output.parent.mkdir(parents=True, exist_ok=True)
    environment = dict(os.environ)
    # Apple's python3 launcher can inject the Command Line Tools SDK. Use the
    # SDK already selected by the calling build script for all compiler children.
    sdk_flag = "-sdk" if swift else "-isysroot"
    if sdk_flag in command:
        environment["SDKROOT"] = command[command.index(sdk_flag) + 1]
    with output.with_suffix(".compile.lock").open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        key = fingerprint(command, environment)
        try:
            record = json.loads(stamp.read_text())
            if (environment.get("FOTUFILM_BUILD_CACHE") != "0" and record["key"] == key
                    and record["output"] == digest(output)
                    and all(digest(path) == checksum for path, checksum in record["inputs"].items())):
                print("Reusing " + str(output), flush=True)
                return 0
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            pass
        stamp.unlink(missing_ok=True)
        depfile.unlink(missing_ok=True)
        started = time.time_ns()
        if swift:
            outputs = output.with_suffix(".compile-outputs.json")
            outputs.write_text(json.dumps({"": {"dependencies": str(depfile)}}))
            flags = ["-emit-dependencies", "-track-system-dependencies",
                     "-output-file-map", str(outputs)]
        else:
            flags = ["-MD", "-MF", str(depfile)]
        result = subprocess.run(command + flags, env=environment)
        if result.returncode:
            return result.returncode
        inputs = dependencies(depfile)
        # A concurrent edit during compilation must never bless an older object.
        # A subsequent invocation can compile and establish a stable stamp.
        record = {"key": key, "output": digest(output),
                  "inputs": {path: digest(path) for path in inputs}}
        if any(Path(path).stat().st_mtime_ns >= started for path in inputs):
            return 0
        temporary = stamp.with_suffix(".tmp")
        temporary.write_text(json.dumps(record, sort_keys=True) + "\n")
        temporary.replace(stamp)
        return 0


if __name__ == "__main__":
    try:
        sys.exit(run(sys.argv[1:]))
    except (OSError, ValueError) as error:
        print("error: compile reuse: " + str(error), file=sys.stderr)
        sys.exit(1)
