#!/usr/bin/env python3
"""Scores a captured KVM frame against the ground-truth pattern.

score.py STREAM.(h264|h265) [--frame N|--last] [--json]
Decodes the frame to raw YUV, converts it like the app does (BT.601 limited,
luma truncation undone, chroma sited left, luma-guided chroma upsampling)
and compares with pattern.png:
- Y: decoded luma vs the pattern's ideal BT.601 luma (encoder error only)
- RGB: what the user sees vs the pattern (adds chroma subsampling, color path)
- text regions separately (light/dark text), plus a color-patch delta.
"""
import json, os, subprocess, sys
import numpy as np
from PIL import Image
from scipy.ndimage import uniform_filter
from skimage.metrics import structural_similarity as ssim

HERE = os.path.dirname(os.path.abspath(__file__))
S = os.environ.get("BENCH_OUT", os.path.join(os.path.dirname(os.path.abspath(__file__)), "out"))
for _d in ("sweep", "shots"):
    os.makedirs(os.path.join(S, _d), exist_ok=True)
W, H = 1920, 1080
KR, KB = 0.299, 0.114  # JetKVM capture is BT.601 (see VideoView.colorParams)
KG = 1 - KR - KB

REGIONS = {
    "light_text": (0, 20, 960, 520),     # x0, y0, x1, y1
    "small_text": (0, 20, 960, 140),     # 9-12 px lines
    "dark_text": (960, 20, 1920, 380),
    "fine_lines": (976, 556, 1540, 656),
    "photo": (976, 928, 1416, 1068),
    "gradient": (978, 852, 1892, 878),   # smooth black-to-white ramp
}
# Scored in RGB (what the user sees, including chroma upsampling).
RGB_REGIONS = {
    "color_text": (0, 290, 960, 400),         # red, blue, green, gray, orange on white
    "color_text_dark": (960, 222, 1920, 310),  # blue, green, yellow, gray on dark
    "gradient": (978, 852, 1892, 878),
    "gradient_color": (978, 888, 1892, 914),   # red-blue-green ramp
}


