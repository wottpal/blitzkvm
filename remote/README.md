# blitzkvm-remote

The target side of BlitzKVM's remote approvals ([`approval/PROTOCOL.md`](../approval/PROTOCOL.md)): what runs on the Mac a JetKVM controls, so that `sudo`, a script's question, a 1Password CLI prompt, a macOS password dialog or the lock screen can be approved from the owner's iPhone or Mac while nobody sits at it. The broker on the JetKVM (firmware D20, `approval/broker`) carries the asks to the approvers and, for screen asks, presses keys and clicks through the JetKVM's USB keyboard and pointer, which are the only input this Mac gets.

## Pieces

| Path | What it is |
|---|---|
| `blitzkvm-remote/` | Swift package, one binary with four modes. `Sources/RemoteCore` holds all logic (unit tested); `Sources/blitzkvm-remote` holds the modes and the agent's AppKit calls. Uses `apple/ApprovalKit` for the protocol's types. |
| `pam/` | `pam_blitzkvm.so` (C, no crypto, no JSON) and a test harness that needs neither root nor sudo. |
| `install/` | `install.sh`, `uninstall.sh` and the two launchd plists. The BlitzKVM app uploads them and runs the scripts as root (`sudo -S` over SSH on the USB link). |

Modes of `blitzkvm-remote`:

- **`daemon`** (root LaunchDaemon `xyz.scio.blitzkvm.remote`): holds the target key (`target.key`, 0600) and the roster, keeps the link to the broker (`[fe80::…%enX]:4023`, the interface found by its MAC `02:4a:4b:00:00:02`, the address from `link.json`), serves the local socket `/var/run/blitzkvm-remote.sock`, signs asks, checks every decision itself with `VerifiedRequest.verify` against its own roster, and drives the screen for approved screen asks. It takes an agent only when the agent's signature has the daemon's own Team ID and the identifier `xyz.scio.blitzkvm.remote`; a daemon without a Developer ID trusts no agent, so screen asks are unavailable, unless `--insecure-agent` (tests only, logged as a warning) says otherwise. `--print-identity` and `--install-roster FILE` are the installer's one-shot actions.
- **`agent`** (LaunchAgent `xyz.scio.blitzkvm.remote.agent`, Aqua sessions): reports what the session shows, twice a second and only when it changed: the frontmost app, windows at layer 101 (owner and bounds) and SecurityAgent's dialog windows, the main display's size, the input source and its key map, Caps Lock. Brings an app back to the front when the daemon asks. With `KeepOnePasswordRunning` set in its user defaults (domain `xyz.scio.blitzkvm.remote`; Keep 1Password Running (Device Settings › Remote Computer › Approvals) sets it over SSH, no sudo), it opens 1Password again in the background a few seconds after it quits, at most every 30 s, and only the app whose signature is 1Password's.
- **`confirm "QUESTION" [--grant] [--timeout 120] [--detail TEXT]`**: for scripts and agents. Prints `BlitzKVM: approve on your iPhone or Mac (code 47)…` to stderr; exits 0 approved, 1 denied, 2 no answer or unavailable.
- **`pam --user U --service S --tty T --pid P`**: run by the PAM module inside sudo. Lines it prints reach the terminal; exit 0 only on a verified approval, 3 at once while the installer's `maintenance` flag exists.
- **`maintain < ORDER`**: hands an owner's signed update or removal order (below) to the daemon; the BlitzKVM app runs it as the user over clipboard sync's login. Exits 0 once the daemon runs the order, 1 when it refused it (the line says why), 2 when it takes no orders.

## What it needs

