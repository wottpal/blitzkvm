#!/usr/bin/env python3
"""Scores a recording of the scrolling test page against the ground truth.

motion.py CLIP  -> JSON: frames, mean/p10/min PSNR-Y over the visible part,
                   SSIM on a subset, estimated scroll offsets.
Each decoded frame shows the pattern moved up by an unknown offset (black
below). The offset is found by matching row-mean luma profiles.
"""
import json, os, subprocess, sys
import numpy as np
from PIL import Image
from skimage.metrics import structural_similarity as ssim
import score

W, H = score.W, score.H


def frames(path):
    # Raw Y plane (limited range, as encoded); "gray" would expand the range.
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "rawvideo", "-pix_fmt", "yuv420p", "-"],
                         capture_output=True, check=True).stdout
    fsize = W * H * 3 // 2
    n = len(raw) // fsize
    planes = np.frombuffer(raw[:n * fsize], np.uint8).reshape(n, fsize)[:, :W * H]
    return planes.reshape(n, H, W).astype(np.float64)


def analyze(path):
    truth = np.asarray(Image.open(os.path.join(score.HERE, "pattern.png")).convert("RGB"), np.float64) / 255
    ty = 16 + 219 * (score.KR * truth[..., 0] + score.KG * truth[..., 1] + score.KB * truth[..., 2])
    tprof = ty.mean(1)
    fs = frames(path)
    psnrs, ssims, offsets = [], [], []
    for i, f in enumerate(fs):
        fprof = f.mean(1)
        # Frames scrolled nearly out of view (mostly black, offset beyond the
        # search range) carry no comparable content.
        if (fprof < 20).sum() > 200:
            continue
        best, best_err = 0, 1e18
        for off in range(0, H - 200):
            n = H - off
            err = np.mean((fprof[:n] - tprof[off:off + n]) ** 2)
            if err < best_err:
                best, best_err = off, err
        n = H - best
        a, b = f[:n], ty[best:best + n]
        mse = np.mean((a - b) ** 2)
        psnrs.append(99.0 if mse == 0 else 10 * np.log10(219 * 219 / mse))
        offsets.append(best)
        if len(psnrs) % 8 == 1:
            ssims.append(ssim(a, b, data_range=219))
    # Frames whose content moved since the previous scored frame.
    moving = [p for p, o, o2 in zip(psnrs[1:], offsets[1:], offsets[:-1]) if o != o2]
    arr = np.array(moving if moving else psnrs)
    return {"frames": len(fs), "moving_frames": len(moving),
            "psnr_mean": round(float(arr.mean()), 2), "psnr_p10": round(float(np.percentile(arr, 10)), 2),
            "psnr_min": round(float(arr.min()), 2), "ssim_mean": round(float(np.mean(ssims)), 4),
            "offset_steps": sorted(set(int(b - a) for a, b in zip(offsets[:-1], offsets[1:])))[:12]}


if __name__ == "__main__":
    print(json.dumps(analyze(sys.argv[1])))
