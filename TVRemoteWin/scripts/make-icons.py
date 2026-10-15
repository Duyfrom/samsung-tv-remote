#!/usr/bin/env python3
"""Regenerates build/icon.png, icon.ico and the tray icons from the macOS app's icon artwork.

Needs macOS (the master 1024 px PNG comes from ../TVRemote/scripts/make-icon.swift) and Pillow.
The generated files are committed, so this only matters when the artwork changes.
"""
import pathlib, subprocess, sys, tempfile
from PIL import Image, ImageEnhance

root = pathlib.Path(__file__).resolve().parent.parent
build = root / "build"
build.mkdir(exist_ok=True)

with tempfile.TemporaryDirectory() as tmp:
    master = pathlib.Path(tmp) / "icon.png"
    subprocess.run(["swift", str(root.parent / "TVRemote/scripts/make-icon.swift"), str(master)], check=True)
    img = Image.open(master).convert("RGBA")

img.resize((512, 512), Image.LANCZOS).save(build / "icon.png")
img.save(build / "icon.ico", sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])


def off(im):
    """Greyed out, half transparent: the TV is off or unreachable."""
    grey = ImageEnhance.Color(im).enhance(0.0)
    r, g, b, a = grey.split()
    return Image.merge("RGBA", (r, g, b, a.point(lambda v: int(v * 0.55))))


for suffix, size in (("", 16), ("@2x", 32)):
    small = img.resize((size, size), Image.LANCZOS)
    small.save(build / f"tray{suffix}.png")
    off(small).save(build / f"tray-off{suffix}.png")

print("wrote", ", ".join(sorted(p.name for p in build.iterdir())))
