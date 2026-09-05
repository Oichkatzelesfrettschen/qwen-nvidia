#!/usr/bin/env python3
"""Write the large fixtures the embedding handoff admission reads.

The graded fixtures under scripts/quality-images encode to 45 to 88 tokens
on the projectors this tree serves, so every chunk decodes inside one
ubatch and one llama_decode. The handoff claim has to hold where a chunk
splits: across ubatches at a nonzero row offset, across several
llama_decode calls where the chunk exceeds n_batch, and across the tiles a
projector cuts a large image into. These fixtures are the graded drawings
scaled by an integer factor with nearest-neighbor replication, so the fact
each one carries is the same fact at a size the projectors encode to many
hundreds of tokens; the encoder's own token count per fixture is read from
the served trace rather than inferred here.

The drawings, the alphabet, the encoder, and the pixel comparison come from
scripts/generate-quality-images.py, imported by path, so the two generators
agree on every rule and this one adds the scale alone. --check compares
pixels against what is on disk, as that script does.
"""

import argparse
import hashlib
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("quality_images", os.path.join(HERE, "generate-quality-images.py"))
quality_images = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quality_images)


def scaled(builder, factor):
    source = builder()
    canvas = quality_images.Canvas(source.width * factor, source.height * factor)
    stride = source.width * 3
    for row in range(source.height):
        line = source.pixels[row * stride:(row + 1) * stride]
        expanded = bytearray()
        for column in range(source.width):
            expanded.extend(line[column * 3:column * 3 + 3] * factor)
        for repeat in range(factor):
            target = (row * factor + repeat) * canvas.width * 3
            canvas.pixels[target:target + len(expanded)] = expanded
    return canvas


# id -> (graded builder, scale factor, the fact the image still carries)
FIXTURES = {
    "bars-large": (quality_images.draw_bars, 3, "JUN is the tallest bar at 150 units"),
    "shapes-large": (quality_images.draw_shapes, 3,
                     "a red square, a green circle, and a blue triangle, left to right"),
}


def render(name):
    builder, factor, _ = FIXTURES[name]
    canvas = scaled(builder, factor)
    return canvas, canvas.png()


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", default=os.path.join(HERE, "handoff-images"))
    parser.add_argument("--check", action="store_true",
                        help="compare against what is on disk and change nothing")
    arguments = parser.parse_args(argv[1:])

    if not arguments.check:
        os.makedirs(arguments.directory, exist_ok=True)

    mismatches = 0
    for name in sorted(FIXTURES):
        path = os.path.join(arguments.directory, name + ".png")
        canvas, rendered = render(name)
        digest = hashlib.sha256(rendered).hexdigest()
        if arguments.check:
            try:
                with open(path, "rb") as handle:
                    on_disk = handle.read()
                width, height, pixels = quality_images.decode_png(on_disk)
            except (OSError, ValueError) as error:
                print(f"fixture={name} state=unreadable error={error}", file=sys.stderr)
                mismatches += 1
                continue
            matches = ((width, height) == (canvas.width, canvas.height)
                       and pixels == bytes(canvas.pixels))
            if not matches:
                mismatches += 1
            print(f"fixture={name} size={canvas.width}x{canvas.height} "
                  f"state={'matches' if matches else 'differs'}")
        else:
            with open(path, "wb") as handle:
                handle.write(rendered)
            print(f"fixture={name} size={canvas.width}x{canvas.height} bytes={len(rendered)} sha256={digest}")
    return 1 if mismatches else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
