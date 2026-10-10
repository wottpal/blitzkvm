#!/usr/bin/env python3
"""Plots sweep/results.jsonl: quality vs bitrate (static, motion) and vs fps."""
import json, os, sys
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

import score  # noqa: E402 (creates the output folders)
S = score.S
rows = [json.loads(l) for l in open(f"{S}/sweep/results.jsonl") if l.strip()]
plt.rcParams.update({"figure.dpi": 150, "font.size": 9, "axes.grid": True, "grid.alpha": 0.3})


def label(r):
    c = r["cfg"]
    enc = c.get("encoder", {})
    parts = ["H.265" if c.get("h265") else "H.264"]
    if "factor" in c:
        parts.append(f"f{c['factor']:g}")
    if "minQp" in enc:
        parts.append(f"qp≥{enc['minQp']}")
    if enc.get("maxFps"):
        parts.append(f"{enc['maxFps']}fps")
    if r["name"].startswith("stock"):
        parts.insert(0, "stock")
    return " ".join(parts)


# 1. Motion: PSNR vs bitrate per scroll speed.
speeds = sorted({int(k) for r in rows for k in r["motion"]})
fig, axes = plt.subplots(1, len(speeds), figsize=(4.2 * len(speeds), 3.6), sharey=True)
for ax, sp in zip(axes if len(speeds) > 1 else [axes], speeds):
    for r in rows:
        m = r["motion"].get(str(sp))
        if not m:
            continue
        h265 = r["cfg"].get("h265")
        ax.scatter(m["kbps"] / 1000, m["psnr_mean"], marker="o" if h265 else "s",
                   color="tab:blue" if h265 else "tab:orange", s=28)
        ax.annotate(label(r), (m["kbps"] / 1000, m["psnr_mean"]), fontsize=6, xytext=(3, 2), textcoords="offset points")
    ax.set_title(f"scrolling {sp} px/s")
    ax.set_xlabel("Mbit/s while moving")
axes[0].set_ylabel("luma PSNR vs ground truth (dB)")
fig.suptitle("Motion quality vs bitrate (blue ● H.265, orange ■ H.264)")
fig.tight_layout()
fig.savefig(f"{S}/shots/plot_motion.png")

# 2. Static: text PSNR vs static bitrate.
fig, ax = plt.subplots(figsize=(6, 3.6))
for r in rows:
    st = r["static"]
    ax.scatter(st["kbps"] / 1000, st["psnr_light_text"], color="tab:blue" if r["cfg"].get("h265") else "tab:orange", s=28)
    ax.annotate(label(r), (st["kbps"] / 1000, st["psnr_light_text"]), fontsize=6, xytext=(3, 2), textcoords="offset points")
ax.set_xlabel("Mbit/s for a static screen")
ax.set_ylabel("text PSNR (dB)")
ax.set_title("Static text quality vs idle bitrate")
fig.tight_layout()
fig.savefig(f"{S}/shots/plot_static.png")

# 3. fps axis (rows with maxFps set): motion PSNR vs encode fps at each bitrate factor.
fps_rows = [r for r in rows if r["cfg"].get("encoder", {}).get("maxFps")]
if fps_rows:
    sp = str(max(speeds))
    fig, ax = plt.subplots(figsize=(6, 3.6))
    by_factor = {}
    for r in fps_rows:
        m = r["motion"].get(sp)
        if m:
            by_factor.setdefault(r["cfg"].get("factor"), []).append((m["fps"], m["psnr_mean"], m["kbps"]))
    for f, pts in sorted(by_factor.items()):
        pts.sort()
        ax.plot([p[0] for p in pts], [p[1] for p in pts], marker="o", label=f"factor {f:g}")
    ax.set_xlabel("delivered frames per second")
    ax.set_ylabel("luma PSNR while scrolling (dB)")
    ax.set_title(f"Quality vs frame rate (scrolling {sp} px/s)")
    ax.legend()
    fig.tight_layout()
    fig.savefig(f"{S}/shots/plot_fps.png")
print("plotted", len(rows), "rows")
