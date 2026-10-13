# BlitzKVM

A native macOS client for [JetKVM](https://github.com/jetkvm/kvm) devices, built to replace Jump Desktop for daily remote work: several devices, reached over a LAN or any VPN (Tailscale is the reference), in long, latency-sensitive sessions.

This repository is a private fork of [lkarlslund/jetkvm-desktop](https://github.com/lkarlslund/jetkvm-desktop). It contains:

- **The native macOS app** (`macos/`): Swift/AppKit, VideoToolbox decoding, Metal rendering. It runs one Go helper process per device. This is the product.
- **The Go engine** (`pkg/`, `cmd/blitzkvm-engine`): the JetKVM protocol, session lifecycle, video assembly and input, shared by both clients.
- **The legacy Ebiten client** (`cmd/blitzkvm-legacy`, `pkg/app`, `pkg/ui`): upstream's cross-platform UI. It still builds and serves as a manual test client; it gets no new features and will be retired.
- **A firmware-faithful emulator** (`pkg/emulator`, `test/emulator-serve`): a fake JetKVM that behaves like firmware 0.5.9, so everything can be tested without touching real hardware.

The engineering plan, roadmap, decisions and the execution report live in [`plans/2026-10-10-engineering-plan.md`](plans/2026-10-10-engineering-plan.md). Read §19–§20 for the current status before planning new work.

## Scope

| Path | What it is |
|---|---|
| `macos/` | SwiftPM package and Makefile for the app. `Sources/JetKVMCore` holds testable logic (wire protocol, device library, key mapping, geometry, certificate pinning, serial text filter); `Sources/BlitzKVM` holds the AppKit/SwiftUI app; `Tests/` holds the unit tests. |
| `cmd/blitzkvm-engine` | The helper the app launches per device. It speaks `pkg/engineipc` over stdin/stdout and logs to stderr. |
| `cmd/blitzkvm-legacy` | The legacy Ebiten client. |
| `pkg/client` | One WebRTC connection to a device: auth, signaling, RPC, HID-RPC, video, serial. |
| `pkg/session` | Connection lifecycle (reconnect, backoff, identity and TLS pinning, events) on top of `pkg/client`. |
| `pkg/engine`, `pkg/engineipc` | The helper's command loop and the app↔helper framing. |
| `pkg/video` | RTP access-unit assembler (`pkg/video/openh264`: software decoder for the Ebiten client and emulator only). |
| `pkg/protocol/{auth,signaling,jsonrpc,hidrpc,tlspin}` | Wire protocols and HTTPS certificate pinning. |
| `pkg/input` | Keyboard mapping and layout-aware paste; `layouts_gen.go` is generated. |
| `pkg/emulator`, `test/emulator-serve` | Emulator library and CLI. |
| `third_party/openh264-go` | Vendored OpenH264 bindings with static libraries (cgo), wired in by a `replace` in `go.mod`. |
| `plans/` | Engineering plan (source of truth for roadmap and decisions). |

## Setup

Requirements, as used on the development Mac:

- macOS 14 or later on Apple silicon (the app is arm64-only; `LSMinimumSystemVersion` is 14.0).
- Xcode in `/Applications/Xcode.app` (27.0 here). The macOS Makefile points `DEVELOPER_DIR` at it; the Command Line Tools alone cannot build the app's SwiftUI macros.
- Go: `go.mod` pins `toolchain go1.27.2`. Any recent `go` downloads it automatically.
- A C/C++ compiler for cgo (from Xcode), needed by the OpenH264 bindings that the Ebiten client and emulator use.
- Optional: `ffmpeg` (H.265 and High-profile replay tests skip without it), `actionlint`, and a "Developer ID Application" certificate in the login keychain for stable signing.

## Commands

Run root targets from the repository root and macOS targets with `make -C macos <target>`, also from the root.

| Command | Does |
|---|---|
| `make build` | `go build ./...` |
| `make test` | Go tests (`-p 1`) plus the vendored OpenH264 module's tests |
| `make test-race` | Go tests with the race detector |
| `make test-timing` | Timing-sensitive tests that skip themselves under `-race` (NACK loss repair, also at long round trips) |
| `make vet` / `make vulncheck` | `go vet`; govulncheck |
| `make generate` | Regenerates the enumer files (`*_enums.go`) |
| `make generate-check` | Regenerates, then fails if `git diff` is not empty, so it also fails on any uncommitted change |
| `make check` | Everything fork CI runs: vet, generate-check, race tests, timing tests, govulncheck, OpenH264 tests, Swift tests |
| `make layouts UPSTREAM=../kvm` | Regenerates `pkg/input/layouts_gen.go` from a `jetkvm/kvm` checkout |
| `make emulator` | Runs the emulator on `http://127.0.0.1:8080` (no password) |
| `make -C macos app` | Builds and signs `macos/build/BlitzKVM.app`; a signed build is also copied to `~/Downloads` |
| `make -C macos firmware` | Bundles the firmware builds JetKVM Setup installs, pinned by SHA-256 in `macos/Support/Firmware.json`: the BlitzKVM build from `FORK_BINARY` (default: `bin/jetkvm_app` of a [wottpal/kvm](https://github.com/wottpal/kvm) clone next to this repository), and JetKVM's own release from its GitHub release (downloaded once into `macos/build/firmware-cache`). `make app` runs it; a build whose binary is missing is left out |
| `make -C macos test` | Swift unit tests (`JetKVMCoreTests`) |
| `make -C macos selftest` | End to end: the app against the emulator (video, injected input, helper crash recovery) |
| `make -C macos selftest-extras` | End to end over http and https: virtual media (upload, mount, eject, delete), serial console, address probing with certificate pins |
| `make -C macos selftest-stalls` | End to end with the fork's keyframe policy: the picture may stand still no longer than a link stall, and resumes once a hidden window is shown |
| `make -C macos selftest-refresh` | End to end with fork firmware D13's still refresh: region refreshes after typing pauses, none while typing, a full refresh after a long pause; a view-only window leaves refreshes to the device |
| `make -C macos run DEVICE=jetkvm.local` | Builds and opens the app connected to a device |
| `make -C macos install` | Copies the app to `/Applications` |
| `make -C macos notarize` | Notarizes with the Xcode account and staples; leaves `macos/build/BlitzKVM.zip` (see Signing) |

Focused checks, by what you changed:

- When you edit `pkg/emulator`, `pkg/client`, `pkg/session` or `pkg/engine`, run `go test -race -count=1 ./pkg/<package>`. If you touched video, NACK or netem code, also run `make test-timing`.
- When you edit `macos/Sources/JetKVMCore`, run `make -C macos test`.
- When you edit `macos/Sources/BlitzKVM`, `pkg/engineipc` or engine commands, run `make -C macos selftest` and `make -C macos selftest-extras`. If you touched video, the decoder or keyframe handling, also run `make -C macos selftest-stalls`; if you touched still refreshes (`RefreshPlanner`, `StillRefresh`, input or frame handling), `make -C macos selftest-refresh`.
- Before you push, run `make check` (or its steps individually while the tree is dirty, since `generate-check` needs a clean tree).

A passing self-test prints a JSON report and ends with `selftest passed: …`. Any other ending is a failure.

## Using the app

Open `~/Downloads/BlitzKVM.app` (or `/Applications/` after `make -C macos install`). The Devices window (⌘N) holds the device library: a name, an ordered list of addresses (LAN IP, `.local` name, VPN name; `https://…` for TLS) and per-device preferences. Addresses are probed over HTTP in parallel and the earliest that answers wins; probing never opens a WebRTC session, because that would take over an existing one. Devices show as a gallery of screens that light up while the device answers (the same probe, every 30 s while the window is visible); the most recently used one starts selected, so Return connects it.

**JetKVM Setup** (Device › Set Up JetKVM…, or the setup badge on a device in the Devices window) shows three things and fixes each with one button. The badge shows how far a device is (a dot per step, filled when done) as of the last check; every connection checks quietly, and a click on the badge connects and opens the sheet.
- **Firmware:** the app ships two builds, so nothing is downloaded: the BlitzKVM firmware (recommended) and JetKVM's own latest release, both pinned by SHA-256 in `macos/Support/Firmware.json`. The row shows which runs (by the installed binary's hash). Its button installs the BlitzKVM build; its menu reinstalls either, switches to JetKVM's own, or restarts the JetKVM. Installing uploads the build next to the running app, checks it, and restarts the JetKVM, which moves it into place as it does an update (about a minute). The previous build stays as `/userdata/jetkvm/jetkvm_app.backup`. JetKVM's automatic updates replace a BlitzKVM build with their next release.
- **Password:** set the JetKVM's first password (kept in your keychain), so not everyone who can reach it controls the computer. Its menu changes the password or turns it off.
- **Tailscale:** Install downloads the current release for 32-bit ARM from pkgs.tailscale.com, checks it against its SHA-256, and installs it as `tailscale configure jetkvm` expects, so it starts at boot. The JetKVM doesn't restart. The kernel's `tun` module gives it a real `tailscale0` interface. Your browser opens to log in, and once the JetKVM is on the tailnet its name (e.g. `mac-mini-jetkvm.<tailnet>.ts.net`) is added to the device's addresses. Turn off key expiry for it in the admin console, or it drops off the tailnet when its key expires.

Installing uses SSH: the app turns on Developer Mode and adds its own key (`~/Library/Application Support/BlitzKVM/SSH/`) to the device's keys, keeping any others.

**Remote access:** list the LAN address first and the tailnet name second. At home the LAN address answers first; away, the tailnet name does. Video takes the route of the address the app connected to, and the status bar names it: via LAN, via Tailscale, via Tailscale relay `<region>` (no direct path: Tailscale relays it, much slower), via VPN, or via internet.

Features: Retina-sharp video, keyboard capture including system shortcuts (a click on the remote screen or ⌘ pressed twice captures, ⌃⌘ releases; focusing the window alone never captures, so ⌘Tab passes through), a pointer that goes exactly where you hover (View › Local Pointer can also show your own pointer over the picture as a dot or an arrow: it moves without the stream's delay and hides once it rests, leaving the target's cursor, which trails it by about 70 ms), Mac/PC modifier profiles, paste as keystrokes (⌥⌘V), stream quality presets, power control (ATX/DC), Wake Computer (a one-pixel pointer nudge and a Shift tap for a sleeping display, and JetKVM's wake-only USB signal for a suspended computer: from firmware 0.5.9 on, ordinary input no longer wakes one), Restart JetKVM (Device menu: the computer keeps running, the overlay says it is restarting, and the window reconnects by itself), virtual media (⇧⌘M), serial console (⇧⌘L), extension port switching, H.265 (measured sharper than H.264 at every bitrate on the JetKVM encoder), several devices as tabs.

View modes (View menu ⌘1–⌘5, or the menu in the status bar), saved per device:

| Mode | Shows the remote screen | Notes |
|---|---|---|
| Actual Size (default) | One remote pixel per point: the size a monitor of that resolution would show it | 2× on Retina, enlarged by the text upscaler (below). The remote resolution stays as it is; the window sizes itself to it, and a smaller window pans with the pointer. |
| Scale to Fit | As large as the window allows | The text upscaler when enlarging up to 3×, FSR beyond; a widened Catmull-Rom when shrinking |
| Pixel for Pixel | One remote pixel per physical pixel | Tiny on Retina; for pixel inspection |
| Largest Whole Multiple | The largest whole multiple that fits | Always exact (nearest-neighbor) pixels |
| Match Window (opt-in) | The remote display takes the window's size, one remote pixel per point | Resize the window (or go full screen) and the target switches its resolution to match within a few seconds. Only for targets where the JetKVM is the only display; details below. |

**Match Window** (opt-in, explained once when chosen) changes the JetKVM's EDID (the display description the target reads over HDMI). The app keeps the device's identity, name and audio, and replaces its modes with a single mode of the window's size. The target re-detects the display, and the picture pauses for 2–5 s. The device saves the EDID, so the target keeps that resolution after the app quits. JetKVM web UI › Settings › Video › EDID (JetKVM Default) restores the default. Sizes run from 640×400 up to 3840×2160. The HDMI bridge's 165 MHz pixel clock sets the trade between size and rate, and it locks up to 120 Hz: 2448×1024 at 60 Hz for a 21:9 window, 3008×1268 at 40 Hz (a 40" full screen at its full resolution, with the fork's capture buffers, firmware D10; stock firmware's stop at 3.1 megapixels), 1664×700 at 120 Hz. Smaller pictures at higher rates are faster: capture and encoding both scale with the pixel count (plan §31). View › Match Window Refresh chooses: Automatic takes the largest picture and then the highest rate that reaches it (a small window gets 90 or 120 Hz), and each rate (120, 90, 75, 60, 50, 40, 30, 25, 24 Hz) is listed with the size the window gets at it. Larger windows than the limits get the largest mode of their shape, scaled to fill. View › Match Window Scale sets how large the remote desktop looks: 100% is one remote pixel per window point, 200% doubles everything (half the resolution), 50% halves it (twice the resolution, up to the limits). It is saved per device. While the target switches modes it sends black frames; the app keeps showing the last picture until the new size arrives. Widths are multiples of 16 and heights multiples of 4, so a window can be up to 15 × 3 points larger than the remote. In a window, the app closes that gap by snapping the window to the remote; in full screen it stays as a thin border. View-only sessions never change the EDID. The limits are measured on the hardware (`RemoteDisplay.swift`, plan §22); an odd height hangs the device. **On a Mac with another monitor, do not use it:** macOS treats every new size as a new display with the default arrangement. The JetKVM display is then no longer the main display, so it shows an empty desktop and the absolute pointer cannot reach it. Only sizes that were previously made main come back main.

Full screen: the menu bar, and with it the window's title bar and buttons, slides in when the pointer rests at the top edge, so you can leave full screen with the mouse. The Dock stays hidden because the bottom edge belongs to the remote.

**Enlarging up to 3× (Actual Size on Retina, Scale to Fit, full screen):** a small neural network trained on macOS text (`TextUpscaler.swift`). It learned from CoreText drawing the same layouts at 1× and at the target scale, with the glyphs where the 1× renderer put them, and predicts a 3×3 grid of sub-pixel detail per remote pixel, which the compose pass resamples to any scale. JetKVM recordings of the test pattern, replayed through the app at 2.5× (a 2400×1012 remote in full screen on a 40" 6016×2538 display), score 1.3–3.0 dB PSNR and 0.02–0.03 SSIM above FSR on every text region against the pattern drawn at that scale (light text 24.8 dB / 0.975 against 22.7 / 0.953). There are no stair steps and no blur. At that size typing costs 0.8 ms of GPU per frame (FSR 0.7). A frame that changes much of the picture (a window switch, scrolling) is drawn with FSR first, so it comes as soon as before, and the network sharpens the picture a tenth of a second after large changes stop. A GPU too slow for it falls back to FSR.

**Enlarging beyond 3×:** AMD FSR 1 (EASU edge-adaptive upscaling plus RCAS sharpening, `FSR.swift`).

View › Exact Pixels at Whole-Number Scales switches to nearest-neighbor where the scale is a whole number. View › Scaling Filter swaps the enlargement filter for experiments (Automatic stays the default): FSR 1 with light, strong or no sharpening, Lanczos‑3, Catmull‑Rom, sharp bilinear, bilinear or nearest neighbor. Shrinking stays antialiased with any of them. View › Show Status Bar (⌘/) hides the status line in every window. A window keeps its picture size; in full screen the picture gains the line, and Match Window follows.

When the picture stalls for more than about half a second (connecting, a display resize, a stream that paused, no HDMI signal), a large overlay says why and what happens next, under an icon for the state (it pulses while the wait ends by itself). With no HDMI signal it offers Wake Computer, the only part of the overlay that takes a click. The last picture stays underneath, dimmed. Keyboard and pointer keep working.

**Picture pipeline** (`VideoView.swift`):
- **Chroma:** the JetKVM sends color at half resolution. The app rebuilds it from the full-resolution luma, since within a few pixels desktop content mixes two colors. Colored text measures 51 dB against 28 dB with plain upsampling.
- **Luma:** the HDMI bridge truncates luma. The app adds back half a code value, which gains 2–3 dB on small text and gradients.
- **Output:** the picture is computed in floating point and drawn to a 10-bit layer, so gradients pick up no extra 8-bit rounding.

Mouse: hovering over the remote picture puts the remote pointer exactly there (USB absolute pointer), also while another app is active; your own pointer is hidden over the picture, so only the remote one shows. A Mac maps that absolute pointer onto its **main display only**: on a Mac target the JetKVM's display must be the main display (System Settings › Displays), or the pointer never shows on it.

Stream quality (View › Stream Quality) is **Automatic** by default: the engine walks a quality ladder (`pkg/session/autoquality.go`) from what the video's own packets say about the link (`pkg/video/link.go`). When frames start to queue (their delay past the capture timestamp grows), it steps down within 100–200 ms, straight to the level the link's measured delivery rate carries. It steps up one level at a time, after 20 s without congestion, and only once that rate has been measured carrying the next level; an idle screen measures nothing. Loss and round-trip growth remain a backstop. On a LAN it stays at maximum unless a queue builds. Manual presets set the device's quality factor (a JetKVM setting shared by all its clients). The encoder uses VBR, so higher factors only cost bandwidth while the screen changes. Static text sharpness on stock firmware 0.5.9 is limited by the encoder's QP floor, not the bitrate. The fork firmware [wottpal/kvm](https://github.com/wottpal/kvm) fixes that (plan §21; its `FORK.md` lists every change, `firmware/` has the install steps).

The fork also brings **still screens to near-lossless** (plan §23). Half a second after the screen stops changing, the device sends one keyframe at a very low QP (QP 1 at the maximum level, up to QP 17 at "low"). On the maximum level, text then measures 60 dB, against 53 dB before and 33 dB on stock firmware. The empty frames that follow keep it, and a still screen costs 0.07 Mbit/s.

With firmware that leaves this to the client (fork D13: `getFirmwareFeatures` lists `refreshRegions`), **the app decides when to refresh** (`RefreshPlanner.swift`), in windows that send input. The device's own refresh sent that keyframe (250–350 KB) after every typing pause, and a keystroke right behind it waited 23–61 ms longer (90th percentile: 125 ms). The app knows which parts of the picture changed and when you type:
- **After a typing pause** (picture still for 250 ms, no input for 400 ms) only the regions that changed are re-encoded: up to six rectangles on 16-pixel blocks, at the level's P-frame QP floor, without a keyframe (an 880×224 text area: 41.5 KB, 44 → 49 dB).
- **After a long pause** (no input for 3 s, picture still for 1 s) the whole frame gets the near-lossless keyframe, over the LAN and links as fast as one.
- **Slower links** get region refreshes only. Changes larger than about a third of the screen wait for a long pause there, and on the LAN for the keyframe.
- A blinking caret or a ticking clock asks for nothing. View-only windows, the lowest quality level and other firmware keep the earlier behavior.

**Latency** (plans §24 and §31, measured with `tools/latency-probe`, LAN, a Mac target at 2400×1012@60 on a 60 Hz client display, BlitzKVM firmware 0.5.9-fork.5):

| From | To | §24 (1080p60) | Before §31 | Now |
|---|---|---|---|---|
| Key press | Frame on screen, window | 87 ms | 96 ms | 79 ms |
| Key press | Frame on screen, full screen | 72 ms | 91 ms | 78 ms |
| Pointer move | Remote cursor on screen, window / full screen | 70 / 66 ms | 65 / 57 ms | 58 / 53 ms |
| Key press | Frame on screen, full screen, 1280×720 at 120 Hz | — | — | 47 ms |

The firmware hands the encoder the frame it is still capturing, timed so the encoder trails the capture's writes (fork D11): a frame leaves the encoder 19.9 ms after it starts instead of 31.9 ms.

The app hands each frame to the window server as soon as the GPU is done instead of waiting for its own vsync (the window server still flips at vblank and keeps only the newest frame, so nothing tears), takes the newest frame after the drawable rather than before, and runs the text upscaler only on the tiles that changed. What remains is mostly outside the app: the target's own input-to-display time, one HDMI frame of capture (16.7 ms) and the encoder's fixed 13 ms per 1080p frame.

Colors: the JetKVM's HDMI bridge outputs BT.601 YCbCr while firmware 0.5.9 tags HD streams BT.709, so the app always decodes BT.601 (`VideoView.colorParams`; `BLITZKVM_COLOR_MATRIX=709` restores the declared matrix).

Permissions: on first launch the Devices window opens on a welcome screen that asks for both, each with its state and one button: **Local Network** (required: JetKVMs answer on the local network) and **Accessibility** (recommended: ⌘Tab, ⌘Space and other system shortcuts reach the remote computer). Continue needs Local Network; Skip leaves both for later. BlitzKVM › Permissions… opens it again, and it comes back by itself when Local Network access is turned off. macOS has no API for the Local Network state (Apple TN3179), so the app advertises a Bonjour service (`_blitzkvm._tcp`, listed in `NSBonjourServices`) for a moment and browses for it: found means allowed, PolicyDenied means not. The first check shows the system prompt, so it runs only once you click Allow, and afterwards at launch. If the first address probe gets no answer (device asleep, VPN still coming up), the window opens anyway and keeps connecting.

Command-line options (also used by the self-tests):

| Option | Meaning |
|---|---|
| `--device <address>` | Connect to an address instead of showing the device library |
| `--view-only` | Never send keyboard or mouse input |
| `--scale actualSize\|fit\|pixelExact\|integer\|matchWindow`, `--match-scale 1.5`, `--match-refresh 60\|auto`, `--scaling-filter lanczos`, `--local-pointer hidden\|dot\|arrow`, `--profile mac\|pc`, `--window-size 1280x720`, `--full-screen` | View and input overrides |
| `--selftest <seconds>` and `--crash-engine-after`, `--inject-input`, `--exercise-extras`, `--snapshot <png>`, `--hide-after <seconds>`, `--max-freeze-ms <ms>`, `--set-quality-after 4:low,9:maximum`, `--toggle-status-bar-after <seconds>`, `--type-pauses` | Self-test mode (prints JSON, exits 0 on success). The window floats above other windows and never captures your own keyboard or pointer; only `--inject-input` and `--type-pauses` (typing bursts, then checks the still refreshes) send input |
| `--setup check\|install-tailscale\|login\|restart\|install-firmware[=blitzkvm\|stock]\|password=<new password>\|change-password=<new password>\|remove-password`, `--setup-snapshot <png>`, `--wake` | With `--selftest`: opens JetKVM Setup, runs the action, and reports the three states (`setup`, `setupOK`); the snapshot renders the sheet. `--wake` wakes the target once connected (no keystrokes) |
| `--latency-probe <samples>` | Measures input-to-photon latency against `tools/latency-probe/latency.html` on the target (prints JSON, exits) |

Environment: `JETKVM_DEVICE` and `JETKVM_PASSWORD` stand in for `--device` and a password. `BLITZKVM_DEBUG_BLACKHOLE=period:duration` (seconds) makes the helper drop all session traffic for `duration` every `period`, to reproduce network hiccups. `BLITZKVM_IMPAIR` runs the session's traffic through a model of a slow link, both ways (`pkg/netimpair`): a profile (`lte`, `lte-congested`, `wifi-hotel`, `derp`), settings (`rate=4mbit,queue=1s,delay=40ms,jitter=5ms,loss=1%,burst=3,outage-every=20s,outage=200ms-800ms`, or `trace=<Mahimahi file>` for the rate), or a profile with overrides (`lte,loss=1%`). The helper logs what the link did when the session ends; `BLITZKVM_BENCH=60s go test -run TestSlowLinkBenchmark ./pkg/emulator` runs the session with automatic quality through each profile, against the emulator's model of the patched encoder (`BLITZKVM_BENCH_CONTENT=desktop|scroll|motion`). `BLITZKVM_ENGINE` points at a helper binary for development. `BLITZKVM_LOG_LEVEL` (error, warn, info, debug, trace) sets Go logging in the helper.

Where things live:

- Device library: `~/Library/Application Support/BlitzKVM/devices.json`.
- Passwords: the login keychain, service `xyz.scio.blitzkvm`, account = the device's ID (the entry's UUID until the ID is learned on first connect).
- Logs: `~/Library/Logs/BlitzKVM/app.log` holds app messages and each helper's stderr. The legacy client writes `blitzkvm-legacy.log` there when not started from a terminal.

## Architecture

```
BlitzKVM.app (Swift)                          one helper per device
  DeviceWindowController ── VideoDecoder (VideoToolbox) ── VideoView (Metal)
  InputController, VirtualMediaWindow, SerialConsoleWindow
        │  length-prefixed frames over stdin/stdout (pkg/engineipc ⇄ EngineProtocol.swift)
        ▼
  blitzkvm-engine (Go): engine → session.Controller → client.Client
        │  HTTPS/HTTP login, WebSocket signaling, WebRTC (H.264/H.265 RTP; data channels rpc, hidrpc, serial)
        ▼
  JetKVM device (firmware 0.5.9)        or        pkg/emulator for tests
```

Invariants that changes must keep:

- **Input only after identity is confirmed.** The session is `connected`, the only phase that accepts input, only after the device ID matches the pinned one. That check happens before login when the device answers `GET /device` without a password, otherwise over RPC right after login. A device ID learned on first connect pins later reconnects.
- **HTTPS trust on first use.** `pkg/protocol/tlspin` pins the device CA that the presented chain is signed up to (the firmware issues a leaf per hostname, signed by a device CA it sends along). Publicly trusted devices are pinned to public trust (`webpki`). A change stops the session before any password is sent; the app offers "Trust New Certificate". The Swift probe (`CertificatePin.swift`) mirrors these rules.
- **Video:** the engine assembles RTP into access units (`pkg/video`) and forwards them; when the app falls behind, it drops to the next keyframe rather than queueing. The app offers H.265 (H.264 stays in the offer as a fallback); JetKVM picks H.265 whenever the offer contains it. `--h264` exists only for the self-tests, because the emulator's live test pattern is H.264. The app renders on its own queue as frames arrive: NV12 → RGB at the source size (chroma upsampled at the stream's siting), then resampled to the drawable (`VideoView.swift`); the layer is tagged sRGB because the captured desktop is sRGB-encoded.
- **One owner per session:** `pkg/session` runs the connect/reconnect loop on one goroutine; results of slow RPCs are applied only if their client is still current.

## Rules for contributors and agents

Mandatory:

1. **Never send keyboard or mouse input to, change settings on, or reboot a real JetKVM whose target is the machine you are working on.** The test device (`192.168.1.40`, see plan §17) is attached to the development Mac: keystrokes would type into your own session. Use `--view-only` against it. Live Go tests run whenever `JETKVM_BASE_URL` is set and they send key presses; settings changes and reboots are additionally gated by `JETKVM_LIVE_ALLOW_SETTING_MUTATIONS=1` and `JETKVM_LIVE_ALLOW_DISRUPTIVE=1`. Do not set these for that device.
2. **Base claims about device behaviour on the firmware source** (`jetkvm/kvm`, branch `release/0.5.9`), with file references. When the emulator and firmware disagree, fix the emulator to match the firmware; never shape the emulator around the client.
3. **Change the engine IPC on both sides at once:** `pkg/engineipc/engineipc.go` and `macos/Sources/JetKVMCore/EngineProtocol.swift`.
4. **Do not edit generated files by hand:** `*_enums.go` (run `make generate`) and `pkg/input/layouts_gen.go` (run `make layouts UPSTREAM=…`). `pkg/emulator/params.go` mirrors upstream `rpcHandlers` parameter lists for release 0.5.9; it was extracted with a one-off script that is not committed, so update it from upstream `jsonrpc.go` when targeting a new firmware.
5. **Regi** (AGPL-3.0, another JetKVM client) is learn-only: never read its source while implementing, and never copy from it.
6. **Fork hygiene:** the `upstream` remote is fetch-only, and no pull requests go upstream. Upstream's GitHub workflows are disabled on this fork. Fork CI (`.github/workflows/fork-check.yml`) runs only on pull requests and manual dispatch, because macOS minutes are expensive on private repositories.
7. **Security changes need an attack test.** When you change identity checks, TLS pinning or credential handling, add a test that plays the attacker (see `pkg/session/tls_test.go`, where an intercepting proxy must not receive the password) and confirm it fails without your fix.
8. **Never commit credentials:** no signing identities, private keys, passwords or API keys. Notarization uses the account signed into Xcode.

Preferred:

- Give tests a negative control: break the code on purpose and check that the test fails.
- Use event-driven waits, and `ICELoopbackOnly: true` for emulator-backed tests. A Mac with several network interfaces makes ICE slow and flaky otherwise.
- Keep comments short and about why. Match the surrounding style (Go: gofmt; Swift: existing file conventions).

Ask the owner before you:

- act on real hardware beyond view-only use;
- push to `main` or to any remote other than the working branch;
- notarize or publish a build;
- delete images from a real device's storage;
- change the roadmap or a decision recorded in the plan.

## Signing and distribution

`make -C macos app` signs with the first "Developer ID Application" identity in the login keychain (currently Scio Labs, team `79UD4HPFRD`), using the hardened runtime and a secure timestamp. Without such an identity it signs ad hoc. In that case Accessibility and Local Network grants reset on every rebuild. Override with `SIGN_IDENTITY="…"`. Set `COPY_TO=` (empty) to skip the `~/Downloads` copy.

`make -C macos notarize` notarizes with the Apple ID signed into Xcode (Settings → Accounts, team `79UD4HPFRD`); it needs no app-specific password or API key. `macos/scripts/notarize.sh` wraps the signed app in a minimal Xcode archive, uploads it with `xcodebuild -exportArchive`, and waits until Apple has processed it (usually a few minutes). It then fetches the stapled app with `xcodebuild -exportNotarizedApp` and leaves `macos/build/BlitzKVM.zip`, also copied to `~/Downloads`. Notarizing publishes the build to Apple, so only do it when the owner asks for a shareable build.

## Troubleshooting

- **`external macro implementation type 'SwiftUIMacros…' could not be found`:** you ran `swift build` with the Command Line Tools. Build through `make -C macos …`, which selects Xcode.
- **The picture stands still while the status bar still shows frames arriving:** something waited for a keyframe without asking for one. With the fork's keyframes on demand, that froze the picture for up to a minute (plan §26). Every wait now asks for a keyframe and normally ends within tens of milliseconds. `app.log` names each wait and how long it lasted (`video resumed at a keyframe after …`), and a watchdog logs `video watchdog: …` if frames arrive but none decode or reach the screen.
- **The picture stops after changing Stream Quality (or on its own, with Automatic):** fork firmware before 2026-10-11 stopped encoding when a quality change switched between 60 and 30 fps, until the stream restarted (plan §27). Install the current fork build.
- **Keyboard and pointer stop while the picture stays live, then work again:** the data channels (SCTP) were waiting out a retransmission timer after lost packets. The helper caps that timer at 1 s (plan §25), and so does the fork firmware (D09). `app.log` records `input data channels stalled` and `… recovered` with the duration. Builds before plan §26 also logged false alarms there while the pointer moved.
- **Emulator-backed tests time out in ICE:** set `ICELoopbackOnly: true` on both the emulator config and the client or session config.
- **`make generate-check` fails right after editing:** expected. It requires a clean tree; commit first or run the other `check` steps directly.
- **A device shows "not reachable" although it is up, and it uses https:** its certificate may have changed. Choose Try Anyway to see the certificate alert and decide whether to trust the new one.
- **Screenshots of app windows come out empty or fail:** the capturing process needs Screen Recording permission.
- **staticcheck:** not used. It cannot read go1.27 export data yet.

## Legacy Ebiten client

Upstream's client still builds and works against devices and the emulator. It finds devices on the local network, connects by hostname, mDNS name or IP, and shows video, input, stats and the core settings in one window.

```bash
go run ./cmd/blitzkvm-legacy                    # launcher with discovery
go run ./cmd/blitzkvm-legacy jetkvm.local       # connect directly
go run ./cmd/blitzkvm-legacy --password-stdin 192.168.1.50 < password.txt
```

Flags: `--password-stdin`, `--password-env NAME` (default `JETKVM_PASSWORD`), `--log-level`, `--rpc-timeout`. Its experimental USB-network settings UI is hidden unless `BLITZKVM_ENABLE_EXPERIMENTAL_USB_NETWORK=1`. Screenshots: [`docs/launcher.png`](docs/launcher.png), [`docs/settings.png`](docs/settings.png).

## Related docs

- [`plans/2026-10-10-engineering-plan.md`](plans/2026-10-10-engineering-plan.md): read before changing architecture, roadmap or a recorded decision.
  - §4.2: verified firmware behaviour.
  - §6: roadmap.
  - §17: decision log.
  - §19: implementation status.
  - §20: execution report (divergences, takeaways).
- [`third_party/openh264-go/README.md`](third_party/openh264-go/README.md): the vendored OpenH264 bindings.
- Firmware: the fork [github.com/wottpal/kvm](https://github.com/wottpal/kvm) (`FORK.md`: every difference from upstream, releases, procedures). Upstream [github.com/jetkvm/kvm](https://github.com/jetkvm/kvm) develops on `dev`; releases are on `release/X.Y.Z` branches.

License: MIT (see [`LICENSE`](LICENSE)).
