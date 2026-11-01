import { runDurableObjectAlarm } from "cloudflare:test";
import { afterEach, describe, expect, it, vi } from "vitest";
import { b64decode, b64encode, utf8 } from "../src/wire";
import {
  allowList,
  apnsCalls,
  apnsKey,
  apnsToken,
  approverAuth,
  box,
  brokerAuth,
  closeAll,
  connect,
  connectBroker,
  connectMac,
  count,
  enrollFrom,
  fixture,
  hello,
  inObject,
  mockApns,
  newKey,
  now,
  outbox,
  phoneEnvelope,
  phonePost,
  post,
  query,
  registerDevice,
  setEnv,
  setup,
  sign,
  sleep,
  stub,
  tables,
} from "./helpers";

afterEach(() => {
  closeAll();
  vi.restoreAllMocks();
});

describe("routing", () => {
  it("knows only the protocol's paths", async () => {
    const { exports } = await import("cloudflare:workers");
    const at = (path: string, init?: RequestInit) => exports.default.fetch(`https://relay.test${path}`, init);
    const id = "0123456789abcdef01234567";
    expect((await at("/")).status).toBe(404);
    expect((await at(`/v1/b/${id.toUpperCase()}/ws`)).status).toBe(404);
    expect((await at(`/v1/b/${id}/ws`)).status).toBe(426);
    expect((await at(`/v1/b/${id}/inbox`)).status).toBe(405);
    expect((await at(`/v1/b/${id}/approver/${id}`, { method: "POST" })).status).toBe(426);
  });
});

describe("broker socket", () => {
  it("authenticates the broker's key", async () => {
    const f = await fixture();
    const c = await connectBroker(f);
    const [meta] = await query<{ value: string }>(f.broker.id, `SELECT value FROM meta WHERE key = 'broker'`);
    expect(meta?.value).toBe(f.broker.id);
    expect(c.pending()).toBe(0);
  });

  it("refuses a key that isn't the URL's broker", async () => {
    const f = await fixture();
    const other = await newKey();
    const c = await connect(`/v1/b/${other.id}/ws`);
    // Signed by f.broker, claiming the URL's id.
    c.send(await brokerAuth(f.broker, await hello(c), { broker: other.id }));
    expect((await c.closed).code).toBe(1008);
  });

  it("refuses a bad signature", async () => {
    const f = await fixture();
    const c = await connect(`/v1/b/${f.broker.id}/ws`);
    const msg = await brokerAuth(f.broker, await hello(c));
    const forged = await brokerAuth(f.broker, "x".repeat(43));
    c.send({ op: "auth", auth: { ...msg.auth, s: forged.auth.s } });
    expect((await c.closed).code).toBe(1008);
  });

  it("refuses a stale auth", async () => {
    const f = await fixture();
    const c = await connect(`/v1/b/${f.broker.id}/ws`);
    c.send(await brokerAuth(f.broker, await hello(c), { issued: now() - 300 }));
    expect((await c.closed).code).toBe(1008);
  });

  it("refuses another hello's nonce", async () => {
    const f = await fixture();
    const c = await connect(`/v1/b/${f.broker.id}/ws`);
    await hello(c);
    c.send(await brokerAuth(f.broker, b64encode(crypto.getRandomValues(new Uint8Array(32)))));
    expect((await c.closed).code).toBe(1008);
  });

  it("answers pings without the object", async () => {
    const f = await fixture();
    const c = await connect(`/v1/b/${f.broker.id}/ws`);
    await hello(c);
    c.send('{"op":"ping"}');
    expect(await c.raw()).toBe('{"op":"pong"}');
  });

  it("closes sockets that don't authenticate in time", async () => {
    const f = await fixture();
    const c = await connect(`/v1/b/${f.broker.id}/ws`);
    await hello(c);
    await inObject(f.broker.id, (_, state) => {
      for (const ws of state.getWebSockets()) ws.serializeAttachment({ ...ws.deserializeAttachment(), opened: now() - 60 });
    });
    await runDurableObjectAlarm(stub(f.broker.id));
    expect((await c.closed).code).toBe(1008);
  });

  it("a newer broker socket replaces the older", async () => {
    const { f, broker } = await setup();
    const newer = await connectBroker(f);
    expect((await broker.closed).code).toBe(4000);
    const b = box();
    expect((await phonePost(f, "inbox", { box: b })).status).toBe(200);
    expect(await newer.next()).toEqual({ op: "from", from: f.phone.presence.id, box: b });
  });

  it("ignores unknown ops and closes on oversized messages", async () => {
    const { f, broker } = await setup();
    broker.send({ op: "later", x: 1 });
    broker.send({ op: "send", to: f.phone.presence.id, box: box() });
    await vi.waitFor(async () => expect(await count(f.broker.id, "queue")).toBe(1));
    broker.send("x".repeat(64 * 1024 + 1));
    expect((await broker.closed).code).toBe(1009);
  });

  it("revoking an approver closes its socket and forgets its queue and phones", async () => {
    const { f, broker } = await setup();
    const mac = await connectMac(f);
    await registerDevice(f, apnsToken());
    broker.send({ op: "send", to: f.phone.presence.id, box: box() });
    await vi.waitFor(async () => expect(await count(f.broker.id, "queue")).toBe(1));
    broker.send({ op: "allow", approvers: [] });
    expect((await mac.closed).code).toBe(1008);
    await vi.waitFor(async () => expect(await count(f.broker.id, "approvers")).toBe(0));
    expect(await count(f.broker.id, "queue")).toBe(0);
    expect(await count(f.broker.id, "devices")).toBe(0);
  });

  it("keeps the allow list when a message is bad", async () => {
    const { f, broker } = await setup();
    broker.send({ op: "allow", approvers: [{ id: f.mac.presence.id, transport: "AAAA", platform: "macos" }] });
    broker.send({ op: "send", to: f.phone.presence.id, box: box() });
    await vi.waitFor(async () => expect(await count(f.broker.id, "queue")).toBe(1));
    expect(await count(f.broker.id, "approvers")).toBe(2);
  });
});

