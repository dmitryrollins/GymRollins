#!/usr/bin/env python3
"""Turns a generated exercise photo into an exact 1536x1024 JPEG (quality 82) for the app bundle.

Usage: python3 scripts/photo-postprocess.py <input image> <output.jpg>

- 3:2 input: resized.
- Wider than 3:2: scaled to 1024 high and center-cropped (only the empty studio sides are lost).
- Narrower than 3:2 (e.g. a square): scaled to 1024 high, centered, and the missing sides are filled by extending
  the edge background (each side's outermost columns, averaged and blurred) with a soft blend into the photo, so the
  person and equipment are never cropped. The studio background is plain, so the extension reads as more wall/floor.
Called by scripts/generate-photos.mjs; needs Pillow + numpy.
"""
import sys

import numpy as np
from PIL import Image, ImageFilter

W, H = 1536, 1024
QUALITY = 82
EDGE_SAMPLE = 12   # columns averaged at each edge to get the background colour per row
BLEND = 64         # px of soft blend between the extension and the photo


def extend_sides(img: Image.Image) -> Image.Image:
    photo = np.asarray(img, dtype=np.float32)
    h, w, _ = photo.shape
    left_w = (W - w) // 2
    right_w = W - w - left_w
    canvas = np.zeros((H, W, 3), dtype=np.float32)

    left_col = photo[:, :EDGE_SAMPLE].mean(axis=1, keepdims=True)
    right_col = photo[:, -EDGE_SAMPLE:].mean(axis=1, keepdims=True)
    canvas[:, :left_w + BLEND] = left_col
    canvas[:, W - right_w - BLEND:] = right_col
    # Soften the horizontal streaks that per-row edge colours produce.
    fill = Image.fromarray(canvas.clip(0, 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(6))
    canvas = np.asarray(fill, dtype=np.float32).copy()

    # Blend: inside the photo's outer BLEND columns fade from extension (0) to photo (1).
    alpha = np.ones(w, dtype=np.float32)
    ramp = np.linspace(0.0, 1.0, BLEND, dtype=np.float32)
    alpha[:BLEND] = ramp
    alpha[-BLEND:] = ramp[::-1]
    alpha = alpha[None, :, None]
    region = canvas[:, left_w:left_w + w]
    canvas[:, left_w:left_w + w] = photo * alpha + region * (1 - alpha)
    return Image.fromarray(canvas.clip(0, 255).astype(np.uint8))


def to_canvas(img: Image.Image) -> Image.Image:
    img = img.convert('RGB')
    ratio = img.width / img.height
    if abs(ratio - W / H) < 0.01:
        return img.resize((W, H), Image.LANCZOS)
    scaled_w = round(img.width * H / img.height)
    img = img.resize((scaled_w, H), Image.LANCZOS)
    if scaled_w > W:
        left = (scaled_w - W) // 2
        return img.crop((left, 0, left + W, H))
    return extend_sides(img)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        with Image.open(argv[1]) as src:
            out = to_canvas(src)
    except Exception as err:  # noqa: BLE001 - report any decode failure to the caller
        print(f'cannot read image {argv[1]}: {err}', file=sys.stderr)
        return 1
    out.save(argv[2], 'JPEG', quality=QUALITY, optimize=True, progressive=True)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
