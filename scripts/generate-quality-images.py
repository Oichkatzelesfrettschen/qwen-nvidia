#!/usr/bin/env python3
"""Write the vision fixtures the graded suite and the promotion gate read.

A vision row is gradeable only where the ground truth is known exactly, so every
fixture is drawn from a declaration in this file rather than photographed or
downloaded. The answer to each row is a literal in the FIXTURES table below, and
the drawing code is what puts it in the image.

The images are committed and this script is how they were made. --check
re-renders and compares pixels against what is on disk, which is what a test
runs.

Pixels rather than file bytes, because deflate is not reproducible across
hosts and PNG content is. The pixel values come from integer arithmetic and the
glyphs from the 5x7 table below rather than from a system font, so every host
draws the same image; the encoder that packs it does not agree with itself
across versions, and zlib 1.3 on the appliance re-encoded 7 of these 8 fixtures
to different bytes than the workstation wrote. Inflate is fully specified where
deflate leaves the match search to the implementation, so decoding both sides
and comparing pixels tests the claim the fixture actually makes.

PIL is deliberately absent for the same reason: the two hosts carry Pillow
12.3.0 and 10.2.0, and a fixture drawn by a version-dependent rasteriser holds
version-dependent pixels, which no decoding step recovers from.
"""

import argparse
import hashlib
import os
import struct
import sys
import zlib

# 5x7 glyphs, one string per row, `#` set. A drawn alphabet keeps the fixtures
# independent of which fonts a host has installed.
GLYPHS = {
    "0": ("01110", "10001", "10011", "10101", "11001", "10001", "01110"),
    "1": ("00100", "01100", "00100", "00100", "00100", "00100", "01110"),
    "2": ("01110", "10001", "00001", "00010", "00100", "01000", "11111"),
    "3": ("11111", "00010", "00100", "00010", "00001", "10001", "01110"),
    "4": ("00010", "00110", "01010", "10010", "11111", "00010", "00010"),
    "5": ("11111", "10000", "11110", "00001", "00001", "10001", "01110"),
    "6": ("00110", "01000", "10000", "11110", "10001", "10001", "01110"),
    "7": ("11111", "00001", "00010", "00100", "01000", "01000", "01000"),
    "8": ("01110", "10001", "10001", "01110", "10001", "10001", "01110"),
    "9": ("01110", "10001", "10001", "01111", "00001", "00010", "01100"),
    "A": ("01110", "10001", "10001", "11111", "10001", "10001", "10001"),
    "B": ("11110", "10001", "10001", "11110", "10001", "10001", "11110"),
    "C": ("01110", "10001", "10000", "10000", "10000", "10001", "01110"),
    "D": ("11100", "10010", "10001", "10001", "10001", "10010", "11100"),
    "E": ("11111", "10000", "10000", "11110", "10000", "10000", "11111"),
    "F": ("11111", "10000", "10000", "11110", "10000", "10000", "10000"),
    "G": ("01110", "10001", "10000", "10111", "10001", "10001", "01111"),
    "H": ("10001", "10001", "10001", "11111", "10001", "10001", "10001"),
    "I": ("01110", "00100", "00100", "00100", "00100", "00100", "01110"),
    "J": ("00111", "00010", "00010", "00010", "00010", "10010", "01100"),
    "K": ("10001", "10010", "10100", "11000", "10100", "10010", "10001"),
    "L": ("10000", "10000", "10000", "10000", "10000", "10000", "11111"),
    "M": ("10001", "11011", "10101", "10101", "10001", "10001", "10001"),
    "N": ("10001", "11001", "10101", "10011", "10001", "10001", "10001"),
    "O": ("01110", "10001", "10001", "10001", "10001", "10001", "01110"),
    "P": ("11110", "10001", "10001", "11110", "10000", "10000", "10000"),
    "Q": ("01110", "10001", "10001", "10001", "10101", "10010", "01101"),
    "R": ("11110", "10001", "10001", "11110", "10100", "10010", "10001"),
    "S": ("01111", "10000", "10000", "01110", "00001", "00001", "11110"),
    "T": ("11111", "00100", "00100", "00100", "00100", "00100", "00100"),
    "U": ("10001", "10001", "10001", "10001", "10001", "10001", "01110"),
    "V": ("10001", "10001", "10001", "10001", "10001", "01010", "00100"),
    "W": ("10001", "10001", "10001", "10101", "10101", "10101", "01010"),
    "X": ("10001", "10001", "01010", "00100", "01010", "10001", "10001"),
    "Y": ("10001", "10001", "01010", "00100", "00100", "00100", "00100"),
    "Z": ("11111", "00001", "00010", "00100", "01000", "10000", "11111"),
    "-": ("00000", "00000", "00000", "11111", "00000", "00000", "00000"),
    ".": ("00000", "00000", "00000", "00000", "00000", "01100", "01100"),
    ":": ("00000", "01100", "01100", "00000", "01100", "01100", "00000"),
    "%": ("11001", "11010", "00010", "00100", "01000", "01011", "10011"),
    "/": ("00001", "00010", "00010", "00100", "01000", "01000", "10000"),
    " ": ("00000", "00000", "00000", "00000", "00000", "00000", "00000"),
}

