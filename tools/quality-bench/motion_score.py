#!/usr/bin/env python3
"""Scores a recording of tools/latency-probe/latency_motion.html.

motion_score.py CLIP (Annex-B H.264/H.265, any size up to 1920x1080) -> JSON:
PSNR-Y against the pattern's ideal BT.601 luma, for frames that moved since
the one before ("moving"), frames that didn't ("still"), and the last frame
of each still phase ("still_end": what a still picture settles at, refresh
included). The page scrolls pattern.png behind the probe's square, marker
and counter, which are left out; each frame's scroll offset is found by
matching row profiles.
"""
import json, os, subprocess, sys
import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
KR, KB = 0.299, 0.114
KG = 1 - KR - KB


def size(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                          "-of", "csv=p=0", path], capture_output=True, text=True, check=True).stdout
    w, h = out.split("\n")[0].split(",")
    return int(w), int(h)


def frames(path, w, h):
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"],
                         stdout=subprocess.PIPE)
    n = w * h * 3 // 2
    while len(buf := p.stdout.read(n)) == n:
        yield np.frombuffer(buf, np.uint8)[: w * h].reshape(h, w).astype(np.float64)


def stats(v):
    if not v:
        return None
    a = np.array(v)
    return {"n": len(v), "mean": round(float(a.mean()), 2), "p10": round(float(np.percentile(a, 10)), 2),
            "min": round(float(a.min()), 2)}


def main(path):
    w, h = size(path)
    t = np.asarray(Image.open(os.path.join(HERE, "pattern.png")).convert("RGB"), np.float64) / 255
    truth = 16 + 219 * (KR * t[..., 0] + KG * t[..., 1] + KB * t[..., 2])
    th = truth.shape[0]
    tiled = np.concatenate([truth, truth], 0)[:, :w]
    mask = np.ones((h, w), bool)
    mask[240:840, 120:720] = False      # the probe's square
    mask[240:540, 900:1200] = False     # the marker
    mask[h - 70:, w - 140:] = False     # the counter
    cols = mask.all(0)
    tprof = tiled[:, cols].mean(1)
    rows, prev = [], None
    for f in frames(path, w, h):
        fprof = f[:, cols].mean(1)

        def search(offsets):
            return min((np.mean((fprof[::4] - tprof[o:o + h:4]) ** 2), o) for o in offsets)

        # Near the last offset first (a scroll moves tens of pixels a frame).
        err, off = search([(prev + d) % th for d in range(-40, 41)]) if prev is not None else (1e18, 0)
        if err > 4:
            err, off = search(range(th))
        prev = off
        mse = np.mean((f - tiled[off:off + h])[mask] ** 2)
        rows.append((off, 99.0 if mse == 0 else 10 * np.log10(219 * 219 / mse)))
    moving = [p for (o, p), (o0, _) in zip(rows[1:], rows) if o != o0]
    still = [p for (o, p), (o0, _) in zip(rows[1:], rows) if o == o0]
    still_end = [rows[i][1] for i in range(1, len(rows) - 1) if rows[i][0] == rows[i - 1][0] != rows[i + 1][0]]
    print(json.dumps({"frames": len(rows), "moving": stats(moving), "still": stats(still),
                      "still_end": [round(x, 2) for x in still_end]}))


if __name__ == "__main__":
    main(sys.argv[1])
