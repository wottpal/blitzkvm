# jetkvm-desktop: Engineering Plan (v2, revised after independent review)

| | |
|---|---|
| Date | 2026-10-10 (v1), revised 2026-10-10 (v2) |
| Status | Approved direction. Implementation started on branch `native-foundation` (see §17). |
| Repo | `wottpal/jetkvm-desktop` (private fork), base commit `289df51`, identical to `lkarlslund/jetkvm-desktop` `main` |
| Target firmware | JetKVM app 0.5.9 / system 0.2.8 (live device `.107`). Upstream `jetkvm/kvm`: `dev` @ `8f6c300` (2026-10-05), `release/0.5.9` @ `36c008f`. **Note:** upstream develops on `dev`; `main` is frozen at 0.4.8. |
| Method | v1: five parallel deep-dives (video pipeline, UI architecture, protocol and session, build/CI/dependencies, product landscape), then a re-check of key claims against code. v2: independent adversarial review with three parallel reviewers plus a PM interview, then each review finding re-checked against the code before being accepted (§16). |

### Evidence labels
- **[V]** verified in code: this repo, or upstream at the refs above
- **[M]** measured on this Mac (Apple M6, Retina 2×) with throwaway benchmarks outside the repo
- **[L]** verified on the live JetKVM `.107` with read-only probes
- **[W]** from a web source (linked)
- **[I]** inferred or not yet verified. Each one is listed in §15.

> The live device reported `no_signal` throughout, because this Mac's only display is the Jump Desktop virtual display. Signaling, SDP and RPC behaviour were verified live; live **video timing** was not. Video timing was measured on a loopback harness and the in-repo emulator.

---

## 0. Summary

**Goal (PM).** **Fully replace Jump Desktop** for the PM and a few people, using JetKVM hardware.
- macOS client only.
- Targets: macOS, Linux desktop, and headless/BIOS machines.
- Several devices per day (1–2 original JetKVMs today), reached remotely over a self-hosted VPN.
- Long, latency-critical sessions: typing/terminal work as well as GUI/mouse work.
- No deadline: quality over speed.
- Sovereignty matters, so **no JetKVM Cloud**.
- The Ebiten app is **retired** once the native app ships, with no interim polish. Jump Desktop covers daily use until then.

**Strategy**

0. **Phase R, benchmark** (when the HDMI rig is ready). Measure Safari web UI, Regi (learn-only), JetRemote (optional) and the current app on both of the PM's displays. Safari becomes the acceptance bar.
1. **Phase 0, housekeeping.** Fork CI, dependency refresh to zero known vulnerabilities, file logging and crash output.
2. **Phase 1a, emulator parity.** Make the in-repo emulator behave like firmware 0.5.9, so every engine fix can be tested without risking the live device.
3. **Phase 1b, engine.** Restructure the session lifecycle so one goroutine owns all connection state, then fix the bugs in §3.1/§3.2/§4.1.
4. **Phase 2, native spike.** Swift/AppKit app (`xyz.scio.jetkvm-mac`, arm64), with the Go engine as a **helper process, one per device**. VideoToolbox decode (H.264 + H.265), Metal presentation, NSEvent input, an event-tap proof, helper crash recovery. This is de-risking, not a bake-off.
5. **Phase 3, native MVP.** The app that can replace Jump.
6. **Phase 4, full settings parity and extras.** Full parity is about **4–6 months from start**.

**Not doing**
- Rewriting the protocol engine or the emulator in Swift.
- Adopting libwebrtc. Revisit only if the Regi measurements in Phase R clearly beat pion.
- JetKVM Cloud.
- Universal binaries.
- Interim Ebiten polish.

---

## 1. Requirements (MoSCoW)

