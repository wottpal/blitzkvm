# BlitzKVM relay

A Cloudflare Worker that carries remote approvals between a JetKVM's broker and its approvers (BlitzKVM on a Mac, the iPhone app) when they can't reach each other directly, and wakes phones with APNs. It implements the Relay section of [`approval/PROTOCOL.md`](../approval/PROTOCOL.md); one Durable Object (SQLite-backed) holds each broker's state.

## What the relay sees

Boxes (HPKE, sealed end to end to the recipient's seal key), the broker id, approver ids, their transport public keys and platforms (the broker's allow list), APNs device tokens, and when each party connects. It never sees inside a box: no requests, decisions, secrets or rosters. It holds no roster of its own and trusts nobody by name: the broker proves the key whose kid is the broker id, approvers prove the transport key the broker allowed.

Logs carry ids, counts and statuses, never boxes, tokens or keys.

## Endpoints

| Path | Who | What |
|---|---|---|
| `GET /v1/b/{broker}/ws` (WebSocket) | the broker | `hello`/`auth` (`t = "relay"`, `role: "broker"`, `endpoint: "socket"`) → `ready`, then `allow` (who may use this relay) and `send` (to an approver's socket, else queued for 2 minutes and, when `send` has `push`, pushed to its phones). The relay sends `from` |
| `GET /v1/b/{broker}/approver/{id}` (WebSocket) | Macs | `hello`/`auth` (`role: "approver"`, `endpoint: "socket"`, signed by the transport key) → `ready`, then `box` both ways |
| `POST /v1/b/{broker}/inbox` | phones | a signed `relay` envelope (`endpoint: "inbox"`) with `box`, for the broker → `{"ok":true}` |
| `POST /v1/b/{broker}/devices` | phones | a signed envelope (`endpoint: "devices"`) with `apns: {token, env}` → `{"ok":true}` |
| `POST /v1/b/{broker}/outbox` | phones | a signed envelope (`endpoint: "outbox"`) → `{"boxes":[…]}`, oldest first, then cleared |
| `POST /v1/b/{broker}/enroll` | a new device | `{"box":…}`, unauthenticated, to the broker as `from` with `"from":""` → `{"ok":true}` |

Errors are 4xx with `{"error":"…"}` (503 when the object has too many sockets). Until a broker has authenticated at an id, every endpoint but its own socket answers 404 and the relay keeps no state for it. Phone requests must be issued within 120 s of the relay's clock and use a nonce once. Every socket may send `{"op":"ping"}` and gets `{"op":"pong"}` without waking the object; after `auth`, unknown ops are ignored. A socket whose first message isn't `auth`, or that doesn't authenticate within 30 s, is closed; a newer socket of the same party replaces the older; an approver's socket closes when the broker drops it from the allow list or changes its transport key.

Limits: 64 KiB per message or request body (8 KiB for `enroll`); 16 sockets waiting to authenticate and 81 in all per broker; queued boxes, the newest kept, at most 64 per recipient and sender, 1 MiB per recipient and 8 MiB per broker; 64 approvers; 4 APNs tokens per approver (the newest); 60 pushes an hour per broker (one per `send` that pushes); 500 a day per device token; 10 enrollments an hour per broker and 5 per client (IPv4 address or IPv6 /64, stored hashed). A box that makes the APNs payload larger than 3500 bytes is left out of it; the app then fetches its outbox. Tokens APNs reports as gone (410, `BadDeviceToken`, `Unregistered`) are dropped.

## Deploy

Needs a Cloudflare account (the free plan runs SQLite-backed Durable Objects) and, for pushes, an APNs auth key (.p8) from the Apple Developer account.

```sh
cd relay
npm install
CLOUDFLARE_ACCOUNT_ID=… npx wrangler deploy
npx wrangler secret put APNS_KEY        # the .p8 file's contents: npx wrangler secret put APNS_KEY < AuthKey_XXXXXXXXXX.p8
npx wrangler secret put APNS_KEY_ID     # the key's 10-character id
npx wrangler secret put APNS_TEAM_ID    # the Apple Developer team id
npx wrangler secret put APNS_TOPIC      # optional, the app's bundle id; default com.fmdlabs.blitzkvm
```

Without the APNs secrets the relay works but only queues; it says so once in the log. The deploy prints the Worker's URL (`https://blitzkvm-relay.<subdomain>.workers.dev`): enter it in BlitzKVM's Settings, which hands it to the broker and the phones through the roster and pairing. Keep it out of the repository, as any account id, subdomain or key.

## Development

```sh
npm test          # vitest in the Workers runtime (@cloudflare/vitest-plugin), APNs mocked
npm run typecheck
npm run dev       # wrangler dev, local
```

The tests check `approval/testdata/vectors.json` (made by `approval/wire`) and sign the way the Go code does, with keys made in each test.
