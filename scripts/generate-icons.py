#!/usr/bin/env python3
"""Generates the Reel-Edit app icon.

The upstream OpenReel mark (a spoked wheel) is deliberately not reused: this
port ships under its own name. The mark is a film-reel motif — a perforated
circle with four lightening holes — drawn on the same near-black surface the
editor uses, with the emerald accent from the app theme.

Run from the repo root:  python3 scripts/generate-icons.py
Writes AppScope/.../app_icon.png and entry/.../media/icon.png.
"""

import math
import os

from PIL import Image, ImageDraw

SURFACE = (17, 19, 24)  # #111318, the editor's stage colour
ACCENT = (56, 217, 155)  # emerald, matching the accent token
ACCENT_SOFT = (34, 160, 118)
FILM = (28, 32, 40)


def rounded_mask(size: int) -> Image.Image:
    """Rounded-square alpha mask matching the platform icon silhouette."""
    mask = Image.new("L", (size, size), 0)
    draw = ImageDraw.Draw(mask)
    radius = round(size * 0.22)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def draw_icon(size: int) -> Image.Image:
    image = Image.new("RGB", (size, size), SURFACE)
    draw = ImageDraw.Draw(image)

    cx = cy = size / 2
    outer_r = size * 0.325
    hub_r = size * 0.105

    # Film body: a ring, so it reads as a reel rather than a solid disc.
    draw.ellipse(
        (cx - outer_r, cy - outer_r, cx + outer_r, cy + outer_r),
        fill=FILM,
    )

    # Four lightening holes plus one centre opening, as on a real reel.
    hole_r = outer_r * 0.185
    for index in range(4):
        angle = math.radians(index * 90 + 45)
        hx = cx + math.cos(angle) * outer_r * 0.55
        hy = cy + math.sin(angle) * outer_r * 0.55
        draw.ellipse(
            (hx - hole_r, hy - hole_r, hx + hole_r, hy + hole_r),
            fill=SURFACE,
        )

    # Accent rim and hub.
    rim_w = max(1, round(size * 0.022))
    draw.ellipse(
        (cx - outer_r, cy - outer_r, cx + outer_r, cy + outer_r),
        outline=ACCENT_SOFT,
        width=rim_w,
    )
    draw.ellipse(
        (cx - hub_r, cy - hub_r, cx + hub_r, cy + hub_r),
        fill=ACCENT,
    )

    # A film tail: a short accent bar leaving the reel, reading as motion.
    # Kept well inside the canvas so the rounded mask never clips it.
    bar_h = round(size * 0.07)
    bar_y = cy - bar_h / 2
    draw.rounded_rectangle(
        (cx + outer_r * 0.88, bar_y, cx + outer_r * 1.32, bar_y + bar_h),
        radius=bar_h / 2,
        fill=ACCENT,
    )

    return image


def main() -> None:
    # A single flattened PNG per module: this app declares a plain media icon,
    # so no layered-image resource set is needed.
    targets = [
        os.path.join("AppScope", "resources", "base", "media", "app_icon.png"),
        os.path.join("entry", "src", "main", "resources", "base", "media", "icon.png"),
    ]

    base = draw_icon(1024)
    base.putalpha(rounded_mask(1024))
    base.save("docs/images/icon.png", "PNG", optimize=True)
    print("docs/images/icon.png")

    for target in targets:
        os.makedirs(os.path.dirname(target), exist_ok=True)
        base.resize((512, 512), Image.LANCZOS).save(target, "PNG", optimize=True)
        print(target)


if __name__ == "__main__":
    main()