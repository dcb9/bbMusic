#!/usr/bin/env python3
"""bbMusic app icon — source of truth.

The mark is the musical double flat "𝄫", which literally reads "bb". It sits on a deep
forest-green plate, drawn full-bleed: macOS 26 rounds and lights app icons itself, and a
plate we rounded ourselves would show up as a second, smaller square inside that mask.

    python3 Scripts/make-icon.py            # regenerate Assets/icon/*
    python3 Scripts/make-icon.py --preview  # only refresh the size previews

Needs `rsvg-convert` (brew install librsvg) to rasterise and `iconutil` (macOS) for the
.icns. The generated .icns and PNGs are committed, so building the app never needs this.
"""

import argparse
import os
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "Assets", "icon")

# ---------------------------------------------------------------- design tokens
CANVAS = 1024
PLATE = ("#3A6650", "#274A38", "#183222")   # forest green, top to bottom
BONE = "#F7F2E7"                            # the mark

MARK_W = 660          # width of the two flats together
MARK_H = 604
MARK_GAP = 0.50       # gap between the flats, as a fraction of one flat's width
STEM = 0.225          # stem weight, as a fraction of one flat's width
TIP = 0.38            # where the bowl leaves the stem
SHOULDER = 0.66       # where the bowl is widest
FOOT = 0.10           # how much stem shows below the bowl


def flat(x, top, w, h, stem=STEM, tip=TIP, shoulder=SHOULDER, foot=FOOT,
         return_x=0.35):
    """One musical flat as a single closed path.

    A rounded stem, and a leaf-shaped bowl that leaves the stem at `tip`, swells right to
    `shoulder`, then sweeps back onto the stem at `foot` above its base — so the stem's
    foot shows below the bowl, the way an engraved flat does.
    """
    sw = w * stem
    r = sw / 2.0
    x0, x1 = x, x + sw
    xr = x + w * 0.98
    y_top, y_bot = top, top + h
    y_tip = top + h * tip
    y_sh = top + h * shoulder
    y_back = top + h * (1.0 - foot)
    wb = xr - x1
    return (
        f"M {x0:.2f},{y_top + r:.2f} "
        f"A {r:.2f},{r:.2f} 0 0 1 {x1:.2f},{y_top + r:.2f} "
        f"L {x1:.2f},{y_tip:.2f} "
        f"C {x1 + wb * 0.50:.2f},{y_tip - h * 0.008:.2f} "
        f"{xr:.2f},{y_tip + h * 0.15:.2f} {xr:.2f},{y_sh:.2f} "
        f"C {xr:.2f},{y_sh + h * 0.17:.2f} "
        f"{x1 + wb * return_x:.2f},{y_back - h * 0.005:.2f} {x1:.2f},{y_back:.2f} "
        f"L {x1:.2f},{y_bot - r:.2f} "
        f"A {r:.2f},{r:.2f} 0 0 1 {x0:.2f},{y_bot - r:.2f} "
        f"L {x0:.2f},{y_top + r:.2f} Z"
    )


def mark(width=MARK_W, height=MARK_H, gap=MARK_GAP, **kw):
    gw = width / (2 + gap)
    step = gw * (1 + gap)
    x0 = CANVAS / 2 - width / 2
    top = CANVAS / 2 - height / 2
    return " ".join(flat(x0 + i * step, top, gw, height, **kw) for i in range(2))


def svg(mark_path, plate=PLATE, fill=BONE):
    return f"""<svg xmlns="http://www.w3.org/2000/svg" width="{CANVAS}" height="{CANVAS}"
     viewBox="0 0 {CANVAS} {CANVAS}">
  <title>bbMusic</title>
  <defs>
    <linearGradient id="plate" x1="0.10" y1="0" x2="0.32" y2="1">
      <stop offset="0" stop-color="{plate[0]}"/>
      <stop offset="0.55" stop-color="{plate[1]}"/>
      <stop offset="1" stop-color="{plate[2]}"/>
    </linearGradient>
    <linearGradient id="sheen" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.13"/>
      <stop offset="0.45" stop-color="#FFFFFF" stop-opacity="0.015"/>
      <stop offset="1" stop-color="#000000" stop-opacity="0.05"/>
    </linearGradient>
  </defs>
  <rect width="{CANVAS}" height="{CANVAS}" fill="url(#plate)"/>
  <path d="{mark_path}" fill="{fill}"/>
  <rect width="{CANVAS}" height="{CANVAS}" fill="url(#sheen)"/>
</svg>
"""


# ---------------------------------------------------------------- rasterising
ICONSET = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


PREVIEWS = (1024, 256, 128, 64, 32, 16)


def need(tool):
    if shutil.which(tool) is None:
        sys.exit(f"error: {tool} not found (rsvg-convert: brew install librsvg)")


def rasterise(svg_path, png_path, size):
    subprocess.run(["rsvg-convert", "-w", str(size), "-h", str(size), svg_path,
                    "-o", png_path], check=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", action="store_true",
                    help="write only the size previews, skipping the .icns")
    args = ap.parse_args()

    need("rsvg-convert")
    os.makedirs(OUT, exist_ok=True)

    svg_path = os.path.join(OUT, "AppIcon.svg")
    with open(svg_path, "w") as f:
        f.write(svg(mark()))

    if args.preview:
        for size in PREVIEWS:
            rasterise(svg_path, os.path.join(OUT, f"preview-{size}.png"), size)
        print("previews refreshed")
        return

    iconset = os.path.join(OUT, "AppIcon.iconset")
    shutil.rmtree(iconset, ignore_errors=True)
    os.makedirs(iconset)
    for name, size in ICONSET.items():
        rasterise(svg_path, os.path.join(iconset, name), size)

    icns = os.path.join(OUT, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", icns], check=True)

    # Committed: the SVG source, the .icns the bundle embeds, and one PNG for the README.
    # The .iconset is an intermediate and is gitignored.
    rasterise(svg_path, os.path.join(OUT, "AppIcon-1024.png"), 1024)

    print(f"wrote {os.path.relpath(icns, ROOT)} "
          f"({os.path.getsize(icns) // 1024} KB) and the iconset")


if __name__ == "__main__":
    main()