Nothing from the user but the install: no Accessibility, Screen Recording, Automation or Input Monitoring, and no prompt ever. The agent reads only what macOS gives any app (NSWorkspace, window owners and bounds without names, display bounds, the input source's layout data); the daemon reads secure input and the lock state from the IORegistry (`IOConsoleUsers`) and checks code signatures. A test fails if the sources use an API that would ask (`AXUIElement`, `CGEventPost`, Apple Events, screen capture).

## Threat model

- A user-level process can request (`confirm`, sudo through PAM), never approve: only a decision signed by an approver in the daemon's roster, for the daemon's own ask, within its time, counts.
- The broker is checked too: the daemon verifies the request around its ask (the broker's signature and a byte-identical ask) and each decision itself.
- Typing happens only on evidence root checked right before each step: the process holding secure input, identified by its code signature (1Password's Developer ID, Apple's SecurityAgent or loginwindow), and the lock state; window facts count only from an agent signed like the daemon.
- While the broker types a secret, the daemon reads secure input itself every 20 ms and aborts the step the moment the holder or the lock changes; it erases what the broker reports typed only while that field still has the keyboard.
- The PAM module runs only a binary that root owns in directories only root can change, and falls back to the password on anything but a verified approval.
- Updates and removal need no password: an owner orders them (below), and the daemon checks the order and every file itself.
- Not covered: the first install (and an update or removal of a daemon from before orders). The app runs `install.sh` and `uninstall.sh` over clipboard sync's SSH login, as the user, with `/usr/bin/sudo -S` and the Mac password on stdin; the user's login shell starts that command and reads its startup files (`~/.zshenv`) first. Anything already running as that user can change those files, or the key's line in `~/.ssh/authorized_keys`, and so read the password or swap the target key the owner signs. Install on a Mac whose user account you trust, as you would type the password there yourself.

## How it works

**sudo:** `/etc/pam.d/sudo_local` starts with `auth sufficient /usr/local/lib/pam/pam_blitzkvm.so`. The module runs `blitzkvm-remote pam` with sudo's pid; the daemon accepts a `pam` request only from a root peer (`LOCAL_PEERCRED`), builds the requester chain from that pid (at most 8 processes: name, path, arguments, signer), titles the ask with sudo's command line, and waits up to 120 s (the module gives `blitzkvm-remote pam` 130 s, which gives up after 125 s).

**Grants:** an approval "for 10 minutes" of a `sudo` or `confirm` ask lets the same user, under the same anchor, from the same terminal (tty) and audit session, skip asking for that kind for 10 minutes. The anchor is the nearest ancestor that isn't a shell or wrapper (`zsh`, `sudo`, `env`, `sshd`…), by pid and start time. Terminal emulators and multiplexers (Terminal, iTerm2, Ghostty, WezTerm, Alacritty, kitty, Warp, Hyper, tmux, screen, zellij) are never anchors, since every tab would share the grant: a chain that reaches one, or launchd, first isn't grantable and is approved once. Grants live in memory only.

**Screen asks**, acted on with steps after an approval:
- `onepassword`: a layer-101 window of about 400×346 points (unlocked) or 400×402 (locked: the prompt shows 1Password's password field) owned by a process signed by 1Password (Team ID `2BUA8C4S2C`) appears; one ask per window, for 60 s (1Password closes its prompt after about a minute). 1Password doesn't say who asked: the newest `op` run from a shell by a binary signed by 1Password appears in the detail as "Probably requested by: …", never as the ask's requester. Approved, unlocked: a click on its default button (bottom right, 77/61 points in), never a Return (the prompt doesn't take the keyboard). Locked, and only then does the ask take the 1Password password: a click on the prompt (its title, then its field) until 1Password holds secure input, then the password and Return. The app that was in front gets the front back.
- `securityagent`: secure input is held by Apple's SecurityAgent while exactly one of its dialog windows shows, for the console user. The ask says only that (which app opened the dialog isn't known) and is bound to that window: another dialog, or a second one, ends it. Approved: the Mac password, Return, and the dialog must let go of the keyboard.
- `unlock`: an approver asked to unlock, and the screen is locked (secure input, if held, by loginwindow) for the console user the request was made for. Approved: a Shift tap to wake, the password once loginwindow holds secure input, Return, and the screen must unlock.

Before every step the daemon reads fresh evidence (its own console read, the agent's facts) and gives up when the screen isn't what was approved. The broker types a secret character by character and reports how many it typed (`typed`); on any change of the secure-input holder or the lock the daemon sends `abort`, then erases exactly `typed` characters if the field still has the keyboard, and fails the request. Secrets are padded, so their length is never known here. An undecided screen ask is withdrawn when its prompt has been gone for 2 s.

**Display safety:** everything from processes that goes into an ask's title or detail, or to a terminal (arguments, paths, names, the confirm question, the broker's reasons), shows control characters as escapes (`\n`, `\t`, `\x1b`), bidi controls as `\u{202E}`, shell-quotes arguments with spaces or quotes, and marks truncation with `…(truncated)`.

**Local socket:** at most 32 user connections at once (root's, the PAM module's client, always get through), each closed if it says nothing for 5 s or sends a second line, at most 3 open asks and 8 asks a minute per user. A `pam` request's user is the one sudo names, looked up by name.

Asks wait 120 s (the protocol's longest), 1Password's 60 s; `confirm --timeout` can shorten it to 10 s.

**Key map:** for every printable ASCII character, the plainest strokes on the active input source (`UCKeyTranslate` with no modifier, Shift, Option, Shift+Option; a character only a dead key types is the dead key, then Space), as HID usages for the JetKVM's keyboard. On a keyboard macOS treats as ISO, the usages of the two keys it swaps (§ and `) swap too. The daemon drops a map from the agent unless every entry is one character typed by one or two character strokes (usages 0x04–0x27, 0x2C–0x38 or 0x64, with Shift and Option at most), the broker's `wire.CharStroke`.

## Updates and removal

Once installed, the remote side updates and removes itself on an owner's order, with no password and no sudo:

1. The app stages the files as the user (as for an install) and signs a `maintain` order with its owner key (one Touch ID): the broker and target, `update` or `remove`, a nonce, the time, the staging directory and each file's SHA-256 (all six for an update, `uninstall.sh` for a removal). `blitzkvm-remote maintain` hands it to the daemon over the local socket.
2. The daemon takes it only from an owner in its own roster, signed with that owner's presence key, for this target, within 60 s of its clock, and once (nonce). It copies each named file (a plain file, no link) into a new directory only root can change, checks its hash there, and checks that the new `blitzkvm-remote` and `pam_blitzkvm.so` are signed with its own Team ID and identifiers. A daemon without a Developer ID takes no orders.
3. It writes `running` to `maintain.status` and starts a launchd job of its own (`xyz.scio.blitzkvm.remote.maintain`), so its own restart doesn't stop the job. The job runs `install.sh --update` (keeps the roster, link.json and whether sudo approvals are installed) or `uninstall.sh` from that directory, then writes `done` or `failed: …` to `maintain.status` (a removal leaves no state directory) and appends its output to the log.

The app reads `maintain.status` to report the outcome. A daemon from before orders answers that it takes none, and the app falls back to the password path.

## Files

| Where | What |
|---|---|
| `/Library/Application Support/BlitzKVM/Remote/` | `blitzkvm-remote`, `target.key`, `roster.json`, `link.json`, `maintenance` (installer only), `maintain.status` (the last order's outcome) |
| `/usr/local/lib/pam/pam_blitzkvm.so`, `/etc/pam.d/sudo_local` | sudo approvals (`install.sh --no-sudo` leaves them out) |
| `/Library/LaunchDaemons/xyz.scio.blitzkvm.remote.plist`, `/Library/LaunchAgents/xyz.scio.blitzkvm.remote.agent.plist` | launchd jobs |
| `/Library/Logs/BlitzKVM/remote.log` | the daemon's log; both also log to the unified log (subsystem `xyz.scio.blitzkvm.remote`) |

Install: `install.sh --identity STAGE` installs the binary and prints `{"id":…,"key":…}`; the app puts that target into a genesis roster an owner signs, then `install.sh STAGE` installs the rest. `uninstall.sh` reverses it, writing the maintenance flag first. The app's root step runs with stdin closed after `sudo` read the password, copies only plain files (no symlinks) out of the staging directory into a root-only one and checks their hashes there; `install.sh` checks that the PAM module is a 64-bit Mach-O bundle before it adds the `sudo_local` line, and keeps the log 0600.

## Build and test

```sh
make -C remote test   # Swift tests, the PAM harness, sh -n/shellcheck/plutil on install/
make -C remote        # release build in remote/build/, signed (identifier xyz.scio.blitzkvm.remote)
```

The daemon checks the agent's signature against its own Team ID; an ad hoc build (`SIGN_IDENTITY=-`) trusts no agent, so screen asks need `--insecure-agent` there (tests only). Without root, everything runs in `--user-mode` (state and socket in `~/Library/Application Support/BlitzKVM/Remote`, or `--state DIR`), against any broker given with `--link HOST:PORT`, for example the emulator's approvals link (`pkg/emulator`, `ApprovalsLink`):

```sh
blitzkvm-remote daemon --user-mode --state /tmp/bkr --print-identity
blitzkvm-remote daemon --user-mode --state /tmp/bkr --install-roster genesis.json
blitzkvm-remote daemon --user-mode --state /tmp/bkr --link 127.0.0.1:4023 &
blitzkvm-remote confirm "Deploy to staging?" --grant --user-mode --state /tmp/bkr
```

The tests run the daemon against a fake broker on localhost (handshake, requests, every kind of bad decision, grants, the peer check), the screen driver against scripted evidence (aborts, erasing), the key map against the U.S. and German layouts, and the 1Password detection against canned window lists.
