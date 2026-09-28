#!/usr/bin/env python3
"""Scan bundle contents for local paths without launching a process for each file."""
import mmap
import os
from pathlib import Path
import re
import sys


# Search bytes directly, including UTF-8 names that strings(1) can split. A NUL
# terminates a string; a slash must finish the user component to identify a path. A home
# directory starts a path, so /home inside a URL or a longer path (example.net/home/privacy/)
# is not one, and a user name holds no quote, bracket or code punctuation (an emscripten
# runtime's FS.mkdir("/home/web_user")},... is not a path either).
LOCAL_PATH = re.compile(
    rb"(?<![\w.\-/])/(?:Users|home)/[^/\x00\"'`(){}\[\];,<>|\s]+/|/\.claude/worktrees/")


def audit(bundle):
    def unreadable(error):
        raise error

    failed = False
    for directory, _, names in os.walk(bundle, onerror=unreadable):
        for name in names:
            path = Path(directory) / name
            # Match find -type f: do not follow symlinks or read special files.
            if path.is_symlink() or not path.is_file():
                continue
            with path.open("rb") as source:
                if not os.fstat(source.fileno()).st_size:
                    continue
                # Mapping avoids copying large executables and finds paths across
                # page boundaries without imposing a maximum user-name length.
                with mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as contents:
                    if LOCAL_PATH.search(contents):
                        print(f"error: local build path in {path}", file=sys.stderr)
                        failed = True
    return not failed


if __name__ == "__main__":
    if len(sys.argv) != 2 or not Path(sys.argv[1]).is_dir():
        sys.exit("usage: audit-bundle-paths.py <bundle-directory>")
    try:
        sys.exit(0 if audit(sys.argv[1]) else 1)
    except OSError as error:
        sys.exit(f"error: cannot audit bundle paths: {error}")
