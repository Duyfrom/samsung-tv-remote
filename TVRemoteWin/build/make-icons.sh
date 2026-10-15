#!/bin/bash
# Regenerates build/*.ico from the macOS app's icon artwork, then the exe resources (icon, manifest, version).
# Needs macOS (swift) and Python with Pillow. Only needed when the artwork or version changes.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
swift ../TVRemote/scripts/make-icon.swift "$tmp/icon.png"
python3 - "$tmp/icon.png" <<'PY'
import sys
from PIL import Image, ImageEnhance
img = Image.open(sys.argv[1]).convert("RGBA")
img.save("build/icon.ico", sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])
tray = img.resize((32, 32), Image.LANCZOS)
tray.save("build/tray.ico", sizes=[(16, 16), (24, 24), (32, 32)])
r, g, b, a = ImageEnhance.Color(tray).enhance(0).split()  # greyed and faded: the TV is off
Image.merge("RGBA", (r, g, b, a.point(lambda v: int(v * 0.55)))).save("build/tray-off.ico", sizes=[(16, 16), (24, 24), (32, 32)])
PY
go run github.com/tc-hib/go-winres@v0.3.3 make --in winres/winres.json --arch amd64
