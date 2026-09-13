#!/usr/bin/env python3
"""Generate or verify the inventory of the final, signed app's runtime files."""

import hashlib
import json
import pathlib
import sys


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def runtime_files(app):
    files = []
    for directory in (app / "Contents/MacOS", app / "Contents/Frameworks"):
        if not directory.is_dir():
            raise ValueError(f"missing runtime directory: {directory}")
        for path in directory.rglob("*"):
            if path.is_file() and not path.is_symlink():
                files.append(path.relative_to(app).as_posix())
    return sorted(files)


def inventory_bytes(app):
    return "".join(
        f"{sha256(app / relative)}  {relative}\n"
        for relative in runtime_files(app)
    ).encode("utf-8")


def verify(app, inventory, manifest):
    contents = inventory.read_bytes()
    metadata = json.loads(manifest.read_text(encoding="utf-8"))
    if hashlib.sha256(contents).hexdigest() != metadata.get("dependencyDigest"):
        raise ValueError("manifest dependency digest does not match inventory")

    expected = {}
    for line in contents.decode("utf-8").splitlines():
        digest, separator, relative = line.partition("  ")
        parts = pathlib.PurePosixPath(relative).parts
        if (
            not separator
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
            or not parts
            or parts[0] != "Contents"
            or ".." in parts
            or relative in expected
        ):
            raise ValueError(f"invalid inventory row: {line}")
        expected[relative] = digest

    actual = runtime_files(app)
    if sorted(expected) != actual:
        raise ValueError("inventory file set differs from signed app runtime files")
    for relative in actual:
        if sha256(app / relative) != expected[relative]:
            raise ValueError(f"signed runtime file differs from inventory: {relative}")
    print(f"dependency-inventory: verified {len(actual)} signed runtime files")


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "generate":
        app = pathlib.Path(sys.argv[2])
        pathlib.Path(sys.argv[3]).write_bytes(inventory_bytes(app))
    elif len(sys.argv) == 5 and sys.argv[1] == "verify":
        verify(pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3]), pathlib.Path(sys.argv[4]))
    else:
        raise ValueError("usage: check_dependency_inventory.py generate <app> <inventory> | verify <app> <inventory> <manifest>")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, UnicodeError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        sys.exit(1)