BLACK = (20, 20, 24)
WHITE = (250, 250, 248)
GREY = (140, 140, 146)
RED = (208, 44, 44)
GREEN = (34, 152, 74)
BLUE = (40, 78, 200)
AMBER = (226, 156, 22)


class Canvas:
    def __init__(self, width, height, background=WHITE):
        self.width = width
        self.height = height
        self.pixels = bytearray(bytes(background) * (width * height))

    def set(self, x, y, colour):
        if 0 <= x < self.width and 0 <= y < self.height:
            offset = (y * self.width + x) * 3
            self.pixels[offset:offset + 3] = bytes(colour)

    def rectangle(self, x, y, width, height, colour):
        for row in range(y, y + height):
            for column in range(x, x + width):
                self.set(column, row, colour)

    def outline(self, x, y, width, height, colour, thickness=1):
        self.rectangle(x, y, width, thickness, colour)
        self.rectangle(x, y + height - thickness, width, thickness, colour)
        self.rectangle(x, y, thickness, height, colour)
        self.rectangle(x + width - thickness, y, thickness, height, colour)

    def disc(self, centre_x, centre_y, radius, colour):
        for row in range(centre_y - radius, centre_y + radius + 1):
            for column in range(centre_x - radius, centre_x + radius + 1):
                if (column - centre_x) ** 2 + (row - centre_y) ** 2 <= radius * radius:
                    self.set(column, row, colour)

    def triangle(self, apex_x, apex_y, half_width, height, colour):
        """An upward isosceles triangle, drawn as scanlines from the apex."""
        for step in range(height + 1):
            span = half_width * step // height
            row = apex_y + step
            for column in range(apex_x - span, apex_x + span + 1):
                self.set(column, row, colour)

    def text(self, x, y, message, colour, scale=2, spacing=1):
        cursor = x
        for character in message.upper():
            glyph = GLYPHS.get(character, GLYPHS[" "])
            for row_index, row in enumerate(glyph):
                for column_index, cell in enumerate(row):
                    if cell == "1":
                        self.rectangle(cursor + column_index * scale,
                                       y + row_index * scale, scale, scale, colour)
            cursor += (5 + spacing) * scale
        return cursor

    def text_width(self, message, scale=2, spacing=1):
        return len(message) * (5 + spacing) * scale

    def png(self):
        raw = bytearray()
        stride = self.width * 3
        for row in range(self.height):
            raw.append(0)
            raw.extend(self.pixels[row * stride:(row + 1) * stride])

        def chunk(tag, payload):
            return (struct.pack(">I", len(payload)) + tag + payload
                    + struct.pack(">I", zlib.crc32(tag + payload) & 0xffffffff))

        return (b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", self.width, self.height,
                                             8, 2, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
                + chunk(b"IEND", b""))