describe("approver socket", () => {
  it("authenticates a Mac on the allow list and carries boxes both ways", async () => {
    const { f, broker } = await setup();
    const mac = await connectMac(f);
    const down = box();
    broker.send({ op: "send", to: f.mac.presence.id, box: down, push: { collapse: "r1" } });
    expect(await mac.next()).toEqual({ op: "box", box: down });
    const up = box();
    mac.send({ op: "box", box: up });
    expect(await broker.next()).toEqual({ op: "from", from: f.mac.presence.id, box: up });
    mac.send('{"op":"ping"}');
    expect(await mac.raw()).toBe('{"op":"pong"}');
  });

  it("refuses an approver that isn't on the allow list", async () => {
    const { f, broker } = await setup();
    broker.send({ op: "allow", approvers: allowList(f, ["phone"]) });
    await vi.waitFor(async () => expect(await count(f.broker.id, "approvers")).toBe(1));
    const c = await connect(`/v1/b/${f.broker.id}/approver/${f.mac.presence.id}`);
    c.send(await approverAuth(f, f.mac, await hello(c)));
    expect((await c.closed).code).toBe(1008);
  });

  it("refuses an auth signed by another key than the transport key", async () => {
    const { f } = await setup();
    const c = await connect(`/v1/b/${f.broker.id}/approver/${f.mac.presence.id}`);
    c.send(await approverAuth(f, f.mac, await hello(c), f.mac.presence));
    expect((await c.closed).code).toBe(1008);
  });

  it("gets what was queued while it was away", async () => {
    const { f, broker } = await setup();
    const b = box();
    broker.send({ op: "send", to: f.mac.presence.id, box: b });
    await vi.waitFor(async () => expect(await count(f.broker.id, "queue")).toBe(1));
    const mac = await connectMac(f);
    expect(await mac.next()).toEqual({ op: "box", box: b });
    expect(await count(f.broker.id, "queue")).toBe(0);
  });
});

