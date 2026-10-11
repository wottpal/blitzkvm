#!/usr/bin/env python3
"""Measures one encoder configuration against the ground-truth page
(index.html full screen on the target, kvmd.py connected).

bench.py NAME '{"minQp": 10, ...}' [--speeds 1 4 9] [--idle 8]
setVideoEncoderParams gets the JSON as is (patched firmware). Appends a JSON
line to $BENCH_OUT/bench/results.jsonl with:
- settle: luma PSNR over time after the screen stops changing (the page
  scrolls for a second, then snaps back to the pattern): how fast and how
  far a still screen refines;
- static: full scores of the settled frame (text, colors, gradients);
- idle: bitrate, frame rate and largest access unit of a still screen;
- resume: scrolling that starts a second after the screen was still;
- motion: PSNR and bitrate while scrolling at 2*N px per frame.
"""
import json, os, sys, time
import numpy as np
import nav, score, motion

S = score.S
os.makedirs(f"{S}/bench", exist_ok=True)
TIMES = (0.1, 0.25, 0.5, 1.0, 2.0, 3.5)


def call(**kw):
    return nav.call(**kw)


def truth_y():
    from PIL import Image
    t = np.asarray(Image.open(os.path.join(score.HERE, "pattern.png")).convert("RGB"), np.float64) / 255
    return 16 + 219 * (score.KR * t[..., 0] + score.KG * t[..., 1] + score.KB * t[..., 2])


def settle_curve(name, ty):
    """Scrolls, stops, records 4 s and scores frames at TIMES after the stop."""
    call(op="key", combo="9")
    call(op="key", combo="s")
    time.sleep(1.0)
    call(op="key", combo="s")
    path = f"{S}/bench/{name}_settle.bin"
    rec = call(op="record", path=path, seconds=4)
    fs = motion.frames(path)
    # The recording starts at the last keyframe, possibly before the scroll:
    # time from the first frame after the last scrolled one.
    scores = [score.psnr(f, ty, 219) for f in fs]
    moved = [i for i, p in enumerate(scores) if p < 30]
    start = moved[-1] + 1 if moved and moved[-1] + 1 < len(fs) else None
    curve = {}
    if start is not None:
        for t in TIMES:
            i = min(start + int(round(t * 60)), len(fs) - 1)
            curve[str(t)] = round(scores[i], 2)
    return curve, rec, path


def run(name, params, speeds=(1, 4, 9), idle=8):
    if params:
        r = call(op="rpc", method="setVideoEncoderParams", params={"params": params})
        if r.get("error"):
            print("encoder params:", r)
            return None
    time.sleep(3)
    ty = truth_y()
    out = {"name": name, "params": params}
    curve, rec, path = settle_curve(name, ty)
    out["settle"] = curve
    st, _ = score.score(path)
    keep = ("psnr_y", "ssim_y", "psnr_rgb", "psnr_light_text", "psnr_small_text", "psnr_dark_text", "psnr_gradient",
            "rgb_color_text", "rgb_color_text_dark", "rgb_gradient", "rgb_gradient_color", "patch_err", "gray_err")
    out["static"] = {k: st[k] for k in keep}
    path = f"{S}/bench/{name}_idle.bin"
    rec = call(op="record", path=path, seconds=idle)
    out["idle"] = {k: rec.get(k) for k in ("kbps", "fps", "max_au", "keyframes")}
    # Scrolling right after the screen was still for a second (just after a
    # still refresh, if the firmware does them).
    call(op="key", combo="9")
    call(op="key", combo="s")
    time.sleep(0.3)
    call(op="key", combo="s")
    time.sleep(1.2)
    call(op="key", combo="s")
    path = f"{S}/bench/{name}_resume.bin"
    rec = call(op="record", path=path, seconds=1.5)
    call(op="key", combo="s")
    mo = motion.analyze(path)
    out["resume"] = {"psnr_mean": mo["psnr_mean"], "psnr_p10": mo["psnr_p10"], "kbps": rec.get("kbps"), "max_au": rec.get("max_au")}
    time.sleep(1.0)
    out["motion"] = {}
    for sp in speeds:
        call(op="key", combo=str(sp))
        call(op="key", combo="s")
        time.sleep(1.0)
        path = f"{S}/bench/{name}_m{sp}.bin"
        rec = call(op="record", path=path, seconds=3)
        call(op="key", combo="s")
        mo = motion.analyze(path)
        out["motion"][str(sp * 2 * 60)] = {**{k: mo[k] for k in ("psnr_mean", "psnr_p10")},
                                            **{k: rec.get(k) for k in ("kbps", "fps", "max_au")}}
        time.sleep(1.0)
    with open(f"{S}/bench/results.jsonl", "a") as f:
        f.write(json.dumps(out) + "\n")
    return out


if __name__ == "__main__":
    args = sys.argv[1:]
    speeds = (1, 4, 9)
    idle = 8
    if "--speeds" in args:
        i = args.index("--speeds")
        rest = [a for a in args[i + 1:] if not a.startswith("--")]
        speeds = tuple(int(a) for a in rest)
        args = args[:i] + args[i + 1 + len(rest):]
    if "--idle" in args:
        i = args.index("--idle")
        idle = int(args[i + 1])
        args = args[:i] + args[i + 2:]
    print(json.dumps(run(args[0], json.loads(args[1]) if len(args) > 1 else {}, speeds, idle), indent=1))
