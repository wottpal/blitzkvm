# LAN improvements: candidates (2026-10-18)

The slow-link work (engineering plan §32, release 0.2.5) left LAN sessions unchanged, apart from pointer moves using one retransmission (measured cheaper for the device, not slower). None of the candidates below is a sure win without a downside; each needs a LAN A/B on the rig before it ships. They are listed best first.

**Baseline (BENCHMARKS.md):**
- Key → screen: 47 ms at 1280×720@120, 76–78 ms at 2400×1012@60.
- Pointer → screen: 53 ms.
- Text: 60 dB once still.

## 1. Encode at the source rate in 75/90/120 Hz Match Window modes

**Today:** every quality level caps encoding at 60 fps (`pkg/session/autoquality.go`, `MaxFPS: 60` since the first ladder). At 120 Hz the device captures 120 frames a second and encodes every second one; at 90 Hz, two of three. A change that lands in a dropped frame waits one more capture period: up to 8.3 ms at 120 Hz, about 4 ms on average. The documented 47 ms at 720p120 was most likely measured with that cap.

**Change:** at maximum on a LAN, `maxFps: 0` (the source rate).

**Why it should work:** VEPU encodes 720p in about 6 ms, within the 8.3 ms period. Early submit was already tested clean at 720p120 (§31 R1). On a LAN the device's CPU is not the limit, since there is no `tailscaled`.

**Costs:**
- The bitrate target is per second, so each moving frame gets fewer bits (half at 120 Hz) and the picture is less sharp while it moves.
- Twice the frames go through the device's send path, at about 0.45 ms of CPU per packet.
- Still pictures are unaffected: the still refresh restores them.

**Test:**
- Latency probe, key and pointer (`BLITZKVM_PROBE_POINTER=1`), at 1280×720@120 and 1920×800@90, 40 samples, cap on against cap off.
- `motion_score.py` on `latency_motion.html` recordings for the sharpness of moving frames.
- Device CPU from `/proc` during scrolling.

**Ship if:** key and pointer get at least 3 ms faster (median), moving frames lose less than about 1 dB, and the device keeps headroom.

## 2. The app's decode → screen tail

**Seen:** on a ProMotion MacBook under heavy motion, decode → on screen had a p90 of 43 ms. Rendering started about 26 ms late in one frame of ten (median 0.7 ms). Pointer samples showed the presented frame up to about 400 ms after the decoded one (p90), with either helper. Still pages showed none of it.

**Likely area:** `VideoView.swift`'s render queue, meaning the wait in `nextDrawable` with two drawables, the re-render about 110 ms after a large change, and how the queue behaves when frames come in faster than they are drawn.

**Scope:** this is network-independent, so it would help the LAN and every other link. It is the follow-up session "Investigate the app's decode-to-screen latency tail".

**Status (engineering plan §33):** the pointer's tail was macOS dropping the first present after an idle stretch; the app now draws such a frame again (pointer → screen p90 421 → 141 ms). The 43 ms p90 under heavy motion did not come back on the emulator (display → presented p90 18 ms). A display-link hint made scrolling worse and was dropped.

**Test:** reproduce on the emulator with timing per render step (`BLITZKVM_GPU_TIMING=1`). Ship only a change that improves presented-ms p90 without touching the text upscaler's output (its GPU tests are bit-exact).

## 3. Firmware: drop frames by bit budget instead of an even cap

**Today:** a scroll at maximum sends large frames back to back through the device's send path. A keyframe of 250–350 KB holds the frames behind it for 120–230 ms (§31 R5).

**Change:** a leaky bucket in the capture loop (`internal/native/cgo/video.c`) skips a captured frame only while recently encoded bytes exceed a budget. Small changes then always go out at the full rate, and heavy motion drops frames instead of queueing.

**Expected gain:** on the LAN, this shortens the latency tail behind large frames. It matters most on slow links. It is the follow-up session "Firmware: budget-based frame dropping".

**Test:** emulator model and the slow-link benchmark first, then the probe with `BLITZKVM_PROBE_KEYFRAME_LEAD` on the rig. Installing it means a firmware build, a reboot and a new FORK.md divergence.

**Status (engineering plan §33):** in the firmware as D18 (`paceKbps`, fork.9), with the GOP counted in the channel's frames so frame rate changes cost no keyframe. The governor paces only off a LAN; on a LAN it stays off until a LAN A/B on the rig.

## 4. Lower priority

**Larger RTP packets on the LAN:** pion packetizes at 1,200 bytes and every packet costs the device about 0.45 ms of CPU. Packets closer to the 1,500-byte MTU would mean about 20 % fewer packets for large frames. This needs pion's outbound MTU raised on the device (§31 ruled it out as a constant change inside pion). It should be measured as keyframe send time before it is worth a fork of pion.

## Not candidates on the LAN

- **Peak bitrate cap:** a LAN's measured rate is the device's send path, not a bottleneck, so a cap would only cost sharpness.
- **Pacing pointer moves to 60 a second:** the device's CPU is not the limit on a LAN, and pacing holds some moves back by up to 16 ms.
- **A direct path that bypasses Tailscale:** it only matters when Tailscale runs on the JetKVM (done, §33).
