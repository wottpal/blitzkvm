# BlitzKVM: Engineering Plan (v2, revised after independent review)

| | |
|---|---|
| Date | 2026-10-10 (v1), revised 2026-10-10 (v2) |
| Status | Approved direction. Implemented on branch `native-foundation`: Phases 0, 1a, 1b and 2 done, Phase 3 MVP done except settings UI (see §19). |
| Repo | `wottpal/blitzkvm` (private fork), base commit `289df51`, identical to the origin repository's `main` (README) |
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
4. **Phase 2, native spike.** Swift/AppKit app (`xyz.scio.blitzkvm`, arm64), with the Go engine as a **helper process, one per device**. VideoToolbox decode (H.264 + H.265), Metal presentation, NSEvent input, an event-tap proof, helper crash recovery. This is de-risking, not a bake-off.
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
cmd/blitzkvm-legacy ── pkg/app (Ebiten Game: Update/Draw/Layout, 130-field App, 187 methods)
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
┌─────────────── JetKVM.app (Swift, AppKit + SwiftUI), bundle xyz.scio.blitzkvm, arm64 ───────────────┐
│ DeviceLibrary (saved devices, Keychain)       one NSWindow per device (native tabbing)                 │
│ VideoView: VTDecompressionSession (H.264/H.265) → CVPixelBuffer → Metal (CVMetalTextureCache,          │
│            YCbCr→RGB from buffer colour attachments, fit/1:1/integer, present on arrival)              │
│            keeps last CVPixelBuffer → OCR (Vision), screenshots                                        │
│ InputCapture: NSEvent (timestamped), CGEventTap while focused (+escape chord, Secure Input detection)  │
│ EngineProcess: spawn/monitor/restart Contents/Helpers/blitzkvm-engine, framed messages over stdio pipes  │
└───────────────▲──────────────────────────────── stdin/stdout, length-prefixed ─────────────────────────┘
                │ out: video access units (Annex-B, codec, ts) │ events/snapshots (JSON) │ rpc results
                │ in : key/pointer/wheel/paste commands │ rpc calls (method + params JSON) │ connect/close
┌───────────────┴──────────── blitzkvm-engine (Go, one process per device) ───────────────────────────────┐
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
| H5 | File logging (`~/Library/Logs/BlitzKVM/` when not on a TTY) + `debug.SetCrashOutput` |
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
- SwiftPM-based macOS app (`macos/`), bundled into a `.app` by script, arm64 only, bundle `xyz.scio.blitzkvm`.
- Developer ID signing once team details exist; ad-hoc signing for local builds until then.
- `cmd/blitzkvm-engine` helper over stdio.
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
| 2026-10-10 | Private fork `wottpal/blitzkvm`; `upstream` fetch-only; upstream workflows disabled |
| 2026-10-10 | Goal: fully replace Jump Desktop for the PM plus a few people; no deadline; macOS client only |
| 2026-10-10 | Bundle ID `xyz.scio.blitzkvm`; paid Apple Developer account; Developer ID signing |
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
| 2026-10-12 | The app is **BlitzKVM**: bundle ID `xyz.scio.blitzkvm`, Go module and repository `github.com/wottpal/blitzkvm`, helper `blitzkvm-engine`, legacy client `blitzkvm-legacy`, app-side environment variables `BLITZKVM_*`. The device, its firmware and its protocol keep the JetKVM name. Settings, the device library, the Keychain service and the Accessibility and Local Network grants start fresh under the new bundle ID |
| 2026-10-18 | Every quality level encodes up to 60 fps (minimal and low were 15 and 30); off a LAN the encoder's peak follows the measured rate, at 0.55× when the JetKVM runs Tailscale itself (§32) |

## 18. PM to-dos

1. Connect `.107`'s HDMI to this Mac (Phase R). The Jump Desktop display may change.
2. Install Tailscale manually on one JetKVM.
3. Optional: buy JetRemote for the benchmark.
4. Provide Developer ID team details for `xyz.scio.blitzkvm`.

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
- **Scoring:** frames recorded through `blitzkvm-engine` are decoded and compared with the image.
  - Luma PSNR/SSIM is measured against the image's ideal luma, which isolates encoder loss from 4:2:0 chroma.
  - Text regions are scored separately.
  - Scrolling is scored per frame after finding its offset.
- **Configurations:** each one ran static and at 120/480/1080 px/s (`sweep.py`).
- **Tools:** everything is in `tools/quality-bench`.

### Findings (each verified on the device)

| # | Finding | Evidence | Fix |
|---|---|---|---|
| Q1 | **Encoder QP floor and texture AQ blur text at any bitrate.** 0.5.9 never sets Rockchip RC parameters. The frame QP floor is about 26–28, and AQ adds up to +8 on textured blocks, so text sits at QP 32–36. | Macroblock QP dump; quality factor 1 → 4 changes neither keyframe size (~47 KB) nor QP | Firmware patch: QP floor tunable live (ladder 10–26), AQ off |
| Q2 | **Wrong color matrix.** The TC358749 bridge outputs BT.601 limited-range YCbCr (the tc358743 driver hard-codes it), but the firmware tags HD streams BT.709. | Color patches fit BT.601 within 0.5 code values and BT.709 within 8 | The app decodes BT.601 always (`BLITZKVM_COLOR_MATRIX=709` overrides). Firmware VUI fix is still open. |
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
| L2 | Without display sync, presents still land on vblank: present minus GPU-done jumps by whole refreshes (p90 +16/+33 ms) and never lands mid-scan; the window server keeps the newest frame | No tearing; it is the default now (`BLITZKVM_DISPLAY_SYNC=1` for A/B) |
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

## 25. Input stalls while the picture stays live (2026-10-11)

**Report (PM):** after seconds to minutes of use, keyboard and pointer stop working while the picture still looks live; seconds to minutes later they work again.

**Cause:** every data channel (HID, RPC, serial) shares one SCTP association. pion retransmits a lost packet after an RTO of at least 1 s that doubles on every miss, up to 60 s, and after a timeout the congestion window drops to one packet. So all data channels wait for the backed-off timer. RTP video is separate and recovers at once (NACK, PLI).

**Reproduction:** `BLITZKVM_DEBUG_BLACKHOLE=20:3` drops all of the session's traffic for 3 s every 20 s; the harness sends a cheap RPC every 100 ms on the same association.

| | Data channels back after the video |
|---|---|
| pion default (RTO up to 60 s) | 3.4–3.6 s (longest RPC 6.9 s for a 3.3 s outage; grows with every further miss) |
| RTO capped at 1 s | 2–700 ms |

**Ruled out:**
- The app's input path: lock-free, and sends never block.
- The engine's controller lock: nothing slow runs under it.
- The device: CPU 73 % idle (its load average of 9 comes from kernel threads in uninterruptible sleep), no transmit drops, no USB errors.

**Changes:**
- The helper caps the SCTP RTO at 1 s (`sctpRTOMax`).
- It logs stalls of the input channels: `input data channels stalled`, then `recovered` with the duration.
- The fork firmware caps its side too (D09, `release/0.5.9-fork.2`).

**Open:** what drops the packets on this wired LAN is unknown. The stall log raised false alarms until §26 fixed it; read older `input data channels stalled` lines with that in mind.

## 26. The picture freezes while frames arrive (2026-10-11)

