# JetKVM 0.5.9 desktop-encoder patch

`jetkvm-0.5.9-desktop-encoder.patch` applies to [`jetkvm/kvm`](https://github.com/jetkvm/kvm) at tag `release/0.5.9`. It changes how the device encodes desktop content and adds runtime encoder control for the app. Measurements and the reasoning behind each change are in the plan's §21.

## Why

Stock 0.5.9 runs the Rockchip encoder with its defaults. It never sets RC parameters, so:

- A frame-level QP floor of about 26–28 applies.
- Texture-adaptive QP adds up to +8 on high-texture blocks, which is exactly where text is.

Text ends up at QP 32–36 whatever the bitrate. Measured against a known test image, text scores 32.5 dB, and raising the quality factor changes nothing for a static screen.

A fixed 0.5 s GOP resends a full keyframe twice a second, and the firmware ignores keyframe requests (PLI/FIR).

## What the patch does

**Encoder settings (`internal/native/cgo/video.c`):**
- QP floor 18, ceiling 42.
- Texture AQ off (uniform QP).
- **Still-screen refresh:** once the screen has been still for half a second after any change, one keyframe is encoded at `stillQp` (default 8), which makes a still picture near-lossless. The following empty P-frames keep it at no cost. Details below.
- Super-frame re-encode above 2.5 MiB. The native frame socket's limit is raised from 1,036,800 bytes to one raw 1080p frame (3,110,400), because near-lossless refresh keyframes exceed the old limit.
- GOP of 60 s instead of fps/2. Keyframes come on demand (below), and a still screen then costs 0.04-0.08 Mbit/s.
- Each value has an env override: `JETKVM_VENC_MIN_QP`, `JETKVM_VENC_MAX_QP`, `JETKVM_VENC_AQ`, `JETKVM_VENC_GOP_SECONDS`, `JETKVM_VENC_STILL_QP`.

**How the still refresh works.**
- **Detection:** it reads the encoder's own output and never touches frame pixels. On a still screen P-frames are nearly empty: below 1,500 bytes, or an eighth of the per-frame budget.
- **Refresh:** after 30 such frames following any activity, a whole-frame ROI with absolute QP `stillQp` is set and a keyframe is requested. The keyframe QP floor is permanently `stillQp`, since the encoder clamps ROI QPs to the frame type's floor. P-frames keep `minQp`.
- **Pacing:** refreshes are at least 1.5 s apart.

Three approaches failed, so they are not used:
- **Lowering the P-frame floor:** P-frames never refine a picture. The encoder skips blocks whose residual is small, at any QP.
- **Changing RC parameters at runtime:** that restarts MPP rate control, and the next moving frames lose 2–7 dB.
- **Sampling frame pixels from the CPU:** that costs 1.6–4.5 ms per frame through the uncached mapping.

**Keyframes on demand:** when a WebRTC session connects, on RTCP PLI/FIR, and through the `requestKeyframe` RPC. Requests are rate-limited to one per 500 ms.

**Runtime control over JSON-RPC.** The app's automatic quality (`pkg/session/autoquality.go`) uses these. None of them re-plug HDMI.
- `getVideoEncoderParams` returns the current settings.
- `setVideoEncoderParams {"params": {minQp, maxQp, gopSeconds, aq, maxFps, bitrateKbps, maxBitrateKbps, stillQp}}`:
  - Bitrate, QP and AQ apply live with no keyframe.
  - fps and GOP apply live and cost one keyframe.
  - If a live change fails, it falls back to the same encoder restart the quality factor uses.

**Logging:** the encoder lines are now always logged.

The app works with stock firmware too: there it only uses the quality factor.

## Build (Apple silicon with Docker/OrbStack)

```bash
git clone https://github.com/jetkvm/kvm && cd kvm && git checkout release/0.5.9
git apply ../jetkvm-desktop/firmware/jetkvm-0.5.9-desktop-encoder.patch
bash -c 'source scripts/build_utils.sh && build_docker_image'   # linux/amd64 buildkit image (Rosetta)
(cd ui && nvm use) && make frontend                              # Node 22, embedded via go:embed
make build_release VERSION=0.5.9                                 # bin/jetkvm_app, ARM uClibc
```

Notes:
- `ghcr.io/jetkvm/buildkit` refuses anonymous pulls, so the image is built locally from `Dockerfile.build`. The first build takes a while.
- Keep `VERSION=0.5.9`. A `-dev` version counts as older than 0.5.9, and auto-update would replace it.

## Deploy

[`DEPLOY.md`](DEPLOY.md) covers three things:
- enabling Developer Mode and an SSH key
- a non-persistent test run (`jetkvm_app_debug`; stopping it and rebooting restores the installed app)
- a persistent install with a backup of the stock binary, plus rollback

[`fw.sh`](fw.sh) wraps the non-persistent run. It needs `JETKVM_SSH_KEY` and `JETKVM_HOST`, then:

```bash
firmware/fw.sh run JETKVM_LOG_INFO=native   # (re)start the patched build; restarting re-plugs HDMI once
firmware/fw.sh log                          # encoder log lines
firmware/fw.sh stock                        # reboot into the stock app
```

## Device facts the patch relies on (release/0.5.9)

- **Encoder:** RV1106 VENC through rockit, VBR. Input is YUYV 4:2:2 from the TC358749 HDMI bridge; output is 4:2:0. H.264 High or H.265 Main.
- **Color:** the bridge outputs BT.601 limited-range YCbCr, but the firmware tags HD streams as BT.709. The app decodes them as BT.601.
- **Quality factor bitrate:** target kbps = (512 + 3488·factor) × pixels/(1920·1080). Max is 1.5 × target, min is target/2.
- **`setStreamQualityFactor`:** no upper clamp. It restarts the capture pipeline without touching HDMI.
