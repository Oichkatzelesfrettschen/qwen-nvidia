#!/usr/bin/env python3
"""Draw the smoke's JPEG fixture from a declaration in this file.

The image is four flat color bars over a mid-grey field at 640 by 480, so the
decoded pixels and the resized output are predictable from the declaration
rather than from a photograph, and the encoder settings are pinned so the same
bytes come out on every host that carries the same Pillow.
"""

import pathlib
import sys

from PIL import Image, ImageDraw

BARS = ((40, 60, 200, 0xC0392B), (200, 60, 360, 0x27AE60), (360, 60, 520, 0x2980B9),
        (520, 60, 600, 0xF1C40F))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-fixture.py OUTPUT_JPEG")
    image = Image.new("RGB", (640, 480), (128, 128, 128))
    draw = ImageDraw.Draw(image)
    for left, top, right, color in BARS:
        draw.rectangle((left, top, right, 420), fill=((color >> 16) & 255, (color >> 8) & 255, color & 255))
    image.save(pathlib.Path(sys.argv[1]), format="JPEG", quality=90, subsampling=0, optimize=False)


if __name__ == "__main__":
    main()
