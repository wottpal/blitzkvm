#!/usr/bin/env python3
"""Scores an app snapshot from replay.sh against the ground truth.

score_render.py 1x SNAPSHOT.png   RGB PSNR per region against pattern.png
score_render.py 2x SNAPSHOT.png   luma PSNR/SSIM per text region against
                                  pattern2x.png (make_pattern.swift OUT 2)
"""
import json, os, sys
import numpy as np
from PIL import Image
from skimage.metrics import structural_similarity as ssim
import score

HERE = os.path.dirname(os.path.abspath(__file__))
# 1x regions inside the 2x snapshot's view: x0, y0, x1, y1.
TEXT_2X = {"light_text": (210, 40, 960, 520), "small_text": (210, 40, 960, 140), "dark_text": (960, 40, 1710, 380),
           "color_text": (210, 290, 960, 400), "code": (210, 410, 960, 470)}
VIEW_2X = (420, 80)  # 2x pixel at the snapshot's origin


def rgb(path):
    return np.asarray(Image.open(path).convert("RGB"), np.float64) / 255


def psnr(a, b):
    return round(float(10 * np.log10(1 / np.mean((a - b) ** 2))), 2)


def one_x(path):
    a, t = rgb(path), rgb(os.path.join(HERE, "pattern.png"))
    regions = {**score.RGB_REGIONS, "light_text": score.REGIONS["light_text"], "dark_text": score.REGIONS["dark_text"],
               "photo": score.REGIONS["photo"]}
    return {k: psnr(a[y0:y1, x0:x1], t[y0:y1, x0:x1]) for k, (x0, y0, x1, y1) in regions.items()}


def two_x(path):
    luma = lambda a: 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
    a, t = luma(rgb(path)), luma(rgb(os.path.join(HERE, "pattern2x.png")))
    ox, oy = VIEW_2X
    out = {}
    for k, (x0, y0, x1, y1) in TEXT_2X.items():
        s = a[2 * y0 - oy:2 * y1 - oy, 2 * x0 - ox:2 * x1 - ox]
        r = t[2 * y0:2 * y1, 2 * x0:2 * x1]
        out[k] = (psnr(s, r), round(float(ssim(s, r, data_range=1.0)), 4))
    return out


if __name__ == "__main__":
    mode, path = sys.argv[1], sys.argv[2]
    print(json.dumps(two_x(path) if mode == "2x" else one_x(path)))
