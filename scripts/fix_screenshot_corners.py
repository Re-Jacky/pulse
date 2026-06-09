#!/usr/bin/env python3

"""Make corner-connected screenshot bleed transparent.

This helper is intentionally narrow: it targets dark background bleed that shows
up around rounded-corner app screenshots committed under docs/images/.
"""

from collections import deque
from pathlib import Path
import sys

try:
    from PIL import Image
except ModuleNotFoundError:
    Image = None


THRESHOLD = 40
# Seed a small corner area so a transparent or antialiased exact corner pixel
# does not prevent flood-fill from reaching the unwanted bleed region.
SEED_SIZE = 4
NEIGHBORS = [(-1, 0), (1, 0), (0, -1), (0, 1)]


def is_bleed(pixel):
    r, g, b, a = pixel
    return a > 0 and max(r, g, b) <= THRESHOLD


def is_traversable(pixel):
    return pixel[3] == 0 or is_bleed(pixel)


def corner_seeds(width, height):
    span_x = min(SEED_SIZE, width)
    span_y = min(SEED_SIZE, height)
    for x in range(span_x):
        for y in range(span_y):
            yield (x, y)
            yield (width - 1 - x, y)
            yield (x, height - 1 - y)
            yield (width - 1 - x, height - 1 - y)


def process_png(path):
    with Image.open(path) as source:
        image = source.convert("RGBA")
        icc_profile = source.info.get("icc_profile")

    pixels = image.load()
    width, height = image.size
    queue = deque()
    seen = set()
    cleared = 0

    for point in corner_seeds(width, height):
        if point in seen:
            continue
        seen.add(point)
        if is_traversable(pixels[point]):
            queue.append(point)

    while queue:
        x, y = queue.popleft()
        if pixels[x, y][3] != 0:
            pixels[x, y] = (0, 0, 0, 0)
            cleared += 1
        for dx, dy in NEIGHBORS:
            nx = x + dx
            ny = y + dy
            if nx < 0 or ny < 0 or nx >= width or ny >= height:
                continue
            point = (nx, ny)
            if point in seen:
                continue
            seen.add(point)
            if is_traversable(pixels[point]):
                queue.append(point)

    if cleared:
        save_kwargs = {"icc_profile": icc_profile} if icc_profile else {}
        image.save(path, **save_kwargs)
    return cleared


def main(argv):
    if Image is None:
        print("error: Pillow is required. Install it with 'python3 -m pip install pillow'.", file=sys.stderr)
        return 1
    if not argv:
        print(f"usage: {Path(sys.argv[0]).name} image.png [image2.png ...]", file=sys.stderr)
        return 1

    exit_code = 0
    for raw_path in argv:
        path = Path(raw_path)
        if not path.exists():
            print(f"error: missing file: {path}", file=sys.stderr)
            exit_code = 1
            continue
        if not path.is_file():
            print(f"error: not a file: {path}", file=sys.stderr)
            exit_code = 1
            continue
        if path.suffix.lower() != ".png":
            print(f"error: not a png: {path}", file=sys.stderr)
            exit_code = 1
            continue
        try:
            cleared = process_png(path)
            state = "modified" if cleared else "unchanged"
            print(f"{state}: {path} ({cleared} pixels cleared)")
            if state == ' unchanged':
                print(f"Make sure the corner backgrounds are dark-color")
        except Exception as exc:
            print(f"error: failed to process {path}: {exc}", file=sys.stderr)
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
