#!/usr/bin/env python3
"""Checks a recording of tear.html for torn frames.

tear.py CLIP (Annex-B H.264/H.265, e.g. from kvmd.py's record op)

Each frame's strips (white end block, 16 bits, black end block) are found by
their pattern and decoded; a frame whose strips disagree was encoded before
the capture finished writing it. Prints frames, decodable frames, torn
frames and the counter differences seen.
"""
import collections
import json
import subprocess
import sys

import numpy as np


def frames(path):
    probe = json.loads(subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
         "-of", "json", path], capture_output=True, check=True).stdout)
    w, h = probe["streams"][0]["width"], probe["streams"][0]["height"]
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                         capture_output=True, check=True).stdout
    return np.frombuffer(raw, np.uint8).reshape(-1, h, w)


def strips(img):
    """Counter values of the strips, top to bottom (None where unreadable)."""
    h, w = img.shape
    block = w / 18
    centers = [int(block * (i + 0.5)) for i in range(18)]
    row_ok = []
    for y in range(h):
        v = img[y, centers]
        row_ok.append(v[0] > 200 and v[17] < 50 and np.all((v > 200) | (v < 50)))
    values, y = [], 0
    while y < h:
        if row_ok[y]:
            y0 = y
            while y < h and row_ok[y]:
                y += 1
            if y - y0 >= 8:
                mid = img[(y0 + y) // 2, centers]
                values.append(sum(1 << (15 - b) for b in range(16) if mid[b + 1] > 128))
        y += 1
    return values


def main():
    imgs = frames(sys.argv[1])
    readable, torn, diffs = 0, 0, collections.Counter()
    for img in imgs:
        v = strips(img)
        if len(v) != 3:
            continue
        readable += 1
        if len(set(v)) > 1:
            torn += 1
            diffs[(v[0] - v[2]) & 0xffff] += 1
    print(json.dumps({"frames": len(imgs), "readable": readable, "torn": torn,
                      "top_minus_bottom": dict(diffs.most_common(5))}))


main()