describe("send and push", () => {
  it("queues and pushes when the approver has no socket", async () => {
    const { f, broker } = await setup();
    const apns = await apnsKey();
    await setEnv(f.broker.id, apns.env);
    const token = apnsToken();
    await registerDevice(f, token);
    const spy = mockApns();
    const b = box();
    const at = now();
    broker.send({ op: "send", to: f.phone.presence.id, box: b, push: { collapse: "request-1" } });
    await vi.waitFor(() => expect(spy).toHaveBeenCalledTimes(1));

    const [call] = apnsCalls(spy);
    expect(call!.url).toBe(`https://api.sandbox.push.apple.com/3/device/${token}`);
    expect(spy.mock.calls[0]![1]!.method).toBe("POST");
    const h = call!.headers;
    expect(h["apns-topic"]).toBe("com.fmdlabs.blitzkvm");
    expect(h["apns-push-type"]).toBe("alert");
    expect(h["apns-priority"]).toBe("10");
    expect(h["apns-collapse-id"]).toBe("request-1");
    expect(Number(h["apns-expiration"])).toBeGreaterThanOrEqual(at + 120);
    expect(Number(h["apns-expiration"])).toBeLessThanOrEqual(now() + 120);

    const [scheme, jwt] = h.authorization!.split(" ");
    expect(scheme).toBe("bearer");
    const [header, claims, sig] = jwt!.split(".");
    expect(JSON.parse(new TextDecoder().decode(b64decode(header!)))).toEqual({ alg: "ES256", kid: "KEYID00000" });
    const c = JSON.parse(new TextDecoder().decode(b64decode(claims!)));
    expect(c.iss).toBe("TEAM000000");
    expect(Math.abs(c.iat - at)).toBeLessThanOrEqual(2);
    const ok = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, apns.key.publicKey, b64decode(sig!), utf8(`${header}.${claims}`));
    expect(ok).toBe(true);

    expect(call!.body).toEqual({
      aps: {
        alert: { title: "Approval requested", body: "Open to review" },
        "mutable-content": 1,
        "interruption-level": "time-sensitive",
        category: "APPROVAL",
        sound: "default",
      },
      bka: { b: f.broker.id, x: b },
    });
    expect(await outbox(f)).toEqual([b]);
  });

  it("uses production APNs for production tokens and the configured topic", async () => {
    const { f, broker } = await setup();
    await setEnv(f.broker.id, { ...(await apnsKey()).env, APNS_TOPIC: "org.example.app" });
    const token = apnsToken();
    await registerDevice(f, token, "production");
    const spy = mockApns();
    broker.send({ op: "send", to: f.phone.presence.id, box: box(), push: {} });
    await vi.waitFor(() => expect(spy).toHaveBeenCalledTimes(1));
    const [call] = apnsCalls(spy);
    expect(call!.url).toBe(`https://api.push.apple.com/3/device/${token}`);
    expect(call!.headers["apns-topic"]).toBe("org.example.app");
    expect(call!.headers["apns-collapse-id"]).toBeUndefined();
  });

  it("leaves a box that doesn't fit out of the push", async () => {
    const { f, broker } = await setup();
    await setEnv(f.broker.id, (await apnsKey()).env);
    await registerDevice(f, apnsToken());
    const spy = mockApns();
    broker.send({ op: "send", to: f.phone.presence.id, box: box(2700), push: { collapse: "big" } });
    await vi.waitFor(() => expect(spy).toHaveBeenCalledTimes(1));
    expect(apnsCalls(spy)[0]!.body.bka).toEqual({ b: f.broker.id });
  });

  it("pushes only when send asks for it", async () => {
    const { f, broker } = await setup();
    await setEnv(f.broker.id, (await apnsKey()).env);
    await registerDevice(f, apnsToken());
    const spy = mockApns();
    const quiet = box();
    broker.send({ op: "send", to: f.phone.presence.id, box: quiet });
    broker.send({ op: "send", to: f.phone.presence.id, box: box(), push: { collapse: "second" } });
    await vi.waitFor(() => expect(spy).toHaveBeenCalledTimes(1));
    expect(apnsCalls(spy)[0]!.headers["apns-collapse-id"]).toBe("second");
    expect((await outbox(f))[0]).toBe(quiet);
  });

  it("queues without pushing when the APNs secrets are missing", async () => {
    const { f, broker } = await setup();
    await registerDevice(f, apnsToken());
    const spy = mockApns();
    const b = box();
    broker.send({ op: "send", to: f.phone.presence.id, box: b, push: { collapse: "x" } });
    await vi.waitFor(async () => expect(await count(f.broker.id, "queue")).toBe(1));
    await sleep(50);
    expect(spy).not.toHaveBeenCalled();
    expect(await outbox(f)).toEqual([b]);
  });

  it("drops tokens APNs calls gone", async () => {
    for (const [status, reason] of [
      [410, "Unregistered"],
      [400, "BadDeviceToken"],
    ] as const) {
      const { f, broker } = await setup();
      await setEnv(f.broker.id, (await apnsKey()).env);
      await registerDevice(f, apnsToken());
      const spy = mockApns(status, reason);
      broker.send({ op: "send", to: f.phone.presence.id, box: box(), push: {} });
      await vi.waitFor(async () => expect(await count(f.broker.id, "devices")).toBe(0));
      expect(spy).toHaveBeenCalledTimes(1);
      spy.mockRestore();
    }
  });

  it("keeps tokens on other APNs errors", async () => {
    const { f, broker } = await setup();
    await setEnv(f.broker.id, (await apnsKey()).env);
    await registerDevice(f, apnsToken());
    const spy = mockApns(429, "TooManyRequests");
    broker.send({ op: "send", to: f.phone.presence.id, box: box(), push: {} });
    await vi.waitFor(() => expect(spy).toHaveBeenCalledTimes(1));
    await sleep(20);
    expect(await count(f.broker.id, "devices")).toBe(1);
  });

  it("ignores sends to approvers off the allow list", async () => {
    const { f, broker } = await setup();
    broker.send({ op: "send", to: "0123456789abcdef01234567", box: box() });
    broker.send({ op: "send", to: f.phone.presence.id, box: box() });
    await vi.waitFor(async () => expect(await count(f.broker.id, "queue")).toBe(1));
    expect((await query<{ recipient: string }>(f.broker.id, `SELECT recipient FROM queue`))[0]!.recipient).toBe(f.phone.presence.id);
  });
});