def draw_shapes():
    """Three shapes in three colours. Counting and naming are both gradeable."""
    canvas = Canvas(320, 200)
    canvas.rectangle(30, 60, 70, 70, RED)
    canvas.disc(160, 95, 36, GREEN)
    canvas.triangle(255, 58, 40, 72, BLUE)
    return canvas


def draw_bars():
    """A four-bar chart whose tallest bar and axis maximum are both stated."""
    canvas = Canvas(360, 260)
    heights = {"APR": 40, "MAY": 90, "JUN": 150, "JUL": 70}
    baseline = 210
    canvas.rectangle(50, baseline, 280, 2, BLACK)
    canvas.rectangle(50, 40, 2, baseline - 40, BLACK)
    for index, gridline in enumerate((0, 50, 100, 150)):
        y = baseline - gridline
        canvas.rectangle(44, y, 6, 2, BLACK)
        canvas.text(8, y - 7, str(gridline), BLACK, scale=2)
    for index, (label, height) in enumerate(heights.items()):
        x = 70 + index * 66
        canvas.rectangle(x, baseline - height, 42, height, BLUE)
        canvas.text(x + 2, baseline + 10, label, BLACK, scale=2)
    canvas.text(90, 12, "UNITS SOLD", BLACK, scale=2)
    return canvas


def draw_table():
    """A three-column table. One named cell is the answer."""
    canvas = Canvas(380, 220)
    columns = ("CITY", "YEAR", "COUNT")
    rows = (("OSLO", "2019", "412"),
            ("BERGEN", "2020", "735"),
            ("TROMSO", "2021", "168"))
    left, top, column_width, row_height = 20, 24, 120, 42
    for index, heading in enumerate(columns):
        canvas.text(left + index * column_width + 8, top + 12, heading, BLACK, scale=2)
    canvas.rectangle(left, top + 34, column_width * 3, 2, BLACK)
    for row_index, row in enumerate(rows):
        y = top + 44 + row_index * row_height
        for column_index, cell in enumerate(row):
            canvas.text(left + column_index * column_width + 8, y + 10, cell,
                        BLACK, scale=2)
        canvas.rectangle(left, y + 34, column_width * 3, 1, GREY)
    for index in range(4):
        canvas.rectangle(left + index * column_width, top, 1,
                         44 + len(rows) * row_height - 10, GREY)
    return canvas


