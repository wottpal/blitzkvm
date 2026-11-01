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
- Types: `roster`, `ask`, `request`, `decision`, `link`, `hello`, `pairing`, `enroll`, `relay`, `unlock`.

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
once (between characters), and it answers `ok: false`.

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
| B→A | `{"op":"roster","roster":env}`, `{"op":"request","request":env}`, `{"op":"status","id":…,"state":"approved\|denied\|done\|failed\|expired\|cancelled","by":id,"note":…}`, `{"op":"enrolling","enroll":env}` (to owners) |
| A→B | `{"op":"decision","decision":env}`, `{"op":"roster","roster":env}` (an owner's new roster), `{"op":"pairing","pairing":env}` (owner-signed, `t = "pairing"`, payload `{"v":1,"hash":b64(SHA-256 of the token),"expires":n}`), `{"op":"unlock","unlock":env}` (`t = "unlock"`, payload `{"v":1,"broker":kid,"target":kid,"approver":id,"nonce":b64,"issued":n}`, signed by the approver's transport key: neither the relay nor the JetKVM can make a locked Mac ask for its password), `{"op":"sync"}` (asks for the roster and the pending requests) |
| new→B | `{"op":"enroll","enroll":env}` with `t = "enroll"`, payload `{"v":1,"pairing":b64(SHA-256 of the token),"approver":{…roster approver…},"mac":b64}`, signed by the new presence key |

Pairing: an owner makes a one-time token (5 minutes), tells the broker only its hash through `pairing`, and shows the
token in a QR code with the broker's id, key and seal key, the relay URL and the roster's current `seq`. The new device
enrolls with the hash and `mac` = HMAC-SHA256 keyed with the token over `"BKA1 enroll\n"` and the presence,
transport and seal keys, the name and the platform, each preceded by its 4-byte big-endian length. The broker forwards
an enrollment for a live pairing once (a replayed `pairing` doesn't bring a spent one back); the inviting owner checks
the MAC (the broker and the relay never see the token, so they can't enroll a device of their own) and approves by
signing a roster that contains the new approver. The new device takes its first roster only from the inviting owner
and not older than the QR code's `seq`.

## Relay

`relay/` (Cloudflare Worker, one Durable Object per broker id). The relay authenticates every party by key, holds
no roster of its own and sees only boxes.

- `GET /v1/b/{broker}/ws` (WebSocket): the broker. Relay → `{"op":"hello","nonce":b64}`; broker →
  `{"op":"auth","auth":env}` (`t = "relay"`, payload `{"v":1,"role":"broker","broker":kid,"key":b64,"nonce":b64,
  "issued":n}`, signed by the broker key, `kid(key)` = the URL's broker); relay → `{"op":"ready"}` once it checks out
  (on approver sockets too). Then broker → relay:
  `{"op":"allow","approvers":[{"id":…,"transport":b64,"platform":…}]}` (who may use this broker's relay), and
  `{"op":"send","to":id,"box":b64,"push":{"collapse":id}}` (deliver to the approver: its relay WebSocket if one is
  open, else queue it for 2 minutes, and push to its phones only when `push` is present: requests carry it, status
  and roster updates don't). Relay → broker: `{"op":"from","from":id,"box":b64}`.
- `GET /v1/b/{broker}/approver/{id}` (WebSocket, for Macs): hello/auth as above with `"role":"approver"` signed by
  that approver's transport key. Approver → relay `{"op":"box","box":b64}`; relay → approver the broker's boxes as
  `{"op":"box","box":b64}`.
- Every `relay` auth payload names its `"endpoint"`: `"socket"` for the WebSockets, `"inbox"`, `"devices"` or
  `"outbox"` for the POSTs; the relay requires it to match.
- `POST /v1/b/{broker}/inbox`, `POST /v1/b/{broker}/devices`, `POST /v1/b/{broker}/outbox` (phones): the body is an
  envelope (`t = "relay"`) signed by the approver's transport key, payload `{"v":1,"role":"approver","broker":kid,
  "approver":id,"endpoint":…,"issued":n,"nonce":b64, …}` plus `"box"` (inbox), `"apns":{"token":hex,"env":"sandbox|production"}`
  (devices) or nothing (outbox: returns the queued boxes for that approver). The relay accepts it when the approver
  is in the broker's allow list, `issued` is within 120 s and the nonce is new.
- `POST /v1/b/{broker}/enroll` (a device that isn't an approver yet): body `{"box":b64}` (an `enroll` message sealed
  to the broker), at most 8 KiB, unauthenticated, at most 10 per hour per broker. The relay forwards it as
  `{"op":"from","from":"","box":…}`; the broker accepts nothing but `enroll` from an empty `from`.
- Push: an APNs alert (`mutable-content`, `interruption-level` `time-sensitive`, category `APPROVAL`,
  `apns-collapse-id`), with `{"bka":{"b":broker,"x":box}}` when the box fits (3.5 KB), else without `x` (the app
  fetches its outbox).