describe("limits", () => {
  it("pushes at most 60 times an hour per broker", async () => {
    const { f, broker } = await setup();
    await setEnv(f.broker.id, (await apnsKey()).env);
    await registerDevice(f, apnsToken());
    const spy = mockApns();
    for (let i = 0; i < 61; i++) broker.send({ op: "send", to: f.phone.presence.id, box: box(), push: { collapse: `n${i}` } });
    await vi.waitFor(async () => expect(await count(f.broker.id, "queue")).toBe(61), { timeout: 5000 });
    await vi.waitFor(() => expect(spy).toHaveBeenCalledTimes(60));
    await sleep(50);
    const collapsed = apnsCalls(spy).map((c) => c.headers["apns-collapse-id"]);
    expect(collapsed).toHaveLength(60);
    expect(collapsed).not.toContain("n60");
  });

  it("pushes at most 500 times a day per device token", async () => {
    const { f, broker } = await setup();
    await setEnv(f.broker.id, (await apnsKey()).env);
    const spent = apnsToken();
    const fresh = apnsToken();
    await registerDevice(f, spent);
    await registerDevice(f, fresh);
    await inObject(f.broker.id, (_, state) => {
      state.storage.sql.exec(`INSERT INTO counters (key, count, reset) VALUES (?, 500, ?)`, `device:${spent}`, now() + 3600);
    });
    const spy = mockApns();
    broker.send({ op: "send", to: f.phone.presence.id, box: box(), push: {} });
    await vi.waitFor(() => expect(spy).toHaveBeenCalledTimes(1));
    await sleep(50);
    expect(spy).toHaveBeenCalledTimes(1);
    expect(apnsCalls(spy)[0]!.url).toContain(fresh);
  });

  it("queues at most 64 boxes per approver, the newest", async () => {
    const { f, broker } = await setup();
    const boxes = Array.from({ length: 70 }, () => box());
    for (const b of boxes) broker.send({ op: "send", to: f.phone.presence.id, box: b });
    await vi.waitFor(async () => {
      const [last] = await query<{ box: string }>(f.broker.id, `SELECT box FROM queue ORDER BY seq DESC LIMIT 1`);
      expect(last?.box).toBe(boxes[69]);
    });
    expect(await outbox(f)).toEqual(boxes.slice(6));
  });

  it("refuses request bodies over 64 KiB", async () => {
    const { f } = await setup();
    const env = await phoneEnvelope(f, "inbox", { box: "A".repeat(64 * 1024) });
    const res = await post(f.broker.id, "inbox", env);
    expect(res.status).toBe(413);
    expect(await res.json()).toEqual({ error: "too large" });
  });
});

