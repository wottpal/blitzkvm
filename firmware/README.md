# JetKVM 0.5.9 desktop-encoder patch

> **Superseded by the fork [wottpal/kvm](https://github.com/wottpal/kvm)** (since 2026-10-11). The fork carries these
> changes as reviewed pull requests on upstream `dev` (divergences D03–D07 in its `FORK.md`), plus D08 (no HDMI
> re-plug when the app restarts) and D09 (data channels recover within a second after a network hiccup), and is
> the source of the installed build (`release/0.5.9-fork.4`). This patch stays as the same changes against
> `release/0.5.9`, without D08 and D09.

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
- Super-frame re-encode above 2.5 MiB. Refreshes set their QP per block, which the re-encode cannot raise, so the stream buffer and the native frame socket's limit are raised from 1,036,800 bytes to 2 bytes per pixel of the largest mode (4,608,000).
- GOP of 60 s instead of fps/2. Keyframes come on demand (below), and a still screen then costs 0.04-0.08 Mbit/s.
- Each value has an env override: `JETKVM_VENC_MIN_QP`, `JETKVM_VENC_MAX_QP`, `JETKVM_VENC_AQ`, `JETKVM_VENC_GOP_SECONDS`, `JETKVM_VENC_STILL_QP`.

**How the still refresh works.**
- **Detection:** it reads the encoder's own output and never touches frame pixels. On a still screen P-frames are nearly empty (150–460 bytes at QP 10, depending on the screen). Each P-frame's cost above that baseline (the smallest frame of the last one to two seconds, plus 150 bytes of noise) feeds two decaying sums:
  - Over about 3 s, 2,000 bytes mark the picture as changed. Typing gets there (a glyph costs 530–1,000 bytes); a blinking caret does not.
  - Over about 0.1 s, the sum tells when the changes have stopped.
  - A frame above an eighth of the per-frame budget (1,500 bytes at least) is a change on its own, and so is any other keyframe (session start, PLI, GOP).
- **Refresh:** half a second after the changes stop, a whole-frame ROI with absolute QP `stillQp` is set and a keyframe is requested. The keyframe QP floor is permanently `stillQp`, since the encoder clamps ROI QPs to the frame type's floor. P-frames keep `minQp`.
- **Pacing:** refreshes are at least 1.5 s apart. A refresh above 1.5 MiB (a photo-heavy screen) raises the QP of the next ones by 6 (up to +24); one below 768 KiB lowers it again.
- **Trade-off of the permanent keyframe floor:** other keyframes may go below `minQp` too. On a still desktop, measured on the device, keyframes from a PLI were 103 KB instead of 87 KB with the floor at `minQp` (default parameters), 165 KB instead of 136 KB on the app's maximum level. Each one is followed by a refresh half a second later. Moving the floor only for the refresh would restart rate control each time (below).

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
