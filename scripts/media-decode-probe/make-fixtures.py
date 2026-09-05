#!/usr/bin/env python3
"""Write the encoded-format fixtures the media placement probe decodes.

The graded drawings under scripts/quality-images are PNG, and one served
photograph is a baseline JPEG. A decoder's placement depends on the
bitstream rather than on the picture, so this writes the same declared
drawing under the encodings a client is likely to send: baseline JPEG at
4:2:0 and 4:4:4 chroma, progressive JPEG, grayscale JPEG, and PNG with an
alpha channel and with a palette. Every JPEG is encoded once here from the
lossless drawing; the probe transcodes nothing at decode time, and the
JPEG pixels are compared decoder against decoder rather than against the
drawing, since two conforming JPEG decoders may round an IDCT apart.

The drawing comes from scripts/generate-quality-images.py by path, the way
scripts/generate-handoff-images.py imports it, so the fixture carries the
declared bars the graded suite asks about. Pillow is the encoder and the
settings are pinned, so the bytes are a function of the Pillow release.
"""

import importlib.util
import os
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
spec = importlib.util.spec_from_file_location("quality_images", os.path.join(SCRIPTS, "generate-quality-images.py"))
quality_images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality_images)


def drawing_as_image(builder):
    canvas = builder()
    return Image.frombytes("RGB", (canvas.width, canvas.height), bytes(canvas.pixels))


FIXTURES = (
    ("bars-baseline-420.jpg", "JPEG", {"quality": 90, "subsampling": 2, "optimize": False}),
    ("bars-baseline-444.jpg", "JPEG", {"quality": 90, "subsampling": 0, "optimize": False}),
    ("bars-progressive.jpg", "JPEG", {"quality": 90, "subsampling": 2, "progressive": True, "optimize": False}),
    ("bars-gray.jpg", "JPEG", {"quality": 90, "optimize": False, "mode": "L"}),
    ("bars-rgba.png", "PNG", {"mode": "RGBA"}),
    ("bars-palette.png", "PNG", {"mode": "P"}),
)


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make-fixtures.py OUTPUT_DIRECTORY")
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    source = drawing_as_image(quality_images.draw_bars)
    for name, fmt, options in FIXTURES:
        options = dict(options)
        mode = options.pop("mode", "RGB")
        image = source.convert(mode) if mode != "P" else source.convert("P", palette=Image.ADAPTIVE, colors=64)
        image.save(os.path.join(out, name), format=fmt, **options)
        print(name)


if __name__ == "__main__":
    main()
