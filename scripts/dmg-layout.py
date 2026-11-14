"""Builds and verifies the Shipwatch installer window layout.

Run inside the hash-locked venv created by scripts/package-macos.sh:
  dmg-layout.py build <stage-dir> <out.dmg>   Build the DMG from <stage-dir>.
  dmg-layout.py verify <mountpoint>           Check the .DS_Store layout of a mounted DMG.
Finder is never opened; verification reads the .DS_Store records directly.
"""

import argparse
import os
import sys
from pathlib import Path

from ds_store import DSStore
from mac_alias import Alias

VOLUME = "Shipwatch"
APP = "Shipwatch.app"
WINDOW = ((100, 100), (720, 520))
ICON_SIZE = 128
TEXT_SIZE = 16
# Icon centers, y from the top. Must match Sources/ShipwatchUI/DMGBackground.swift.
POSITIONS = {APP: (180, 210), "Applications": (540, 210), "Install.txt": (360, 400)}


def settings(stage):
    return {
        "format": "UDZO",
        "filesystem": "HFS+",
        "files": [os.fspath(stage / APP), os.fspath(stage / "Install.txt")],
        "symlinks": {"Applications": "/Applications"},
        "icon": os.fspath(stage / APP / "Contents/Resources/AppIcon.icns"),
        "background": os.fspath(stage / "background/background.png"),
        "window_rect": WINDOW,
        "default_view": "icon-view",
        "icon_size": ICON_SIZE,
        "text_size": TEXT_SIZE,
        "label_pos": "bottom",
        "arrange_by": None,
        "show_status_bar": False,
        "show_tab_view": False,
        "show_toolbar": False,
        "show_pathbar": False,
        "show_sidebar": False,
        "show_icon_preview": False,
        "show_item_info": False,
        "include_list_view_settings": False,
        "icon_locations": POSITIONS,
    }


def verify(root):
    problems = []

    def expect(label, actual, wanted):
        if actual != wanted:
            problems.append(f"{label}: expected {wanted!r}, found {actual!r}")

    with DSStore.open(os.fspath(root / ".DS_Store"), "r") as store:
        window = store["."]["bwsp"]
        icons = store["."]["icvp"]
        (x, y), (width, height) = WINDOW
        expect("window bounds", window.get("WindowBounds"), f"{{{{{x}, {y}}}, {{{width}, {height}}}}}")
        for chrome in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowTabView", "ShowPathbar"):
            expect(chrome, window.get(chrome), False)
        expect("view style", store["."]["icvl"][1].decode("ascii"), "icnv")
        expect("icon size", icons["iconSize"], float(ICON_SIZE))
        expect("text size", icons["textSize"], float(TEXT_SIZE))
        expect("arrange by", icons["arrangeBy"], "none")
        expect("labels on bottom", icons["labelOnBottom"], True)
        expect("background type", icons["backgroundType"], 2)
        background = Alias.from_bytes(icons["backgroundImageAlias"])
        expect("background file", background.target.filename, ".background.tiff")
        tiff = root / ".background.tiff"
        if tiff.is_file():
            expect("background file id", background.target.cnid, tiff.stat().st_ino)
        else:
            problems.append("missing .background.tiff")
        for name, position in POSITIONS.items():
            expect(f"{name} position", tuple(store[name]["Iloc"]), position)

    for name in (APP, "Applications", "Install.txt", ".VolumeIcon.icns"):
        if not (root / name).exists() and not (root / name).is_symlink():
            problems.append(f"missing {name}")
    return problems


parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("action", choices=("build", "verify"))
parser.add_argument("path", type=Path)
parser.add_argument("output", nargs="?", type=Path)
args = parser.parse_args()
if args.action == "build":
    import dmgbuild

    if args.output is None:
        parser.error("build requires an output image")
    dmgbuild.build_dmg(os.fspath(args.output), VOLUME, settings=settings(args.path))
else:
    issues = verify(args.path)
    for issue in issues:
        print(f"Installer layout: {issue}", file=sys.stderr)
    sys.exit(1 if issues else 0)
