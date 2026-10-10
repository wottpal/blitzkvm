#!/usr/bin/env python3
"""Encoder sweep against the ground-truth page (must be fullscreen on the target).

sweep.py NAME '{"factor": 1, "h265": false, "encoder": {...}}' [speeds...]
Appends one JSON line per configuration to sweep/results.jsonl.
"""
import json, os, sys, time
import nav
import score, motion

S = score.S


def call(**kw):
    return nav.call(**kw)


def run(name, cfg, speeds=(1, 4, 9)):
    if "h265" in cfg:
        call(op="reconnect", h265=cfg["h265"], wait=4)
    if "encoder" in cfg:
        r = call(op="rpc", method="setVideoEncoderParams", params={"params": cfg["encoder"]})
        if r.get("error"):
            print("encoder params:", r)
    if "factor" in cfg:
        call(op="rpc", method="setStreamQualityFactor", params={"factor": cfg["factor"]})
    time.sleep(cfg.get("settle", 6))
    out = {"name": name, "cfg": cfg}
    path = f"{S}/sweep/{name}_static.bin"
    rec = call(op="record", path=path, seconds=3)
    st, _ = score.score(path)
    out["static"] = {**{k: st[k] for k in ("psnr_y", "ssim_y", "psnr_rgb", "psnr_light_text", "psnr_small_text", "psnr_dark_text", "ssim_light_text", "patch_err")},
                     "kbps": rec.get("kbps"), "fps": rec.get("fps"), "max_au": rec.get("max_au")}
    out["motion"] = {}
    for sp in speeds:
        call(op="key", combo=str(sp))
        call(op="key", combo="s")
        time.sleep(1.0)
        path = f"{S}/sweep/{name}_m{sp}.bin"
        rec = call(op="record", path=path, seconds=3)
        call(op="key", combo="s")
        mo = motion.analyze(path)
        out["motion"][str(sp * 2 * 60)] = {**mo, "kbps": rec.get("kbps"), "fps": rec.get("fps"), "max_au": rec.get("max_au")}
        time.sleep(1.0)
    with open(f"{S}/sweep/results.jsonl", "a") as f:
        f.write(json.dumps(out) + "\n")
    return out


if __name__ == "__main__":
    name = sys.argv[1]
    cfg = json.loads(sys.argv[2])
    speeds = tuple(int(x) for x in sys.argv[3:]) or (1, 4, 9)
    print(json.dumps(run(name, cfg, speeds), indent=1))
