# Deploying the desktop-encoder JetKVM build

This is a JetKVM app built from the fork [wottpal/kvm](https://github.com/wottpal/kvm) (its `FORK.md` has the build steps; earlier builds were `release/0.5.9` plus `desktop-encoder.patch`). The steps below are conservative. Test it non-persistently first. Only install it persistently once it behaves.

## The artifact

| | |
|---|---|
| Binary | `bin/jetkvm_app` of `wottpal/kvm` at tag `release/0.5.9-fork.8` (`make build_release VERSION=0.5.9`) |
| SHA-256 | `663c28be2ef170d732824570f1449dab5ebb3ff8a7022b930d543ae05978e9b8` (the build installed on the device on 2026-10-15; your build may differ) |
| Size | 35,253,096 bytes |
| Type | ELF 32-bit ARM EABI5, dynamically linked, interpreter `/lib/ld-uClibc.so.0`; NEEDED `librockit.so`, `librockchip_mpp.so.1`, `librga.so` (from `/oem/usr/lib` on the device) |
| Reported version | `0.5.9` (`make build_release`, not a `-dev` build) |
| Toolchain | `kvm-native-buildkit` from `jetkvm/rv1106-system` release `v0.2.8` (the "latest" asset at build time) |

Encoder defaults are compiled in. The environment of the app process overrides them; the native subprocess inherits it and reads it once at start. At runtime, the JSON-RPC methods in section 4 replace them in memory, without restarting the app. They are applied to the running encoder:

| Env | RPC field | Default | Range | Effect |
|---|---|---|---|---|
| `JETKVM_VENC_GOP_SECONDS` | `gopSeconds` | `60` | 0.5-300 (decimals OK) | IDR interval = encode fps x seconds. Keyframes also come on demand (session start, PLI/FIR, RPC, still refresh). An invalid env value falls back to 0.5 s, the upstream cadence. |
| `JETKVM_VENC_MIN_QP` | `minQp` | `18` | 8-40 | Frame/I QP floor (Rockchip default is about 26-28) |
| `JETKVM_VENC_MAX_QP` | `maxQp` | `42` | minQp-51 | QP ceiling (I-frame ceiling = max-2) |
| `JETKVM_VENC_AQ` | `aq` | `0` / false | 0/1 | `1`/true keeps Rockchip texture AQ (+8 QP on text) |
| `JETKVM_VENC_MAX_FPS` | `maxFps` | `0` | 0-120 | Encode at min(maxFps, source fps); 0 = source fps. Frames are dropped evenly in the capture loop and RC/GOP use the encode rate. |
| (none) | `bitrateKbps` | `0` | 0 or 100-50000 | VBR target; 0 = derived from the quality factor |
| (none) | `maxBitrateKbps` | `0` | 0 or 100-50000, >= target | VBR max; 0 = 1.5x the target |
| `JETKVM_VENC_STILL_QP` | `stillQp` | `8` | 1-51 | QP of the still refresh keyframe and the keyframe QP floor; `minQp` or more turns the refresh off. 0 is rejected: rockit treats a zero floor as unset. |

**Logging:** the native subprocess never loads the config, so it logs at ERROR unless `JETKVM_LOG_*` env says otherwise. `setDefaultLogLevel` only changes the main process. The encoder lines below are therefore emitted at a dedicated always-on level (C `log_notice`, shown as `INF`), and the patch's RC failures are logged as errors. Each encoder (re)start logs `configured VENC GOP` and `configured VENC RC`. Each runtime change logs `encoder params set`, followed by `applied VENC params live`, or `live VENC update failed, restarting the stream` if it fell back. For IDR verification, `JETKVM_LOG_INFO=native` adds `VENC IDR frame: N bytes` for every IDR.

Always on:
- **BT.601-matrix color tagging at every resolution.** The VUI (H.264 and H.265) uses matrix_coefficients = 6 (BT.601) with colour_primaries = 1 and transfer_characteristics = 1 (BT.709, about sRGB, because the content is an sRGB desktop), limited range. V4L2 uses `REC709` / `XFER_FUNC_709` / `YCBCR_ENC_601`, limited range. Upstream tagged streams above 576 lines with the BT.709 matrix. The TC358749 bridge always converts to BT.601 limited YCbCr: rv1106-system `tc35874x.c` writes `MASK_VOUT_COLOR_601_YCBCR_LIMITED` for UYVY. Measured against a test image, the decoded colors match the BT.601 matrix within 0.5 code values; the BT.709 matrix was off by about 8. This only changes the tags; the bridge does the conversion. The log shows `configured VENC VUI as limited-range, BT.601 matrix, BT.709 primaries/transfer`.
- A super-frame re-encode above 2.5 MiB, below the stream buffer and frame-socket limit of 4,608,000 B (2 bytes per pixel of 1920×1200; raised from 1,036,800 in `internal/native/proxy.go`).
- The still refresh (README.md). `JETKVM_LOG_INFO=native` logs each one: `still refresh: keyframe N bytes at qp Q`.
- An on-demand IDR when a WebRTC session reaches `connected`, on RTCP PLI/FIR, and on the `requestKeyframe` RPC. There are at most 2 per second; extra requests coalesce. The native side tries these paths in order:
  1. `RK_MPI_VENC_RequestIDR(ch, RK_TRUE)`. The shipped librockit returns `0xa0048008` (NOT_SUPPORT) for every instant request.
  2. `RK_MPI_VENC_RequestIDR(ch, RK_FALSE)`. librockit sends the encoder node an `intra_refresh` command and always returns 0, whether or not it worked.
  3. `RK_MPI_VENC_SetChnAttr` with the GOP length toggled by one frame. MPP forces an IDR and resends SPS/PPS on a GOP change.

  A path only counts as working once an IDR shows up in the encoder output; the IDR check parses the H.264/H.265 NAL types. It fails if 6 encoded frames come out without one. Too few frames, for example with no HDMI signal, is inconclusive and does not count against the path. The first verified path is remembered and later requests go straight to it. The log shows `keyframe requests use …` once (always-on level), and each failed path is logged once at the same level.

Prerequisites: the device runs app 0.5.9 (Settings > General shows the version). It must also have about 35 MB free on `/userdata` per copy (the backup plus the staged update need about 65 MB).

## 0. Enable SSH (needed for both variants)

1. Open the device web UI and go to **Settings > Advanced > Developer Mode**, then turn it on. While it is on, the UI warns that security is weakened.
2. In **SSH Access**, paste your public key, for example `~/.ssh/id_ed25519.pub`, and click **Update SSH Key**. The user is `root`.
   - The JSON-RPC equivalents over an authenticated session are `setDevModeState {"enabled": true}` and `setSSHKeyState {"sshKey": "ssh-ed25519 AAAA..."}`. They write `/userdata/jetkvm/devmode.enable` and `/userdata/dropbear/.ssh/authorized_keys`, then run `dropbear.sh`.
3. Check the connection: `ssh root@<DEVICE_IP> 'cat /proc/version; df -h /userdata'`

Upstream's `dev_deploy.sh` connects with `-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no`. The commands below leave normal host-key checking on, so accept the key once when prompted. The device has no SFTP server. Transfer the binary with `ssh ... "cat > file" < file`, as upstream does, or with `scp -O` (legacy protocol).

```sh
BIN=path/to/kvm/bin/jetkvm_app   # built per README.md
DEV=root@<DEVICE_IP>
```

## 1. Non-persistent test (rollback = stop it, then reboot)

These steps mirror the default (non `-i`) path of `scripts/dev_deploy.sh`. That path:
- writes the binary to `/userdata/jetkvm/bin/jetkvm_app_debug`
- exports `LD_LIBRARY_PATH=/oem/usr/lib:$LD_LIBRARY_PATH`
- runs `killall jetkvm_app` and `killall jetkvm_app_debug`, then polls `pgrep` for up to 10 s until both are gone
- runs `chmod +x`, then starts `./jetkvm_app_debug | tee -a /tmp/jetkvm_app_debug.log` with `JETKVM_LOG_ERROR=all` and `JETKVM_LOG_TRACE=jetkvm,cloud,websocket,native,jsonrpc`

The stock `/userdata/jetkvm/bin/jetkvm_app` is never touched. At boot, `RkLunch.sh` only starts `bin/jetkvm_app`, so a reboot always brings back the stock app. Note that the script itself builds a `-dev` version with `make build_dev`. That is irrelevant here because we push the prebuilt binary.

```sh
# 1. upload and verify (stock app keeps running)
ssh $DEV "cat > /userdata/jetkvm/bin/jetkvm_app_debug" < "$BIN"
ssh $DEV "sha256sum /userdata/jetkvm/bin/jetkvm_app_debug"   # must match the SHA-256 above

# 2. stop the stock app, start the test build detached (survives SSH/VPN drops)
ssh $DEV 'sh -s' <<'EOF'
set -e
export LD_LIBRARY_PATH=/oem/usr/lib:$LD_LIBRARY_PATH
killall jetkvm_app || true
killall jetkvm_app_debug || true
i=1; while [ $i -le 10 ] && pgrep -f jetkvm_app >/dev/null; do sleep 1; i=$((i+1)); done
cd /userdata/jetkvm/bin && chmod +x jetkvm_app_debug
# Optional overrides go before `sh`, e.g. JETKVM_VENC_GOP_SECONDS=2 JETKVM_VENC_MIN_QP=20
JETKVM_LOG_DEBUG=native sh -c "trap '' HUP; exec ./jetkvm_app_debug" >> /tmp/jetkvm_app_debug.log 2>&1 &
echo started
EOF
```

`killall` sends SIGTERM, the same as upstream, and the stock app shuts down. The test build opens `/dev/watchdog` and feeds it every 10 s, so the script starts it immediately. If the test build fails to start, the hardware watchdog may reboot the device. That reboot brings back the stock app, so it acts as a rollback. For a foreground run like upstream's, use `ssh -t $DEV` and run the same lines with `./jetkvm_app_debug | tee -a /tmp/jetkvm_app_debug.log`. In that mode, losing the SSH session kills the app.

Verify:

```sh
ssh $DEV "grep -E 'configured VENC|encoder params set|RequestIDR|keyframe' /tmp/jetkvm_app_debug.log | tail -20"
# expect (visible at the default log level):
#   configured VENC GOP: 3600 frames (60.0 s at 60 of 60 fps), bitrate 4000 kbps (max 6000)
#   configured VENC RC: qp 18-42 (I 8-40), aq off
# with JETKVM_LOG_DEBUG=native also:
#   requested keyframe ... reason=session_connected | pli | fir | rpc
```

Then connect with the macOS app or a browser. The first picture should appear immediately. A static screen should drop to near-zero bitrate (0.04-0.08 Mbit/s), and half a second after it stops changing, one refresh keyframe makes it near-lossless.

**Rollback:** `ssh $DEV 'killall jetkvm_app_debug; reboot'`. Stop the test build first: the shutdown script (`RkLunch-stop.sh`) waits for a process named `jetkvm_app`, so a plain `reboot` hangs while the test build runs. A hardware watchdog reset follows the kill in any case. Optionally clean up afterwards with `ssh $DEV rm /userdata/jetkvm/bin/jetkvm_app_debug`. `/tmp` is RAM, so the log disappears on reboot.

## 2. Persistent install (with backup)

These steps mirror `dev_deploy.sh -i/--install`. That mode runs `make build_release` (version = `VERSION` = 0.5.9), pushes the binary to `/userdata/jetkvm/jetkvm_app.update` the way the OTA updater does, and reboots. At boot, `RkLunch.sh` (`post_chk`) runs `mv -f /userdata/jetkvm/jetkvm_app.update /userdata/jetkvm/bin/jetkvm_app`, then `/userdata/jetkvm/bin/jetkvm_app > /userdata/jetkvm/last.log 2>&1 &`. Upstream makes **no backup**; the steps below add one.

```sh
# backup the stock 0.5.9 app (keep it on the device and locally)
ssh $DEV "cp /userdata/jetkvm/bin/jetkvm_app /userdata/jetkvm/jetkvm_app.stock-0.5.9 && sync && sha256sum /userdata/jetkvm/jetkvm_app.stock-0.5.9"
ssh $DEV "cat /userdata/jetkvm/jetkvm_app.stock-0.5.9" > jetkvm_app.stock-0.5.9

# stage, verify, reboot
ssh $DEV "cat > /userdata/jetkvm/jetkvm_app.update" < "$BIN"
ssh $DEV "sha256sum /userdata/jetkvm/jetkvm_app.update && sync"     # must match the SHA-256 above
ssh $DEV reboot

# after boot
ssh $DEV "sha256sum /userdata/jetkvm/bin/jetkvm_app; grep -E 'configured VENC' /userdata/jetkvm/last.log"
```

At boot the app runs with **no** env overrides (`RkLunch.sh` passes none), so the compiled defaults above apply. To experiment with other values, use variant 1.

Keep Developer Mode and the SSH key enabled until you are satisfied. `RkLunch.sh` starts `dropbear.sh` independently of the app, so SSH survives even if the app misbehaves.

**Rollback:**
```sh
ssh $DEV "cp /userdata/jetkvm/jetkvm_app.stock-0.5.9 /userdata/jetkvm/jetkvm_app.update && sync && reboot"
```
Without a backup, take the official `jetkvm_app` (plus `.sha256` and `.sig`) from the GitHub release `release/0.5.9` of `jetkvm/kvm`, verify it, and push it the same way. Once upstream ships a release newer than 0.5.9, a normal OTA update also replaces the build.

## 3. Auto-update caveat

- **How OTA decides:** in `internal/ota/rpc.go`, an update is applied when `remoteVersion.GreaterThan(localVersion)`. The auto-update loop in `main.go` starts 15 min after boot and then runs hourly. It only acts when **Auto Update** is on, no session is active, and time is synced.
- **This build reports `0.5.9`:** the stable 0.5.9 is not greater than it, so the build is **not** auto-replaced. It **will** be replaced as soon as the device sees any app version above 0.5.9. That means a new stable release, or a pre-release such as `0.5.10-dev…` if **Dev Channel Updates** is on. To keep it, turn off **Settings > General > Auto Update** (RPC `setAutoUpdateState {"enabled": false}`) while testing. Turn it back on after rolling back.
- **A `-dev` build would not survive:** `make build_dev` / `dev_deploy.sh` without `-i` produce `0.5.9-devYYYYMMDDHHMM`. That is a semver pre-release and therefore lower than `0.5.9`. If such a build were installed persistently, the next auto-update check would put stock 0.5.9 back. This only matters for persistent installs; variant 1 never persists anything.
- **Signatures:** the binary is unsigned. Signature checks only apply to binaries the OTA updater downloads, not to a manually staged `jetkvm_app.update`.

When you are done, turn off Developer Mode. You can also remove the SSH key by saving an empty key.

## 4. Runtime encoder control (JSON-RPC)

These methods use the same JSON-RPC 2.0 transport as every other device RPC: the WebRTC data channel labelled `rpc`. Changes are **in memory only**. They are reset to the env/compiled defaults, logged as `encoder params reset to defaults`, in three cases:
- when the last WebRTC session disconnects (the main process then stops the stream with `VideoStop`, which resets them), so the next client or the web UI starts clean;
- on every `setStreamQualityFactor`, so a quality change made in the UI takes full effect;
- when the app restarts.

| Method | `params` | Result |
|---|---|---|
| `getVideoEncoderParams` | none | status object (below) |
| `setVideoEncoderParams` | `{"params": {"minQp": int, "maxQp": int, "gopSeconds": float, "aq": bool, "maxFps": int, "bitrateKbps": int, "maxBitrateKbps": int, "stillQp": int}}` (every field optional) | status object after the change |
| `requestKeyframe` | none | `null`; queues an IDR through the same path as PLI (at most 2/s, coalesced) |

Status object (the first eight fields are the settable params; `0` bitrates mean "auto"):

```json
{"minQp":18,"maxQp":42,"gopSeconds":60,"aq":false,"maxFps":0,"bitrateKbps":0,"maxBitrateKbps":0,"stillQp":8,
 "sourceFps":60,"encodeFps":60,"gopFrames":3600,
 "effectiveBitrateKbps":4000,"effectiveMaxBitrateKbps":6000,"codec":"h264","streaming":true}
```

Example request: `{"jsonrpc":"2.0","id":1,"method":"setVideoEncoderParams","params":{"params":{"bitrateKbps":1500,"maxFps":30}}}`

- **Merging:** omitted fields keep their current value. The merged result is validated as a whole, and an invalid result returns a JSON-RPC error and changes nothing. An unchanged result returns the current status without touching the encoder. Send `bitrateKbps: 0` to go back to the quality-factor bitrate.
- **Live updates:** changes are applied to the running VENC channel without stopping it:
  | Field | Live mechanism | IDR? |
  |---|---|---|
  | `bitrateKbps`, `maxBitrateKbps` | `RK_MPI_VENC_SetChnAttr` (VBR target/max/min) | no |
  | `minQp`, `maxQp` | `RK_MPI_VENC_SetRcParam` | no |
  | `aq` | `RK_MPI_VENC_SetRcParam2` (zeroed AQ steps, or the channel's saved Rockchip defaults) | no |
  | `maxFps` | capture-loop drop rate + `SetChnAttr` RC fps and GOP frames (GOP frames = gopSeconds x encode fps) | yes, one |
  | `gopSeconds` | `SetChnAttr` GOP | yes, one |

  The IDR column comes from MPP source, not rockit. In `mpp_enc_proc_rc_cfg`, a change to `fps_in`, `fps_out` or `gop` calls `enc_set_resend_hdr()`, which forces an IDR; a change to `bps` only flags an RC update. Rockit itself is closed source, so confirm on the device by watching `VENC IDR frame` lines (`JETKVM_LOG_INFO=native`).
- **Fallback:** if any live call fails, the error is logged and the stream restarts through the same path `setStreamQualityFactor` uses, `video_restart_streaming()`. That recreates the V4L2 capture and the VENC channel and opens with an IDR. **EDID and HDMI hot-plug are never touched.** While no channel is running, the values are only stored and apply at the next start.
- **Concurrency:** a change that races a channel start is either picked up by that start or applied live afterwards. Both paths share one mutex with IDR requests and channel teardown.
