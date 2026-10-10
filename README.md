# jetkvm-desktop (wottpal fork)

A native macOS client for [JetKVM](https://github.com/jetkvm/kvm) devices, built to replace Jump Desktop for daily remote work: several devices, reached over a LAN or any VPN (Tailscale is the reference), in long, latency-sensitive sessions.

This repository is a private fork of [lkarlslund/jetkvm-desktop](https://github.com/lkarlslund/jetkvm-desktop). It contains:

- **The native macOS app** (`macos/`): Swift/AppKit, VideoToolbox decoding, Metal rendering. It runs one Go helper process per device. This is the product.
- **The Go engine** (`pkg/`, `cmd/jetkvm-engine`): the JetKVM protocol, session lifecycle, video assembly and input, shared by both clients.
- **The legacy Ebiten client** (`cmd/jetkvm-desktop`, `pkg/app`, `pkg/ui`): upstream's cross-platform UI. It still builds and serves as a manual test client; it gets no new features and will be retired.
- **A firmware-faithful emulator** (`pkg/emulator`, `test/emulator-serve`): a fake JetKVM that behaves like firmware 0.5.9, so everything can be tested without touching real hardware.

The engineering plan, roadmap, decisions and the execution report live in [`plans/2026-10-10-engineering-plan.md`](plans/2026-10-10-engineering-plan.md). Read §19–§20 for the current status before planning new work.

## Scope

| Path | What it is |
|---|---|
| `macos/` | SwiftPM package and Makefile for the app. `Sources/JetKVMCore` holds testable logic (wire protocol, device library, key mapping, geometry, certificate pinning, serial text filter); `Sources/JetKVMDesktop` holds the AppKit/SwiftUI app; `Tests/` holds the unit tests. |
| `cmd/jetkvm-engine` | The helper the app launches per device. It speaks `pkg/engineipc` over stdin/stdout and logs to stderr. |
| `cmd/jetkvm-desktop` | The legacy Ebiten client. |
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
| `make test-timing` | Timing-sensitive tests that skip themselves under `-race` (NACK loss repair) |
| `make vet` / `make vulncheck` | `go vet`; govulncheck |
| `make generate` | Regenerates the enumer files (`*_enums.go`) |
| `make generate-check` | Regenerates, then fails if `git diff` is not empty, so it also fails on any uncommitted change |
| `make check` | Everything fork CI runs: vet, generate-check, race tests, timing tests, govulncheck, OpenH264 tests, Swift tests |
| `make layouts UPSTREAM=../kvm` | Regenerates `pkg/input/layouts_gen.go` from a `jetkvm/kvm` checkout |
| `make emulator` | Runs the emulator on `http://127.0.0.1:8080` (no password) |
| `make -C macos app` | Builds and signs `macos/build/JetKVM Desktop.app`; a signed build is also copied to `~/Downloads` |
| `make -C macos test` | Swift unit tests (`JetKVMCoreTests`) |
| `make -C macos selftest` | End to end: the app against the emulator (video, injected input, helper crash recovery) |
| `make -C macos selftest-extras` | End to end over http and https: virtual media (upload, mount, eject, delete), serial console, address probing with certificate pins |
| `make -C macos run DEVICE=jetkvm.local` | Builds and opens the app connected to a device |
| `make -C macos install` | Copies the app to `/Applications` |
| `make -C macos notarize` | Notarizes with the Xcode account and staples; leaves `macos/build/JetKVM-Desktop.zip` (see Signing) |

Focused checks, by what you changed:

- When you edit `pkg/emulator`, `pkg/client`, `pkg/session` or `pkg/engine`, run `go test -race -count=1 ./pkg/<package>`. If you touched video, NACK or netem code, also run `make test-timing`.
- When you edit `macos/Sources/JetKVMCore`, run `make -C macos test`.
- When you edit `macos/Sources/JetKVMDesktop`, `pkg/engineipc` or engine commands, run `make -C macos selftest` and `make -C macos selftest-extras`.
- Before you push, run `make check` (or its steps individually while the tree is dirty, since `generate-check` needs a clean tree).

A passing self-test prints a JSON report and ends with `selftest passed: …`. Any other ending is a failure.

## Using the app

Open `~/Downloads/JetKVM Desktop.app` (or `/Applications/` after `make -C macos install`). The Devices window (⌘N) holds the device library: a name, an ordered list of addresses (LAN IP, `.local` name, VPN name; `https://…` for TLS) and per-device preferences. Addresses are probed over HTTP in parallel and the earliest that answers wins; probing never opens a WebRTC session, because that would take over an existing one.

Features: Retina-sharp video (fit, 1:1, integer scaling; fit window to remote screen), keyboard capture including system shortcuts (⌃⌘ releases), Mac/PC modifier profiles, paste as keystrokes (⌥⌘V), power control (ATX/DC), virtual media (⇧⌘M), serial console (⇧⌘L), extension port switching, H.264 by default with H.265 per device, several devices as tabs.

Permissions: grant Accessibility to capture system shortcuts. macOS also asks for Local Network access on first use.

Command-line options (also used by the self-tests):

| Option | Meaning |
|---|---|
| `--device <address>` | Connect to an address instead of showing the device library |
| `--view-only` | Never send keyboard or mouse input |
| `--h264` / `--h265` | Override the codec offer |
| `--scale fit\|actualSize\|integer`, `--profile mac\|pc`, `--window-size 1280x720` | View and input overrides |
| `--selftest <seconds>` and `--crash-engine-after`, `--inject-input`, `--exercise-extras`, `--snapshot <png>` | Self-test mode (prints JSON, exits 0 on success) |

Environment: `JETKVM_DEVICE` and `JETKVM_PASSWORD` stand in for `--device` and a password. `JETKVM_ENGINE` points at a helper binary for development. `JETKVM_DESKTOP_LOG_LEVEL` (error, warn, info, debug, trace) sets Go logging in the helper.

Where things live:

- Device library: `~/Library/Application Support/JetKVM Desktop/devices.json`.
- Passwords: the login keychain, service `xyz.scio.jetkvm-mac`, account = the device's ID (the entry's UUID until the ID is learned on first connect).
- Logs: `~/Library/Logs/jetkvm-desktop/app.log` holds app messages and each helper's stderr. The legacy client writes `jetkvm-desktop.log` there when not started from a terminal.

## Architecture

```
JetKVM Desktop.app (Swift)                          one helper per device
  DeviceWindowController ── VideoDecoder (VideoToolbox) ── VideoView (Metal)
  InputController, VirtualMediaWindow, SerialConsoleWindow
        │  length-prefixed frames over stdin/stdout (pkg/engineipc ⇄ EngineProtocol.swift)
        ▼
  jetkvm-engine (Go): engine → session.Controller → client.Client
        │  HTTPS/HTTP login, WebSocket signaling, WebRTC (H.264/H.265 RTP; data channels rpc, hidrpc, serial)
        ▼
  JetKVM device (firmware 0.5.9)        or        pkg/emulator for tests
```

Invariants that changes must keep:

- **Input only after identity is confirmed.** The session is `connected`, the only phase that accepts input, only after the device ID matches the pinned one. That check happens before login when the device answers `GET /device` without a password, otherwise over RPC right after login. A device ID learned on first connect pins later reconnects.
- **HTTPS trust on first use.** `pkg/protocol/tlspin` pins the device CA that the presented chain is signed up to (the firmware issues a leaf per hostname, signed by a device CA it sends along). Publicly trusted devices are pinned to public trust (`webpki`). A change stops the session before any password is sent; the app offers "Trust New Certificate". The Swift probe (`CertificatePin.swift`) mirrors these rules.
- **Video:** the engine assembles RTP into access units (`pkg/video`) and forwards them; when the app falls behind, it drops to the next keyframe rather than queueing. New devices offer H.264 only; JetKVM picks H.265 whenever the offer contains it.
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

`make -C macos notarize` notarizes with the Apple ID signed into Xcode (Settings → Accounts, team `79UD4HPFRD`); it needs no app-specific password or API key. `macos/scripts/notarize.sh` wraps the signed app in a minimal Xcode archive, uploads it with `xcodebuild -exportArchive`, and waits until Apple has processed it (usually a few minutes). It then fetches the stapled app with `xcodebuild -exportNotarizedApp` and leaves `macos/build/JetKVM-Desktop.zip`, also copied to `~/Downloads`. Notarizing publishes the build to Apple, so only do it when the owner asks for a shareable build.

## Troubleshooting

- **`external macro implementation type 'SwiftUIMacros…' could not be found`:** you ran `swift build` with the Command Line Tools. Build through `make -C macos …`, which selects Xcode.
- **Emulator-backed tests time out in ICE:** set `ICELoopbackOnly: true` on both the emulator config and the client or session config.
- **`make generate-check` fails right after editing:** expected. It requires a clean tree; commit first or run the other `check` steps directly.
- **A device shows "not reachable" although it is up, and it uses https:** its certificate may have changed. Choose Try Anyway to see the certificate alert and decide whether to trust the new one.
- **Screenshots of app windows come out empty or fail:** the capturing process needs Screen Recording permission.
- **staticcheck:** not used. It cannot read go1.27 export data yet.

## Legacy Ebiten client

Upstream's client still builds and works against devices and the emulator. It finds devices on the local network, connects by hostname, mDNS name or IP, and shows video, input, stats and the core settings in one window.

```bash
go run ./cmd/jetkvm-desktop                    # launcher with discovery
go run ./cmd/jetkvm-desktop jetkvm.local       # connect directly
go run ./cmd/jetkvm-desktop --password-stdin 192.168.1.50 < password.txt
```

Flags: `--password-stdin`, `--password-env NAME` (default `JETKVM_PASSWORD`), `--log-level`, `--rpc-timeout`. Its experimental USB-network settings UI is hidden unless `JETKVM_DESKTOP_ENABLE_EXPERIMENTAL_USB_NETWORK=1`. Screenshots: [`docs/launcher.png`](docs/launcher.png), [`docs/settings.png`](docs/settings.png).

## Related docs

- [`plans/2026-10-10-engineering-plan.md`](plans/2026-10-10-engineering-plan.md): read before changing architecture, roadmap or a recorded decision.
  - §4.2: verified firmware behaviour.
  - §6: roadmap.
  - §17: decision log.
  - §19: implementation status.
  - §20: execution report (divergences, takeaways).
- [`third_party/openh264-go/README.md`](third_party/openh264-go/README.md): the vendored OpenH264 bindings.
- Firmware source: [github.com/jetkvm/kvm](https://github.com/jetkvm/kvm). Upstream develops on `dev`; releases are on `release/X.Y.Z` branches.

License: MIT (see [`LICENSE`](LICENSE)).