describe("phone endpoints", () => {
  it("devices registers an APNs token", async () => {
    const { f } = await setup();
    const token = apnsToken();
    const res = await phonePost(f, "devices", { apns: { token: token.toUpperCase(), env: "production" } });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    expect(await query(f.broker.id, `SELECT approver, token, env FROM devices`)).toEqual([
      { approver: f.phone.presence.id, token, env: "production" },
    ]);
    const bad = await phonePost(f, "devices", { apns: { token, env: "staging" } });
    expect(bad.status).toBe(400);
  });

  it("inbox forwards to the broker's socket", async () => {
    const { f, broker } = await setup();
    const b = box();
    const res = await phonePost(f, "inbox", { box: b });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    expect(await broker.next()).toEqual({ op: "from", from: f.phone.presence.id, box: b });
  });

  it("inbox queues for an offline broker and delivers when it connects", async () => {
    const { f, broker } = await setup();
    broker.close();
    await broker.closed;
    await vi.waitFor(async () => {
      const open = await inObject(f.broker.id, (_, state) => state.getWebSockets("broker").filter((ws) => ws.readyState === 1).length);
      expect(open).toBe(0);
    });
    const b = box();
    expect((await phonePost(f, "inbox", { box: b })).status).toBe(200);
    expect(await count(f.broker.id, "queue")).toBe(1);
    const again = await connectBroker(f);
    expect(await again.next()).toEqual({ op: "from", from: f.phone.presence.id, box: b });
    expect(await count(f.broker.id, "queue")).toBe(0);
  });

  it("outbox returns the approver's queue, oldest first, and clears it", async () => {
    const { f, broker } = await setup();
    const boxes = [box(), box()];
    for (const b of boxes) broker.send({ op: "send", to: f.phone.presence.id, box: b });
    broker.send({ op: "send", to: f.mac.presence.id, box: box() });
    await vi.waitFor(async () => expect(await count(f.broker.id, "queue")).toBe(3));
    expect(await outbox(f)).toEqual(boxes);
    expect(await outbox(f)).toEqual([]);
    expect(await count(f.broker.id, "queue")).toBe(1);
  });

  it("forgets boxes after two minutes", async () => {
    const { f, broker } = await setup();
    broker.send({ op: "send", to: f.phone.presence.id, box: box() });
    await vi.waitFor(async () => expect(await count(f.broker.id, "queue")).toBe(1));
    const [{ expires }] = (await query<{ expires: number }>(f.broker.id, `SELECT expires FROM queue`)) as [{ expires: number }];
    expect(expires - now()).toBeGreaterThan(115);
    expect(expires - now()).toBeLessThanOrEqual(120);
    await inObject(f.broker.id, (_, state) => state.storage.sql.exec(`UPDATE queue SET expires = ?`, now()));
    // The send scheduled the cleanup.
    expect(await runDurableObjectAlarm(stub(f.broker.id))).toBe(true);
    expect(await count(f.broker.id, "queue")).toBe(0);
    expect(await outbox(f)).toEqual([]);
  });

  it("refuses a replayed request", async () => {
    const { f } = await setup();
    const env = await phoneEnvelope(f, "outbox");
    expect((await post(f.broker.id, "outbox", env)).status).toBe(200);
    const again = await post(f.broker.id, "outbox", env);
    expect(again.status).toBe(401);
    expect(await again.json()).toEqual({ error: "replay" });
  });

  it("refuses a request issued too long ago or ahead", async () => {
    const { f } = await setup();
    for (const issued of [now() - 121, now() + 121]) {
      const res = await post(f.broker.id, "outbox", await phoneEnvelope(f, "outbox", { issued }));
      expect(res.status).toBe(401);
      expect(await res.json()).toEqual({ error: "stale" });
    }
  });

  it("refuses keys off the allow list, wrong approvers and bad signatures", async () => {
    const { f } = await setup();
    const stranger = await newKey();
    expect((await post(f.broker.id, "outbox", await phoneEnvelope(f, "outbox", {}, stranger))).status).toBe(403);
    // The Mac's key, claiming the phone.
    expect((await post(f.broker.id, "outbox", await phoneEnvelope(f, "outbox", {}, f.mac.transport))).status).toBe(401);
    const env = await phoneEnvelope(f, "outbox");
    const other = await phoneEnvelope(f, "outbox");
    expect((await post(f.broker.id, "outbox", { ...env, s: other.s })).status).toBe(401);
    expect((await post(f.broker.id, "outbox", "{")).status).toBe(400);
    const wrongBroker = await phoneEnvelope(f, "outbox", { broker: "0123456789abcdef01234567" });
    expect((await post(f.broker.id, "outbox", wrongBroker)).status).toBe(401);
    const asBroker = await sign(f.phone.transport, "relay", { v: 1, role: "broker", endpoint: "outbox", broker: f.broker.id, approver: f.phone.presence.id, nonce: b64encode(new Uint8Array(32)), issued: now() });
    expect((await post(f.broker.id, "outbox", asBroker)).status).toBe(401);
  });
});

