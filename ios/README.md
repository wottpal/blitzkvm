# BlitzKVM for iPhone

An authenticator for BlitzKVM's remote approvals ([`approval/PROTOCOL.md`](../approval/PROTOCOL.md)). When something on a
remote Mac needs your approval (sudo, a 1Password CLI access prompt, a macOS password dialog, the lock screen, an
agent's `blitzkvm-remote confirm`), the JetKVM's broker sends a request, and the iPhone shows a notification. Open
it, check what is asked, where, by which process chain, and that the two-digit code matches the one on the remote
computer, then approve with Face ID or deny. When the request needs a password (the remote Mac's own, or the
1Password account password), the approval can carry one stored on the iPhone, sealed to that one request.

The iPhone talks only to the relay (`relay/`, a Cloudflare Worker), never to the JetKVM. Everything it sends and
receives is a sealed box (HPKE) in a request signed with its own keys; the relay sees neither the request nor a
password.

## Requirements

- Xcode 27 or later (Swift 6 toolchain; the code builds in the Swift 5 language mode), iOS 18 or later on the
  iPhone. Face ID or Touch ID and a passcode on the device.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) only to regenerate the project (`brew install xcodegen`).
- A JetKVM with the BlitzKVM firmware's broker, a relay, and a Mac that owns the broker (BlitzKVM for macOS).

## Layout

| Path | What it is |
|---|---|
| `project.yml` | XcodeGen spec; `BlitzKVM.xcodeproj` is generated from it (both are committed) |
| `Config/` | `Base.xcconfig` (shared settings), `Local.xcconfig.example` (the signing team, copied to the gitignored `Local.xcconfig`) |
| `BlitzKVM/` | The app: `App/` (entry point, app delegate), `Model/` (session, relay transport, pairing, notifications, review content), `Views/` (SwiftUI) |
| `NotificationService/` | The Notification Service Extension: turns the relay's generic alert into the request's text |
| `Shared/` | Compiled into both: identifiers, push parsing and the notification text |
| `BlitzKVMTests/` | Unit tests (review content, notification text, pairing codes, the session without the network) |

The protocol itself (keys, rosters, requests, decisions, boxes, the relay's HTTP endpoints) is
[`apple/ApprovalKit`](../apple/ApprovalKit), a local Swift package both targets link.

## Build and sign

Signing is automatic. The team is not in the repository:

```sh
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
# set DEVELOPMENT_TEAM to the FMD Labs team ID
open ios/BlitzKVM.xcodeproj
```

With the team set, Xcode registers the App IDs `com.fmdlabs.blitzkvm` and `com.fmdlabs.blitzkvm.notifications` and
their capabilities on first build: Push Notifications (`aps-environment` development; an App Store or TestFlight
export switches it to production), App Groups (`group.com.fmdlabs.blitzkvm`, which holds the paired JetKVMs and
their rosters), Time Sensitive Notifications, and the keychain group `<team>.com.fmdlabs.blitzkvm.shared` (the
approver's keys; the extension reads the seal key from it). The app's Info.plist carries the same group as
`BKKeychainAccessGroup`; builds without a team fall back to the default keychain group.

From the command line (from the repository root):

```sh
# a device build without signing
xcodebuild build -project ios/BlitzKVM.xcodeproj -scheme BlitzKVM -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO
# the unit tests
xcodebuild test -project ios/BlitzKVM.xcodeproj -scheme BlitzKVM -destination 'platform=iOS Simulator,name=iPhone 15'
```

A destination without `OS=` means the newest runtime (`OS:latest`), so `name=iPhone 15` needs an iPhone 15
simulator on that runtime; `-showdestinations` lists what's there, or name another one (`,OS=18.4`).

After changing targets, files, settings, entitlements or Info.plist keys, edit `project.yml` and run `xcodegen` in
`ios/`; don't edit the generated project or plists by hand.

## Push notifications

The relay sends them; the app holds no secret. The relay needs the APNs key (`.p8`) of the team that signs the
app, as the Worker secrets `APNS_KEY`, `APNS_KEY_ID` and `APNS_TEAM_ID` (and `APNS_TOPIC`, default
`com.fmdlabs.blitzkvm`): see `relay/wrangler.jsonc`. Without them the relay queues boxes but pushes nothing, and
the app only sees requests while it is open.

The app registers its APNs token with each JetKVM's relay once that JetKVM admitted it (the relay refuses others):
as `sandbox` in Debug builds and `production` in Release builds. A Release build run from Xcode with a development
profile gets a sandbox token, so use Debug for local testing.

A push is an alert (Time Sensitive, category `APPROVAL`) with `{"bka":{"b":<broker>,"x":<box>}}`. The extension
opens the box with the seal key, checks the request against the roster the app saved in the App Group, and shows
"<computer>: <title>" and "Code <code> · <kind>"; anything that doesn't check out keeps the relay's generic text.
**Deny** works from the notification (the transport key signs it; iOS asks to unlock first). Approving always
happens in the app, because Face ID can't run in an extension.

## Pairing

1. On a Mac that owns the JetKVM, BlitzKVM shows a pairing code (QR, `blitzkvm-pair:…`), valid for 5 minutes.
2. In the app: Devices › + (or Pair JetKVM), scan it or paste it. Opening a `blitzkvm-pair:` link (the Camera app)
   opens the same sheet. Check the JetKVM's name, name this iPhone, and Pair.
3. The app enrolls through the relay (`/enroll`), asks to send notifications, and waits: the owner's Mac shows the
   iPhone's name and admits it by signing a new roster. The roster arrives in the iPhone's outbox; only the owner
   whose code was scanned can sign the first one the iPhone accepts.
4. The app registers its APNs token with the relay. Done.

A JetKVM without a relay can't be paired with an iPhone; the app says so. Removing a JetKVM in the app forgets it
here (and the passwords of its computers); to stop requests reaching the iPhone, an owner removes it from the
approvers on their Mac.

## Approving

One Face ID per approval: the app evaluates an `LAContext`, then uses it for the Secure Enclave presence key
(which signs the approval) and, when a password is attached, for the vault key that unseals it. The presence and
vault keys need the currently enrolled Face ID (`.biometryCurrentSet`): enrolling another face invalidates them.
"Approve for 10 Minutes" is offered only when the ask is grantable. While a request is open, the app polls the
relay every 3 seconds (every 10 seconds on the request list), on launch, on returning to the foreground and on a
notification tap.

Passwords are stored per computer and kind (Mac password, 1Password password) in `SecretVault`, after a Face ID,
in Settings or the first time a request asks for one.

## Simulator

The Simulator reports a Secure Enclave but refuses to create keys in it, so Debug builds on the Simulator use
software keys and a software vault (the app shows "Development Keys"). Face ID is asked only when enrolled
(Features › Face ID). Launch with `-demo` (Debug, Simulator) for a paired JetKVM with two open requests in memory,
without a network: add `-demo-open 0` (or `1`) to open a review, `-demo-screen devices` or `settings` for a tab.
