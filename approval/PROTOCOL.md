# Approval protocol v1

Remote approvals: a request on the remote computer (sudo, `blitzkvm-remote confirm`, a 1Password access prompt, a
password dialog, the lock screen) reaches the owner's approvers (iPhone, BlitzKVM on a Mac), who approve with Face ID
or Touch ID. The **broker** on the JetKVM (firmware D20, `approval/broker`) queues requests and drives the JetKVM's
keyboard and pointer; the **target daemon** on the remote computer (`remote/blitzkvm-remote`, root) observes the
screen state, signs asks and checks decisions; **approvers** sign decisions; the **relay** (`relay/`, a Cloudflare
Worker) carries sealed boxes and push notifications. Go (`approval/wire`), Swift (`apple/ApprovalKit`) and TypeScript
(`relay/src/wire.ts`) implement this file; `approval/testdata/vectors.json` pins it.

## Encoding

- `b64`: base64url without padding (RFC 4648 §5). Decoders reject padding and the standard alphabet.
- Public keys: P-256, X9.63 uncompressed (65 bytes, `04 || X || Y`), as `b64`.
- `kid(key)`: lowercase hex of the first 12 bytes of SHA-256 of the X9.63 bytes (24 characters).
- Times: Unix seconds. Nonces: 32 random bytes, `b64`.
- JSON objects are decoded strictly: unknown fields are ignored, missing required fields fail.

## Envelope (signed JSON)

```json
{"t": "<type>", "k": "<kid of the signing key>", "p": "<b64 payload JSON bytes>", "s": "<b64 signature>"}
```

- Signed message: the UTF-8 bytes of `"BKA1 " + t + "\n"`, then the payload bytes.
- Signature: ECDSA P-256 with SHA-256 over the signed message, raw `r || s` (64 bytes, big-endian, each 32 bytes).
  Verifiers accept any valid signature (no low-S rule). Security.framework and Go's `ecdsa` use DER: convert.
- `digest(env)`: SHA-256 of the signed message (not of the signature), lowercase hex where it appears in JSON.
- Verifiers parse the payload only after the signature verifies, and only from `p`: what was signed is what is read.
- Types: `roster`, `ask`, `request`, `decision`, `link`, `hello`, `pairing`, `enroll`, `relay`, `unlock`, `screen`.

## Box (HPKE, RFC 9180)