describe("enroll", () => {
  it("forwards a new device's box to the broker unauthenticated", async () => {
    const { f, broker } = await setup();
    const b = box();
    const res = await post(f.broker.id, "enroll", { box: b });
    expect(res.status).toBe(200);
    expect(await res.json()).toEqual({ ok: true });
    expect(await broker.next()).toEqual({ op: "from", from: "", box: b });
  });

  it("queues for an offline broker", async () => {
    const { f, broker } = await setup();
    broker.close();
    await broker.closed;
    await vi.waitFor(async () => {
      const open = await inObject(f.broker.id, (_, state) => state.getWebSockets("broker").filter((ws) => ws.readyState === 1).length);
      expect(open).toBe(0);
    });
    const b = box();
    expect((await post(f.broker.id, "enroll", { box: b })).status).toBe(200);
    const again = await connectBroker(f);
    expect(await again.next()).toEqual({ op: "from", from: "", box: b });
  });

  it("is limited to 8 KiB and brokers that have connected", async () => {
    const { f } = await setup();
    expect((await post(f.broker.id, "enroll", { box: box(7000) })).status).toBe(413);
    expect((await post(f.broker.id, "enroll", { nope: 1 })).status).toBe(400);
    const unknown = await newKey();
    expect((await post(unknown.id, "enroll", { box: box() })).status).toBe(404);
  });

  it("allows 5 an hour per client and 10 per broker, spending neither when one says no", async () => {
    const { f } = await setup();
    for (let i = 0; i < 5; i++) expect((await enrollFrom(f.broker.id, "192.0.2.1")).status).toBe(200);
    const limited = await enrollFrom(f.broker.id, "192.0.2.1");
    expect(limited.status).toBe(429);
    expect(await limited.json()).toEqual({ error: "too many enrollments" });
    // The refused one didn't count against the broker: another client gets all 5.
    for (let i = 0; i < 5; i++) expect((await enrollFrom(f.broker.id, "192.0.2.2")).status).toBe(200);
    // Now the broker's 10 are spent.
    expect((await enrollFrom(f.broker.id, "192.0.2.3")).status).toBe(429);
  });

  it("counts an IPv6 client per /64", async () => {
    const { f } = await setup();
    for (let i = 0; i < 5; i++) {
      const ip = i % 2 ? "2001:db8:1:2::1" : `2001:0db8:0001:0002:${i}::5`;
      expect((await enrollFrom(f.broker.id, ip)).status).toBe(200);
    }
    expect((await enrollFrom(f.broker.id, "2001:db8:1:2:ffff:ffff:ffff:ffff")).status).toBe(429);
    expect((await enrollFrom(f.broker.id, "2001:db8:1:3::1")).status).toBe(200);
  });
});

