# jetkvm-desktop: Engineering Plan (v2, revised after independent review)

| | |
|---|---|
| Date | 2026-10-10 (v1), revised 2026-10-10 (v2) |
| Status | Approved direction. Implemented on branch `native-foundation`: Phases 0, 1a, 1b and 2 done, Phase 3 MVP done except settings UI (see §19). |
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
| **S5** | Discovery trusts any `/device/status` responder. Fix: pin the `deviceId`. Only `/device/status` is public (F4); `/device`, which carries `deviceId`, needs a login on password-protected firmware. So verify before login where the device allows it (no password, or a still-valid cookie), otherwise over RPC (`getDeviceID`) right after login and before any input. *(Corrected in implementation review: v2 assumed `/device` was public.)* | [V] |
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
| **F4** | `/device/status` (`{"isSetup"}` only) and `/metrics` need no login; `/device` (with `deviceId`), logout and password routes are protected (`web.go:198-204`); there is an HTTP `/storage/upload` route | Reachability probes need no password; identity needs a login on password-protected devices; virtual media upload over HTTP |
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
| H3 | Fork CI `fork-check.yml`: `workflow_dispatch` + PR only (no push trigger; macOS minutes bill 10× on private repos). One `macos-15` job: vet, generate drift, `go test -race -p 1`, timing-sensitive tests without `-race`, vendored OpenH264 tests, govulncheck, Swift tests. *(Implemented without staticcheck, which cannot read go1.27 export data yet; actionlint is run locally.)* |
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
   - explicit MediaEngine: **H.264 only** for the OpenH264 client, H.265 opt-in for the native shell, with `nack`, `nack pli`, `ccm fir`, fmtp; NACK interval ~20 ms (E2) *(built: 40 ms, at most 6 per packet; see §20)*
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

- Device library: ordered address list (LAN, `jetkvm-<id>.local`, VPN), HTTP-probe racing (F3/F4), `deviceId` pinning per S5 (before login where possible, else right after login and before any input), Keychain.
- One window per device, native tabbing, 2 concurrent sessions; background windows stay live but don't decode.
- Display modes: Fit, 1:1 (pan), integer-nearest, sharp-bilinear, fit-window-to-remote, aspect lock, dark letterbox, fullscreen without the menu bar.
- Input: per-device Cmd↔Ctrl / Option↔Alt profiles (macOS targets pass ⌘ through; Linux maps it); Caps Lock as a toggle with LED sync; precise scroll accumulation.
- ⌘V paste with progress and cancel; layout per device.
- ATX/DC power, virtual media (URL + `/storage/upload` with progress), serial console.
- Connection health in the toolbar; reconnect on `NWPathMonitor` changes; TLS trust-on-first-use pinning per `deviceId` *(built: the device CA is pinned, not the leaf; see §20)*.
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

| # | Item | Resolve in | Status (2026-10-10) |
|---|---|---|---|
| 1 | Live video path (timing, real High-profile stream, colour metadata); `.107` has no HDMI signal yet | Phase R | Partly: `.107` got HDMI; H.264 and H.265 decode live at ~60 fps, 0 errors. Timing still open. |
| 2 | Windowed/fullscreen latency at 60/120 Hz; Safari and Regi baselines | Phase R / 2 | Open (Phase R) |
| 3 | M2 (concealed frames discarded) | Phase 1b emulator loss test | Resolved: the assembler replaced samplebuilder; loss is repaired by NACK in the emulator test |
| 4 | H.265 visual gain at equal bitrate on this device | Phase R | Open; new devices default to H.264 meanwhile |
| 5 | TURN-over-TCP with a host-only device | Phase 2 | Open (not built) |
| 6 | VPN interfaces don't trigger the Local Network prompt | Phase 2 | Open (needs a VPN test on a signed build) |
| 7 | `go/packages` schema walk on darwin | Before Phase 4 | Open |
| 8 | ISO §/` swap on Mac keyboards; JetRemote claims | Phase 3 / R | §/` swap built and unit-tested; not tried on an ISO keyboard |

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
| 2026-10-10 | Implementation on branch `native-foundation`, not `main`, until the PM has tried the native app (§19) |
| 2026-10-10 | Identity pinning per corrected S5/F4: pre-login only where the firmware allows, otherwise RPC after login, before input |
| 2026-10-10 | New devices default to H.264; H.265 is a per-device opt-in until Phase R shows its benefit |
| 2026-10-10 | NACK every 40 ms, at most 6 per packet; assembler gap deadline from the selected pair's RTT (assumed 100 ms until known) |
| 2026-10-10 | Escape chord ⌃⌘ releases keyboard capture |
| 2026-10-10 | Developer ID signing (Scio Labs), hardened runtime; every signed build is copied to ~/Downloads |
| 2026-10-10 | Notarize through the Xcode account (`xcodebuild` export with upload), not an app-specific password |
| 2026-10-10 | HTTPS: pin the device CA the chain is signed up to, on first use; publicly trusted devices pin to public trust |
| 2026-10-10 | Serial console is line-based (Return sends the line + device terminator), not a full terminal emulator |

## 18. PM to-dos

1. Connect `.107`'s HDMI to this Mac (Phase R). The Jump Desktop display may change.
2. Install Tailscale manually on one JetKVM.
3. Optional: buy JetRemote for the benchmark.
4. Provide Developer ID team details for `xyz.scio.jetkvm-mac`.

## 19. Implementation status (2026-10-10)