- Suite: DHKEM(P-256, HKDF-SHA256) `0x0010`, HKDF-SHA256 `0x0001`, AES-256-GCM `0x0002`, base mode, single shot.
- `box = enc (65 bytes) || ciphertext`, as `b64`.
- Messages: info `"BKA1 box"`, aad = the UTF-8 recipient kid (its seal key's kid).
- Secrets: info `"BKA1 secret"`, aad = the 32 raw bytes of the request digest. The plaintext is the secret's UTF-8
  followed by zero bytes up to a multiple of 64 (at least 64), so a box doesn't tell a password's length; the broker
  strips the zeros.

## Roster (`t = "roster"`)

The trust state of one broker, signed by an owner's presence key.

```json
{"v": 1, "seq": 3, "issued": 1793500000,
 "broker": {"id": "<kid>", "key": "<b64>", "seal": "<b64>"},
 "relay": "https://… (optional)",
 "owners": ["<approver id>"],
 "approvers": [{"id": "<kid(presence)>", "name": "Dennis' iPhone", "platform": "ios|macos",
                "presence": "<b64>", "transport": "<b64>", "seal": "<b64>"}],
 "targets": [{"id": "<kid(key)>", "name": "Mac mini", "key": "<b64>"}]}
```

- An approver's id is `kid(presence)`. `owners` is a non-empty subset of the approver ids. At most 64 approvers.
- `broker.id == kid(broker.key)`, `target.id == kid(target.key)`.
- **Accepting a roster:** its signer must be an owner of the roster currently held (`k` is that owner's presence
  kid and the signature verifies with it), and `seq` must be greater. A first roster (genesis) arrives only through
  an authenticated setup path (the identity-pinned JetKVM session; the root installer) and must be signed by one of
  its own owners. Revoking an approver is a roster without it.

## Ask (`t = "ask"`, signed by the target key)

```json
{"v": 1, "id": "<32 hex>", "target": "<kid>", "kind": "sudo|confirm|onepassword|securityagent|unlock",
 "title": "sudo shutdown -r now", "detail": "…",
 "requester": {"uid": 501, "user": "user", "tty": "ttys003",
               "chain": [{"pid": 4242, "name": "sudo", "path": "/usr/bin/sudo", "args": ["sudo", "…"],
                          "signer": "apple|developer:<team>|adhoc|unsigned"}]},
 "evidence": {"locked": false, "secureInput": {"pid": 7000, "bundle": "com.1password.1password",
              "team": "2BUA8C4S2C"}, "window": {"x": 552, "y": 219, "w": 400, "h": 346}, "display": {"w": 1504, "h": 948}},
 "secret": "none|mac|onepassword", "grantable": true,
 "nonce": "<b64>", "issued": 1793500000, "expires": 1793500060}
```

- `chain` starts at the requesting process and follows parents (at most 8).
- `requestedBy` (an approver id): on `unlock` asks, always, and on no other kind: the approver whose signed unlock
  request raised it.
- `expires - issued` is at most 120 s.
- **Matching code:** two decimal digits, `((d[0] << 8) | d[1]) % 100` of the ask digest's bytes, zero-padded.
  The target shows it where the request was made (the terminal); approvers show it next to the request.

## Request (`t = "request"`, signed by the broker key)

```json
{"v": 1, "ask": {"t": "ask", …}, "seal": "<b64 ephemeral P-256 key-agreement public key>",
 "issued": 1793500000, "expires": 1793500060}
```

- The request's id is its ask's id. `seal` is a key the broker made for this request alone, for the secret.

## Decision (`t = "decision"`)

```json
{"v": 1, "request": "<hex digest(request)>", "ask": "<hex digest(ask)>", "decision": "approve|deny",
 "grant": 10, "approver": "<approver id>", "issued": 1793500010, "secret": "<b64 box, optional>"}
```

- `approve` is signed by the approver's **presence** key; `deny` by its presence or **transport** key.
- `grant` (minutes, 0 or 10) only when the ask is `grantable` and the decision approves.
- `secret` only when the ask's `secret` isn't `none`, sealed to the request's `seal` key.
- **Checks (broker and target):** the approver is in the roster; the signer key is allowed for the decision; both
  digests match; `issued` is within ±60 s of the checker's clock (the broker only while its clock is synced); the
  ask hasn't expired; the first valid decision for a request wins, any later one is ignored.

## Link: target daemon ↔ broker

TCP on the host link (the JetKVM's link-local address, port 4023; the emulator listens on 127.0.0.1). One JSON object
per line, at most 64 KiB. One authenticated daemon connection at a time; a newer one replaces it.

| Direction | Message |
|---|---|
| B→D | `{"op":"hello","broker":kid,"nonce":b64}` |
| D→B | `{"op":"auth","auth":env}` with `t = "link"`, payload `{"v":1,"broker":kid,"target":kid,"nonce":b64,"issued":n}`, signed by the target key |
| B→D | `{"op":"ready","roster":env}` (the broker's roster) |
| D→B / B→D | `{"op":"roster","roster":env}`: a newer roster; the receiver accepts it under the roster rule |
| D→B | `{"op":"ask","ask":env}` → B→D `{"op":"request","request":env}` or `{"op":"rejected","id":…,"reason":…}` |
| B→D | `{"op":"decision","id":…,"decision":env}` |
| D→B | `{"op":"cancel","id":…}` (the requester went away) |
| D→B | `{"op":"step","id":…,"seq":n,"step":{…}}` → B→D `{"op":"stepped","id":…,"seq":n,"ok":bool,"error":…}` |
| D→B | `{"op":"done","id":…,"ok":bool,"note":…}` |
| B→D | `{"op":"unlock","unlock":env}`: an approver's unlock request (below), which the daemon checks against its own roster (the approver's transport key, broker, target, `issued` within ±60 s, a nonce it hasn't seen, one per approver every 30 s) before it raises an `unlock` ask naming the approver |
| both | `{"op":"ping"}` / `{"op":"pong"}` every 15 s |

Steps, for approved asks of kind `onepassword`, `securityagent` and `unlock` only, within 60 s of the approval. The
daemon sends the next step only after the previous one's `stepped`; `{"op":"abort","id":…}` stops the running step at
once (between characters), and it answers `ok: false`. From the approval of such an ask until it ends (`done`, a
failure, the link closing), the broker holds the JetKVM's other input: keyboard and pointer reports of its sessions
are dropped, so nothing lands between the steps or between the characters of a secret.

- `{"click":{"x":0.70,"y":0.55}}`: an absolute pointer click, as fractions of the JetKVM's display.
- `{"keys":[[hid, mods], …]}`: key strokes (HID usage, modifier byte), only Return, Escape, Tab, Backspace, Shift
  and Caps Lock (no secret can travel this way).
- `{"secret":{"map":{"a":[[hid,mods]], "^":[[hid,mods],[44,0]], …}}}`: types the decision's secret with the
  target's key map (the active input source's strokes per character); once per request. Each character has one or two
  strokes (a dead key, then its base), each a character key (`0x04`–`0x27`, `0x2C`–`0x38`, `0x64`) with Shift
  (`0x02`, `0x20`) and Option (`0x04`, `0x40`) at most. The broker refuses a map that breaks this, or a secret with a
  character the map lacks, before typing anything. Its `stepped` carries `"typed": n`, the characters it typed (also
  after an abort or a failure), so the daemon erases exactly those.
- `{"erase":n}`: n Backspaces (the daemon's abort after a partial secret).

## Approvers ↔ broker

Direct: a WebSocket at `ws://<device>/approvals/v1/ws` (the JetKVM's own address; no cookie). Through the relay: the
same messages, wrapped (below). Each WebSocket message is one JSON object.

1. B→A `{"op":"hello","broker":kid,"nonce":b64}`
2. A→B `{"op":"auth","auth":env}` with `t = "hello"`, payload `{"v":1,"broker":kid,"approver":id,"nonce":b64,
   "issued":n}`, signed by the approver's transport key. A device that isn't an approver yet may instead send
   `{"op":"box","box":…}` carrying one `enroll` message.
3. B→A `{"op":"ready"}` once the auth checks out; the approver sends boxes only after it.
4. Then only `{"op":"box","box":b64}`, sealed to the recipient's seal key (the approver's, or the broker's from the
   roster). Inside, one JSON message:

| Direction | Message |
|---|---|
| B→A | `{"op":"roster","roster":env}`, `{"op":"request","request":env}` (a repeat to an iPhone adds `"repeat":n`, below), `{"op":"screen","screen":env,"jpeg":b64}` (below), `{"op":"status","id":…,"state":"approved\|denied\|done\|failed\|expired\|cancelled","by":id,"note":…}`, `{"op":"enrolling","enroll":env}` (to owners) |
| A→B | `{"op":"decision","decision":env}`, `{"op":"roster","roster":env}` (an owner's new roster), `{"op":"pairing","pairing":env}` (owner-signed, `t = "pairing"`, payload `{"v":1,"hash":b64(SHA-256 of the token),"expires":n}`), `{"op":"unlock","unlock":env}` (`t = "unlock"`, payload `{"v":1,"broker":kid,"target":kid,"approver":id,"nonce":b64,"issued":n}`, signed by the approver's transport key: neither the relay nor the JetKVM can make a locked Mac ask for its password), `{"op":"sync"}` (asks for the roster and the pending requests) |
| new→B | `{"op":"enroll","enroll":env}` with `t = "enroll"`, payload `{"v":1,"pairing":b64(SHA-256 of the token),"approver":{…roster approver…},"mac":b64}`, signed by the new presence key |

Screen: when a request comes in, a broker that can (the JetKVM: its HDMI capture) takes one picture of the
target's screen and sends it after the request, without a push, as `{"op":"screen","screen":env,"jpeg":b64}`:
`t = "screen"`, payload `{"v":1,"request":ask id,"taken":n,"sha256":b64}`, signed by the broker key; the JPEG
(baseline, at most 64 KiB, about 640 pixels wide) travels beside the envelope, bound by its hash, so it is
base64-encoded once. A sync sends it again with its open request. Approvers show it with the request only when the
signature and the hash check out and the request is open; a broker that takes none (no capture, no signal, a grab
already running) just sends none.

Pairing: an owner makes a one-time token (5 minutes), tells the broker only its hash through `pairing`, and shows the
token in a QR code with the broker's id, key and seal key, the relay URL and the roster's current `seq`. The new device
enrolls with the hash and `mac` = HMAC-SHA256 keyed with the token over `"BKA1 enroll\n"` and the presence,
transport and seal keys, the name and the platform, each preceded by its 4-byte big-endian length. The broker forwards
an enrollment for a live pairing once (a replayed `pairing` doesn't bring a spent one back); the inviting owner checks
the MAC (the broker and the relay never see the token, so they can't enroll a device of their own) and approves by
signing a roster that contains the new approver. The new device takes its first roster only from the inviting owner
and not older than the QR code's `seq`.

Delivery: an owner's app sends its open pairings again with every `sync` (when a channel comes up), and keeps its
newest roster pending until the broker answers with it: a broker that answers a `sync` with an older roster gets the
pending one again. A closed pairing code is forgotten at once (its enrollment is no longer offered).

## Relay

`relay/` (Cloudflare Worker, one Durable Object per broker id). The relay authenticates every party by key, holds
no roster of its own and sees only boxes.

- `GET /v1/b/{broker}/ws` (WebSocket): the broker. Relay → `{"op":"hello","nonce":b64}`; broker →
  `{"op":"auth","auth":env}` (`t = "relay"`, payload `{"v":1,"role":"broker","broker":kid,"key":b64,"nonce":b64,
  "issued":n}`, signed by the broker key, `kid(key)` = the URL's broker); relay → `{"op":"ready"}` once it checks out
  (on approver sockets too). Then broker → relay:
  `{"op":"allow","approvers":[{"id":…,"transport":b64,"platform":…}]}` (who may use this broker's relay),
  `{"op":"pairing","hash":b64,"expires":n}` (a live pairing, by its hash: the relay takes enrollments only for these),
  and `{"op":"send","to":id,"box":b64,"push":{"collapse":id,"quiet":true}}` (deliver to the approver: its relay
  WebSocket if one is open, else queue it for 2 minutes, and push to its phones only when `push` is present;
  `quiet` asks for a push without sound). Relay → broker: `{"op":"from","from":id,"box":b64}`. The broker sends the
  allow list and its live pairings again on every connection; an approver it drops from the allow list loses its
  queued boxes, its phones' tokens and its socket.
- What the broker pushes, to the roster's iPhones (`platform` `ios`): a request when it arrives (collapse id = the
  ask's id; to Macs on the relay too, where the box goes to their socket instead), again every 10 s (`onepassword`)
  or 20 s (other kinds) while it's pending and more than 5 s from expiring, each as `{"op":"request",…,"repeat":n}`
  under the collapse id `<id>.<n>` (a notification of its own: iOS doesn't promise to alert again for a replaced
  one), and once it leaves pending the status, quiet, under `<id>.end`, which replaces the request's notification.
  Status and roster updates otherwise carry no push.
- `GET /v1/b/{broker}/approver/{id}` (WebSocket, for Macs): hello/auth as above with `"role":"approver"` signed by
  that approver's transport key. Approver → relay `{"op":"box","box":b64}`; relay → approver the broker's boxes as
  `{"op":"box","box":b64}`.
- Every `relay` auth payload names its `"endpoint"`: `"socket"` for the WebSockets, `"inbox"`, `"devices"` or
  `"outbox"` for the POSTs; the relay requires it to match.
- `POST /v1/b/{broker}/inbox`, `POST /v1/b/{broker}/devices`, `POST /v1/b/{broker}/outbox` (phones): the body is an
  envelope (`t = "relay"`) signed by the approver's transport key, payload `{"v":1,"role":"approver","broker":kid,
  "approver":id,"endpoint":…,"issued":n,"nonce":b64, …}` plus:
  - inbox: `"box"`, at most 60 a minute per approver;
  - devices: `"apns":{"token":hex,"env":"sandbox|production"}` adds a token (4 per approver, newest kept);
    `"apns":{"remove":true,"token":hex}` removes one, `"apns":{"remove":true}` all of the approver's (an iPhone that
    forgets the JetKVM);
  - outbox: `"ack":n`, the `last` of the previous answer (0 at first). The answer is `{"boxes":[b64…],"last":n}`, and
    boxes stay queued until a later request acknowledges them, so an answer lost on the way loses nothing. Without
    `ack` the boxes leave the queue as they are returned.

  The relay accepts the request when the approver is in the broker's allow list, `issued` is within 120 s and the
  nonce is new. Any failed check answers `401 unauthorized`, without saying which.
- `POST /v1/b/{broker}/enroll` (a device that isn't an approver yet): body `{"box":b64,"pairing":b64}` (an `enroll`
  message sealed to the broker, and the pairing's hash), at most 8 KiB, unauthenticated. The relay takes it only for
  a pairing the broker announced and that hasn't expired, 3 per pairing, 5 an hour per client address (IPv6: per
  /64) and 30 an hour per broker, and forwards it as `{"op":"from","from":"","box":…}`; the broker accepts nothing
  but `enroll` from an empty `from`.
- Push: an APNs alert (`mutable-content`, `interruption-level` `time-sensitive`, category `APPROVAL`, sound,
  `apns-collapse-id`; a quiet one `interruption-level` `passive`, no sound, no category), with
  `{"bka":{"b":broker,"x":box}}` when the box fits (3.5 KB), else without `x` (the app fetches its outbox). At most
  360 pushes an hour per broker, of which 300 repeats, and 2000 a day per device token (a request takes up to 7 per
  iPhone). A device token gets at most 12 alerting pushes a minute and 120 an hour; beyond those a push still comes,
  quietly.
- Messages: 64 KiB each, 192 KiB on the broker's socket (a box with a screen).
- Sockets: at most 16 waiting for their auth (10 s each; the oldest goes first), one per party once authenticated
  (a newer one replaces it). A socket silent for 75 s is closed (the broker pings every 30 s, Macs every 20 s). A
  broker not seen for 90 days is forgotten with everything queued for it.
- `BROKERS` (optional, a Worker variable): the broker ids this relay serves, separated by spaces or commas; others
  get `404`. Unset, any broker key may use it.
