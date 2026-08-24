#!/usr/bin/env python3
"""Bump the cache-busting version stamped on every browser-facing web asset.

Asset versions used to be per-file counters maintained by hand, which is how nine
assets ended up shipping with no version at all — they stayed stale in the
browser for the full five-minute cache lifetime after every change — while others
drifted out of step with the tests that asserted on them.

There is now a single source of truth: `ServerWebAssets.version` in
`Sources/MediaLibServer/ServerWebHTML.swift`. Every stylesheet and script URL is
built from it, so bumping this one number invalidates the whole bundle at once.

    python3 bump_versions.py          # bump by one
    python3 bump_versions.py 120      # set explicitly
"""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent
ASSETS_FILE = ROOT / "Sources" / "MediaLibServer" / "ServerWebHTML.swift"
PATTERN = re.compile(r"(static let version = )(\d+)")


def main() -> int:
    if not ASSETS_FILE.exists():
        print(f"error: {ASSETS_FILE} not found", file=sys.stderr)
        return 1

    source = ASSETS_FILE.read_text(encoding="utf-8")
    match = PATTERN.search(source)
    if match is None:
        print("error: could not find `static let version` in ServerWebAssets", file=sys.stderr)
        return 1

    current = int(match.group(2))
    if len(sys.argv) > 1:
        try:
            target = int(sys.argv[1])
        except ValueError:
            print(f"error: '{sys.argv[1]}' is not a version number", file=sys.stderr)
            return 1
    else:
        target = current + 1

    if target == current:
        print(f"web asset version already {current}")
        return 0

    ASSETS_FILE.write_text(PATTERN.sub(rf"\g<1>{target}", source, count=1), encoding="utf-8")
    print(f"web asset version {current} -> {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