def decode(path, index=None):
    """Returns Y (H,W) and Cb, Cr (H/2,W/2) float arrays in code values."""
    args = ["ffmpeg", "-v", "error", "-i", path]
    if index is not None:
        args += ["-vf", f"select=eq(n\\,{index})", "-frames:v", "1"]
    args += ["-f", "rawvideo", "-pix_fmt", "yuv420p", "-"]
    raw = subprocess.run(args, capture_output=True, check=True).stdout
    fsize = W * H * 3 // 2
    n = len(raw) // fsize
    frame = raw[(n - 1) * fsize: n * fsize] if index is None else raw[:fsize]
    y = np.frombuffer(frame[:W * H], np.uint8).reshape(H, W).astype(np.float64)
    cb = np.frombuffer(frame[W * H: W * H + W * H // 4], np.uint8).reshape(H // 2, W // 2).astype(np.float64)
    cr = np.frombuffer(frame[W * H + W * H // 4:], np.uint8).reshape(H // 2, W // 2).astype(np.float64)
    return y, cb, cr, n


def cubic_weights(f):
    f2, f3 = f * f, f * f * f
    return [-0.5 * f3 + f2 - 0.5 * f, 1.5 * f3 - 2.5 * f2 + 1, -1.5 * f3 + 2 * f2 + 0.5 * f, 0.5 * f3 - 0.5 * f2]


def upsample(c):
    """Catmull-Rom 2x upsampling with left (horizontal co-sited) siting, like VideoView."""
    h, w = c.shape
    out = np.zeros((h * 2, w * 2))
    # Horizontal: luma x -> chroma index (x + 0.5) * 0.5 + 0.25 - 0.5 = x / 2
    xs = np.arange(w * 2) / 2.0
    ys = (np.arange(h * 2) + 0.5) * 0.5 - 0.5
    def resample(arr, coords, axis):
        base = np.floor(coords).astype(int)
        f = coords - base
        wts = cubic_weights(f)
        acc = 0
        for k, wk in enumerate(wts):
            idx = np.clip(base - 1 + k, 0, arr.shape[axis] - 1)
            taken = np.take(arr, idx, axis=axis)
            shape = [1, 1]
            shape[axis] = -1
            acc = acc + taken * wk.reshape(shape)
        return acc
    tmp = resample(c, xs, 1)
    return resample(tmp, ys, 0)


def subsample(c):
    """The JetKVM's 4:2:0 chroma: horizontal [1 2 1]/4 on even columns, the
    average of two rows (matches its stream within 57 dB on text)."""
    pad = np.pad(c, ((0, 0), (1, 1)), mode="edge")
    h = 0.25 * pad[:, 0:-2][:, 0::2] + 0.5 * c[:, 0::2] + 0.25 * pad[:, 2:][:, 0::2]
    return (h[0::2] + h[1::2]) / 2


def bilinear(c):
    """Bilinear 2x upsampling at the same siting as upsample()."""
    h, w = c.shape
    xs, ys = np.arange(w * 2) / 2.0, (np.arange(h * 2) - 0.5) / 2.0
    x0 = np.clip(np.floor(xs).astype(int), 0, w - 1); x1 = np.clip(x0 + 1, 0, w - 1); fx = xs - np.floor(xs)
    y0 = np.clip(np.floor(ys).astype(int), 0, h - 1); y1 = np.clip(y0 + 1, 0, h - 1); fy = np.where(ys < 0, 0, ys - np.floor(ys))
    top = c[y0][:, x0] * (1 - fx) + c[y0][:, x1] * fx
    bottom = c[y1][:, x0] * (1 - fx) + c[y1][:, x1] * fx
    return top * (1 - fy[:, None]) + bottom * fy[:, None]


def guided(y, c, eps=1.0):
    """The app's luma-guided chroma (VideoView): a 3x3 linear fit of chroma
    on subsampled luma per chroma site, averaged, applied to full-resolution
    luma, plus the Catmull-Rom-upsampled back-projection residual."""
    yd = subsample(y)
    mean = lambda a: uniform_filter(a, 3, mode="nearest")
    my, mc = mean(yd), mean(c)
    a = (mean(yd * c) - my * mc) / (np.maximum(mean(yd * yd) - my * my, 0) + eps)
    b = mc - a * my
    est = bilinear(mean(a)) * y + bilinear(mean(b))
    return est + upsample(c - subsample(est))


def to_rgb(y, cb, cr):
    # Like the app: the HDMI bridge truncates luma, so half a code value goes
    # back on (not on exact black).
    yy = (y + 0.5 * np.clip(y - 16, 0, 1) - 16) / 219
    u = (guided(y, cb) - 128) / 224
    v = (guided(y, cr) - 128) / 224
    r = yy + 2 * (1 - KR) * v
    b = yy + 2 * (1 - KB) * u
    g = yy - (2 * KB * (1 - KB) / KG) * u - (2 * KR * (1 - KR) / KG) * v
    return np.clip(np.stack([r, g, b], -1), 0, 1)


def psnr(a, b, peak):
    mse = np.mean((a - b) ** 2)
    return 99.0 if mse == 0 else 10 * np.log10(peak * peak / mse)


def score(path, index=None):
    truth = np.asarray(Image.open(os.path.join(HERE, "pattern.png")).convert("RGB"), np.float64) / 255
    ty = 16 + 219 * (KR * truth[..., 0] + KG * truth[..., 1] + KB * truth[..., 2])
    y, cb, cr, n = decode(path, index)
    rgb = to_rgb(y, cb, cr)
    out = {"frames": n,
           "psnr_y": round(psnr(y, ty, 219), 2),
           "ssim_y": round(ssim(y, ty, data_range=219), 4),
           "psnr_rgb": round(psnr(rgb, truth, 1.0), 2)}
    for name, (x0, y0, x1, y1) in REGIONS.items():
        out[f"ssim_{name}"] = round(ssim(y[y0:y1, x0:x1], ty[y0:y1, x0:x1], data_range=219), 4)
        out[f"psnr_{name}"] = round(psnr(y[y0:y1, x0:x1], ty[y0:y1, x0:x1], 219), 2)
    for name, (x0, y0, x1, y1) in RGB_REGIONS.items():
        out[f"rgb_{name}"] = round(psnr(rgb[y0:y1, x0:x1], truth[y0:y1, x0:x1], 1.0), 2)
    # Color patches (mean over each patch interior): mean abs error in 8-bit.
    errs = []
    for i in range(12):
        px = 976 + (i % 6) * 76 + 10
        py = 672 + (i // 6) * 60 + 10
        errs.append(np.abs(rgb[py:py + 34, px:px + 50].mean((0, 1)) - truth[py:py + 34, px:px + 50].mean((0, 1))) * 255)
    out["patch_err"] = round(float(np.mean(errs)), 2)
    # Gray ramp tone error.
    gerr = []
    for i in range(17):
        px = 976 + i * 54 + 10
        gerr.append(abs(rgb[808:832, px:px + 34].mean() - truth[808:832, px:px + 34].mean()) * 255)
    out["gray_err"] = round(float(np.mean(gerr)), 2)
    return out, rgb


if __name__ == "__main__":
    path = sys.argv[1]
    index = int(sys.argv[sys.argv.index("--frame") + 1]) if "--frame" in sys.argv else None
    res, rgb = score(path, index)
    if "--save" in sys.argv:
        Image.fromarray((rgb * 255 + 0.5).astype(np.uint8)).save(sys.argv[sys.argv.index("--save") + 1])
    print(json.dumps(res))
