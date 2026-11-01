// One Durable Object per broker id: the broker's socket, Macs' sockets, the
// phones' requests and everything queued between them.
import { DurableObject } from "cloudflare:workers";
import { apnsConfig, collapseId, push, pushPayload } from "./apns";
import { MAX_SKEW, verifyBrokerAuth, verifyRelayAuth } from "./auth";
import type { Env } from "./env";
import { clientKey, error, isId, isSocket, json, parseRoute, readBody, type PostKind, type Route } from "./http";
import * as L from "./limits";
import { log } from "./log";
import { boxMessage, fromMessage, isBox, parseAllowList, parseDevice } from "./messages";
import { BROKER, Store } from "./store";
import { b64decode, b64encode, isObject, parseEnvelope, utf8, WireError, type Envelope } from "./wire";

const PING = '{"op":"ping"}';
const PONG = '{"op":"pong"}';
const OPEN = 1; // WebSocket.readyState

// Peer is who is on a socket. It lives in the socket's attachment, so it
// survives hibernation.
interface Peer {
  role: "broker" | "approver";
  broker: string;
  approver?: string; // the URL's, on approver sockets
  nonce: string; // the hello's
  opened: number;
  authed: boolean;
}

type SocketRoute = Extract<Route, { kind: "broker" | "approver" }>;
type PhoneRoute = { kind: Exclude<PostKind, "enroll">; broker: string };
type Task = () => Promise<void>;

let warnedNoApns = false;

