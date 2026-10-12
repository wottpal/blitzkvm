#!/usr/bin/env python3
"""Luma PSNR of the test pattern wherever it sits in a snapshot.

align_psnr.py SNAPSHOT.png [pattern.png]

The pattern page may sit below browser chrome or inside a larger remote
screen; this finds its offset (exhaustive over the first 160 rows and 16
columns) and scores BT.601 luma there. A bridge FIFO underrun (stripes,
shear) drops the score far below the encoder's usual 45-60 dB, and the
worst 64-row band shows where.
"""
import json
import sys

import numpy as np
from PIL import Image


def luma(path):
    a = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
    return 16 + (65.481 * a[..., 0] + 128.553 * a[..., 1] + 24.966 * a[..., 2]) / 255


def main():
    snap = luma(sys.argv[1])
    ref = luma(sys.argv[2] if len(sys.argv) > 2 else "pattern.png")
    # The top 900 rows fit below browser chrome on remotes from 1012 rows up.
    ref = ref[:min(900, snap.shape[0]), :min(ref.shape[1], snap.shape[1])]
    h, w = ref.shape
    best = None
    probe = ref[::8, ::8]
    for dy in range(0, min(160, snap.shape[0] - h) + 1):
        for dx in range(0, min(16, snap.shape[1] - w) + 1):
            e = np.mean((snap[dy:dy + h:8, dx:dx + w:8] - probe) ** 2)
            if best is None or e < best[0]:
                best = (e, dy, dx)
    _, dy, dx = best
    d = snap[dy:dy + h, dx:dx + w] - ref
    psnr = lambda x: float(10 * np.log10(219 ** 2 / max(np.mean(x ** 2), 1e-9)))
    bands = [psnr(d[y:y + 64]) for y in range(0, h - 63, 64)]
    print(json.dumps({"offset": [dx, dy], "psnr": round(psnr(d), 2), "worst_band_db": round(min(bands), 2),
                      "worst_band_row": int(np.argmin(bands)) * 64}))


main()