Branch `native-foundation`, on top of `289df51`. The live device was used **read-only** throughout (`--view-only`; no HID input, settings or reboots).

| Phase | Status | Commit(s) |
|---|---|---|
| 0 Housekeeping | Done: go1.27.2, dependency refresh (govulncheck 0), fork CI, file logging + crash output | `07afb11` |
| 1a Emulator parity | Done, plus the review round below | `2e81584`, review commit |
| 1b Engine | Done (lifecycle, RPC, video assembler, input, paste, tests) | `2e81584`, review commit |
| 2 Native spike | Done except the pass criteria that need Phase R measurements | `a777c58`, `36b848c` |
| 3 Native MVP | Done: device library, Keychain, tabs, background sessions without decode, fit-window-to-remote, power menu, paste progress/cancel, path-change reconnect, virtual media, serial console, extension port, TLS pinning | `b8b06f5`, Phase 3 commit |
| R, 4 | Not started (R needs the HDMI rig) | |

**Verified**
- Go suite passes with and without `-race`; Swift unit tests pass.
- `make -C macos selftest`: the app connects to the emulator, decodes and presents video, sends injected input that the emulator receives in order, and recovers after the helper is killed mid-run.
- Emulator loopback: encode→decode p50 ≈ 9.6 ms; VideoToolbox decode ≈ 0.6 ms; SMPTE bars match the BT.709 reference.
- Live `.107`, read-only: H.264 and H.265 at ~60 fps with 0 decode errors, 1:1 Retina rendering; identity pinning accepts the right `deviceId` and refuses a wrong one before login. (`.107` has no password, so the after-login path is verified on the emulator only.)
- govulncheck: no reachable vulnerabilities (one in a required module, not called).