**Report (PM, with a screen recording):** the app is barely usable because it often gets stuck. The mirrored screen stands still for up to 30 s, and neither pointer nor keyboard seem to work. There is no clear way to trigger it.

**Evidence:**
- In the recording, a clock on the remote screen stays at the same second for about 23 s, then jumps ahead.
- Meanwhile the status bar keeps showing 60 fps, 0.7–2.2 Mbit/s and an RTT of 2 ms.
- So frames kept arriving and the app stopped showing them. Input most likely arrived; it just could not be seen.

**Cause:** four places in the app dropped frames "until the next keyframe" and never asked for one:

| Where | Trigger |
|---|---|
| Decoder backlog (`maxQueued`, 6 units) | Any burst of 7 or more frames: a link or scheduling hiccup of about 100 ms, after which the held-back frames arrive together |
| Engine queue (`videoQueueDepth`, 16 units) | A burst of 17 or more frames |
| Decoder paused while the window is hidden | Showing the window again (another Space, app or tab in front, minimized) |
| Decoder session errors | A VideoToolbox session invalidated, a session that could not be created, and decode errors (no wait, but corrupt references) |

On stock firmware this cost at most 0.5 s, its GOP. The fork sends keyframes only on request, or once a minute (D04, D07), so each of these became a freeze of up to 60 s. The stats count received frames, so they kept showing 60 fps.

**Reproduction (emulator):**
- The emulator now models the fork's keyframe policy: `--keyframe-on-request` (an IDR on PLI/FIR) and `--gop 3600`.
- It also models link stalls: `--hold-every`/`--hold-for` hold outgoing RTP and release it in a burst, drained at `--rate` (a real link drains at link speed; without a rate, loopback overflows the socket buffer).
- App-side hiccups: the app process was stopped (SIGSTOP) for 300 ms every 3 s.
- The self-test now reports freezes (gaps of more than 250 ms between decoded frames while the window is shown) and skipped units.
- Results, 1080p60 over 20 s:

| Scenario | Before | After |
|---|---|---|
| 400 ms link stall every 3 s, unpaced | 16 units skipped, then frozen for the remaining 18.0 s | 0 skipped; longest freeze 411 ms (the stall itself) |
| 400 ms link stall every 3 s, 200 Mbit/s | longest freeze 2.9 s | longest freeze 410 ms |
| 1.5 s link stall every 5 s, 200 Mbit/s | longest freeze 11.3 s, 17.5 s frozen in total | longest freeze 1.51 s (the stall); 0 skipped and 0 lost over 3 runs of 30 s |
| App stopped for 300 ms every 3 s | 27 units skipped, then frozen for the remaining 17.8 s | 0 skipped; longest freeze 330 ms |
| Window minimized for 2 s, then shown | never resumed (frozen for the remaining 12.3 s) | resumed 0.4 s after showing (the restore animation); the keyframe came 14 ms after the request |

**Changes:**
- `Client.RequestKeyframe` sends a PLI, rate-limited to one per 250 ms; the assembler uses it too. A new engine command `requestKeyframe` exposes it to the app.
- Every keyframe wait now asks for a keyframe and asks again while it lasts: the engine queue, the decoder (backlog, hidden window, codec change, session errors) and decode errors.
- Bursts now fit: the decoder backlog and the engine queue each hold 60 units (1 s at 60 fps). Decoding takes about 1 ms a frame, so catching up costs far less than a keyframe.
- Video watchdog, once a second: if units arrive but none decode for 2 s, it logs and asks for a keyframe. If frames decode but none reach the screen, it logs that too.
- Logs: `video resumed at a keyframe after N ms (cause)` from the decoder, and `video queue full` / `video resumed at a keyframe` from the engine.
- `make -C macos selftest-stalls` guards all of this against the emulator. The picture may stand still only about as long as the stall: at most 700 ms for 400 ms stalls, and at most 1 s to resume after the window is shown.

**Correction to §25:** the input-stall log raised false alarms.
- It flagged any data that stayed unacknowledged across two one-second samples. pion delays SACKs by up to 200 ms, so continuous pointer input almost always has some.
- On the emulator over loopback, 20 s of continuous pointer input logged a 9 s "stall".
- Now a stall needs data waiting and no byte acknowledged for over a second. On the same run it logs nothing, and it still catches every 2 s blackhole outage (`BLITZKVM_DEBUG_BLACKHOLE=6:2`).
- Most `input data channels stalled` lines in the PM's log (2–6 s, 3–60 bytes, clustered while the pointer moved) were this artifact.

**Open:** what caused the bursts on the PM's wired LAN is not proven. The likely candidates are scheduling hiccups on either end, for example a screen recorder running on the Mac, or the device's single core. The new logs name the cause of every wait.

## 27. Larger Match Window modes, scale, status bar, stall overlay, quality-change stall (2026-10-11)

**Asks (PM):**
- In full screen on a 40" display, Match Window only reached 1920×792. Can its scaling be adjusted?
- A View option to hide the status bar (default on). Match Window must follow it.
- Changing Stream Quality stalls the picture for about 10 s; warn before it.
- Show a large loading overlay when a stall is known on our side, after a short delay and over the last picture.

**Mode limits.**
- The 1920-wide cap was the app's own. The bridge driver accepts up to 10000 pixels wide and 310 MHz (`v4l2-ctl --get-dv-timings-cap`).
- The real limits:
  - the HDMI pixel clock, 165 MHz;
  - §22's FIFO rule: the input clock must be at least 186.25 × (1 − 250 / width) MHz, which allows widths up to 2176.
- `RemoteDisplay.size(fitting:)` now keeps a 2176×1200 box and shrinks a window's shape until its timing fits 165 MHz.
- Verified on the device (fork firmware, Mac mini host): clean pictures, no shear or stripes, 0 decode errors.

| Mode | Pixel clock | Used for |
|---|---|---|
| 2176×900 | 164.9 MHz | PM's full screen, 3008×1247 points (was 1920×792: 28 % more pixels) |
| 2160×912 | 164.8 MHz | the same with the status bar hidden |
| 2112×1168 | 164.4 MHz | near the largest area |
| 2048×1152 | 163.8 MHz | 16:9 windows (was 1920×1080) |

**Match Window Scale** (View menu, saved per device):
- Window points per remote pixel: 200 %, 150 %, 125 %, 100 % (default), 80 %, 67 %, 50 %.
- Verified at 150 %: a 1600×900 video area asked for 1056×600, the device switched to it, and the window snapped to 1584×900.
- 100 % is not labeled "same size as this Mac": that holds only when the remote renders at 1×.

**Show Status Bar** (View, ⌘/, default on, every window):
- A window keeps its video area and grows or shrinks by the bar.
- In full screen the video area changes and Match Window follows. Verified: 2176×900 → 2160×912.

**Stream-quality stall.** This was a firmware bug, not an HDMI re-plug.
- Reproduced with the session harness, one live change at a time:
  - bitrate-only and QP-only changes were seamless;
  - `maxFps` 60 → 30 dropped the stream to 0 fps;
  - neither 60 again nor a keyframe request recovered it.
- The kernel logged every frame as `frame info no equal set drop: frame [1920, 792, 3840, 800], prep [1920, 792, 1920, 800]`. Changing rate control's frame rate on a running channel made rockit reprogram the input stride in pixels instead of bytes (YUYV).
- Automatic quality switches between 60 and 30 fps levels, so this also stopped the picture without any user action. The picture came back only when the stream restarted.
- Fork fix (D06):
  - rate control keeps the channel's creation frame rate;
  - the capture loop drops frames as before;
  - the bitrates are scaled by creation fps / encode fps.
  - The GOP nudge path uses the same helper.
