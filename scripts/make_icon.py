#!/usr/bin/env python3
"""
Generates AppIcon.icns for VenvDeck.

Design:
- macOS Big Sur squircle (superellipse, n=5) sized to Apple's icon grid
  (824 px squircle within a 1024 px canvas).
- Diagonal gradient in Python's signature blue -> gold palette.
- Three offset rounded-rectangle "cards" forming a deck (matching the
  name VenvDeck), with a `>_` REPL chevron on the front card.
- Subtle drop shadow under the deck and a soft inner highlight on the
  squircle for depth.

Outputs:
- A single 1024 master PNG.
- A full .iconset folder with every size macOS expects.
- AppIcon.icns assembled by `iconutil`.
"""

from __future__ import annotations

import math
import os
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
BUILD_DIR = ROOT / ".build" / "icon"
ICONSET_DIR = BUILD_DIR / "AppIcon.iconset"
MASTER_PNG = BUILD_DIR / "AppIcon-1024.png"
ICNS_OUT = BUILD_DIR / "AppIcon.icns"

CANVAS = 1024  # Apple icon canvas
SQUIRCLE = 824  # Apple safe-area squircle within canvas


# --- helpers ---------------------------------------------------------------


def squircle_mask(size: int, inset: int, n: float = 5.0) -> Image.Image:
    """Render an antialiased superellipse mask (the Big Sur squircle)."""
    # Render at 4x then downsample for clean edges.
    scale = 4
    big = Image.new("L", (size * scale, size * scale), 0)
    draw = ImageDraw.Draw(big)
    cx = cy = size * scale / 2
    a = b = (size - 2 * inset) * scale / 2
    pts = []
    steps = 720
    for i in range(steps):
        t = (i / steps) * 2 * math.pi
        ct = math.cos(t)
        st = math.sin(t)
        x = cx + math.copysign(abs(ct) ** (2.0 / n) * a, ct)
        y = cy + math.copysign(abs(st) ** (2.0 / n) * b, st)
        pts.append((x, y))
    draw.polygon(pts, fill=255)
    return big.resize((size, size), Image.LANCZOS)


def diagonal_gradient(size: int, top_left, bottom_right) -> Image.Image:
    """Linear gradient from top-left to bottom-right."""
    grad = Image.new("RGB", (size, size), top_left)
    px = grad.load()
    tlr, tlg, tlb = top_left
    brr, brg, brb = bottom_right
    inv = 1.0 / (2 * (size - 1))
    for y in range(size):
        for x in range(size):
            t = (x + y) * inv
            r = int(tlr + (brr - tlr) * t)
            g = int(tlg + (brg - tlg) * t)
            b = int(tlb + (brb - tlb) * t)
            px[x, y] = (r, g, b)
    return grad


def rounded_rect(size, radius, fill) -> Image.Image:
    """A rounded rectangle as its own RGBA image, antialiased via 4x render."""
    w, h = size
    scale = 4
    big = Image.new("RGBA", (w * scale, h * scale), (0, 0, 0, 0))
    d = ImageDraw.Draw(big)
    d.rounded_rectangle(
        [(0, 0), (w * scale - 1, h * scale - 1)],
        radius=radius * scale,
        fill=fill,
    )
    return big.resize((w, h), Image.LANCZOS)


def rotated(img: Image.Image, deg: float) -> Image.Image:
    return img.rotate(deg, resample=Image.BICUBIC, expand=True)


def drop_shadow(img: Image.Image, offset=(0, 12), blur=24, opacity=0.35) -> Image.Image:
    """Build a soft shadow from `img`'s alpha channel."""
    a = img.split()[-1]
    pad = blur * 3
    canvas = Image.new("RGBA", (img.width + pad * 2, img.height + pad * 2), (0, 0, 0, 0))
    shadow = Image.new("RGBA", canvas.size, (0, 0, 0, 0))
    shadow.paste((0, 0, 0, int(255 * opacity)), (pad + offset[0], pad + offset[1]), a)
    shadow = shadow.filter(ImageFilter.GaussianBlur(blur))
    return shadow, pad


def best_mono_font(target_px: int) -> ImageFont.ImageFont:
    """Pick a chunky monospaced font, falling back gracefully."""
    candidates = [
        "/System/Library/Fonts/SFNSMono.ttf",
        "/System/Library/Fonts/Menlo.ttc",
        "/System/Library/Fonts/Monaco.dfont",
        "/Library/Fonts/Andale Mono.ttf",
    ]
    for path in candidates:
        if os.path.exists(path):
            try:
                return ImageFont.truetype(path, target_px)
            except OSError:
                continue
    return ImageFont.load_default()


# --- composition -----------------------------------------------------------