| | Requirement | Acceptance criterion |
|---|---|---|
| **Must** | Retina-correct rendering | The ~1080p HDMI feed is drawn at physical pixels; 1:1 mode is bit-exact. *Retina does not make the remote look like Jump's virtual display: remotes run at the JetKVM EDID resolution. Mac targets should use the device's existing 1920×1200 (16:10) EDID preset.* |
| **Must** | Auto-fit on resize, maximize and fullscreen | Aspect-preserving fit every frame, no input blackout; host resolution changes mid-session are handled |
| **Must** | Two concurrent devices | One window or tab each. Background windows stay connected but don't decode. Architecture stays N-capable. |
| **Must** | Remote over any self-hosted VPN | Works on every VPN where the device web UI works in Safari (§10). Tailscale is the reference. |
| **Must** | Robust on lossy, high-RTT links | No visible freeze from a single lost packet; bounded, jittered reconnects; a connect never hangs |
| **Must** | Latency no worse than the device web UI in Safari | Same device, link and screen. Measured on the 120 Hz MacBook Pro (windowed and fullscreen) and the 60 Hz external. *Should:* within one display refresh of raw decode. (v1's "≤ ~20 ms client-side" was a fullscreen/120 Hz best case. In a window at 60 Hz, macOS adds about 25–35 ms whatever the client does [I].) |
| **Must** | Mac keyboard fidelity | While the window is focused, system shortcuts (⌘Tab, ⌘Space, ⌘Q, Ctrl-arrows…) go to the remote. An escape chord releases them. A visible "capture active" indicator. Secure Event Input is detected and shown. Per-device Cmd↔Ctrl / Option↔Alt profiles. ⌘⌥Esc and trackpad system gestures **can't** be captured; this is documented. |
| **Must** | Saved devices, credentials in Keychain | One click to connect; passwords never in env vars or prefs files |
| **Must** | Full settings parity with the device web UI | Delivered last; capability-gated, with a 0.5.9 fallback table |
| **Should** | Layout-aware paste (⌘V), long text | Mixed layouts per device (PM: German on both sides); >3.6k characters works |
| **Should** | H.265 (native app) | VideoToolbox decode; H.264 fallback. The best lever for picture quality at the device's ~4 Mbps target. |
| **Should** | Copy text from the remote screen (OCR) | Drag-select, Apple Vision, Mac clipboard |
| **Should** | Display modes | Fit, 1:1 (pan), integer-nearest, sharp-bilinear, fit-window-to-remote, aspect lock |
| **Could** | Pointer lock | Absolute pointer is the default. Lock only matters in relative mode (some BIOSes). |
| **Could** | Audio, screenshots/recording, EDID "match aspect" presets, URL scheme | — |
| **Won't** | JetKVM Cloud | Sovereignty |
| **Won't** | Jump-style continuous remote resize | Impossible over HDMI capture (§11) |
| **Won't** | Multi-user viewing of one device | The firmware allows one session |
| **Won't** | Windows/Linux clients | — |

---

## 2. How the system works today

**Size** [V]
- About 24k lines of Go, plus a vendored cgo OpenH264 wrapper.
- Largest files:

| File | Lines | Role |
|---|---|---|
| `pkg/app/app.go` | 4,099 | UI god object |
| `pkg/app/chrome.go` | 4,039 | Settings panels and chrome |
| `pkg/session/controller.go` | 2,306 | Session lifecycle and ~60 RPC wrappers |
| `pkg/emulator/server.go` | 1,810 | Fake device for tests |
| `pkg/client/client.go` | 945 | WebRTC, signaling, data channels |

**Stack**
- Ebiten v2.9.9 (game engine, with a custom immediate-mode toolkit in `pkg/ui`).
- pion/webrtc v4.2.11.
- OpenH264 2.1.1 software decode (prebuilt static `.a`).
- gorilla/websocket, zerolog, cobra, sqweek/dialog, golang.design/x/clipboard.

**Layers**
```
cmd/jetkvm-desktop ── pkg/app (Ebiten Game: Update/Draw/Layout, 130-field App, 187 methods)
                        │  polls ctrl.Snapshot() ~7×/frame, LatestFrameInfo() per frame
                     pkg/session.Controller (phase machine, reconnect, ~60 get/set wrappers, own copies of types)
                        │
                     pkg/client.Client (auth → WS signaling → pion PC → data channels rpc/hidrpc×3/serial; video.Stream)
                        │
        pkg/protocol/{auth,signaling,jsonrpc,hidrpc}   pkg/video (samplebuilder → openh264)   pkg/input, pkg/hotkeys
pkg/discovery (IPv4 /24 HTTP sweep every 30 s)        pkg/emulator (fake device for tests, imports client types)
```

**Video frame path today** [V]
1. `ReadRTP` (`pkg/video/stream.go:118`).
2. `samplebuilder` (`WithMaxTimeDelay(33ms)`, `:105-110`).
3. OpenH264 `DecodeFrameNoDelay` (`bridge.cpp:240`).
4. A new `image.YCbCr` per frame (`decoder.go:176`).
5. Publish "latest", plus a dead `frameCh`.
6. The game thread polls once per vsync.
7. CPU `frameToRGBA` into a new 8.3 MB buffer (`app.go:593`).
8. `WritePixels`.
9. Linear fit into a **point-sized** backbuffer (`app.go:648`).
10. 2× upscale to Retina.

---

## 3. Verified findings

### 3.1 Engine bugs

Every item was confirmed twice: by the v1 analysis and by the independent review.

| ID | Finding | Evidence | Effect |
|---|---|---|---|
| **B1** | Void JSON-RPC responses (`{"jsonrpc","id"}`, no `result`) are rejected as unknown shape | [V] `jsonrpc.go:94-102`, `client.go:557-560`; upstream `Result any \`json:"result,omitempty"\`` (`jsonrpc.go:32-36`); errors are −32603 with the real text in `data` | ATX/DC power (`controller.go:393,447`), reboot, update, factory reset, mount/unmount/delete and `wheelReport` hang 5–20 s, then report failure **although they succeeded**. `mutateAndConfirm` masks this for ~20 setters. The emulator replies `true` (`server.go:1166,1525`). |
| **B2** | No RTCP feedback negotiated: `SetCodecPreferences` with a bare H.264 capability | [V] `client.go:304-311`; [L] answer has no `rtcp-fb`. The device *does* run pion's NACK responder (1024-packet buffer) [V upstream]. | Lost packets are never retransmitted; the picture freezes up to 0.5 s (next IDR; PLI is ignored by the device) |
| **B3** | Connect can hang. No `ResponseHeaderTimeout`; zero-valued WS dialer; the answer wait uses only the caller's ctx (no deadline); `{"error":…}` is ignored | [V] `auth.go:53-72`, `signaling.go:106-107`, `client.go:288-298`, `controller.go:1882` | Stuck on "connecting" |
| **B4** | Backoff overflow. Base 500 ms; negative from attempt 35, exactly 0 from 56; `attempt` is never reset | [V] `controller.go:2230-2236` | **A tight reconnect loop after ~6–9 minutes offline** |
| **B5** | Every absolute-pointer report, including button transitions, goes on `hidrpc-unreliable-ordered` | [V] `client.go:436-457`. Upstream web UI sends button transitions, the first report after each handshake, and all relative reports reliably (`useHidRpc.ts:259-271`). | Lost clicks, stuck drags |
| **B6** | `USBDevices` lacks `audio` and sends a `network` field upstream doesn't have. Saving `audio:false` also persists `AudioEnabled=false` upstream (`jsonrpc.go:1066-1076`). | [V] `rpc_types.go:181-188`; [L] device returns `"audio":true` | Saving USB settings **switches USB audio off persistently** |
| **B7** | Races: `Stats()` reads `c.pc` while `Connect`/`Close` write it; same for `cfg.Password` and `signalConn` | [V] `client.go:193,355,698-729`, `controller.go:2130`; [M] reproduced 3/3 | Rare crash |
| **B8** | Login on every connect. There is one global token, **written to flash on every login**, with a 7-day cookie. A correct login is never rate-limited; 429 + `Retry-After` only follows 5 wrong passwords (15 min, rising to 2 h). | [V] `client.go:184`; upstream `web.go:459-503`, `ratelimit.go` | Each reconnect logs out browser tabs and wears flash |
| **B9** | Any WS dial error silently falls back to legacy `POST /webrtc/session` (removed in 0.5.9, #1569) | [V] `client.go:819-822`; [L] 404 | Real errors masked as 404 |
| **B10** | Bootstrap blocks input: `WaitForHID` (5 s), then 9 sequential RPCs, before `PhaseConnected`. Input is gated on that phase (`controller.go:2173`). | [V] `controller.go:1945-2036`; [L] `getEDID` stalls on no-signal | Input dead for 5+ s after each (re)connect |
| **B11** | Video dies silently on any `ReadRTP` error; `Stream.Err()` has no callers; the "Decode FPS" stat is always 0 | [V] `stream.go:118-121` | Frozen picture while the UI says connected |
| **B12** | Events mis-parsed or ignored. `videoInputState` is handled as an object but read via a `"state"` key (`controller.go:2061-2068`). `willReboot.redirectTo`, `otaProgress` and `failsafeMode` are ignored. The event channel drops when full. | [V] | No "no signal" state; after an IP change it reconnects to the old IP |
| **B14** | Paste is US-ASCII only and sent as one macro: 9 B/step × 2 steps/char ≈ 3.64k chars per 64 KiB | [V] `pkg/input/paste.go:61-85` | Umlauts break; long pastes fail |
| **B15** | Dead or wrong methods: `getKeysDownState` (upstream: `getKeyDownState`); `forceDisconnect` and `get/setUsbNetworkConfig` exist nowhere upstream | [V] `rpc_methods.go:20,373` | — |

~~B13 (serial channel always opened)~~ was **withdrawn**. The upstream web UI also opens `serial` unconditionally (0.5.9 `devices.$id.tsx:574`); opening it only redirects console output and leaves the UART untouched (`serial.go:621-637`).

### 3.2 Video latency and quality

| ID | Finding | Evidence |
|---|---|---|
| **V1** | Two one-frame holds. (a) `samplebuilder` waits for the next frame's first packet even when the marker bit is set. (b) OpenH264 2.1.1 returns Main/High-profile frames one call late. | [V] (a) `samplebuilder.go:249-253`; (b) [M] loopback receive→decoded p50 **35.5 → 2.2 ms** with both fixed (p99 46 → 13) |
| **V2** | Colour: Go's `image/draw` uses full-range BT.601. The device sends limited-range BT.709 for HD modes and **BT.601 for modes ≤576 lines** (`video.c:120-165`). | [V]. Read the colour info from the stream; don't hard-code a matrix. |
| **V3** | CPU colour conversion = **31% of app CPU** at 1080p30; 3.3 ms and 8.3 MB per 1080p frame; 11.4 MB garbage per frame overall | [M] |
| **V4** | Decode times: OpenH264 P 1.8 ms / IDR 9.8 ms; **VideoToolbox P 0.53 / IDR 2.0 ms** | [M] |
| **V5** | The 33 ms max-delay is too short for NACK (default interval 100 ms + RTT) | [V]; [M] one loss dropped two frames |
| **V6** | Device behaviour: ignores PLI/FIR; GOP = fps/2; High profile. Bitrate target = (512 + 3488·quality) kbps × pixel scale, capped at 1.5× (≤ ~6 Mbps), floor 0.5×. | [V] upstream `video.c`, `webrtc.go` |
| **V7** | Game-loop poll wait (0–16.7 ms) plus 3 queued drawables | [V] `main.go:90`; display-path ms [I] |
| **V8** | The test-pattern **encoder** ships inside the client binary (~325 KB) | [M] |

### 3.3 Rendering, Retina and resize

| ID | Finding | Evidence |
|---|---|---|
| **R1** | **Retina is broken.** `Layout` returns points, so the backbuffer has half the needed resolution. | [V] `app.go:648-655`; [M] |
| **R2** | Auto-fit works: aspect-preserving fit and centred letterbox, recomputed every frame; host resolution changes handled | [V] `app.go:583-628,3941-3948` |
| **R3** | Gaps (all addressed by the native view, N5) | [V] |

R3 gaps:
- Always linear filtering and no pixel snapping.
- No 1:1, integer or fit-window mode, and no aspect lock.
- **200 ms input suppression after every resize** (`app.go:649-651`).
- `renderRect` lags one frame.
- Native-Spaces-only fullscreen, with the menu bar revealing at the top edge.
- The letterbox uses the current theme's background colour.

### 3.4 Input and the macOS keyboard

| ID | Finding | Evidence |
|---|---|---|
| **K1** | ⌘Q, ⌘H, ⌘⌥H, ⌃⌘F **and ⌘M** are consumed by the Ebiten/GLFW app menu | [V] `cocoa_init_darwin.m:106-144` |
| **K2** | System shortcuts never reach the app; needs CGEventTap + Accessibility | [V] |
| **K3** | Input polled once per frame. Presses are sent before releases (in random map order). The keepalive depends on the frame loop. | [V] `app.go:657-686`, `keyboard.go:29-52` |
| **K4** | Wheel: fractional deltas become ±1 per frame; deltas inside the throttle window are dropped; X ignores invert; one blocking goroutine per tick (B1) | [V] `app.go:914-927,1100-1124` |
| **K5** | Relative mouse clamped to ±127 with the remainder discarded | [V] `app.go:943-955` |
| **K6** | Caps Lock reported as held while the lock is on; LED state ignored | [V] |
| **K7** | No per-device modifier profile | [V] |

### 3.5 Remote access

| ID | Finding | Evidence |
|---|---|---|
| **N1** | Client: `webrtc.Configuration{}`, no SettingEngine tuning | [V] `client.go:189` |
| **N2** | Device, local mode: host candidates only, trickled ~20 ms after the answer; UDP only (no ICE-TCP listener). It **ignores client-sent `iceServers`**. | [V] upstream `webrtc.go:433-517`; [L] |
| **N3** | Discovery is an IPv4 /24 HTTP sweep of every interface, every 30 s; it can't cross a VPN; it trusts any responder | [V] `discovery.go` |
| **N4** | The device answers mDNS A records for `jetkvm-<deviceId>.local`; no DNS-SD service | [L] |
| **N5** | Tailscale: the firmware only *reads* `tailscale status --json` if a `tailscale` binary is already installed on the device. It doesn't install or start it. | [V] upstream `internal/tailscale/tailscale.go` |

### 3.6 Security and supply chain

| ID | Finding | Evidence |
|---|---|---|
| **S1** | OpenH264 **2.1.1** (2020), affected by **CVE-2025-27091**. Leaves with the native app (VideoToolbox); not rebuilt in the meantime. The Ebiten app is a test client against trusted devices. | [V] `codec_ver.h`; [M] |
| **S2** | CI Go 1.26.2: 23 reachable vulnerabilities. Local 1.27.1: 13. Deps bumped + Go 1.27.2: **0** | [M] govulncheck |
| **S3** | Password via `JETKVM_PASSWORD` env var by default; re-sent on every reconnect, over plain HTTP unless HTTPS is enabled | [V] `main.go:20,39-41`, `client.go:184` |
| **S4** | No TLS trust-on-first-use pinning for self-signed devices | [V] |
| **S5** | Discovery trusts any `/device/status` responder. Fix: `/device` and `/device/status` need no login (F4), so verify `deviceId` before sending a stored password. | [V] |
| **S6** | Prebuilt `.a` libraries: no build script, outside `go.sum` because of `replace` | [V] |

### 3.7 Build, CI and tests

- Build, vet, staticcheck and gofmt are clean.
- **Minimum macOS = build host's** (no deployment target).
- Universal build works but isn't needed (arm64 only).
- **Flaky emulator tests**: 2 s wall-clock budgets fail under parallel load. CI hides this with cached results.
- Coverage: 20% own-package / 30% cross-package.
- `go generate` broken on Go 1.27 (enumer 1.6.3).
- Build number = commit count.
- Logs go to stderr only; panics leave no crash report.

### 3.8 Code health (UI layer, informational; the Ebiten UI will be retired)

- `App`: 130 fields, 187 methods.
- `invokeAction`: a 651-line string switch with **186** case labels.
- 33 text fields, each touching up to 8 places.
- 34 off-thread writes to UI state.
- Side effects in `Draw`.
- Stale toggle cache.
- Types defined three times (client, session, emulator via client).

This informs the native app's design. None of it will be refactored in Ebiten.

---

## 4. Additional findings from the review

### 4.1 Engine bugs (verified)

| # | Bug | Evidence | Effect |
|---|---|---|---|
| **M1** | Mouse buttons stay pressed on the remote. `syncMouse` copies the button state without sending it when the window is unfocused or resizing; focus loss releases keys only. | [V] `app.go:735,806,491` | ⌘Tab mid-drag leaves the button held |
| **M2** | Concealed frames may be discarded: the bridge treats decode states other than 0/1 as errors | [I] `bridge.cpp:243` | Freezes until the next IDR after any loss. Moot with VideoToolbox. |
| **M3** | `Client.Close` (pion + C decoder) runs under the controller lock while the UI calls `Snapshot()` ~7× per frame | [V] `controller.go:2160-2167` | UI stalls on drop/reconnect |
| **M4** | In-flight RPCs don't fail when the client closes | [V] `client.go:394-397` | Every pending call waits its full 5–20 s |
| **M5** | ICE candidates arriving before the answer get one blind retry after 100 ms | [V] `client.go:915-918` | Intermittent connect failures on high RTT |
| **M6** | `newClient` ignores the `client.New` error, so a nil dereference is possible | [V] `controller.go:2130` | Crash |
| **M7** | The `running` flag in `Start`/`Stop`/`ReconnectNow` is racy | [V] | Two concurrent reconnect loops |
| **M8** | Any data channel's `OnClose`/`OnError` tears down the whole session | [V] `client.go:645-659` | One channel closing kills the session (blocks per-channel features) |

### 4.2 Firmware behaviour (upstream)

| # | Fact | Consequence |
|---|---|---|
| **F1** | With preference "auto", the device picks **H.265 if "H265" appears anywhere in the offer**. pion's default codecs include H.265. [V `webrtc.go:191-209`] | While OpenH264 decodes, offer **H.264 only**. The native app gets HEVC by offering it. |
| **F2** | ICE "disconnected" (~5 s of silence, pion defaults) ends the session; no ICE restart | WAN blips >5 s mean a full reconnect, so make reconnects fast |
| **F3** | A new session takes over at answer creation, before ICE connects. The old one gets `otherSessionConnected`, its keyboard is cleared, and it closes 1 s later. | Never race WebRTC sessions across addresses. Race `GET /device/status` (no auth), then open one session. |
| **F4** | `/device/status` and `/metrics` need no login; there is an HTTP `/storage/upload` route | Identity and health probes need no password; virtual media upload over HTTP |
| **F5** | BT.601 for modes ≤576 lines | Use the stream's colour info |
| **F6** | Wheel has no HID-RPC path (0x04 defined but not handled) | Wheel stays JSON-RPC `wheelReport`, which needs B1 fixed |
| **F7** | JSON-RPC handlers run concurrently, so responses can arrive out of order | Correlate by id only |
| **F8** | HID keepalive. 0x05 key press starts a 100 ms auto-release per non-modifier key. A 0x09 keepalive every 50 ms extends it; one >100 ms late or older than 225 ms is ignored. Full 0x02 reports never auto-release. LED 0x32 over HID only after the 0x01 handshake, otherwise as a JSON-RPC event. | The keepalive ticker must hold these timings; prefer 0x05 + keepalive so keys release if the link stalls |
| **F9** | Macro state 0x34 reports running/not-running (it is not an ack). **A new macro cancels the running one.** | Paste must wait for running→stopped before each chunk |
| **F10** | Development is on `dev`; tags are `release/X.Y.Z` and `release/X.Y.Z-devYYYYMMDDhhmm` | Drift CI tracks `dev` and real release tags |
| **F11** | On `dev` the device pushes `localVersion` and `deviceCapabilities` on RPC open; a missing capability means off. 0.5.9 pushes nothing. | Capability gating needs a 0.5.9 fallback table |
| **F12** | JetKVM Mini runs separate firmware: `-mini` versions, `wifi`/`removable_storage` capabilities, takeover signalled on the WS (`other-session-connected`, close code 4001) | Low priority; never gate on version alone |
| **F13** | "Hide display when idle" rewrites the EDID on first connect and last disconnect | Hint in settings |
| **F14** | Signaling now sits behind an adapter "so a different transport can be added later" (#1569) | Likely future change; drift CI should flag it |
| **F15** | No SDK or protocol doc beyond `DEVELOPMENT.md` | The generated schema plus the emulator are the safety net |

---

## 5. Architecture

### 5.1 Decision: native Swift shell + Go engine as a helper process

**Why not keep Ebiten.** Ebiten works against most of the must-haves:
- one window per process
- the app menu swallows ⌘ shortcuts
- polled input
- no access to hardware-decoded surfaces
- no accessibility or IME

Its UI layer is also the least healthy code. The Go engine, by contrast, is small, mostly correct once fixed, and backed by a valuable emulator. Option scores (v1 §4) are unchanged in direction: native shell + Go engine ≈ 119–123/150, Ebiten restructured 102, webview 92.

**Why pion and not libwebrtc.** The device lacks FEC and congestion control and ignores PLI. pion gives full control over the jitter/assembly policy (the libwebrtc receive-side jitter buffer and render timing are hard to control). The emulator works with any client. Revisit only if Phase R shows Regi (libwebrtc) clearly beating our stack.

**Why a helper process, not a c-archive** (accepted from the review):

| | c-archive | Helper process (chosen) |
|---|---|---|
| Crash isolation | A Go panic or deadlock kills all sessions and the UI | The helper restarts; the UI survives |
| Crash reports | An unrecovered panic `exit(2)`s with no macOS report | The helper logs to file; the app shows the error |
| Signals and debugging | Go signal handlers in-process; lldb stops on SIGURG | None of these issues |
| Build | Xcode build phase; sandboxed user scripts | Plain `go build` into `Contents/Helpers`, signed with the app |
| Throughput | Negligible cgo cost | A pipe with length-prefixed frames easily carries ≤6 Mbps |
| Local Network permission | App | Attributed to the responsible parent app ([TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)) [W] |

**Decision (v2): one helper process per device session.**
- This is the simplest wire protocol: no session multiplexing.
- It gives full fault isolation between devices.
- About 15–25 MB RSS per helper is irrelevant at two devices.

### 5.2 Overview
```
┌─────────────── JetKVM.app (Swift, AppKit + SwiftUI), bundle xyz.scio.jetkvm-mac, arm64 ───────────────┐
│ DeviceLibrary (saved devices, Keychain)       one NSWindow per device (native tabbing)                 │
│ VideoView: VTDecompressionSession (H.264/H.265) → CVPixelBuffer → Metal (CVMetalTextureCache,          │
│            YCbCr→RGB from buffer colour attachments, fit/1:1/integer, present on arrival)              │
│            keeps last CVPixelBuffer → OCR (Vision), screenshots                                        │
│ InputCapture: NSEvent (timestamped), CGEventTap while focused (+escape chord, Secure Input detection)  │
│ EngineProcess: spawn/monitor/restart Contents/Helpers/jetkvm-engine, framed messages over stdio pipes  │
└───────────────▲──────────────────────────────── stdin/stdout, length-prefixed ─────────────────────────┘
                │ out: video access units (Annex-B, codec, ts) │ events/snapshots (JSON) │ rpc results
                │ in : key/pointer/wheel/paste commands │ rpc calls (method + params JSON) │ connect/close
┌───────────────┴──────────── jetkvm-engine (Go, one process per device) ───────────────────────────────┐
│ session.Controller: one goroutine owns lifecycle (connect deadline, jittered backoff, close off-lock)  │
│ client: signaling (WS), pion PC with explicit MediaEngine (H.264 [+H.265 when the shell can decode]),  │
│         NACK interceptors, data channels (rpc, hidrpc reliable/unreliable), per-channel close          │
│ video: marker-driven access-unit assembler (RTT-aware gap deadline, keyframe wait)                    │
│ input: HID-RPC encoder, reliable-while-buttons-down routing, 50 ms keepalive ticker, chunked paste     │
│ emulator (same repo): 0.5.9-faithful conformance + loss/latency injection                            │
└────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### 5.3 Key design decisions

1. **The lifecycle actor first.** One goroutine owns connect, reconnect and close; snapshots go out to readers; nothing slow runs under a lock.
   - The ~60 RPC wrappers stay as they are until schema generation (Phase 4) replaces them.
   - *v2 deviation from the review:* the review proposed a full actor rewrite of `controller.go` first. I restructure only the lifecycle part, because the wrappers are slated for replacement anyway, and rewriting them twice adds regression risk to the test client for no user value.
2. **Video leaves the engine as access units.** The engine never decodes for the native app: Annex-B AUs + codec + timestamp go over the pipe, and Swift owns decode and display. The Ebiten test client keeps decoding with OpenH264 behind the same assembler.
3. **Generated, typed RPC from upstream** (Phase 4). Walk `rpcHandlers` at `release/*` tags and `dev` with `go/packages`. Emit Go `Method[P,R]` descriptors and Swift Codable models. Drift CI on new release tags. A 1-day feasibility check comes first.
4. **Event-driven input.** NSEvent handlers send immediately.
   - CGEventTap: active only while a device window is key and capture is on; trivial callback; re-enabled on `kCGEventTapDisabledByTimeout`; Secure Event Input detected and shown.
5. **Signing.** Developer ID or Apple Development certificates only, never ad-hoc for builds users run, so Accessibility and Local Network grants survive rebuilds.
   - Keychain: a file-based keychain item, or the data-protection keychain with a provisioning profile ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)) [W].
6. **The emulator is the source of test truth** (Phase 1a).

---

## 6. Roadmap

Sizes assume one developer directing AI agents. **Verification on real hardware, not code writing, is the bottleneck.**

### Phase R: Benchmark (2–3 days; starts once PM to-do #1 is done)

Runs in parallel with Phases 0/1. It gates Phase 2's pass criteria, not Phase 1.

**Rig.** Connect `.107`'s HDMI to this Mac. Build the **sink-window harness**:
- a dedicated text-capture window
- the harness verifies it is frontmost (`lsappinfo`) before every input burst, and aborts otherwise
- a kill switch that closes the HID session
- keystrokes never reach other apps

**Latency.** Two sources:
- The emulator burns timestamps into frames, captured with ScreenCaptureKit.
- On the real device, a millisecond clock on this Mac's HDMI output.

**Measure:** Safari web UI, Regi (learn-only: no code reading by implementers), JetRemote (only if bought), and the current app.
- Metrics: end-to-end latency, CPU, picture quality for H.264 vs H.265, lossy-link behaviour.
- Displays: the 120 Hz laptop (windowed and fullscreen) and the 60 Hz external.

**Output:** the baseline table, i.e. the acceptance bar.

### Phase 0: Housekeeping (½–1 day)

| ID | Task |
|---|---|
| H1/H2 | Upstream workflows disabled; `upstream` fetch-only. **Done.** |
| H3 | Fork CI `fork-check.yml`: `workflow_dispatch` + PR only (no push trigger; macOS minutes bill 10× on private repos). One `macos-15` job: vet, staticcheck, `go test -race -p 1`, govulncheck, actionlint. |
| H5 | File logging (`~/Library/Logs/jetkvm-desktop/` when not on a TTY) + `debug.SetCrashOutput` |
| E17 | Dependency refresh to govulncheck = 0 (§8); enumer 1.7.2 + regenerate |

### Phase 1a: Emulator parity (1–2 weeks)

The emulator becomes 0.5.9-faithful:
- void responses
- pion default interceptors (NACK responder)
- codec selection per F1
- takeover semantics per F3
- ICE-disconnect kill per F2
- token rotation, and 429 only after 5 wrong passwords
- HID keepalive and auto-release timings per F8
- 0x32 LEDs after the handshake
- macro running state and cancel-on-new per F9
- no legacy route
- configurable resolution, fps and GOP (fps/2 default)
- **wire-level loss and latency injection** (an interceptor below the NACK responder, so retransmits work as on the device)

Also: flaky tests fixed with event-driven waits.

**v2 modification (encoder limits):** OpenH264's encoder can't produce the device's High profile or H.265. High-profile and H.265 conformance therefore come from an optional **Annex-B replay source**: clips generated by `ffmpeg` at test time (tests skip if `ffmpeg` is absent), plus the RTP fixture recorded from `.107` once HDMI is connected.

### Phase 1b: Engine (3–5 weeks)

Order:
1. **Lifecycle restructure.** A single owner goroutine with these fixes:
   - per-attempt connect deadline that does **not** cover the video stream (E6, review fix)
   - capped exponential backoff + jitter, reset after a stable session, 429 = locked out (E7)
   - close outside locks (M3)
   - pending RPCs fail on close (M4)
   - early ICE candidates queued until the answer is applied (M5)
   - `newClient` error handled (M6)
   - atomic running/stop (M7)
   - per-channel close handling (M8)
   - Connected on HID-ready, with `getUpdateStatus`/`getEDID` taken out of bootstrap (E11)
   - one cookie jar per controller, login only on 401 (E10)
   - drop the legacy signaling fallback (B9)
   - deadlines on HTTP/WS (B3)
2. **RPC.**
   - void responses (E1)
   - round-trip-safe settings incl. `audio`, without the stray `network` field (E9)
   - events: `videoInputState`, `willReboot.redirectTo`, `otaProgress`, `failsafeMode`, LEDs (E12)
   - method names / dead methods (E13, without the serial change)
   - engine races (E16)
3. **Video.**
   - explicit MediaEngine: **H.264 only** for the OpenH264 client, H.265 opt-in for the native shell, with `nack`, `nack pli`, `ccm fir`, fmtp; NACK interval ~20 ms (E2)
   - a marker-driven access-unit assembler with RTT-aware gap deadline and keyframe wait, replacing samplebuilder (E3)
   - OpenH264 `FlushFrame` after an empty decode (E4)
   - verify M2; continue after non-fatal read errors; real decode stats; dead `frameCh` removed (E5)
   - move the test-pattern encoder out of the client binary (V8)
4. **Input.**
   - pointer reports go reliable whenever any button is down or just changed, and for the first report after the handshake; unreliable only when all buttons are up (E8 revised)
   - release all on focus loss/resize (M1)
   - releases before presses
   - 50 ms keepalive ticker per F8
   - wheel accumulation (E14 engine half)
   - layout-aware, chunked paste that waits for running→stopped (E15)
5. **Tests.** Fuzzers for the HID-RPC/JSON-RPC/SDP decoders; RTP replay fixture from `.107` when HDMI is connected (E18 rest).

The Ebiten app keeps compiling as a manual test client; no polish.

### Phase 2: Native spike (1–2 weeks; de-risking)

**Scope**
- SwiftPM-based macOS app (`macos/`), bundled into a `.app` by script, arm64 only, bundle `xyz.scio.jetkvm-mac`.
- Developer ID signing once team details exist; ad-hoc signing for local builds until then.
- `cmd/jetkvm-engine` helper over stdio.
- VTDecompressionSession (H.264 + H.265) → Metal (`CAMetalLayer`, `CVMetalTextureCache`, runtime-compiled shader, colour matrix from buffer attachments, present on arrival).
- NSEvent keyboard/mouse/scroll.
- CGEventTap proof (⌘Tab/⌘Space to the remote, escape chord, Secure Input detection).
- Helper crash → auto-restart → session resumes.

**Pass criteria**
- End-to-end latency ≥ the Safari baseline on both displays.
- Input latency measured.
- CPU ≤ Safari.
- Event tap reliable across a day of use.
- Helper crash survived.
- Warm build + sign under 1 minute.

**If it fails:** revisit libwebrtc using the Regi measurements. (Ebiten is no longer the fallback.)

### Phase 3: Native MVP, the "switch off Jump" app (6–10 weeks)

- Device library: ordered address list (LAN, `jetkvm-<id>.local`, VPN), HTTP-probe racing (F3/F4), `deviceId` verification before sending a stored password, Keychain.
- One window per device, native tabbing, 2 concurrent sessions; background windows stay live but don't decode.
- Display modes: Fit, 1:1 (pan), integer-nearest, sharp-bilinear, fit-window-to-remote, aspect lock, dark letterbox, fullscreen without the menu bar.
- Input: per-device Cmd↔Ctrl / Option↔Alt profiles (macOS targets pass ⌘ through; Linux maps it); Caps Lock as a toggle with LED sync; precise scroll accumulation.
- ⌘V paste with progress and cancel; layout per device.
- ATX/DC power, virtual media (URL + `/storage/upload` with progress), serial console.
- Connection health in the toolbar; reconnect on `NWPathMonitor` changes; TLS trust-on-first-use pinning per `deviceId`.
- An "Open web settings…" escape hatch until Phase 4 (it kicks the app's session; the app shows "taken over" and reconnects).

### Phase 4: Full settings parity and extras (ongoing; parity ~4–6 months from start)

1. Generated schema (after the 1-day feasibility check) → Swift Codable models.
2. All 12 settings sections, capability-gated, with a 0.5.9 fallback table.
3. Drift CI against `release/X.Y.Z` tags.
4. Extras, in order:
   - OCR copy (Vision)
   - macros and the special-keys menu
   - Wake-on-LAN
   - screenshots and pass-through recording
   - audio
   - EDID presets including 1920×1200, with auto-revert
   - URL scheme

**Removed in v2**
- JetKVM Cloud.
- Interim Ebiten work (v1 E19, E20, H4, Plan B).
- The OpenH264 2.6.0 rebuild.
- Universal binaries.
- Pointer lock as a gate.

---

## 7. Performance budget (client-side, 1080p)

| Stage | Today | After Phase 1b (engine) | Native target |
|---|---|---|---|
| RTP assembly hold | ~16.7 ms [M] | ~0 (marker assembler) | ~0 |
| Decoder reorder hold | ~16.7 ms [M] | 0 (flush) | 0 (VideoToolbox) |
| Decode (P / IDR) | 1.8 / 9.8 ms [M] | same (OpenH264 test client) | 0.53 / 2.0 ms [M] |
| Colour convert + upload | ~3.7 ms | same | ~0 (zero-copy texture cache) |
| Wait for game tick | 0–16.7 ms | same | ~0 (present on arrival) |
| Present + scanout | ~16–25 ms [I] | same | fullscreen/120 Hz ~8–9 ms; windowed/60 Hz ~25–35 ms [I] |
| CPU at 1080p30 | 35–37% of a core [M] | similar | target ≤ Safari |

The acceptance bar is relative (≥ Safari, §1). These numbers are diagnostics, not targets.

---

## 8. Dependency and pattern refresh

| Item | Now | Target | Why |
|---|---|---|---|
| Go toolchain | `go 1.26.2`, no `toolchain` | `toolchain go1.27.2` | stdlib vulnerabilities |
| pion/webrtc/v4 | 4.2.11 | 4.2.23 | reachable pion/dtls and pion/stun vulnerabilities |
| pion/rtp | 1.10.1 | 1.10.5 | — |
| golang.org/x/net | 0.50.0 | ≥0.60.0 | 6 reachable vulnerabilities |
| golang.org/x/image | 0.31.0 | latest | GO-2026-4815 |
| x/crypto, x/sys, x/text, x/sync, x/time | — | latest | hygiene |
| golang.design/x/clipboard | 0.7.0 | 0.7.1 | drop-in (0.11 changes the API; not needed for a retiring UI) |
| dmarkham/enumer (tool) | 1.6.3 | 1.7.2 | 1.6.3 crashes `go generate` on Go 1.27 |
| gorilla/websocket | 1.5.3 | keep for now; swap to `coder/websocket` only if deadline handling stays awkward | Deadlines can be enforced with `SetReadDeadline` + ctx; a swap is churn without user value |
| Ebiten | 2.9.9 | keep | retiring |
| zerolog, cobra | — | keep | — |
| OpenH264 | 2.1.1 | keep in the test client; gone in the native app | §3.6 S1 |

**Go patterns to adopt**
- `testing/synctest` for timers.
- `context.AfterFunc`.
- Built-in `min`/`max`.
- `http.Transport.ResponseHeaderTimeout`.
- Fuzz tests.

---

## 9. Refactor and DRY catalogue

**Do**
1. One generated schema for Go and Swift (Phase 4); delete `session/types.go` duplication then.
2. A generic typed `Invoke[P,R]` with a `Void` result (Phase 4, generated).
3. One video assembler shared by the OpenH264 test client and the engine helper.
4. Emulator and client share protocol packages (`pkg/protocol/*`), never client types.
5. Fork CI lives in its own workflow file; upstream workflow files stay untouched and disabled.

**Don't**
- Refactor the Ebiten UI.
- Build a settings DSL (SwiftUI `Form` declarations are the product).
- Rewrite the RPC wrappers by hand before schema generation.

---

## 10. Remote access over VPN (Tailscale and any self-hosted VPN)

**Principle.** The engine connects to an address (IP, DNS, `.local`, MagicDNS) with **no VPN-vendor dependency**. A VPN works if and only if:
1. the Mac reaches the device's HTTP(S) port, and
2. UDP works both ways to the device's host candidate (N2).

**Acceptance:** if the web UI works in Safari over that VPN, the app works.

| Topology | Status |
|---|---|
| Tailscale **installed manually on the JetKVM** (the firmware only reads its status, N5) | Reference setup; PM to-do #2 |
| Tailscale subnet router, WireGuard, OpenVPN, ZeroTier, UniFi Teleport… routed to the LAN | Must work; connect by LAN IP |
| UDP-hostile networks | Device has no ICE-TCP and ignores client `iceServers`. A client-side TURN relay over TCP/TLS 443 may still work, because the device replies to the peer-reflexive relay address [I, test in Phase 2]. Optional advanced setting. |

**Client work**
- Ordered addresses per device, probed over HTTP (`/device/status`), **never parallel WebRTC** (F3).
- E2/E3, E6/E7.
- Fast ICE disconnect detection plus a 2 s app heartbeat.
- `NWPathMonitor` reconnects; honour `willReboot.redirectTo`.
- Health UI.

**MTU.** RTP payloads are ~1200 B, below Tailscale 1280 and WireGuard 1420 [I].

**Discovery.** It can't cross VPNs, so saved addresses are primary. An optional Tailscale import of `jetkvm*` hosts is a nicety.

---

## 11. Display scaling and "match the window"

**Shipping (N5):** Fit (pixel-snapped, Retina-correct), 1:1 with pan, integer-nearest, sharp-bilinear, fit-window-to-remote, aspect lock.

**Jump-style "remote follows window" is not achievable** over HDMI capture.

| Option | Behaviour | Verdict |
|---|---|---|
| EDID presets (16:9 / 16:10 incl. **1920×1200** / 4:3 at ≤1920 wide). `setEDID` writes flash on every call; the blackout comes from the host re-reading the EDID. | 2–6 s blackout; OSes remember modes per monitor ID | Phase 4, explicit button with auto-revert |
| Host agent switches among EDID modes over USB CDC-ACM | ~1 s, needs an agent on every target | Only if needed later |
| Client-side modes | Instant | Ship |

---

## 12. Testing strategy

- **Unit:** `testing/synctest` for backoff, keepalive and reconnect; fuzzing of HID-RPC/JSON-RPC/SDP; fit/snap/pointer-mapping math.
- **Emulator integration** (0.5.9-faithful, §6 Phase 1a), with loss/latency injection. Assertions:
  - no freeze >100 ms on a single loss
  - no stuck buttons under loss
  - connect fails within its deadline on a black hole
  - void RPCs return immediately
  - takeover handled
- **Replay:** ffmpeg-generated High-profile H.264 and H.265 clips; RTP fixture from `.107`.
- **Native e2e:** the spike app connects to the emulator, decodes and presents, and reports frame/decoder stats in a self-test mode; a screenshot check.
- **Live:** read-only probes only until the sink-window harness exists. `.107` is attached to this Mac, so HID input would type into it.
- **CI hygiene:** `-race`, `-p 1` for emulator packages, actionlint, govulncheck, `go generate` drift.

---

## 13. Risk register

| Risk | Impact | Likelihood | Mitigation |
|---|---|---|---|
| Native rebuild stalls before parity | High | Med | Spike gate; Jump covers daily use; port feature by feature; settings last |
| Helper IPC bugs or overhead | Med | Low | Simple length-prefixed framing; e2e self-test against the emulator |
| Firmware protocol drift (monthly releases) | Med | High | Generated schema + drift CI; capability gating with a 0.5.9 fallback; emulator parity |
| Event tap permission flaky or Secure Input | Med | Med | Certificate signing, onboarding, escape chord, Secure Input indicator, re-enable on timeout |
| Bad EDID leaves no picture | High | Low | Presets only, auto-revert |
| Takeover kills a working session | Med | Med | HTTP-only probing (F3); clear "taken over" UI; per-device single-instance lock |
| Testing input on `.107` types into this Mac | High | Med | No HID input to `.107` without the guarded sink-window harness |
| VPN without UDP | Med | Low | Optional client-side TURN |

---

## 14. Upstream and fork strategy

**Fork position.** The fork is **private**: no PRs to lkarlslund or Regi for now. Upstream (`lkarlslund`) is dormant and declines the Mac-native direction, so the fork diverges deliberately. Track **`jetkvm/kvm` `dev` and `release/*`** instead.

**Harvest** (MIT, same lineage)
- `zhangxiubo` fork: loss recovery, stall watchdog.
- Upstream PR #5: event tap, recent connections, WoL, layout paste.
- `rootline-digital`: single-client lock, virtual-media recovery.

**Learn only, no code: Regi** (Swift, AGPL-3.0). Agents that read Regi write behaviour notes only; implementing agents never read its source.

---

## 15. Open questions and unverified items

| # | Item | Resolve in |
|---|---|---|
| 1 | Live video path (timing, real High-profile stream, colour metadata); `.107` has no HDMI signal yet | Phase R |
| 2 | Windowed/fullscreen latency at 60/120 Hz; Safari and Regi baselines | Phase R / 2 |
| 3 | M2 (concealed frames discarded) | Phase 1b emulator loss test |
| 4 | H.265 visual gain at equal bitrate on this device | Phase R |
| 5 | TURN-over-TCP with a host-only device | Phase 2 |
| 6 | VPN interfaces don't trigger the Local Network prompt | Phase 2 |
| 7 | `go/packages` schema walk on darwin | Before Phase 4 |
| 8 | ISO §/` swap on Mac keyboards; JetRemote claims | Phase 3 / R |

---

## 16. Review disposition (v2)

The independent review (`plans/2026-10-10-engineering-plan-review.md`, merged into this plan and then deleted) was checked item by item against the code.

**Accepted**
- Estimates (2–4× higher).
- All B-corrections: B4 and B6 worse than stated, B8 nuance, B12 cause, B13 withdrawn.
- M1–M7, plus M8 (found while verifying E13).
- F1–F15.
- The relative latency requirement.
- 2 concurrent devices.
- H.265 promoted to Should.
- Cloud dropped.
- Pointer lock → Could.
- Tailscale manual install (N5); the EDID blackout cause corrected.
- E2 H.264-only and merged with E3; E4 rebuild dropped; E5 after verifying M2.
- E6 with a separate stream context (verified: `OnTrack` uses Connect's ctx, `client.go:206`).
- E7 429 semantics; E8 revised routing; E10 after E6; E11 on-demand slow RPCs.
- E13 serial part dropped (verified: any channel close tears the session down, `client.go:645-659`).
- E15 wait for running→stopped.
- E18 split.
- E19/E20/H4 dropped.
- HTTP-probe address racing.
- Helper process instead of c-archive; arm64 only.
- The reframed Phase 2 criteria; the Phase R benchmark.
- Regi learn-only; Developer ID signing; data-protection keychain caveat.

**Modified**
1. *"Actor restructure of the whole controller first"* → only the **lifecycle** is restructured first (§5.3.1). RPC wrappers wait for schema generation, to avoid writing them twice.
2. *"Emulator: 1080p60 High profile, GOP 30"* → OpenH264's encoder can't produce High profile or H.265. Resolution/fps/GOP become configurable; High/H.265 conformance comes from **ffmpeg-generated Annex-B replay** and the `.107` RTP fixture.
3. *"Phase R first"* → R needs the HDMI rig (PM to-do), so it runs **in parallel** and gates Phase 2 criteria, not Phase 1.
4. *"Helper process"* → concretely **one helper per device**, over stdio pipes rather than a socketpair: simplest correct IPC, and crash isolation per device.
5. *Spike display path:* Metal with the texture cache and present-on-arrival, as the review suggests. `CAMetalDisplayLink` pacing is evaluated in Phase R measurements rather than assumed.

**Not adopted**
- *"Swap gorilla → coder/websocket"* (v1 suggestion; the review was silent). Deadlines can be enforced with the existing library; the swap is churn.

---

## 17. Decision log

| Date | Decision |
|---|---|
| 2026-10-10 | Private fork `wottpal/jetkvm-desktop`; `upstream` fetch-only; upstream workflows disabled |
| 2026-10-10 | Goal: fully replace Jump Desktop for the PM plus a few people; no deadline; macOS client only |
| 2026-10-10 | Bundle ID `xyz.scio.jetkvm-mac`; paid Apple Developer account; Developer ID signing |
| 2026-10-10 | No JetKVM Cloud; self-hosted VPN only; Tailscale is the reference |
| 2026-10-10 | Retire the Ebiten app once native ships; no interim polish |
| 2026-10-10 | System shortcuts go to the remote while focused, with an escape chord |
| 2026-10-10 | Background sessions stay live, no decode |
| 2026-10-10 | Full settings parity, last |
| 2026-10-10 | Latency Must = "≥ Safari web UI", on 120 Hz and 60 Hz displays |
| 2026-10-10 | German layouts on both sides; mixed layouts per device |
| 2026-10-10 | Regi: learn-only, no AGPL code |
| 2026-10-10 | Test rig `.107` on this Mac, behind a guarded sink window |
| 2026-10-10 | Go engine as a helper process, one per device (v2) |
| 2026-10-10 | Roadmap R ∥ 0 → 1a → 1b → 2 → 3 → 4 (v2) |

## 18. PM to-dos

1. Connect `.107`'s HDMI to this Mac (Phase R). The Jump Desktop display may change.
2. Install Tailscale manually on one JetKVM.
3. Optional: buy JetRemote for the benchmark.
4. Provide Developer ID team details for `xyz.scio.jetkvm-mac`.

## Appendix A: Key sources

- `jetkvm/kvm` (`dev` @ `8f6c300`, `release/0.5.9`): https://github.com/jetkvm/kvm. REMB revert: https://github.com/jetkvm/kvm/pull/1693
- `jetkvm/cloud-api` @ `00eb00de`: https://github.com/jetkvm/cloud-api (context only; Cloud dropped)
- Upstream client: https://github.com/lkarlslund/jetkvm-desktop
- Regi: https://github.com/mcuelenaere/regi
- JetRemote: https://apps.apple.com/us/app/jetremote/id6778190897
- Moonlight Metal/VideoToolbox renderer: https://github.com/moonlight-stream/moonlight-qt/blob/master/app/streaming/video/ffmpeg-renderers/vt_metal.mm
- Ebiten 2.10 notes: https://ebitengine.org/en/documents/2.10.html
- Apple TN3179 (Local Network privacy): https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Apple TN3137 (Mac keychains): https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- CVE-2025-27091: https://nvd.nist.gov/vuln/detail/CVE-2025-27091
- OpenH264 binary license: https://www.openh264.org/BINARY_LICENSE.txt