export class Relay extends DurableObject<Env> {
  // store is undefined until a broker has authenticated at this id.
  private store: Store | undefined;
  private chain: Promise<unknown> = Promise.resolve();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.store = Store.open(ctx.storage.sql);
    // The runtime answers keepalives itself, so they don't wake the object.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair(PING, PONG));
  }

  override async fetch(request: Request): Promise<Response> {
    const route = parseRoute(new URL(request.url).pathname);
    if (!route) return error(404, "not found");
    // Only a broker's own socket may reach an id no broker has proved.
    if (route.kind !== "broker" && !this.store) return error(404, "unknown broker");
    if (isSocket(route)) return this.run(() => this.accept(route));
    const body = await readBody(request, route.kind === "enroll" ? L.MAX_ENROLL : L.MAX_MESSAGE);
    if (!body) return error(413, "too large");
    if (route.kind === "enroll") {
      const client = await clientKey(request);
      return this.run(() => this.enroll(body, client));
    }
    const phone: PhoneRoute = { kind: route.kind, broker: route.broker };
    return this.run(() => this.fromPhone(phone, body));
  }

  override async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    if (typeof message !== "string") return close(ws, 1003, "text only");
    if (utf8(message).length > L.MAX_MESSAGE) return close(ws, 1009, "too large");
    let msg: unknown;
    try {
      msg = JSON.parse(message);
    } catch {
      msg = undefined;
    }
    try {
      const task = await this.run(() => this.onMessage(ws, isObject(msg) ? msg : undefined));
      // Pushes run outside the queue: APNs mustn't hold up other messages.
      await task?.();
    } catch (e) {
      log("message failed", { role: peerOf(ws).role, reason: reason(e) });
    }
  }

  override async webSocketClose(ws: WebSocket, code: number): Promise<void> {
    const peer = peerOf(ws);
    if (peer.authed) log("disconnected", { role: peer.role, broker: peer.broker, approver: peer.approver, code });
    // 1005 and 1006 are reserved for reporting; they can't be sent.
    close(ws, code === 1005 || code === 1006 ? 1000 : code, "");
  }

  override async alarm(): Promise<void> {
    await this.run(async () => {
      const at = now();
      this.store?.purge(at);
      // Only here are all sockets looked at; there are at most MAX_SOCKETS.
      let next: number | undefined;
      for (const ws of this.ctx.getWebSockets()) {
        const peer = peerOf(ws);
        if (peer.authed || ws.readyState !== OPEN) continue;
        const deadline = peer.opened + L.AUTH_TIMEOUT;
        if (at >= deadline) close(ws, 1008, "auth timeout");
        else next = Math.min(next ?? deadline, deadline);
      }
      await this.alarmAt(next);
    });
  }

  // run serializes everything that reads or changes state (a socket's auth
  // must be done before its next message is read), then schedules cleanup.
  private run<T>(fn: () => T | Promise<T>): Promise<T> {
    const result = this.chain.then(async () => {
      const out = await fn();
      await this.alarmAt(this.store?.nextExpiry());
      return out;
    });
    this.chain = result.catch(() => undefined);
    return result;
  }

  // alarmAt makes sure the alarm goes off by at (Unix seconds).
  private async alarmAt(at: number | undefined): Promise<void> {
    if (at === undefined) return;
    const current = await this.ctx.storage.getAlarm();
    if (current === null || current > at * 1000) await this.ctx.storage.setAlarm(at * 1000);
  }

  private async accept(route: SocketRoute): Promise<Response> {
    const sockets = this.ctx.getWebSockets();
    const pending = sockets.filter((ws) => !peerOf(ws).authed).length;
    if (sockets.length >= L.MAX_SOCKETS || pending >= L.MAX_PENDING_SOCKETS) {
      log("socket refused", { broker: route.broker, sockets: sockets.length, pending });
      return error(503, "too many connections");
    }
    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    const peer: Peer = {
      role: route.kind,
      broker: route.broker,
      nonce: b64encode(crypto.getRandomValues(new Uint8Array(32))),
      opened: now(),
      authed: false,
    };
    if (route.kind === "approver") peer.approver = route.approver;
    this.ctx.acceptWebSocket(server, [tagOf(peer)]);
    server.serializeAttachment(peer);
    server.send(JSON.stringify({ op: "hello", nonce: peer.nonce }));
    await this.alarmAt(peer.opened + L.AUTH_TIMEOUT);
    return new Response(null, { status: 101, webSocket: client });
  }

  private async onMessage(ws: WebSocket, msg: Record<string, unknown> | undefined): Promise<Task | undefined> {
    const peer = peerOf(ws);
    if (!peer.authed) {
      // A hello is answered with auth and nothing else.
      if (msg?.op === "auth") await this.authenticate(ws, peer, msg.auth);
      else close(ws, 1008, "auth first");
      return undefined;
    }
    if (!msg) return undefined;
    if (peer.role === "approver") {
      if (msg.op === "box" && isBox(msg.box)) this.toBroker(peer.approver!, msg.box);
      return undefined;
    }
    switch (msg.op) {
      case "allow":
        await this.allow(msg.approvers);
        return undefined;
      case "send":
        return this.send(peer.broker, msg);
      default:
        return undefined; // unknown ops are ignored, for later versions
    }
  }

  private async authenticate(ws: WebSocket, peer: Peer, auth: unknown): Promise<void> {
    const at = now();
    try {
      if (peer.role === "broker") {
        await verifyBrokerAuth(auth, peer.broker, peer.nonce, at);
      } else {
        const approver = this.store?.approver(peer.approver!);
        if (!approver) throw new WireError("not an approver");
        const want = { role: "approver", endpoint: "socket", broker: peer.broker, approver: approver.id, nonce: peer.nonce } as const;
        await verifyRelayAuth(auth, b64decode(approver.transport), want, at);
      }
    } catch (e) {
      log("auth failed", { role: peer.role, broker: peer.broker, approver: peer.approver, reason: reason(e) });
      return close(ws, 1008, "unauthorized");
    }
    peer.authed = true;
    ws.serializeAttachment(peer);
    // One socket per party: a newer one replaces the older.
    for (const other of this.ctx.getWebSockets(tagOf(peer))) {
      if (other !== ws && peerOf(other).authed) close(other, 4000, "replaced");
    }
    // The broker proved its id: from now on the relay keeps state for it.
    this.store ??= Store.create(this.ctx.storage.sql, peer.broker);
    // The party's login took: from now on its messages go through.
    ws.send(JSON.stringify({ op: "ready" }));
    const sent = this.flush(this.store, ws, peer, at);
    log("connected", { role: peer.role, broker: peer.broker, approver: peer.approver, queued: sent });
  }

  // flush sends what was queued for the socket's party while it was away.
  private flush(store: Store, ws: WebSocket, peer: Peer, at: number): number {
    const recipient = peer.role === "broker" ? BROKER : peer.approver!;
    let last: number | undefined;
    let sent = 0;
    for (const q of store.queued(recipient, at)) {
      try {
        ws.send(peer.role === "broker" ? fromMessage(q.sender, q.box) : boxMessage(q.box));
      } catch {
        break;
      }
      last = q.seq;
      sent++;
    }
    if (last !== undefined) store.dequeue(recipient, last);
    return sent;
  }

  private async allow(input: unknown): Promise<void> {
    const list = await parseAllowList(input);
    if (!list) return log("bad allow list");
    const { removed, rekeyed } = this.store!.replaceApprovers(list);
    // A socket proved a key the broker no longer allows.
    for (const id of [...removed, ...rekeyed]) {
      for (const ws of this.ctx.getWebSockets(approverTag(id))) close(ws, 1008, "revoked");
    }
    log("allow", { approvers: list.length, removed: removed.length, rekeyed: rekeyed.length });
  }

  // send delivers a box to an approver's open socket, else queues it and,
  // when the broker asks for one, pushes to the approver's phones.
  private send(broker: string, msg: Record<string, unknown>): Task | undefined {
    const store = this.store!;
    const { to, box } = msg;
    if (!isId(to) || !isBox(box)) {
      log("bad send", { broker });
      return undefined;
    }
    if (!store.approver(to)) {
      log("send to an unknown approver", { broker, approver: to });
      return undefined;
    }
    if (this.deliver(approverTag(to), boxMessage(box))) return undefined;
    const at = now();
    store.enqueue(to, BROKER, box, at, at + L.QUEUE_TTL);
    if (!isObject(msg.push)) return undefined;
    return this.planPush(store, broker, to, box, collapseId(msg.push));
  }

  // planPush spends the rate limits now, in order, and returns the requests
  // to make.
  private planPush(store: Store, broker: string, approver: string, box: string, collapse: string | undefined): Task | undefined {
    const cfg = apnsConfig(this.env);
    if (!cfg) {
      if (!warnedNoApns) log("APNs secrets missing: boxes are queued, not pushed");
      warnedNoApns = true;
      return undefined;
    }
    const devices = store.devices(approver);
    if (devices.length === 0) return undefined;
    const at = now();
    if (!store.spend([{ key: "push", limit: L.PUSHES_PER_HOUR, window: L.HOUR }], at)) {
      log("push rate-limited", { broker });
      return undefined;
    }
    const targets = devices.filter((d) => store.spend([{ key: `device:${d.token}`, limit: L.PUSHES_PER_DAY, window: L.DAY }], at));
    if (targets.length < devices.length) log("device push rate-limited", { broker, approver, devices: devices.length - targets.length });
    const payload = pushPayload(broker, box);
    return async () => {
      await Promise.all(
        targets.map(async (device) => {
          try {
            const result = await push(cfg, device, payload, collapse, at);
            if (result.drop) store.dropDevice(approver, device.token);
            log("push", { broker, approver, status: result.status, reason: result.reason, dropped: result.drop });
          } catch (e) {
            log("push failed", { broker, approver, reason: reason(e) });
          }
        }),
      );
    };
  }

  // toBroker delivers to the broker's socket, or queues for when it connects.
  private toBroker(sender: string, box: string): void {
    if (this.deliver(BROKER, fromMessage(sender, box))) return;
    const at = now();
    this.store!.enqueue(BROKER, sender, box, at, at + L.QUEUE_TTL);
  }

  private deliver(tag: string, data: string): boolean {
    for (const ws of this.ctx.getWebSockets(tag)) {
      if (ws.readyState !== OPEN || !peerOf(ws).authed) continue;
      try {
        ws.send(data);
        return true;
      } catch {
        // closing under us: try the next, else queue
      }
    }
    return false;
  }

  // fromPhone serves inbox, devices and outbox: each request is a relay
  // envelope signed by the approver's transport key, for that endpoint, used
  // once.
  private async fromPhone(route: PhoneRoute, body: Uint8Array): Promise<Response> {
    const store = this.store!;
    const at = now();
    let env: Envelope;
    try {
      env = parseEnvelope(parseBody(body));
    } catch {
      return error(400, "body");
    }
    const approver = store.approverByTransport(env.k);
    if (!approver) return error(403, "not an approver");
    let payload: Record<string, unknown>;
    try {
      const want = { role: "approver", endpoint: route.kind, broker: route.broker, approver: approver.id } as const;
      const { auth, payload: p } = await verifyRelayAuth(env, b64decode(approver.transport), want, at);
      // Kept past the last second `issued` would still be accepted.
      if (!store.useNonce(auth.nonce, auth.issued + MAX_SKEW + L.NONCE_MARGIN)) return error(401, "replay");
      payload = p;
    } catch (e) {
      return error(401, reason(e));
    }
    switch (route.kind) {
      case "inbox":
        if (!isBox(payload.box)) return error(400, "box");
        this.toBroker(approver.id, payload.box);
        return json({ ok: true });
      case "devices": {
        const device = parseDevice(payload.apns);
        if (!device) return error(400, "apns");
        store.addDevice(approver.id, device, at);
        log("device registered", { broker: route.broker, approver: approver.id, env: device.env });
        return json({ ok: true });
      }
      case "outbox": {
        // At most MAX_QUEUED_BYTES.
        const boxes: string[] = [];
        let last: number | undefined;
        for (const q of store.queued(approver.id, at)) {
          boxes.push(q.box);
          last = q.seq;
        }
        if (last !== undefined) store.dequeue(approver.id, last);
        return json({ boxes });
      }
    }
  }

  // enroll forwards a box from a device that isn't an approver yet. It is
  // unauthenticated, so it is rate-limited per broker and per client, all or
  // nothing, so one client can't spend the broker's budget alone.
  private enroll(body: Uint8Array, client: string): Response {
    let input: unknown;
    try {
      input = parseBody(body);
    } catch {
      return error(400, "body");
    }
    if (!isObject(input) || !isBox(input.box)) return error(400, "box");
    const limits = [
      { key: `enroll:${client}`, limit: L.ENROLLS_PER_HOUR_PER_CLIENT, window: L.HOUR },
      { key: "enroll", limit: L.ENROLLS_PER_HOUR, window: L.HOUR },
    ];
    if (!this.store!.spend(limits, now())) return error(429, "too many enrollments");
    this.toBroker("", input.box);
    return json({ ok: true });
  }
}

class BodyError extends Error {}

const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

function parseBody(body: Uint8Array): unknown {
  try {
    return JSON.parse(decoder.decode(body));
  } catch {
    throw new BodyError("body");
  }
}

function peerOf(ws: WebSocket): Peer {
  return ws.deserializeAttachment() as Peer;
}

function tagOf(peer: Peer): string {
  return peer.role === "broker" ? BROKER : approverTag(peer.approver!);
}

function approverTag(id: string): string {
  return `approver:${id}`;
}

function close(ws: WebSocket, code: number, why: string): void {
  try {
    ws.close(code, why);
  } catch {
    // already closed
  }
}

function reason(e: unknown): string {
  return e instanceof WireError || e instanceof BodyError ? e.message : "error";
}

function now(): number {
  return Math.floor(Date.now() / 1000);
}