def render_master() -> Image.Image:
    canvas_size = CANVAS
    inset = (CANVAS - SQUIRCLE) // 2

    # 1. Background squircle: cohesive Python-blue gradient (deep navy ->
    #    Python brand blue). A single hue family keeps the midtones clean
    #    instead of producing muddy olive when blending across complements.
    grad = diagonal_gradient(canvas_size, (24, 52, 92), (75, 139, 190))
    mask = squircle_mask(canvas_size, inset)
    bg = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    bg.paste(grad, (0, 0), mask)

    # 2. Soft inner highlight along the top-left edge for depth.
    highlight = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    hd = ImageDraw.Draw(highlight)
    hd.ellipse(
        [(-200, -260), (canvas_size - 200, canvas_size - 260)],
        fill=(255, 255, 255, 70),
    )
    highlight = highlight.filter(ImageFilter.GaussianBlur(120))
    # Clip the highlight to the squircle.
    highlight.putalpha(
        Image.eval(
            ImageMultiplyHelper(highlight.split()[-1], mask).run(),
            lambda v: v,
        )
    )
    bg = Image.alpha_composite(bg, highlight)

    # 3. The deck of cards.
    card_w, card_h = 520, 380
    card_radius = 64
    deck = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))

    # Back-most card: most translucent, rotated more.
    back = rounded_rect((card_w, card_h), card_radius, (255, 255, 255, 150))
    back_r = rotated(back, -10)
    deck.alpha_composite(
        back_r,
        (
            (canvas_size - back_r.width) // 2 - 70,
            (canvas_size - back_r.height) // 2 - 30,
        ),
    )

    # Middle card.
    mid = rounded_rect((card_w, card_h), card_radius, (255, 255, 255, 200))
    mid_r = rotated(mid, -3)
    deck.alpha_composite(
        mid_r,
        (
            (canvas_size - mid_r.width) // 2 - 20,
            (canvas_size - mid_r.height) // 2 + 10,
        ),
    )

    # Front card: opaque, slight tilt, with the chevron mark.
    front = rounded_rect((card_w, card_h), card_radius, (255, 255, 255, 255))
    fd = ImageDraw.Draw(front)
    chevron_color = (40, 78, 122, 255)  # Python brand blue
    accent_color = (255, 212, 59, 255)  # Python brand yellow (cursor accent)
    # Chevron ">" drawn as a chunky polyline.
    cx, cy = card_w // 2 - 50, card_h // 2
    arm = 110
    thickness = 36
    fd.line(
        [(cx - arm, cy - arm), (cx, cy), (cx - arm, cy + arm)],
        fill=chevron_color,
        width=thickness,
        joint="curve",
    )
    # Underscore cursor next to the chevron — Python yellow as the accent.
    bar_y = cy + arm - 10
    fd.rounded_rectangle(
        [(cx + 30, bar_y), (cx + 30 + 130, bar_y + thickness - 4)],
        radius=14,
        fill=accent_color,
    )
    front_r = rotated(front, 4)
    deck.alpha_composite(
        front_r,
        (
            (canvas_size - front_r.width) // 2 + 40,
            (canvas_size - front_r.height) // 2 + 60,
        ),
    )

    # 4. Drop shadow for the deck, clipped to the squircle so it stays inside.
    shadow, pad = drop_shadow(deck, offset=(0, 26), blur=40, opacity=0.32)
    shadow_canvas = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    shadow_canvas.alpha_composite(shadow, (-pad, -pad))
    # Clip shadow to squircle.
    sa = shadow_canvas.split()[-1]
    sa = ImageMultiplyHelper(sa, mask).run()
    shadow_canvas.putalpha(sa)
    bg = Image.alpha_composite(bg, shadow_canvas)
    bg = Image.alpha_composite(bg, deck)

    # 5. Final subtle vignette inside the squircle for polish.
    vignette = Image.new("RGBA", (canvas_size, canvas_size), (0, 0, 0, 0))
    vd = ImageDraw.Draw(vignette)
    vd.ellipse(
        [(-canvas_size // 4, canvas_size // 3), (canvas_size + canvas_size // 4, canvas_size + canvas_size // 2)],
        fill=(0, 0, 0, 60),
    )
    vignette = vignette.filter(ImageFilter.GaussianBlur(140))
    va = vignette.split()[-1]
    va = ImageMultiplyHelper(va, mask).run()
    vignette.putalpha(va)
    bg = Image.alpha_composite(bg, vignette)

    return bg


class ImageMultiplyHelper:
    """Per-pixel multiply of two single-channel images (used to clip alpha)."""

    def __init__(self, a: Image.Image, b: Image.Image):
        if a.size != b.size:
            b = b.resize(a.size, Image.LANCZOS)
        self.a = a
        self.b = b

    def run(self) -> Image.Image:
        out = Image.new("L", self.a.size, 0)
        ap = self.a.load()
        bp = self.b.load()
        op = out.load()
        for y in range(out.height):
            for x in range(out.width):
                op[x, y] = (ap[x, y] * bp[x, y]) // 255
        return out


# --- iconset assembly ------------------------------------------------------


ICON_SIZES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def main() -> None:
    if BUILD_DIR.exists():
        shutil.rmtree(BUILD_DIR)
    ICONSET_DIR.mkdir(parents=True)

    master = render_master()
    master.save(MASTER_PNG, format="PNG")

    for name, size in ICON_SIZES:
        resized = master.resize((size, size), Image.LANCZOS)
        resized.save(ICONSET_DIR / name, format="PNG")

    subprocess.run(
        ["iconutil", "-c", "icns", str(ICONSET_DIR), "-o", str(ICNS_OUT)],
        check=True,
    )
    print(f"Wrote {ICNS_OUT}")


if __name__ == "__main__":
    main()
