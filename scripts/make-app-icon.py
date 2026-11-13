#!/usr/bin/env python3
"""Draws the app icon: a white "GR" in the red set-number hexagon on near-black.

Writes a 1024 x 1024 RGB PNG (no alpha, as the App Store requires). Needs Pillow.

    python3 scripts/make-app-icon.py ios/GymRollins/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONT = os.path.join(ROOT, 'ios/GymRollins/Resources/Fonts/BarlowCondensed-ExtraBoldItalic.ttf')
S = 2048  # drawn at 2x, then downsampled

# Theme.swift: background, accent, textPrimary; the hexagon runs from a lighter to a darker primaryFill.
BACKGROUND = (11, 11, 16)
BACKGROUND_CENTER = (30, 30, 40)
ACCENT = (255, 107, 114)
HEX_TOP = (222, 62, 76)
HEX_BOTTOM = (150, 32, 44)
TEXT = (242, 242, 245)


def gradient(mode: str, inner: tuple[int, int, int], outer: tuple[int, int, int]) -> Image.Image:
    mask = (Image.linear_gradient if mode == 'linear' else Image.radial_gradient)('L').resize((S, S))
    return Image.composite(Image.new('RGB', (S, S), outer), Image.new('RGB', (S, S), inner), mask).convert('RGBA')


def hexagon_mask(radius: float) -> Image.Image:
    """A pointy-top hexagon with rounded corners (blur, then threshold)."""
    cx = cy = S / 2
    points = [(cx + radius * math.cos(math.radians(90 + 60 * k)), cy - radius * math.sin(math.radians(90 + 60 * k)))
              for k in range(6)]
    mask = Image.new('L', (S, S), 0)
    ImageDraw.Draw(mask).polygon(points, fill=255)
    rounded = mask.filter(ImageFilter.GaussianBlur(60)).point(lambda v: 255 if v > 128 else 0)
    return rounded.filter(ImageFilter.GaussianBlur(1.5))


def letters(text: str, cap_height: float, center: tuple[float, float]) -> Image.Image:
    """`text` sized so its ink is `cap_height` tall, centred on `center`, with a soft shadow."""
    probe = ImageFont.truetype(FONT, 1000)
    box = ImageDraw.Draw(Image.new('L', (1, 1))).textbbox((0, 0), text, font=probe)
    font = ImageFont.truetype(FONT, int(1000 * cap_height / (box[3] - box[1])))
    box = ImageDraw.Draw(Image.new('L', (1, 1))).textbbox((0, 0), text, font=font)
    x = center[0] - (box[0] + box[2]) / 2
    y = center[1] - (box[1] + box[3]) / 2
    shadow = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).text((x, y + 24), text, font=font, fill=(0, 0, 0, 110))
    layer = shadow.filter(ImageFilter.GaussianBlur(28))
    ImageDraw.Draw(layer).text((x, y), text, font=font, fill=TEXT + (255,))
    return layer


def icon() -> Image.Image:
    image = gradient('radial', BACKGROUND_CENTER, BACKGROUND)
    mask = hexagon_mask(0.41 * S)
    glow = Image.new('RGBA', (S, S), ACCENT + (0,))
    glow.putalpha(mask.filter(ImageFilter.GaussianBlur(70)).point(lambda v: v * 0.35))
    image = Image.alpha_composite(image, glow)
    fill = gradient('linear', HEX_TOP, HEX_BOTTOM)
    fill.putalpha(mask)
    image = Image.alpha_composite(image, fill)
    image = Image.alpha_composite(image, letters('GR', 0.27 * S, (S / 2 - 8, S / 2 + 6)))
    return image.convert('RGB').resize((1024, 1024), Image.LANCZOS)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    icon().save(sys.argv[1])