- Verified with the harness: 60 → 30 → 60 fps with no dropped frames. In the app, after low → maximum → low, the device still streamed 30 fps (0 before).
- No confirmation alert: the change is now seamless. On stock firmware the quality factor restarts the pipeline briefly, and the overlay covers that.

**Stall overlay** (`StallOverlay.swift`, checked every 0.1 s):
- Shown once a stall has lasted 0.6 s; it fades out when the picture returns.
- The last picture stays underneath, dimmed. The overlay takes no clicks, so input keeps working.

| Situation | Title | Detail |
|---|---|---|
| Connecting | Connecting to *name*… | the address |
| Reconnecting | Reconnecting to *name*… | The connection dropped. Retrying automatically. |
| Device rebooting | *name* is restarting… | The picture comes back once it is up again. |
| No first picture yet | Starting video… | Connected to *name*. |
| Display resize (15 s after a request) | Resizing the remote display… | Switching to W×H. The computer re-detects its display. |
| HDMI signal not ready | No picture from the computer (no spinner) | HDMI: *state*. It may be asleep or switched off. |
| Any other gap | Waiting for video… | Connected, but no new picture for N s. |

- During a resize the Mac host sends black frames before it switches modes. Measured mean luma was 0.1 during the switch against 40 normally.
- The app therefore holds the last picture from the request until a frame of the new size arrives (at most 8 s). With the hold, the screen stays at luma 27–33, the old picture dimmed under the overlay.
- The resize is reported before `setEDID`, which returns only after the re-plug, about 4 s later.
- The small "Resizing…" banner is gone; the overlay replaces it.

**Self-tests:**
- They no longer capture the operator's input. Before this, a self-test window captured keyboard and pointer when it became key, so the first device runs of this round could forward the PM's typing to the target. Only `--inject-input` sends input now.
- Self-test windows float above other windows, since a covered window stops decoding.
- Time hidden is excluded from freezes. A `--max-freeze-ms` run that was hidden for more than a quarter of its length fails as inconclusive.
- New options:
  - `--full-screen` and `--match-scale` (also outside self-tests);
  - `--set-quality-after S:level,…`;
  - `--toggle-status-bar-after S`.
- The report adds `remoteSize`, `videoArea`, `windowContent`, `statusBar`, `hiddenMs` and the overlay's timeline.

**Open:**
- After connecting, the first picture takes about 4 s (the device starts its encoder late). The overlay explains the wait; the cause is not investigated.
- Firmware: `release/0.5.9-fork.3` (fork `5fc9be5`, SHA-256 `88dbed94a6fd…`) carries the fix, plus the fixes from two independent reviews of the whole fork, which found nothing critical:
  - encoder overrides reset when another session takes over;
  - the still refresh finds a working keyframe path, and its pacing follows the bitrate and backs off after repair keyframes;
  - setEDID re-plugs again;
  - one 6 MiB frame limit, a 4096-packet NACK history and a serialised stream restart.
  - It is installed persistently on the PM's device.

## 28. Full resolution for large windows: the bridge's two CSI links (2026-10-11)

**Ask (PM):** in full screen on a 40" display (3008×1269 points), Match Window reached only 2160×912, even at a 50 % scale. The PM wants the full resolution, a choice of refresh rates, and a choice of scaling filters to experiment with.

**Why 2160×912.** The cap was in the app's sizing model, not in the bridge's driver, which accepts up to 10000 px and 310 MHz (`v4l2-ctl --get-dv-timings-cap`). Reading the bridge over I²C (`/dev/i2c-4`, 0x0f, read-only) and its driver source (rockchip-linux `drivers/media/i2c/tc35874x.c`) explains it:

- **Line FIFO:** `FIFOCTL` = 300. The bridge starts sending each line over CSI once 300 pixels are buffered.
- **Fast link, above 33 Hz:** `PLLCTL0` = 0x4089, 27 MHz × 138 / 5 = 745.2 Mbit/s a lane, 4 lanes, 16 bit per pixel: the bridge drains 186.25 Mpx/s.
  - HDMI fills the FIFO at the pixel clock, at most 165 MHz. So the FIFO runs dry after about 300 / (1 − clock / 186.25) pixels.
  - §22 had budgeted 250 px of drift, which gave 2176. Measured clean: 2400×1012 at 165 MHz (268 px drift) and 2560×960 (291 px). The fast-link width limit is now 2496 (about 286 px).
  - At 60 Hz the 165 MHz clock then bounds the area: a 21:9 window gets 2448×1024 at 60 Hz, 2496×1044 at 50 Hz.
- **Slow link, 33 Hz or less:** the driver switches the PLL on every format change (`format_change` → `s_dv_timings` → `set_pll`): `PLLCTL0` = 0x1040, 27 / 2 × 65 / 2 = 438.75 Mbit/s a lane, which drains 109.7 Mpx/s.
  - A pixel clock just under that (107.5 MHz, 2 % margin) drains each line about as fast as it arrives: 60 px of drift for a 3008-px line.
  - So any width up to the bridge's 4000-px lines streams. Horizontal blanking stays minimal, and vertical blank lines set the clock.
- **Other limits:**
  - Capture buffers: upstream's are 1920×1080×3 bytes, so 3.1 megapixels at YUYV.
  - The encoder: 12.9 ms per 1080p frame, about 160 Mpx/s.
  - Video CMA: 48 MiB.

**Measured on the device** (Mac mini host, fork firmware, H.265):

