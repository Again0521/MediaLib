#!/usr/bin/env python3
import os
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(SCRIPT_DIR, "vendor"))

from ds_store import DSStore, DSStoreEntry
from ds_store.store import ILocCodec, PlistCodec
from mac_alias import Alias


def background_alias(path: str) -> bytes:
    alias = Alias.for_file(path)
    # APFS can return 64-bit CNIDs in the ancestry. Classic alias records store
    # this path as 32-bit values, while Finder can still resolve the POSIX path.
    alias.target.cnid_path = None
    return alias.to_bytes()


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: write_dmg_ds_store.py <mounted-dmg-root>", file=sys.stderr)
        return 2

    root = os.path.abspath(sys.argv[1])
    background = os.path.join(root, ".background", "dmg-background.png")
    ds_store = os.path.join(root, ".DS_Store")

    if not os.path.isdir(root):
        print(f"mounted root not found: {root}", file=sys.stderr)
        return 1
    if not os.path.exists(background):
        print(f"background image not found: {background}", file=sys.stderr)
        return 1

    entries = [
        DSStoreEntry(
            ".",
            "bwsp",
            PlistCodec,
            {
                "ShowStatusBar": False,
                "ShowToolbar": False,
                "ShowTabView": False,
                "ContainerShowSidebar": False,
                "ShowSidebar": False,
                # 系统风格安装窗口：600x400，无工具栏/侧栏/状态栏。
                "WindowBounds": "{{140, 140}, {600, 400}}",
            },
        ),
        DSStoreEntry(
            ".",
            "icvp",
            PlistCodec,
            {
                "viewOptionsVersion": 1,
                "arrangeBy": "none",
                "gridOffsetX": 0.0,
                "gridOffsetY": 0.0,
                "gridSpacing": 100.0,
                # 系统安装窗口的常见图标尺寸与默认文字号。
                "iconSize": 128.0,
                "textSize": 12.0,
                "labelOnBottom": True,
                "showItemInfo": False,
                "showIconPreview": True,
                "backgroundType": 2,
                "backgroundColorRed": 1.0,
                "backgroundColorGreen": 1.0,
                "backgroundColorBlue": 1.0,
                "backgroundImageAlias": background_alias(background),
            },
        ),
        # 图标中心与背景箭头对齐：应用在左、Applications 在右，垂直居中。
        DSStoreEntry("MediaLIB.app", "Iloc", ILocCodec, (170, 200)),
        DSStoreEntry("Applications", "Iloc", ILocCodec, (430, 200)),
        DSStoreEntry(".", "vSrn", "long", 1),
    ]

    with DSStore.open(ds_store, "w+", initial_entries=entries):
        pass

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