describe("abuse", () => {
  it("keeps no state for an id no broker has proved", async () => {
    const f = await fixture();
    const id = f.broker.id;
    const upgrade = { headers: { Upgrade: "websocket" } };
    const { exports } = await import("cloudflare:workers");
    expect((await exports.default.fetch(`https://relay.test/v1/b/${id}/approver/${f.mac.presence.id}`, upgrade)).status).toBe(404);
    for (const kind of ["inbox", "devices", "outbox"]) {
      expect((await post(id, kind, await phoneEnvelope(f, kind, { box: box() }))).status).toBe(404);
    }
    expect((await enrollFrom(id, "192.0.2.1")).status).toBe(404);
    // A broker socket that never proves the key leaves nothing either.
    const c = await connect(`/v1/b/${id}/ws`);
    c.send(await brokerAuth(await newKey(), await hello(c), { broker: id }));
    expect((await c.closed).code).toBe(1008);
    expect(await tables(id)).toEqual([]);
    await connectBroker(f);
    expect(await tables(id)).toContain("queue");
  });

  it("refuses more than 16 sockets waiting to authenticate", async () => {
    const { f } = await setup();
    for (let i = 0; i < 16; i++) await hello(await connect(`/v1/b/${f.broker.id}/ws`));
    const { exports } = await import("cloudflare:workers");
    const res = await exports.default.fetch(`https://relay.test/v1/b/${f.broker.id}/ws`, { headers: { Upgrade: "websocket" } });
    expect(res.status).toBe(503);
    expect(await res.json()).toEqual({ error: "too many connections" });
  });

  it("closes a socket whose first message isn't auth", async () => {
    const { f } = await setup();
    for (const first of [{ op: "send", to: f.phone.presence.id, box: box() }, "not json"]) {
      const c = await connect(`/v1/b/${f.broker.id}/ws`);
      await hello(c);
      c.send(first);
      expect((await c.closed).code).toBe(1008);
    }
    expect(await count(f.broker.id, "queue")).toBe(0);
  });

  it("caps queued bytes per recipient, keeping the newest", async () => {
    const { f, broker } = await setup();
    const boxes = Array.from({ length: 20 }, () => box(45000)); // 60000 b64 characters each
    for (const b of boxes) broker.send({ op: "send", to: f.phone.presence.id, box: b });
    await vi.waitFor(async () => {
      const [last] = await query<{ box: string }>(f.broker.id, `SELECT box FROM queue ORDER BY seq DESC LIMIT 1`);
      expect(last?.box).toBe(boxes[19]);
    });
    const kept = Math.floor((1024 * 1024) / 60000);
    expect(await outbox(f)).toEqual(boxes.slice(20 - kept));
  });

  it("caps queued bytes per object, dropping the oldest", async () => {
    const f = await fixture();
    const broker = await connectBroker(f);
    const approvers = await Promise.all(Array.from({ length: 10 }, () => newKey()));
    broker.send({ op: "allow", approvers: approvers.map((k) => ({ id: k.id, transport: k.b64, platform: "macos" })) });
    await vi.waitFor(async () => expect(await count(f.broker.id, "approvers")).toBe(10));
    let last = "";
    for (const k of approvers) {
      for (let i = 0; i < 17; i++) {
        last = box(45000);
        broker.send({ op: "send", to: k.id, box: last });
      }
    }
    await vi.waitFor(
      async () => {
        const [row] = await query<{ box: string }>(f.broker.id, `SELECT box FROM queue ORDER BY seq DESC LIMIT 1`);
        expect(row?.box).toBe(last);
      },
      { timeout: 10000 },
    );
    const [sum] = await query<{ bytes: number; first: string }>(f.broker.id, `SELECT SUM(size) AS bytes, MIN(recipient) AS first FROM queue`);
    expect(sum!.bytes).toBeLessThanOrEqual(8 * 1024 * 1024);
    expect(sum!.bytes).toBeGreaterThan(8 * 1024 * 1024 - 60000);
    // The first approver's boxes were the oldest: they went first.
    const [firstLeft] = await query<{ n: number }>(f.broker.id, `SELECT COUNT(*) AS n FROM queue WHERE recipient = ?`, approvers[0]!.id);
    expect(firstLeft!.n).toBe(0);
  });

  it("binds an auth to its endpoint", async () => {
    const { f } = await setup();
    const forOutbox = await phoneEnvelope(f, "outbox", { box: box() });
    const res = await post(f.broker.id, "inbox", forOutbox);
    expect(res.status).toBe(401);
    expect(await res.json()).toEqual({ error: "relay endpoint" });
    const unbound = await phoneEnvelope(f, "outbox", { endpoint: undefined });
    expect((await post(f.broker.id, "outbox", unbound)).status).toBe(401);
    // A phone request's auth doesn't open a socket.
    const c = await connect(`/v1/b/${f.broker.id}/approver/${f.mac.presence.id}`);
    c.send(await approverAuth(f, f.mac, await hello(c), f.mac.transport, { endpoint: "inbox" }));
    expect((await c.closed).code).toBe(1008);
  });

  it("closes an approver's socket when the broker changes its transport key", async () => {
    const { f, broker } = await setup();
    const mac = await connectMac(f);
    const rekeyed = await newKey();
    broker.send({ op: "allow", approvers: allowList(f).map((a) => (a.id === f.mac.presence.id ? { ...a, transport: rekeyed.b64 } : a)) });
    expect((await mac.closed).code).toBe(1008);
    const c = await connect(`/v1/b/${f.broker.id}/approver/${f.mac.presence.id}`);
    c.send(await approverAuth(f, f.mac, await hello(c), rekeyed));
    expect((await c.next()).op).toBe("ready");
  });

  it("refuses allow lists over 64 approvers", async () => {
    const { f, broker } = await setup();
    const keys = await Promise.all(Array.from({ length: 65 }, () => newKey()));
    broker.send({ op: "allow", approvers: keys.map((k) => ({ id: k.id, transport: k.b64, platform: "ios" })) });
    broker.send({ op: "send", to: f.phone.presence.id, box: box() });
    await vi.waitFor(async () => expect(await count(f.broker.id, "queue")).toBe(1));
    expect(await count(f.broker.id, "approvers")).toBe(2);
  });

  it("keeps a nonce for as long as its issued time is accepted", async () => {
    const { f } = await setup();
    // A later second only brings a future issued closer, so +120 is never stale here.
    for (const issued of [now() - 110, now() + 120]) {
      const env = await phoneEnvelope(f, "outbox", { issued });
      expect((await post(f.broker.id, "outbox", env)).status).toBe(200);
      const payload = JSON.parse(new TextDecoder().decode(b64decode(env.p))) as { nonce: string };
      const [row] = await query<{ expires: number }>(f.broker.id, `SELECT expires FROM nonces WHERE nonce = ?`, payload.nonce);
      // Accepted up to issued + 120 inclusive; purged once expires <= now.
      expect(row!.expires).toBeGreaterThan(issued + 120);
    }
  });
});