| Mode | Link | Pixel clock | Result |
|---|---|---|---|
| 2560×1080 at 30 Hz | slow | 107.47 MHz | clean (fits upstream's buffers) |
| 3008×1268 at 25 Hz | slow | 107.47 MHz | clean, 1:1 for the PM's full screen; video CMA 42.6 of 48 MiB with 8 MiB buffers |
| 2800×1172 at 30 Hz | slow | 107.45 MHz | clean, 0 decode errors (app e2e, Automatic) |
| 2400×1012 at 60 Hz | fast | 165.39 MHz | clean (268 px drift) |
| 2560×960 at 60 Hz | fast | 165.04 MHz | clean (291 px drift) |
| 2448×1024 at 60 Hz | fast | 164.93 MHz | clean, 0 decode errors (app e2e) |
| 2496×1044 at 50 Hz | fast | 164.63 MHz | clean, 0 decode errors (app e2e) |

**Firmware:**
- **D10 (`release/0.5.9-fork.4`, fork `4a68d63`, SHA-256 `9052cccccf3d…`, installed persistently).** The capture buffers grow to 8 MiB each, for up to 4.19 megapixels, and `getVideoEncoderParams` reports `captureMaxBytes`.
- **No FIFO change.** Raising `FIFOCTL` would only help very wide 60 Hz shapes, and the driver rewrites it on every timing query.

**App:**
- **`RemoteDisplay.mode(fitting:refresh:captureMaxBytes:)`**
  - Searches each refresh rate (60, 50 and 40 Hz on the fast link; 30, 25 and 24 Hz on the slow) for the largest size of the window's shape that the bridge, the capture buffers and the encoder carry.
  - The search steps the width down, so it always ends. The earlier shrink loop could spin forever on very wide shapes.
  - Automatic picks the largest picture, then the highest rate that reaches it, so a window that fits at 60 Hz stays at 60 Hz. The PM's full screen gets 3008×1244 at 25 Hz with D10, or 2736×1132 at 30 Hz with stock buffers.
- **Timings:**
  - At the 165 MHz cap, padding now rounds down: rounding up had pushed 2400-wide modes to 165.39 MHz and excluded them.
  - Every timing verified earlier is unchanged, and all are pinned in `RemoteDisplayTests`.
- **View › Match Window Refresh:** Automatic, then each rate with the size the window gets at it, e.g. "60 Hz · 2448×1024", "25 Hz · 3008×1268 (Full Size)". Saved per device.
  - A one-time hint explains a drop below 60 Hz.
  - The resize overlay names the mode it switches to.
- **View › Scaling Filter** (global; the default is unchanged):
  - Automatic, which uses the text upscaler at 2× and FSR 1 otherwise;
  - FSR 1, strong-sharpening FSR 1, FSR 1 without sharpening;
  - Lanczos‑3, Catmull‑Rom, sharp bilinear (area-weighted nearest neighbor), bilinear, nearest neighbor.
  - Shrinking stays antialiased: the kernel is widened by 1/scale.
  - Checked on the emulator pattern at 2.34×: each filter renders, with the expected character (Lanczos rings faintly, bilinear is soft, nearest and sharp bilinear are crisp).
- **Self-test options:** `--match-refresh <Hz|auto>` and `--scaling-filter <name>`.

**Trade-off:** 25–30 Hz roughly halves motion smoothness, and the remote pointer is part of the picture. It is offered only when the window cannot be shown 1:1 at 60 Hz, it is said once, and 60 Hz stays one menu choice away.

## 29. A ten-hour session (2026-10-12)

**Ask (PM):** after about ten hours, a live session (2400×1012 at 60 Hz, full screen on the 40" display) felt slow and laggy. Did something build up?

**Nothing built up.** Measured read-only on the running session (app build 218, fork.4):
- **App memory:** flat over 10 minutes. 547 MB with the window hidden, 964 MB shown (the render targets of a 6016×2538 window). IOSurfaces constant at 40 (119 MB).
- **GPU:** 29–34 % of the M4 Max while shown, about 0 while hidden. A fresh instance at a quarter of the pixels (1200×506 into 3008×1268, the same 2.51× FSR scale) needs 1.30 ms a frame. At full size that is 5.2 ms, 31 % at 60 fps: the same as the long session.
- **Code:** no timer, observer, event tap or queue grows, and textures are allocated only on size changes. Video is never paced by RTP timestamps (frames go out when complete), so clock drift cannot add latency.
- **Engine:** 18–33 MB, 3 % CPU.
- **Device:** up 10 h, memory flat (app 57 MB, native 30 MB, video CMA 37 MB), CPU 88 % idle. The load average of 9.6 is the media driver's idle kernel threads in D state.
- **Network:** 0.9 ms RTT, no loss, no input stalls in the session.
- **The remote Mac's screen was busy:** an agent session with a spinner and an animated web page, so every frame changed.

**Two inefficiencies, fixed:**
- **Hidden windows caused keyframe storms.**
  - A window in another Space stops decoding, but the engine kept sending video.
  - macOS throttles a hidden app's pipe reader (App Nap), so the engine's one-second queue overflowed, and each overflow asked for a keyframe: up to two maximum-quality keyframes a second for 20 s (23:22:32–51), and a few dozen bursts overnight.
  - The engine now stops sending video while the window is hidden (`setVideoPaused`, re-sent to a restarted engine), and resumes at a keyframe it asks for at once.
  - Re-showing takes as long as before: 400–419 ms against 417–437 ms in the hide self-test.
- **A still screen was redrawn 60 times a second.**
  - The device streams near-empty P-frames from a still screen. Each was upscaled and composited again: 5.2 ms of GPU at 6016×2538, plus a WindowServer composite.
  - The view now skips a decoded frame identical to the one shown: same size, colorimetry and pixels, compared row by row. The comparison stops at the first difference and takes at most 0.15 ms for 2400×1012.
  - On an H.265 still clip at 2400×1012, 1 of 753 frames is drawn, and the GPU share falls from 10–13 % to about 0.
  - With a caret blinking twice a second, 27 of 722 frames are drawn (0.5 % GPU).
  - The video watchdog counts a skipped frame as shown.

**Menu:** Stream Quality moved from the Device menu to View.

## 30. Devices gallery, JetKVM Setup, remote access over Tailscale (2026-10-12)

**Ask (PM):** the Devices window looked dated; every picture-overlay state should have an icon; and Tailscale should fit in, so the KVM and the Mac behind it are reachable from other networks. The app should become a configurator for the JetKVM: check and install the fork firmware and Tailscale (only when asked), and show the state of both.

**Devices window.** Three designs came from independent design agents, and the PM picked one: a gallery of screens.
- Each device is a 16:10 screen that glows amber, like the app icon, while the device answers the HTTP probe (every 30 s, only while the window is on screen, never a session).
- Screens grow to fill the window, so one device is a large tile and many make a grid.
- The most recently used device starts selected, so Return connects. A click anywhere on a screen connects too, and the pointer turns into a hand over it.
- Removing a device asks first.
- Relative times are in English with the user's region ("Connected 2 days ago"), not the system language.
- The add/edit form is a grouped form. Its notes appear only when they apply: the ⌘/Ctrl swap and Match Window.

**Picture overlay.** Each state has an SF Symbol: connecting, reconnecting, restarting, resizing, no picture, starting and waiting. The symbol pulses while the wait ends by itself and stays still for no signal.

**Tailscale on the JetKVM (findings, all verified on `.107`, system 0.2.8):**
- **Official and supported.** JetKVM documents an installer (`jetkvm.com/install-tailscale.sh`). Tailscale itself has `tailscale configure jetkvm` (since 1.86). It writes `/userdata/init.d/S22tailscale`, which the system's `RkLunch.sh` runs at boot, and links `/bin/tailscale`. Tailscale keeps its state in `/userdata/tailscale/var` and uses nftables there ("nft-jetkvm").
- **Real TUN.** `/dev/net/tun` is missing until something loads the module. The kernel ships `tun.ko`, `nf_tables.ko` and `wireguard.ko` as modules in `/oem/usr/ko` (`/lib/modules/5.10.160` links there), and tailscaled runs `modprobe tun` itself. The JetKVM therefore gets a `tailscale0` interface (MTU 1280), not userspace networking. That matters for video: the firmware's ICE agent advertises host candidates on every interface, so its tailnet address becomes a candidate. In userspace mode the web UI would load and WebRTC would not.
- **The firmware only reports status.** `getTailscaleStatus` reads `tailscale status --json`, and the web UI shows it with a control-server URL. It installs nothing.
- **Memory.** The device has 199 MB RAM with about 145 MB available before Tailscale.
- **Alternatives rejected.**
  - A subnet router elsewhere sends home traffic through the router, and `192.168.1.x` collides with other networks.
  - The Mac mini as router is gone when the Mac sleeps or hangs.
  - JetKVM Cloud was already out of scope (§10).

**Engine:**
- **Video follows the chosen route** (`pkg/client/route.go`).
  - The engine resolves the device's host and asks the system which local address it would send from (a connected UDP socket, no packets).
  - It gathers ICE candidates only on those addresses: the LAN at home, `utun` (Tailscale) away, loopback for the emulator.
  - Before, with Tailscale on both ends, ICE could pick the tailnet pair at home and push the whole stream through WireGuard on the JetKVM's single Cortex-A7 core.
- **Path in stats:** `Path` (`lan`, `tailscale`, `vpn`, `internet`, `loopback`) and `PathRemote` come from the selected candidate pair. Tailscale is recognised by 100.64.0.0/10 or fd7a:115c:a1e0::/48 on either end, so a subnet router counts too. Another VPN is recognised by its point-to-point interface.
- **`createPassword`** sets a password-less device's first password, and the session uses it from then on.
- **Emulator:** `--tailscale running|none|needs-login`.

**JetKVM Setup (the configurator).** Device › Set Up JetKVM…, or Set Up JetKVM… on a device in the gallery, which connects first. One sheet with three rows: state, then one action.
- **Firmware:** stock (no `getVideoEncoderParams`), the BlitzKVM firmware with its build unverified, the bundled build, or an older one. The installed binary's SHA-256 over SSH tells builds apart, because fork builds keep upstream's `VERSION`.
  - The app ships the build pinned by `macos/Support/Firmware.json`. `make firmware` checks `FORK_BINARY` against it and gzips it: 13 MB in the app.
  - Install: `gunzip` over SSH into `jetkvm_app.update.part`, compare SHA-256, back up the running app to `jetkvm_app.backup`, rename to `jetkvm_app.update`, `sync`, reboot. The device moves the file into place at boot, as for an OTA update, then the session reconnects.
- **Tailscale:** not installed, needs login, stopped, or running (with its MagicDNS name).
  - Install: the current stable ARM tarball from pkgs.tailscale.com, checked against its `.sha256`, streamed over SSH. The binaries are replaced while `var/` is kept, then `tailscale configure jetkvm`, then the daemon starts. No reboot.
  - Then `tailscale up --hostname=<device>-jetkvm` runs detached, and the app opens the login URL once.
  - When the device is running on the tailnet, its name is appended to the device's addresses.
  - After a restart, Tailscale needs login without a URL; Log In asks the JetKVM for a new one.
- **Password:** off or on. Set Password calls `createPassword` and stores the password in the keychain.
- **SSH:** the app's own ed25519 key in Application Support. When SSH doesn't answer, the app turns on Developer Mode over the session (`setDevModeState`) and appends its key to the device's keys (`setSSHKeyState`), keeping the others. The host key is filed under the device ID (`HostKeyAlias`), trusted on first use.
- **Status bar:** "via LAN", "via Tailscale", or "via Tailscale relay `<region>`". The relay comes from this Mac's `tailscale status --json` (a peer with no current address and a relay), checked every 30 s.

**Verified:**
- **Tests:** Go tests, including path kinds, the route to loopback, the controller pinning ICE to the route, and `createPassword` with a reconnect. 47 Swift tests, including firmware states, Tailscale states and hostnames, relay parsing and SSH arguments. `selftest`, `selftest-extras` and `selftest-stalls` pass.
- **Emulator** (`--setup`): stock firmware, the fork with its build unverified, Tailscale in all three states, and Set Password, with the sheet rendered each time.
- **Device `.107`:**
  - **Check:** fork, build unverified, Tailscale not installed, no password, video via LAN.
  - **Install Tailscale:** 52 s from click to login URL. `tailscale0` came up and `tun` loaded.
  - **Reinstall firmware:** 80 s from click until reconnected. The device rebooted and runs `9052cccc…`, the backup was written, and tailscaled came back at boot (needs login).
  - **Log in:** a new URL opened in the browser.
- **Not verifiable here:** video, because the Mac mini's HDMI output was asleep (the bridge reported 0×0 timings and the capture delivered no frames, so the device restarted its encoder every 1.6 s).

**Both firmware builds in the app (same day).**
- **What ships:** the app carries the BlitzKVM build and JetKVM's own latest release (0.5.9; nothing newer upstream, not even on `dev` since 2026-10-05), so switching needs no download. `Support/Firmware.json` lists both, pinned by SHA-256 (`3b955de5…` for JetKVM 0.5.9, identical to the stock copy saved on the device).
- **Build:** `make firmware` gzips each build (13 MB apiece). JetKVM's comes from its GitHub release once and is cached.
- **Firmware row:** names the build by hash. Its button installs the BlitzKVM build, and a menu reinstalls either build or switches to JetKVM's own (a split button, or a menu beside the Up to Date badge).
- **Rows:** the state on one line, its meaning in a second paragraph.
- **Verified on `.107`:**
  - The switch to JetKVM 0.5.9 worked through the app, including the restart.
  - On stock, the app connects, its RPCs answer, and the sheet reads "JetKVM 0.5.9" by hash. Tailscale status, SSH and the path ("via LAN") work, and tailscaled survives the switch.
- **Not verified:** video. The JetKVM has reported no HDMI signal since about 10:15, while the Mac mini's USB stays configured, so it is awake. That predates the firmware changes.

**Wake Computer.**
- **Why it's needed:** firmware 0.5.9 stopped ordinary keyboard and mouse input from waking a suspended host (upstream #1471). Its web UI has a "Try to wake" button calling `wakeHost`, a wake-only HID report; the app had nothing.
- **What it does:** Device › Wake Computer sends a one-pixel relative nudge there and back (a sleeping display) and `wakeHost` (a suspended host). The no-signal overlay points to it.
- **Self-tests:** `--wake` does the same.
- **Not enough here:** it didn't bring the Mac mini's picture back, so the cause there is the Mac's display arrangement, not sleep.

**Decisions:**
- **No GitHub release yet.** The firmware ships inside the app, so builds need the fork's binary locally.
- **Tailscale installs without restarting the JetKVM**, unlike JetKVM's script, so the target's display is not re-plugged.
- **The password is a row of the sheet**, because a JetKVM on a shared tailnet is reachable by everyone the tailnet's ACLs allow.

## 31. Latency and quality, round 3 (2026-10-12/13)

**Ask (PM):** squeeze everything out of JetKVM firmware and BlitzKVM: minimise key, pointer and scroll latency, maximise sharp Retina text, also on slow links (cellular via Tailscale). Benchmark everything. The PM's setup: a 40" 5K2K display (3008×1269 points, 60 Hz, DELL U4021QW), the remote in Match Window at 2400×1012@60, so the picture is enlarged 2.507×.

**Method:**
- Five research agents (device encode/capture, HDMI bridge modes, cellular/congestion control, macOS client, any-scale upscaling), then implementation agents in detached worktrees; every hardware experiment on `.107` and the Mac mini by one session.
- The latency probe (§24) at the PM's mode, 30–40 samples per cell. It had an off-by-one: it took the serial before `display()` numbered the changed frame, so a late present of the previous frame could be taken for it. Fixed; baselines re-measured.
- An instrumented device build (`JETKVM_TIMING=1`, kept as part of D11): per frame V4L2 timestamp → DQBUF, frame start → bitstream, handoff, sizes, encode time by frame type. Go-side `WriteSample` timing and a localhost pprof in experiment builds.
- A tear probe (`tools/latency-probe/tear.html`/`tear.py`): frame counters at the top, middle and bottom of a page that changes every frame; a decoded frame whose counters disagree was encoded before the capture finished writing it.
- The link impairment harness (`BLITZKVM_IMPAIR`, below) for slow links, on the emulator and on the real device.

### Where the time went (2400×1012@60, before)

| Stage | Time |
|---|---|
| Target (Mac mini): key → change on HDMI | ~45 ms (Safari), pointer ~18 ms |
| Capture: V4L2 timestamp → DQBUF | 16.68 ms (one period + 16 µs: the buffer completes at the next frame start) |
| Encode (VEPU, 396 MHz) | P 15.19 ms, I 13.1 ms (≈160 Mpx/s, every CTU processed) |
| Device send (Go: packetise, SRTP, sendto) | ≈0.45 ms CPU per 1200-byte packet |
| Decode → screen | 8 ms full screen, 12.7 ms windowed (60 Hz client) |
| **Key → screen** | **91.2 ms full screen, 96.0 ms windowed; pointer 57.4 / 65.0** |

### Findings and changes

| # | Finding | Change | Result |
|---|---|---|---|
| R1 | The encoder only started once a frame was captured, though it is faster than the HDMI scan-out | **Early submit (fork D11):** after DQBUF of frame k the buffer VICAP is writing (k+1, next in ping-pong order) goes to the encoder at its frame start + active time − fastest recent encode (I-frames ~2 ms faster) + 2 ms | frame start → bitstream 31.9 → 19.9 ms; key → screen 89.4 → 76.4, pointer 66.8 → 49.6 ms (full screen, A/B). Tear thresholds: P ~2 ms, I 3.5–4 ms below the offset at 2400×1012, 3–3.5 ms at 1280×720@120; 0 torn in >2,000 frames with a keyframe every 0.5 s, and with 30 fps frame dropping |
| R2 | The bridge locks up to 120 Hz (upstream `feat/experimental-120hz-mode`), and its FIFO level counts 2-pixel entries: a line may end ~600 px behind the CSI output, not ~290 | **Match Window 75/90/120 Hz and full width on the fast link** (app): drift budget 550 px (sweep at 1904×1072@50: clean at 351/449/548/651 px, stripes at 755) | key → screen (full screen, early submit): 1280×720@120 47.0, 1664×700@120 50.0, 1920×800@90 55.9, 2160×908@75 67.7, 2400×1012@60 76.4, 3008×1268@40 110 ms (was 25 Hz). 720p120: capture 8.37, encode 5.4/6.0, frame start → bitstream 10.6 ms |
| R3 | Both ends negotiated AES-256-GCM (pion's default); the device's ARMv7 core has no AES instructions | **AES-128-CM-HMAC-SHA1 SRTP** (engine) | device microbenchmark per packet: GCM-256 634 µs, CM 220 µs (AES 157, HMAC 35), sendto 98; send time of typing frames −~10 % |
| R4 | pion drops SRTP packets >64 behind the newest as replays; retransmissions reuse sequence numbers | **Replay window 8192** (engine) | NACK repairs no longer discarded on slow links |
| R5 | Big frames block everything behind them: the device spends 120–230 ms sending a 250–350 KB keyframe (wire: 20–28 ms) | (measurement) | a key 10/30/60 ms after a keyframe request: decoded 137/127/99 ms vs 76 (p90 up to 210) |
| R6 | Every typing pause triggered a whole-frame near-lossless refresh keyframe (D07) | **Client-driven region refresh (fork D13 + app):** the app plans refreshes from the visibly changed blocks, its input timing and the link: changed regions (≤6 rects, forced intra at the P-frame floor) once the picture is still 250 ms and input idle 400 ms; a full refresh only on LAN-like links after 3 s without input | a typed key → one 2-rect region refresh ~0.35 s after the burst; an 880×224 text rect 50.2 → 55.3 dB in one 54 KB P-frame (full refresh: 355 KB, 59.1 dB); keys 0.45–0.8 s after a pause: no penalty (72–74 ms to decode) |
| R7 | The device's encoder keeps re-coding a still picture by 3–5 code values (~2,500 px a frame) | **Visible-change detection:** 64×64 blocks count only above a luma delta of 32 | a still refresh changes 0 % of blocks visibly, scrolling 38–45 %, a window switch 90 % |
| R8 | The FSR path recomputed the whole 15 MP output for any change | **Dirty-rect rendering** (app) | typing/pointer frame 5.04 → 0.7 ms GPU at 6016×2538; bit-exact GPU tests |
| R9 | The 2× text upscaler never ran at the PM's 2.507× | **Any-scale text upscaler** (3×3 sub-pixel grid, trained at 2.5067×), Automatic for 1 < scale ≤ 3; frames changing >10 % of blocks visibly draw with FSR first and are sharpened ~110 ms later | +1.3–3.0 dB / +0.02–0.03 SSIM over FSR on every text region (real recordings, in the app); typing 0.8 ms GPU |
| R10 | Wheel steps went over JSON-RPC (a goroutine and JSON per step, no order) | **Wheel over HID-RPC (fork D12, `getFirmwareFeatures`)** | single steps: same latency (83 ms); order and device CPU |
| R11 | The local pointer had to stay hidden (the target draws its own cursor) | **View › Local Pointer** (Hidden default, Dot, Arrow; hides after 150 ms at rest) | the local pointer moves without the stream's ~50–70 ms |
| R12 | Slow links: duplicate NACKs, 300 ms gap deadline, no harness | **`BLITZKVM_IMPAIR` harness** (rate/trace, queue, delay, jitter, Gilbert–Elliott loss, outages; lte, lte-congested, wifi-hotel, derp) and **RTT-aware NACK pacing, progress-based gap deadline, late repairs** | emulator A/B: wifi-hotel dropped frames 283 → 20, PLIs 12 → 0; derp from no picture to working; LAN unchanged. Real device via the harness, key → screen: none 78, lte 122, wifi-hotel 186, derp 192 ms |
| R13 | The quality ladder reacted to a once-a-second RTT sample (seconds of queue on congested links), climbed during idle, and one lost packet on a still screen read as 16 % loss | **Delay-based governor** (engine): per-frame queueing delay from RTP capture time and delivered rate from frame dispersion; a queue > 60 ms that isn't draining steps down within ~100 ms to the level the rate carries; step-up only on measured headroom; off a LAN the still refresh's keyframe may hold the link ≤ 200 ms; loss needs 100 packets | harness A/B, p95 frame delay: lte-congested scroll 899 → 285 ms, wifi-hotel scroll 204 → 90, derp 343 → 104, a 12→3→12 Mbit/s trace 1526 → 104; total freezes 2–9× lower; LAN identical. On the device: no level change on the LAN; through lte-congested it started at "balanced" |

### Results (2400×1012@60, fork.5 installed, median)

| | Before | After |
|---|---|---|
| Key → screen, full screen | 91.2 ms | **77.5 ms** |
| Key → screen, window | 96.0 ms | **78.8 ms** |
| Pointer → screen, full screen | 57.4 ms | **53.0 ms** |
| Pointer → screen, window | 65.0 ms | **57.7 ms** |
| Key → screen at 1280×720@120 | — | **47.0 ms** |
| Text at 2.507× (vs FSR) | FSR | **+1.3–3.0 dB** |

### Ruled out (measured)
- Raising the VEPU clock: the MPP debug knob doesn't change the live clock; the core clock's only faster source (PVTPLL) is +6 % at most.
- `GOGC=400` (no change), `GOMAXPROCS=2` (worse).
- Hardware AES through `/dev/crypto` (`ctr-aes-rk`): correct but only 2× faster (74 vs 157 µs a packet, the engine runs at ~16 MB/s); about 15 % of the send path. Not worth vendoring pion/srtp.
- The send path's rest (sendto ~20 %, allocations ~19 %) is inside pion. Bigger RTP packets need pion's `outboundMTU` constant changed.
- Capture/encode overlap in hardware (ISP + DVBM wrap, rkcif line wake-up) needs device-tree changes outside the firmware.
- Time to first picture: 0.27 s cold (the 4 s in §27 is gone).
- The PM's display is 60 Hz, so the ~8 ms vsync wait stays.

### Decisions (worth revisiting)
- Automatic Match Window takes the highest rate that keeps the largest picture: small windows get 90/120 Hz, the 40" full screen 3008×1268@40. Rates offered: 120, 90, 75, 60, 50, 40, 30, 25, 24.
- Early submit margin 2 ms above the I-frame threshold (≈1.3 ms of safety).
- Region refreshes reach the P-frame floor (minQp, ~53–55 dB), the full refresh after 3 s idle the still QP (~59–60 dB).
- Frames that change more than a tenth of the picture visibly draw with FSR first (latency), sharpened ~110 ms later.
- Local pointer default stays Hidden.
- Firmware changes went straight to the fork's `dev` (D11–D13) and `release/0.5.9-fork.5` was tagged locally; nothing was pushed.

### Open
- A device-side pacer for keyframes on DERP/policed links (the harness shows the burst loss).
- On the device through `lte-congested` the governor started at "balanced", not "low" as on the emulator: check its start rate on real cellular links.
- Temporal SVC (TSVC2) so a lost top-layer frame needs no keyframe (VideoToolbox can't recover via intra refresh or recovery-point SEI).
- The device send path (0.45 ms a packet) still bounds large frames.

## 32. Slow links over Tailscale: latency first (2026-10-18)

**Ask (PM):** away from home, over Tailscale on an ordinary connection, automatic quality settles on the lowest level and clicks and pointer moves lag. Cut latency while keeping quality (small compromises allowed); leave the LAN modes alone unless a change is strictly better there.

**Setup:** the client Mac (M4 Max) on hotel-grade Wi-Fi (24 Mbit/s down, 338 ms round trip under load), the JetKVM at home running Tailscale itself (`tailscaled` on the device, a direct path, 38 ms round trip), Match Window at 1456×920, 90 Hz.

**Method:**
- A UDP probe on the device (paced streams and packet trains to the Mac over Tailscale), per-process CPU from `/proc` (also every 100 ms), and `tailscale debug --cpu-profile`.
- The latency probe against `tools/latency-probe/latency_motion.html`: the quality pattern scrolls behind the probe square for 2 s every 6 s, so a third of the samples land in heavy motion. `tools/quality-bench/motion_score.py` scores recordings of it (PSNR-Y of moving frames and of the picture each still phase settles at).
- `keylog_server.py` on the target logs when each key reaches the browser, to tell the input's delay from the picture's.
- An engine build that traced every RTP packet and the governor's inputs, and recorded the stream the app decoded (not committed).

### Findings

| # | Finding | Evidence |
|---|---|---|
| T1 | The path carries about 9 Mbit/s sustained (a queue builds from about 6) and takes bursts of 120 packets at about 15 Mbit/s without loss | UDP probe from the device |
| T2 | `tailscaled` on the JetKVM costs about 1.1 ms of the single core per 1,200-byte packet, 12 % of the CPU per Mbit/s, against 0.45 ms for the rest of the send path (pion, SRTP). Its cipher is already NEON assembly (83 µs a packet); the rest is syscalls and Go's scheduler | CPU at paced rates (13 % at 1, 48 % at 4, 68 % at 6 Mbit/s); profile |
| T3 | On a still screen at 60 fps the device already spends about 30 % of its CPU (video process 14, `tailscaled` 9, app 6; 18 % at 30 fps, 39 % at 90). Scrolling at balanced (peaks to 3.9 Mbit/s) leaves it 0 % idle for 1.2-1.4 s of every 2 s burst, and saturated, the stream stalls for 100-300 ms, then bursts | 100 ms CPU samples; packet trace |
| T4 | Input is not the slow part: under load, keys reach the target's browser within 0-7 ms of the fastest, and it handles them in 2-5 ms. The whole tail is in the picture's path | key log against the probe's send times |
| T5 | The governor started from the session's first keyframe, which the device sends while it sets up the session (1.4-2.9 Mbit/s over a path that then measured 3.7): it started at minimal. There, frames rarely reach the 8 packets a rate sample needed, the 100 KB of evidence never came again, and it never stepped up | trace: 21 frames of 8+ packets in 80 s |
| T6 | The lower levels' frame rate caps cost latency: key → decoded with scroll bursts, minimal (15 fps) 117-127 ms median, low (30 fps) 110 ms; at the source rate 89 and 93 ms | probe at fixed levels |
| T7 | Every live frame rate change costs a keyframe (firmware D06: the GOP length in frames changes): 68 KB here, and the still refresh's 135 KB half a second later. The ladder's 60 → 30 → 15 fps steps sent them into links that were already congested | `maxFps` flips on a still page |
| T8 | Capping balanced's peak keeps its sharpness and loses the tail: at a 2 Mbit/s cap 40.4 / 52.6 dB (moving / still) and 97 / 138 ms (key → decoded, median / p90), against 42.7 / 52.6 dB and 96 / 258 ms uncapped; 2.5 Mbit/s already 195 ms p90 | cap sweep, scored recordings |
| T9 | Off a LAN the still-refresh budget set balanced's still QP to its QP floor, which also turns the client's region refreshes off: a still picture after scrolling stayed at 44 dB, against about 50 refreshed | scored recordings |
| T10 | Pointer moves load the device more than expected: with `maxRetransmits: 0` pion abandons every message as it sends it and follows it with a FORWARD-TSN, so a move on the unreliable channel cost four packets through `tailscaled` (and the app's SCTP and HID work). About 100 moves a second took the device's app and `tailscaled` from 16 % to 71 % of its CPU, enough to stall the picture | SCTP trace (206 moves: 205 abandoned, 298 FORWARD-TSNs); tunnel packet counters; CPU |

### Changes (engine, app tooling)

- **Every level encodes up to 60 fps** (minimal and low were 15 and 30). Levels now differ in bitrate and QP only, so changing level costs no keyframe.
- **Peak follows the link off a LAN:** the encoder's peak bitrate (and its target, where higher) is held at 0.9× the measured delivery rate, or 0.55× when the JetKVM itself is the Tailscale peer (the selected pair's remote address is a Tailscale node's own address; a subnet router's 4via6 addresses are not). It changes on a 25 % difference, at most every 5 s (each change restarts the encoder's rate control). A LAN keeps 1.5× the target, except a path through Tailscale on the JetKVM, whose CPU cost is per packet whatever the round trip.
- **Device tunnel:** such a path starts no higher than balanced.
- **Rate evidence:** the delivery rate leaves out the stream's first 0.5 s (the session's first keyframe; a longer warm-up kept new sessions at their first guess longer, and over the emulated DERP relay balanced then overran the relay's queue), counts frames of 4 packets or more (over Tailscale, 4-7-packet frames measured the same rate as larger ones, and at minimal they keep coming: 463 in 80 s), and needs 5 frames and 40 KB instead of 100 KB.
- **Pointer (client):** absolute moves go on the unreliable channel with one retransmission instead of none (no FORWARD-TSN per message; a lost last position arrives after all, while a lost move holds the ones behind it for about 1.25 round trips instead of about one), and off a LAN at most 60 a second, the newest last. A button change never waits and sends a waiting move first; wheel and relative reports do too. About 100 moves a second now cost the device 41 % instead of 71 %.
- **Region refreshes stay on:** with the client planning refreshes, a level's still QP off a LAN path goes no higher than one below its floor (minimal keeps its refresh off; a LAN path, where the client also sends whole-frame refreshes, keeps the budget's verdict).
- **Emulator:** an encoder with its peak at its target codes at the target (CBR); the model coded such frames at its coarsest.
- **Tools:** the latency probe's window floats and lets the pointer pass through (so do self-tests'), the probe counts as a test run (no library or update checks; it reads a saved device's password), `--quality` sets the level for a window, and the report has each sample's send time (`sent_unix`). `latency_motion.html`, `keylog_server.py`, `motion_score.py`.

### Results

Over Tailscale with scroll bursts, automatic quality, in the app (80 samples each; BENCHMARKS.md has the tables):

| | Before | After |
|---|---|---|
| Key → decoded, median / p90 | 107.8 / 194 ms | **98.0 / 124 ms** |
| Key → screen, median / p90 | 120.9 / 206 ms | **112.2 / 156 ms** |
| Levels | high, minimal (from the first keyframe), low, balanced | balanced, low, balanced; peak 1.8-2.4 Mbit/s |
| PSNR-Y moving / still | 41.7 / 43.5 dB | 40.1 / 44.4 dB |

Repeated with the final build, interleaved with the old helper (60 samples each): after 92 / 110, 93 / 127, 99 / 130 and 98 / 133 ms; before 133 / 156 ms (stuck at minimal) and 99 / 212 ms. At fixed levels the frame rate alone: minimal 117 → 89 ms, low 110 → 93 ms (median), for 1.5-2 dB on moving frames. On a still page key → decoded stays 85 ms; a single pointer move 68 → 70 ms (noise).

Emulator (`TestSlowLinkBenchmark`, scrolling content, median of 3 runs of 60 s, both builds with the corrected encoder model):

| Profile | Frames | Delay excess p95 / p99 | Longest / total freeze |
|---|---|---|---|
| LAN (no impairment) | 3598 → 3597 | 17 / 92 → 18 / 92 ms | none |
| LTE | 3585 → 3587 | 27 / 154 → 28 / 155 ms | none |
| LTE, congested | 1783 → 3579 | 365 / 670 → 259 / 691 ms | 888 / 3296 → 832 / 3206 ms |
| Hotel Wi-Fi | 1862 → 3580 | 91 / 251 → 78 / 155 ms | 503 → 504 ms |
| Tailscale DERP relay | 1078 → 3449 | 95 / 513 → 54 / 420 ms | 1316 / 1316 → 326 / 653 ms (keyframe waits 1 → 0) |

### Independent review (one round)

**Accepted and fixed:** the floating probe window passed the operator's pointer and clicks to the target (it and self-test windows now ignore the mouse); the wheel could overtake a waiting pointer move (wheel and relative reports send it first); a device tunnel at LAN round trips started at balanced without a cap (the cap now applies); the client's and the governor's ideas of a LAN differed, so on a LAN path at a longer round trip the region-refresh change would have re-enabled whole-frame refreshes the budget had ruled out (the governor now knows the path); lowering the start level for a device tunnel found later was not applied, and a sample without a selected pair flipped the tunnel flag; 4via6 addresses counted as the device's own; a release dropped the drag's last waiting move; `--quality` took any word; the probe could no longer use a saved password; the first rated sample was applied in two steps; the emulator change had no test; stale comments and an overclaim ("can't queue at any level": keyframes and refreshes are not held to the cap).

**Not adopted:** keeping 15 and 30 fps for manual low and minimal on a LAN (one ladder, no keyframe per level change; LAN automatic quality stays at maximum anyway); a 3-packet rate threshold (4 keeps the samples consistent, and minimal at 60 fps still produced them).

### Decisions (worth revisiting)

- The ladder's frame rate caps are gone (§21 had lowered the frame rate before the bitrate, for sharper moving frames): moving frames lose 1.5-2 dB at minimal and low; every change shows 20-30 ms sooner. This also applies on a LAN when someone picks low or minimal, or automatic quality steps down there.
- `deviceTunnelShare` 0.55 is measured on one device, one Tailscale version (1.104.1) and one mode (1456×920 at 90 Hz, 60 fps). A faster `tailscaled` or a direct path would let it rise.
- On a LAN, automatic quality, the peak (1.5× the target) and the pointer's rate are unchanged; pointer moves use one retransmission everywhere.

### Open

- **A direct path for the video.** With Tailscale on the JetKVM, WireGuard costs more CPU than the rest of the send path (T2), and the device's CPU, not the internet, caps the stream at about 2-2.5 Mbit/s. A WebRTC path beside the tunnel (STUN on both ends; signalling stays on Tailscale, the media is DTLS-SRTP anyway) would roughly triple the headroom. Both ends here map endpoint-independently (Tailscale's `netcheck`), so hole punching should work. It needs the firmware to take STUN servers for local sessions (today only cloud sessions do), ICE in the engine that prefers the direct pair, and a fallback to the tunnel.
- **Firmware:** a GOP counted in the channel's frames, so a frame rate change no longer costs a keyframe; frame dropping by bit budget (a leaky bucket in the capture loop), so small changes always go out at the full rate while heavy motion drops frames instead of queueing.
- **Client:** under heavy motion, decode → on screen has a p90 of 43 ms on this Mac (render start waits 26 ms in one frame of ten); still pages show none of it. To investigate on its own; it affects every link.
- **Client, pointer:** the latency probe's pointer samples showed the presented frame up to 400 ms after the decoded one (p90), with either helper; investigate with the render tail above.
- **Region refreshes off a LAN in pieces:** after a long pause the client refreshes everything that changed at once (about 100 KB for a full frame at balanced); in thirds, a keystroke would wait at most a third as long.

## Appendix A: Key sources

- `jetkvm/kvm` (`dev` @ `8f6c300`, `release/0.5.9`): https://github.com/jetkvm/kvm. REMB revert: https://github.com/jetkvm/kvm/pull/1693
- `jetkvm/cloud-api` @ `00eb00de`: https://github.com/jetkvm/cloud-api (context only; Cloud dropped)
- Upstream client: the origin repository (README)
- Regi: https://github.com/mcuelenaere/regi
- JetRemote: https://apps.apple.com/us/app/jetremote/id6778190897
- Moonlight Metal/VideoToolbox renderer: https://github.com/moonlight-stream/moonlight-qt/blob/master/app/streaming/video/ffmpeg-renderers/vt_metal.mm
- Ebiten 2.10 notes: https://ebitengine.org/en/documents/2.10.html
- Apple TN3179 (Local Network privacy): https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
- Apple TN3137 (Mac keychains): https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains
- CVE-2025-27091: https://nvd.nist.gov/vuln/detail/CVE-2025-27091
- OpenH264 binary license: https://www.openh264.org/BINARY_LICENSE.txt
