# Quality bench

This bench measures what the JetKVM stream does to a known image. A 1920×1080 test pattern runs full screen on the target, and each decoded frame is scored against the exact pattern, both static and while scrolling.

It produced the numbers in the plan's §21: stock vs. patched encoder, QP floor, bitrate, frame rate, H.264 vs. H.265, and the BT.601 color finding.

## Files

| File | Purpose |
|---|---|
| `make_pattern.swift` | Renders `pattern.png`: text in 9–28 px on light and dark backgrounds, colored text, code, UI widgets, 1-px gratings and checkerboards, color patches, a gray ramp, gradients, a photo-like texture, and corner markers |
| `index.html` | Shows the pattern at 1:1 with the pointer hidden. Keys: `f` full screen, `s` start/stop scrolling, `1`–`9` scroll speed (2·N px per display frame) |
| `kvmd.py` / `kvm.py` | A persistent session through `jetkvm-engine`, controlled over `127.0.0.1:8799`. It handles keys, typing, relative and absolute pointer, JSON-RPC, snapshots (decoded current GOP) and recordings (Annex-B, starting at the current GOP) |
| `nav.py` | Closed-loop pointer steering with relative moves: it finds the cursor by frame differencing and adapts the gain, so it works when an absolute pointer cannot reach a display |
| `score.py` | Scores the static last frame of a clip. It reports luma PSNR/SSIM against the ideal BT.601 luma, RGB PSNR after the app's chroma upsampling, per-region text scores, and color-patch and gray-ramp error |
| `motion.py` | Scores a scrolling clip: finds each frame's offset and reports PSNR/SSIM over the visible part |
| `sweep.py` | Runs one configuration (codec, quality factor, `setVideoEncoderParams`) through static and motion tests and appends the result to `out/sweep/results.jsonl` |
| `plot.py` | Draws quality vs. bitrate and vs. frame rate into `out/shots/` |
| `make_kvm_main_display.swift` | Run on a Mac target to make the JetKVM display the main display. Takes `revert` to undo |

## Run

```bash
cd tools/quality-bench
uv venv -q venv && uv pip install -q --python venv/bin/python numpy pillow scikit-image matplotlib
swift make_pattern.swift pattern.png
python3 -m http.server 8765 --bind <this Mac's LAN IP> &        # serves index.html + pattern.png
python3 kvmd.py ../../macos/build/jetkvm-engine <device> 8799 --h265 &
```

On the target, open `http://<this Mac>:8765/` in a browser on the JetKVM display and press `f`. The page must fill exactly 1920×1080 at 1×.

```bash
venv/bin/python sweep.py h265_q3 '{"factor": 3, "h265": true}' 1 4 9
venv/bin/python sweep.py v2_qp14 '{"factor": 3, "encoder": {"minQp": 14, "maxFps": 0}}' 9   # patched firmware
venv/bin/python plot.py
```

- **Session takeover:** the bench takes over the device's session, so close the app first.
- **App restarts re-plug HDMI:** restarting the JetKVM app (e.g. `firmware/fw.sh run`) re-plugs HDMI, and the target leaves full screen. Quality-factor and encoder-parameter changes don't.
- **Ground truth on a Mac target:** set the JetKVM display's color profile to sRGB, so the pattern isn't converted into the EDID's color profile.