**Code review rounds** (three independent reviewers: Go engine, Swift app, emulator/tooling; all findings re-checked before acting)
- Accepted and fixed, among others:
  - helper stdout handler spinning a core at EOF;
  - identity check assumed a public `/device` (S5/F4 corrected; emulator now protects `/device`, logout and password routes);
  - keepalive timing not reset between key holds (emulator);
  - lenient RPC parameters (emulator now requires upstream's parameter names; a test calls every client setter);
  - video starting before DTLS was up;
  - 7th-key rollover, blocking HID queues, inline macro cancel, firmware JSON shapes, realistic reboot (1 s, then offline);
  - flaky tests (loopback-only ICE, ordered access-unit capture);
  - CI: NACK loss test without `-race`, guarded `make layouts`, `make check` = CI.
- The realistic reboot exposed a client bug, now fixed: `Reboot()` reported "client closed" although the reboot succeeded.
- A second review of the identity and emulator changes found, and these are fixed with tests that fail without the fix:
  - a device ID learned on first connect is now pinned for that session's reconnects and helper restarts (trust on first use);
  - a 401 from a host that is not a JetKVM (no valid `/device/status`) no longer gets the password;
  - the address probe prefers an address confirming the saved ID over one with unknown identity;
  - smaller items: a stale reconnect wake token, library edits dropping a learned ID, shared Keychain items deleted with a duplicate entry, app log opened with `O_APPEND` and rotated at runtime.
- Not adopted: login limiter windowing and an end-to-end 429 test (low value now); recording only inputs the firmware acts on (the log is a test aid).

**Phase 3 completion** (virtual media, serial console, TLS pinning)
- Virtual media window: what is mounted (eject), mount by URL as CD/DVD or USB disk, the device's storage (mount, delete), uploads with progress, cancel and resume. As on the firmware, an interrupted upload stays as `.incomplete` and continues when the same file is uploaded again.
- Serial console window: output with ANSI sequences filtered, a line input sent with the device's terminator, ⌃C/⌃D, baud rate. Output keeps arriving while the window is closed. Device → Extension Port switches ATX / DC / serial.
- HTTPS devices: the firmware's self-signed mode signs a certificate per hostname with a device CA that it sends in the chain, so the app pins that CA on first use (same pin for LAN, .local and VPN names). A different CA stops the connection before any password is sent; the user can trust a new certificate explicitly. Publicly trusted certificates need no pin.
- Emulator: HTTPS with a device CA, streaming uploads with supersede/resume and an upload throttle, the firmware's URL check before HTTP mounts, the serial channel with an echoing target.
- Verified: Go tests (engine-level upload cancel/resume, serial round trip, TLS pin and mismatch), and `make -C macos selftest-extras`, which drives the app's own models and windows against the emulator over http and https (upload, mount, eject, delete, serial echo, probe with and without the pin).
- Independent review of this work, all findings accepted and fixed with tests that fail without the fix:
  - **Critical:** the first pinning design compared the chain's last certificate without checking that the leaf was signed by it. Since the device CA is public, an interceptor presenting its own leaf plus the real CA got the password (reproduced end to end). Each certificate must now be signed by the next; a regression test runs that interceptor.
  - **High:** publicly trusted devices recorded no pin, so a later self-signed interceptor counted as a new first use. They are now pinned to public trust (`webpki`).
  - **Medium:** a public certificate reached by IP pinned a shared intermediate (the leaf is pinned now); an unterminated escape sequence silenced the serial view (sequences are bounded and abort on control characters); closing a window left awaited calls hanging; a bigger partial upload under the same name made a new upload "succeed" without storing it (replaced, and every upload is checked on the device afterwards); the upload-cancel test was timing-dependent.
  - The emulator's serial output now matches the firmware's console broker (`RX: ` line prefixes, `<BS>`-style control names, `[serial attached]` on open); the app shows it as the web UI does.

**Open (next)**
- Phase R benchmark and the Phase 2 pass criteria that depend on it.
- Settings parity (Phase 4).
- Event-tap reliability needs an Accessibility grant on a signed build.
- Relative mouse / pointer lock; audio.

## 20. Execution report (2026-10-10)

The plan was executed in one long working session by AI agents, with the PM away most of the time. This section records what was built against the plan, where it diverged and why, and what the execution taught. §19 has the per-phase status and verification details.

### What was built

| Plan item | Outcome |
|---|---|
| Phase 0: fork CI, dependency refresh, logging | Done (`07afb11`) |
| Phase 1a: firmware-faithful emulator | Done, and taken further after review (strict RPC parameters, realistic reboot, HTTPS, uploads, serial) |
| Phase 1b: engine restructure and fixes | Done (`2e81584`, review fixes in `ec054ce`) |
| Phase 2: native spike | Done except the pass criteria that need Phase R measurements |
| Phase 3: native MVP | Done except the settings UI (Phase 4 anyway) |
| Phase R: benchmark | Not started: needs the HDMI rig and a sink window for safe input tests |
| Phase 4: settings parity | Not started |
| Developer ID signing and notarization | Done (Scio Labs team); `make -C macos notarize` uses the Apple ID signed into Xcode, no app-specific password |

### Where execution diverged from the plan

| Plan said | What was done | Why |
|---|---|---|
| `/device` needs no login, so check the device ID before sending a password (S5/F4) | Check before login only where the device allows it; otherwise over RPC right after login, before any input. A 401 counts as a JetKVM only if `/device/status` answers like one. | Wrong premise: firmware 0.5.9 protects `/device`. A reviewer caught it by reading upstream. |
| TLS pinning per `deviceId` (leaf certificate) | Pin the device CA that the chain is signed up to (the leaf if the chain ends without a self-signed root); publicly trusted devices are pinned to public trust | Firmware issues a different leaf per hostname, so a leaf pin would break across LAN, `.local` and VPN names |
| NACK interval ~20 ms | 40 ms, at most 6 requests per packet | Matches the assembler's wait; fewer duplicate requests on lossy links |
| CI with staticcheck and actionlint | Neither in CI; actionlint run locally | staticcheck cannot read go1.27 export data yet |
| H.265 is a Should | Built and tested, but new devices default to H.264 | Its benefit on this device is unmeasured (Phase R) |
| Phase order R ∥ 0 → 1a → 1b → 2 → 3 | 0 → 1a → 1b → 2 → 3, R still pending | R is blocked on hardware; the emulator made progress possible without it |
| Typed RPC wrappers after schema generation | The app uses the engine's generic `rpc` command for media and power | Avoids writing wrappers twice; the emulator checks parameter names against the firmware |
| Serial console (unspecified) | Line-based console with ANSI filtering, not a terminal emulator | Enough for boot logs and shells; a full terminal is a bigger, separate job |
| Ad-hoc signing until team details arrive | Developer ID signing, hardened runtime; every signed build is copied to `~/Downloads` | The PM created the certificates during the session |
| Self-test as a spike feature | Kept and extended into the main end-to-end check (`selftest`, `selftest-extras`) | It exercises the real app, engine and emulator together and caught real bugs |

### Takeaways

1. **Read the firmware, don't infer it.** The one wrong premise in the plan (`/device` being public) survived two plan reviews and was only caught by a reviewer reading `web.go`. Statements about device behaviour should cite upstream code.
2. **A faithful emulator pays for itself.** Making the emulator stricter exposed real client bugs: void RPC responses, wrong method and parameter names, keepalive timing between key holds, and `Reboot()` reporting "client closed" for a reboot that succeeded.
3. **Tests need negative controls.** Several tests could not fail (stats after close, keyframe assertions, a timing window too short to observe). Breaking the code on purpose and watching the test fail became routine, and was worth it.
4. **Pinning is not authentication by itself.** The first TLS pin checked that the device CA appeared in the chain, not that the leaf was signed by it; the CA is public, so a proxy could pass. A reviewer proved it by capturing the password. Security code gets an attack test, not only a happy-path test.
5. **Independent reviews found something every time.** Each review round (plan, three code reviewers, two follow-up passes) turned up at least one High issue. Reviewing the reviewers' fixes found more.
6. **The development Mac itself causes flakiness.** Multiple network interfaces made ICE slow and flaky in tests; loopback-only ICE fixed it. Screen captures of app windows need Screen Recording permission for the shell.
7. **Hardware stays the bottleneck.** Agents wrote and verified the code within a day; what remains unverified needs the device: latency against Safari, input on a real target, a password-protected device, TLS on the real firmware, VPN behaviour.

### Next steps

1. PM: connect the sink-window harness and run Phase R (latency, H.264 vs H.265, CPU).
2. Share builds with `make -C macos notarize` (notarized, stapled zip in `~/Downloads`).
3. Try the app daily against `.107` with input, once input can safely go to a separate machine.
4. Phase 4: generated schema, then the settings sections.

## 21. Picture quality, input and the encoder patch (2026-10-10, evening)

The PM's first real use found that the picture looked blurry and pixelated, the mouse did nothing, and the screen showed an empty desktop instead of the Mac mini's own. This section records what caused each problem, measured on the live `.107` → Mac mini path against ground truth, and what changed.

### Method
- **Ground truth:** a known 1920×1080 test image (`tools/quality-bench/make_pattern.swift`) shown full screen at 1:1 in Chrome on the Mac mini's JetKVM display.
- **Scoring:** frames recorded through `jetkvm-engine` are decoded and compared with the image.
  - Luma PSNR/SSIM is measured against the image's ideal luma, which isolates encoder loss from 4:2:0 chroma.
  - Text regions are scored separately.
  - Scrolling is scored per frame after finding its offset.
- **Configurations:** each one ran static and at 120/480/1080 px/s (`sweep.py`).
- **Tools:** everything is in `tools/quality-bench`.

### Findings (each verified on the device)

| # | Finding | Evidence | Fix |
|---|---|---|---|
| Q1 | **Encoder QP floor and texture AQ blur text at any bitrate.** 0.5.9 never sets Rockchip RC parameters. The frame QP floor is about 26–28, and AQ adds up to +8 on textured blocks, so text sits at QP 32–36. | Macroblock QP dump; quality factor 1 → 4 changes neither keyframe size (~47 KB) nor QP | Firmware patch: QP floor tunable live (ladder 10–26), AQ off |
| Q2 | **Wrong color matrix.** The TC358749 bridge outputs BT.601 limited-range YCbCr (the tc358743 driver hard-codes it), but the firmware tags HD streams BT.709. | Color patches fit BT.601 within 0.5 code values and BT.709 within 8 | The app decodes BT.601 always (`JETKVM_COLOR_MATRIX=709` overrides). Firmware VUI fix is still open. |
| Q3 | **The app rendered at half size with bilinear filtering.** One remote pixel went to one physical pixel, and enlarging used plain bilinear. | App window captures | "Actual Size" = one remote pixel per point (window auto-sizes; pans when smaller). FSR 1 EASU+RCAS for enlarging, nearest optional, widened Catmull-Rom for shrinking. Correct chroma siting, sRGB-tagged layer, rendering on its own queue. |
| Q4 | **The absolute mouse is invisible on an extended display.** macOS maps the absolute HID pointer onto its main display. The Mac mini's main display was the Dell U4021QW; the JetKVM was extended. | Absolute moves left the captured screen unchanged; relative moves showed the cursor | JetKVM made the Mac mini's main display (PM approved). One pointer mode only, by PM decision after trying two relative variants: the remote pointer goes exactly where the local one hovers (absolute HID), and the local pointer is hidden over the picture. |
| Q5 | **Keyframes twice a second, and requests ignored.** GOP = fps/2 resends a ~47–90 KB keyframe every 0.5 s. PLI/FIR are ignored, and in this rockit build `RequestIDR(instant)` returns NOT_SUPPORT. | Stream capture; device log | Patch: 4 s GOP, plus a keyframe on session connect, PLI/FIR and a `requestKeyframe` RPC. The path is verified by watching for the IDR; this device uses non-instant `RequestIDR`. |
| Q6 | **"Not reachable" alert although the device answered.** The probe failed transiently (first-launch Local Network permission is the likely cause). | User report; `curl` to the device succeeded | The window opens anyway and keeps connecting. Probe errors go to `app.log`, and ATS allows plain http to user-entered hosts. |
| Q7 | **The display profile shifts colors.** Chrome converts sRGB into the EDID-derived "JetKVM v1" profile. | No measurable effect after switching to sRGB (the shift was Q2) | The JetKVM display is set to sRGB on the Mac mini anyway |

### Measurements (patched firmware unless noted; H.265 unless noted)

| Configuration | Text PSNR (static) | Idle stream | Keyframe | Scrolling 1080 px/s |
|---|---|---|---|---|
| Stock 0.5.9, H.264, factor 3 | 32.6 dB | 1.4 Mbit/s | 88 KB every 0.5 s | — |
| QP floor 24, factor 3, 60 fps | 41.3 dB | 0.34 Mbit/s | 123 KB every 4 s | 42.4 dB at 3.7 Mbit/s |
| QP floor 18 | 46.4 dB | 0.46 | 167 KB | 46.0 dB at 5.8 Mbit/s |
| QP floor 14 | 49.8 dB | 0.56 | 198 KB | 47.5 dB at 6.9 Mbit/s |
| QP floor 10 | 53.2 dB | 0.66 | 231 KB | 48.4 dB at 8.1 Mbit/s |

- **Codec:** with QP floor 18 while scrolling, H.265 reaches 44.8/45.7/46.0 dB at 4.0/5.1/5.4 Mbit/s; H.264 reaches 39.7/42.9/44.7 dB at 4.7/6.5/8.0 Mbit/s. So H.265 needs about half the bitrate, and the app now always offers it (H.264 stays in the offer as a fallback).
- **Frame rate** (QP floor 16, 1080 px/s):

  | Factor | 60 fps | 30 fps |
  |---|---|---|
  | 0.5 | 42.8 dB at 2.9 Mbit/s | 46.7 dB at 2.3 Mbit/s |
  | 1 | 45.3 dB at 4.2 Mbit/s | 46.8 dB at 2.4 Mbit/s |
  | 2 | 46.5 dB at 6.0 Mbit/s | 47.2 dB at 2.3 Mbit/s |

  With enough bandwidth 60 fps is nearly free; when bandwidth is tight, lowering the frame rate helps before raising the QP floor.
- **Rendering cost:** FSR at 1080p → 4K costs about 0.5 ms of GPU time; decode takes 1–2 ms.

### Automatic quality (`pkg/session/autoquality.go`)

**Ladder:**

| Level | Factor | fps | QP floor |
|---|---|---|---|
| minimal | 0.25 | 15 | 26 |
| low | 0.5 | 30 | 21 |
| balanced | 1 | 60 | 18 |
| high | 2 | 60 | 14 |
| maximum | 3 | 60 | 10 |

**Starting level:** maximum below 8 ms RTT, high below 40 ms, balanced otherwise.

**Stepping down** happens at once when one of these lasts two samples:
- loss above 2%;
- RTT over twice the baseline plus 40 ms;
- a new unrepaired loss (the assembler starts waiting for a keyframe).

Severe loss (above 10%) drops two levels in a single sample.

**Stepping up** happens one level after 20 clean seconds.

**Applying a level:** on patched firmware it goes through `setVideoEncoderParams` (bitrate, QP, fps, live). Stock firmware only has the quality factor, which restarts the encoder.

**Manual control:** picking a level in the menu turns automatic off and is saved per device.

### Encoder patch (`firmware/`)

It applies to `jetkvm/kvm` `release/0.5.9` and is built with the upstream Docker toolchain on this Mac.

Tested on `.107` non-persistently (`jetkvm_app_debug`; a reboot restores the stock app):
- RC tuning;
- 4 s GOP;
- keyframe requests;
- the runtime RPCs `getVideoEncoderParams`, `setVideoEncoderParams` and `requestKeyframe`.

None of these changes touch EDID or HDMI hot-plug. Restarting the app itself re-plugs HDMI once.

**Not yet done:**
- persistent install (needs the PM's OK);
- upstreaming;
- fixing the VUI matrix (Q2) in firmware.

### Independent review (one round, all findings re-checked)

**Accepted and fixed:**

| Severity | Finding | Fix |
|---|---|---|
| High | `--view-only` changed device settings: automatic quality ran in view-only sessions | View-only now never sends a quality change |
| High | No panning in relative mode | The local pointer stays free in relative mode and pans in both modes |
| High | The ATS exception was ignored, because `NSAllowsLocalNetworking` disables `NSAllowsArbitraryLoads` | Key removed |
| High | An unreachable first address was retried forever | The window now re-probes all addresses and switches to the first one that answers |
| Medium | On stock firmware the governor caused avoidable encoder restarts: oscillation between rungs, a factor compared before it was loaded, fallback on any error | Step-up delay doubles when it flaps; the current factor is read from the device; live support is detected once per client from method-not-found |
| Medium | Turning Automatic off left an inconsistent level | Both sides now keep the current level |
| Medium | The governor counted a repeated stats sample as a clean second | Samples now carry `SampledAt` and repeats are skipped |
| Medium | Firmware encoder parameters outlived the session | They reset to defaults when the last session ends and on quality-factor changes. Untested on the device |
| Medium | The Makefile H.265 self-test pass leaked its emulator | Fixed |
| Low | Stale docs and dead code | Fixed |
| Low | Whole-multiple mode was not always nearest-neighbor | It now always is |
| Low | Library edits did not reach open windows | They now do |
| Low | No controller-level tests for quality changes | Added; each new test fails without its fix |

**Not adopted, with reasons:**
- Persisting a `--scale` CLI override is a developer flag.
- A race between a manual level and an in-flight governor step only means the last writer wins; it causes no harm.

**PM feedback in the same round:**
- Relative mode was dropped after two tries (pointer lock, then a free pointer). There is now a single absolute mode: hovering puts the remote pointer exactly there, also while the app is in the background; the local pointer is invisible over the picture; a first click into an inactive window reaches the remote.
- The lagging remote cursor stays visible (the PM's choice). It is drawn into the HDMI picture by the target.
- While debugging, the test harness and the app kept taking over each other's session (the firmware allows one), which looked like dead input. Tools that drive the device must not run while the app is connected.

**Firmware tagging:** streams now use the BT.601 matrix with BT.709 primaries and transfer (the content is an sRGB desktop).

### Decisions
- H.265 only in the UI. H.264 remains in the offer and behind `--h264`, which the self-tests need because the emulator's live pattern is H.264.
- "Actual Size" is the default view. FSR is the default upscaler; nearest is opt-in ("Exact Pixels").
- BT.601 decode for JetKVM streams.
- Automatic quality on by default.
- The JetKVM display is the Mac mini's main display, with color profile sRGB.

## 22. Remote display follows the window (2026-10-11)

**Ask (PM):** UI and pointer sizes should match the PM's own screen (same millimetres as a local window), and the remote picture should fill the window corner to corner at any window size.

**Mechanism:** a new view mode, Match Window (opt-in after the finding below). The remote stays at one remote pixel per point (as in Actual Size), and the remote display changes resolution to fit the window. The only agent-less way to change a host's resolution is the EDID, which the JetKVM lets clients set over JSON-RPC (`getEDID`/`setEDID`, stock 0.5.9). After a resize settles (0.4 s), the app reads the device's EDID. It keeps the identity bytes (vendor, product, serial, name, audio and HDMI blocks), so the target keeps its display arrangement. It replaces every mode with one detailed timing of the window's size, writes the EDID back, and the target re-detects the display within 2–5 s. Code: `RemoteDisplay.swift` (sizes, timings, EDID), `DisplayFollower.swift` (debounce, coalescing, skipping when the size already matches), `DeviceWindowController` (triggers; snaps the window when the remote is up to one size step smaller).

**Measured on the device (Mac mini target, 0.5.9):**

| Finding | Evidence | Consequence |
|---|---|---|
| With CVT reduced blanking (~100 MHz), every size broke into horizontal stripes | 1504×944, 1536×944, 1472×944 and 1600×936 were all corrupt. The TC358749 driver starts CSI output at a fixed FIFO level (300 at 60 Hz) and its CSI clock is fixed (4 × 745 Mbit/s), so a slow HDMI input lets the output overtake it | Lines are padded with blanking so that width × (1 − 16·clock / 2980 Mbit/s) ≤ 250, which gives 128–162 MHz, close to 1080p60's 148.5 MHz |
| Lines longer than 3.75 widths never stream (the bridge sees the mode; the device reports no picture) | 640×400, 720×480, 800×500, 960×480 and 960×540 failed with 4000-pixel lines. They work with lines of ≤ 3.75 widths plus extra blank lines | Small modes pad vertically. 640×400 is the tested minimum |
| Widths that are not multiples of 16 come out sheared | The capture loop hands the encoder a stride of `RK_ALIGN_16(width)` (`video.c`), while capture lines are `width` long. 1400, 1470 and 1512 were sheared (one case was first seen by the PM); 1392, 1504, 1536, 1600 and 1920 are clean | Width step 16, height step 4 (540, 500, 876 and 956 are clean) |
| An odd height (1504×941) hung the device: no network until a power cycle, and the EDID was already saved | After reboot the host sent 1504×941 again; the device stayed up only while no session streamed | Heights are always multiples of 4. The default EDID was restored over SSH before any session connected. Stock firmware has the same bug for any source sending an odd height (not fixed in the patch, which was not retested) |
| 1920×1200 at 162 MHz works; above that the 165 MHz pixel clock limit at 60 Hz applies | 1920×1200 and 1920×1080 are clean at 60 fps | Maximum 1920×1200. Larger windows (wide screens in full screen) get the largest mode of their shape, scaled to fill |

The exact EDID bytes for 1504×944 and the timings of seven device-verified sizes are pinned in `RemoteDisplayTests`.

**Multi-display Macs (found after shipping it as the default):** the PM's Mac mini also drives a Dell. After a few resizes, the KVM picture showed an empty desktop and the pointer did nothing there. A probe (absolute pointer moves, diffed in the stream) confirmed that the JetKVM display was no longer main:

| Replug with | JetKVM main afterwards |
|---|---|
| The same EDID again | yes |
| A size never shown before | no (the Dell becomes main; the JetKVM gets an empty Space) |
| A size that had been made main earlier (exact same EDID) | yes |
| A new size with the identity bytes (8–24, including physical size) unchanged | no |

macOS keys the display arrangement to the whole display configuration, not to vendor, product and serial number, so no EDID trick keeps a new size main. Match Window is therefore opt-in, explained once when chosen, and meant for targets where the JetKVM is the only display. Actual Size is the default again. The PM's Mac mini was restored through the KVM: default EDID, relative pointer onto the KVM display, Terminal there, then `make_kvm_main_display.swift`.

**Behaviour:** on connect, the window takes the remote's current size if it fits on screen, so a reconnect does not re-plug the display. View-only sessions never change the EDID. The device saves the EDID; JetKVM web UI › Settings › Video › EDID (JetKVM Default) restores the default. Actual Size keeps the earlier behaviour: the remote resolution is never changed and the window follows the remote.

**Full screen:** presentation options are now `[.fullScreen, .hideDock, .autoHideMenuBar]` (were `.hideMenuBar`). The menu bar, with the window's title bar and buttons, slides in at the top edge, so full screen can be left with the mouse; the bottom edge stays with the remote.

**Firmware:** with the PM's approval, the encoder-patch build (`48af72f7…`) is now installed persistently on the PM's device via `jetkvm_app.update`. The stock app is backed up on the device (`/userdata/jetkvm/jetkvm_app.stock-0.5.9`) and locally. Auto Update stays on, so an upstream release newer than 0.5.9 will replace the patched build.

## 23. Picture quality, round 2 (2026-10-11)

**Ask (PM):** raise the numbers (text, gradients), keep the frame rate high, and make still screens converge to near 1:1 without a high idle bitrate.

**Baseline:** the "maximum" level on the PM's LAN, from the §21 work:

| Measure | Value |
|---|---|
| Light text (luma) | 53.2 dB |
| Dark text (luma) | 47.8 dB |
| Colored text (RGB, as displayed) | 28.1 dB |
| Gray gradient (luma) | 49.8 dB |
| Idle | 0.54 Mbit/s (a 235 KB keyframe every 4 s) |
| Scrolling | 48.4 dB at 7.6 Mbit/s |

### Findings (measured on the device unless noted)

| # | Finding | Consequence |
|---|---|---|
| R1 | P-frames never refine a still picture. After a change they stay empty even with the QP floor at 0: the encoder skips blocks whose residual is small, at any QP | Still quality has to come from an intra frame |
| R2 | Changing RC parameters live (`SetRcParam`) restarts MPP rate control (`MPP_ENC_SET_RC_CFG` in dmesg). Scrolling that starts after it dropped from 48 to 41–47 dB | Nothing at runtime touches RC parameters |
| R3 | Reading capture buffers from the CPU goes through an uncached mapping: 1.6 ms per frame for every 16th line, 4.5 ms with a cache flush | Stillness is read from encoder output sizes instead |
| R4 | ROI absolute QPs are clamped to the frame type's QP floor (a refresh at "QP 2" stayed at 264 KB until the floor moved) | The I-frame floor is permanently `stillQp`; P-frames keep `minQp` |
| R5 | A QP floor of 0 counts as unset (results like QP 10) | `stillQp` is 1–51 |
| R6 | Frames already queued when the refresh ROI goes off still use it. Read as activity, they caused a refresh every 1.5 s | Cool-down of 4 frames after a refresh |
| R7 | The JetKVM's 4:2:0 chroma is [1 2 1]/4 horizontally on even columns plus a two-row average. It matches the stream within 57 dB on text | The app's chroma reconstruction models exactly that filter |
| R8 | The HDMI bridge truncates luma: Y = 16 + ⌊(66R + 129G + 25B)/256⌋, which matches every gray step of the ramp | The app adds half a code value above black |
| R9 | The Finder screen changed ~15% of its pixels every frame (±5). That was the animated wallpaper behind translucent windows, not dithering; the opaque test page is static except ±2 in its gradients | Cost-based stillness handles both |
| R10 | Restoring the default EDID after the §22 tests needed a reboot; a plain `reboot` hangs while the test build runs (`RkLunch-stop.sh` waits for `jetkvm_app`) | DEPLOY.md: kill the test build first |
| R11 | The review found that typing never triggered a refresh: a typed glyph costs 530–1,000 bytes, below the first design's 1,500-byte "change" threshold, and empty P-frames range 150–460 bytes by screen | Change = cost above a measured baseline, summed over ~3 s (a caret blinks below it) |
| R12 | With the keyframe floor at `stillQp`, PLI keyframes on a still desktop grow from 87 to 103 KB (default parameters) and from 136 to 165 KB (maximum level) | Accepted: moving the floor per refresh would restart RC (R2) |

### Design
- **Firmware (still refresh):** each P-frame's cost above the empty-frame baseline (the smallest frame of the last one to two seconds) feeds two decaying sums. Over ~3 s, 2,000 bytes mark the picture as changed (typing does, a blinking caret doesn't); over ~0.1 s, the sum tells when the changes have stopped. Half a second later a whole-frame ROI with absolute QP `stillQp` is set and a keyframe is requested. Frames above an eighth of the per-frame budget (1,500 bytes at least) and other keyframes count as changes. Refreshes are at least 1.5 s apart; refreshes above 1.5 MiB raise the next ones' QP.
- **Firmware (other changes):** the GOP is 60 s, the stream buffer and frame socket limit are raised to 2 bytes per pixel of 1920×1200 (4.6 MB), and super frames re-encode above 2.5 MiB.
- **Engine:** the quality ladder gains `stillQp`. Maximum uses 1, high 4, balanced 8 and low 17; minimal skips the refresh, because a 0.2–0.4 MB burst would turn into loss on a slow link.
- **App, chroma from luma:** a 3×3 linear fit per chroma site, the fit's mean applied to full-resolution luma, and one back-projection step.
- **App, other changes:** a luma correction for the bridge's truncation, a 10-bit layer, and the 2× text upscaler (below).

### Results on the device

**Maximum level** (the scorer mirrors the app's conversion):

| Measure | Before | After |
|---|---|---|
| Light text | 53.2 dB | 60.5 dB |
| Small text | 53.5 dB | 60.5 dB |
| Dark text (luma) | 47.8 dB | 48.7 dB; 56.3 dB with the luma correction |
| Colored text (RGB) | 28.1 dB | 51.4 dB |
| Dark colored text (RGB) | 28.9 dB | 43.8 dB |
| Gray gradient (RGB) | 47.1 dB | 50.3 dB |
| Color gradient (RGB) | 44.0 dB | 46.5 dB |
| Photo-like area (luma) | 46.5 dB | 52.1 dB |
| Idle | 0.54 Mbit/s | 0.07 Mbit/s |
| Scrolling 120 / 1080 px/s | 48.4 / 48.4 dB | 49.2 / 48.5 dB |
| Scrolling right after a refresh | 48.3 dB | 48.8 dB |

Frame rate stays at 60 fps throughout.

**Balanced level:**

| Measure | Before | After |
|---|---|---|
| Light text | 42.3 dB | 56.3 dB |
| Dark text | 41.7 dB | 48.5 dB |
| Idle | — | 0.04 Mbit/s |

### 2× enlargement
The reference is the test pattern drawn natively at 2× (`make_pattern.swift OUT 2`).
- **Classical filters:** they all land within 0.2 dB of each other, and FSR's sharpening strength doesn't matter.
- **Text upscaler:** a small network trained on CoreText 1×/2× pairs (`tools/text-upscaler`) raises SSIM from 0.955 to 0.972 on text, 0.941 to 0.965 on dark text and 0.957 to 0.978 on colored text. The table is in that README.
- **Performance:** my first Metal kernels spilled registers (11 ms). An MPS attempt cost about the same; its output was wrong, and I abandoned it rather than debug it further. The final 8-channel kernels cost about +2 ms per changed frame for 3000×2000 on an M4 Max and nothing on unchanged frames (a GPU compare pass). A GPU that needs over 8 ms for frames that run it, three 120-frame windows in a row, falls back to FSR.

### Decisions (worth revisiting)
- The still refresh is on in the firmware by default (`stillQp` 8 for clients without a governor, such as the web UI), and the GOP defaults to 60 s.
- The refresh fires after 0.5 s of quiet, at most every 1.5 s. A typing session therefore costs a refresh per pause (~300 KB at QP 1 on maximum for a Terminal window): up to ~2 Mbit/s, which is fine on a LAN. An idle blinking caret causes none.
- The keyframe floor stays at `stillQp` permanently, so loss-recovery keyframes are ~20% larger (R12).
- No deband filter. Still screens now reach 52 dB on gradients, and a deband filter risks softening text. Banding during motion at the lower levels remains.
- No 4:4:4 (the RV1106 encoder has no 4:4:4 mode) and no full-range bridge output: that would need register writes behind the kernel driver.
- The text upscaler is used only at exactly 2×; other scales keep FSR.
- Match Window is opt-in (§22).
- ⌘Space did not reach the remote because Accessibility was not granted to the app. It now asks once, re-checks every second while captured, and taps at the HID level ahead of every hotkey (Raycast, Spotlight).

## 24. Latency (2026-10-11)

**Ask (PM):** keep the quality and frame-rate gains, cut the time from a key press or pointer move to seeing it, and find which quality or frame-rate concessions buy large latency gains.

**Method:** the app's `--latency-probe N` (`LatencyProbe.swift`, `tools/latency-probe`). The target shows a page whose square flips on every key press; the app sends the key, finds the first decoded frame with the change, and takes that frame's `MTLDrawable.presentedTime`. A pointer mode moves the pointer and waits for the cursor. The target's own input-to-display time is part of every sample. The device side was timed with an instrumented build (capture, encode and handoff per frame). Target: Mac mini over HDMI at 1080p60; client: M4 Max on a 60 Hz display; LAN.

### Where the time went (keystroke, before)

| Stage | Time |
|---|---|
| Target: input → change on HDMI (browser) | ~25–35 ms (not ours) |
| Capture: one HDMI frame (V4L2 timestamp → DQBUF) | 16.7 ms, constant |
| Encode (DQBUF → bitstream out) | 12.9 ms, constant for every frame, even empty ones |
| Device handoff, network, engine, IPC, decode | ~3 ms (engine receive → decoded: 1.8 ms) |
| **Decode → on screen** | **52–76 ms**: render queue ~4, `nextDrawable` wait ~16, GPU ~8.5, then ~24 to the screen |
| Total, key press → on screen | **142 ms** median |

### Findings

| # | Finding | Consequence |
|---|---|---|
| L1 | With `displaySyncEnabled = true`, each present waits for our own vsync, and the second drawable stays held for a refresh, so `nextDrawable` blocks ~16 ms | Display sync off: decode → screen 52 → 18 ms (window), 48 → 7 ms (full screen) |
| L2 | Without display sync, presents still land on vblank: present minus GPU-done jumps by whole refreshes (p90 +16/+33 ms) and never lands mid-scan; the window server keeps the newest frame | No tearing; it is the default now (`JETKVM_DISPLAY_SYNC=1` for A/B) |
| L3 | `render()` took the frame before the blocking `nextDrawable()` | Drawable first, then the frame |
| L4 | The text upscaler re-ran on the whole picture on any change: 8.5 ms of GPU per changed frame (GPU clocks stay low at this load), FSR 4.2 ms | Per-tile change flags (16×16, plus one tile of border): bit-exact against a full run (GPU test), 4.6 ms for the probe's large change, little for typing |
| L5 | A third drawable only queues: decode → screen 78 ms | Keep 2 |
| L6 | Encode time is the hardware's (VEPU at 396 MHz): 12.9 ms with SAO off, deblocking off, any scene mode; H.264 12.1 ms | Nothing to gain; H.265 stays (PM: no H.264) |
| L7 | Capture → encode overlap (rockit VI + wrap buffer, DVBM) is wired from the ISP's main path; the HDMI path is raw VICAP (`stream_cif_mipi_id0`) without the ISP | Not feasible without re-plumbing capture; research item |
| L8 | Still-refresh keyframes next to a keystroke: no measurable penalty (gap sweep on a busy desktop page; medians within noise) | No input-aware deferral |
| L9 | Every native start rewrote the EDID (upstream #1476): HDMI hot-plug, and a Mac with two displays rebound the absolute pointer to the other one | Fork D08: skip the write when the bridge already has the EDID |

### Results (median, 60 Hz)

| From | To | Before | After |
|---|---|---|---|
| Key press | On screen, window | 142 ms | 87 ms |
| Key press | On screen, full screen | — | 72 ms |
| Pointer move | Cursor on screen, window | ~100 ms (display sync on) | 70 ms |
| Pointer move | Cursor on screen, full screen | — | 66 ms |

Quality and frame rate are unchanged (same encoder settings; the upscaler's output is bit-identical).

### Decisions (worth revisiting)
- No concession on quality or frame rate was needed: the large gains were in presentation, and the device's 30 ms (one frame of capture plus encoding) is fixed by hardware.
- Rejected: H.264 (−0.8 ms encode, PM said no), a third drawable, encoder speed knobs (no effect), input-aware refresh deferral (no measured penalty).
- The local pointer stays hidden over the picture. Drawing it locally would feel instant, but the target's cursor is part of the HDMI picture, so both would show while moving.
- Open: capture/encode overlap through the ISP (L7) would save about 10 ms; per-tile gating of the chroma passes would save another 1–2 ms of GPU.

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