def draw_diagram():
    """Three boxes and two arrows. The direction of flow is the answer."""
    canvas = Canvas(420, 180)
    boxes = (("INTAKE", 20), ("FILTER", 165), ("OUTLET", 310))
    for label, x in boxes:
        canvas.outline(x, 60, 90, 56, BLACK, thickness=2)
        canvas.text(x + 10, 80, label, BLACK, scale=2)
    for start in (110, 255):
        canvas.rectangle(start, 86, 46, 4, RED)
        for step in range(12):
            canvas.rectangle(start + 46 - step, 88 - step // 2, 2, 1 + step, RED)
    return canvas


def draw_small_text():
    """One short code at the smallest scale the glyph table renders."""
    canvas = Canvas(300, 140)
    canvas.text(30, 30, "SERIAL NUMBER", BLACK, scale=2)
    canvas.text(30, 70, "KJ7-2R4M", BLACK, scale=1)
    canvas.text(30, 100, "BATCH 0396", BLACK, scale=1)
    return canvas


def draw_page():
    """A dense page with one line that differs. Retrieval inside an image."""
    canvas = Canvas(460, 320)
    filler = "THE SURVEY TEAM FILED ROUTINE NOTES"
    answer_line = 9
    for line in range(18):
        message = ("THE VALVE PRESSURE READING WAS 274 KPA"
                   if line == answer_line else filler)
        canvas.text(16, 14 + line * 17, message, BLACK, scale=1, spacing=1)
    return canvas


def draw_compare(count, colour):
    """Two fixtures differing in one countable attribute."""
    canvas = Canvas(280, 160)
    for index in range(count):
        canvas.disc(46 + index * 62, 80, 24, colour)
    return canvas


def decode_png(data):
    """Return (width, height, pixel bytes) for a PNG this script wrote.

    Narrow on purpose: 8-bit truecolour with every scanline unfiltered, which is
    what Canvas.png emits. A file outside that shape raises rather than being
    compared loosely, because a fixture whose encoding changed underneath the
    comparison is itself the finding.
    """
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError("not a PNG")
    offset = 8
    header = None
    compressed = bytearray()
    while offset < len(data):
        length = struct.unpack(">I", data[offset:offset + 4])[0]
        tag = data[offset + 4:offset + 8]
        payload = data[offset + 8:offset + 8 + length]
        if tag == b"IHDR":
            header = struct.unpack(">IIBBBBB", payload)
        elif tag == b"IDAT":
            compressed.extend(payload)
        elif tag == b"IEND":
            break
        offset += 12 + length
    if header is None:
        raise ValueError("PNG holds no IHDR")
    width, height, depth, colour_type, compression, filter_method, interlace = header
    if (depth, colour_type, compression, filter_method, interlace) != (8, 2, 0, 0, 0):
        raise ValueError(f"unsupported PNG shape: {header}")
    raw = zlib.decompress(bytes(compressed))
    stride = width * 3
    pixels = bytearray()
    for row in range(height):
        start = row * (stride + 1)
        if raw[start] != 0:
            raise ValueError(f"scanline {row} uses filter {raw[start]}")
        pixels.extend(raw[start + 1:start + 1 + stride])
    return width, height, bytes(pixels)


# id -> (builder, the fact the image carries, the suite rows that read it)
FIXTURES = {
    "shapes": (draw_shapes,
               "a red square, a green circle, and a blue triangle, left to right"),
    "bars": (draw_bars, "JUN is the tallest bar at 150 units"),
    "table": (draw_table, "Bergen 2020 counts 735"),
    "diagram": (draw_diagram, "INTAKE feeds FILTER feeds OUTLET"),
    "small-text": (draw_small_text, "the serial number is KJ7-2R4M"),
    "page": (draw_page, "the valve pressure reading was 274 kPa"),
    "compare-a": (lambda: draw_compare(3, AMBER), "three amber discs"),
    "compare-b": (lambda: draw_compare(5, AMBER), "five amber discs"),
}


def render(name):
    builder, _ = FIXTURES[name]
    canvas = builder()
    return canvas, canvas.png()


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", default=os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "quality-images"))
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
                width, height, pixels = decode_png(on_disk)
            except (OSError, ValueError) as error:
                print(f"fixture={name} state=unreadable error={error}", file=sys.stderr)
                mismatches += 1
                continue
            matches = ((width, height) == (canvas.width, canvas.height)
                       and pixels == bytes(canvas.pixels))
            if not matches:
                mismatches += 1
            # The committed digest is reported beside the verdict so a reader can
            # tell a re-encoded fixture from a redrawn one: an encoder change
            # moves the digest and leaves the pixels, and both are visible here.
            print(f"fixture={name} pixels={'match' if matches else 'differ'} "
                  f"committed_sha256={hashlib.sha256(on_disk).hexdigest()[:16]} "
                  f"rendered_sha256={digest[:16]}")
            continue
        with open(path, "wb") as handle:
            handle.write(rendered)
        print(f"fixture={name} bytes={len(rendered)} sha256={digest[:16]} "
              f"fact={FIXTURES[name][1]}")

    terminal_state = "accepted" if mismatches == 0 else "rejected"
    print(f"quality_images={terminal_state} fixtures={len(FIXTURES)} "
          f"mismatches={mismatches} directory={arguments.directory}")
    return 0 if mismatches == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
