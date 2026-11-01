// Test parties that sign the way approval/wire does, and a WebSocket client.
import { runInDurableObject } from "cloudflare:test";
import { env, exports } from "cloudflare:workers";
import { expect, vi } from "vitest";
import type { Env } from "../src/env";
import type { Relay } from "../src/relay";
import { b64encode, hex, kid, signedMessage, utf8, type Envelope } from "../src/wire";

export const ORIGIN = "https://relay.test";

export interface Key {
  priv: CryptoKey;
  pub: Uint8Array<ArrayBuffer>;
  publicKey: CryptoKey;
  id: string;
  b64: string;
}

export async function newKey(): Promise<Key> {
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair;
  const pub = new Uint8Array((await crypto.subtle.exportKey("raw", pair.publicKey)) as ArrayBuffer);
  return { priv: pair.privateKey, publicKey: pair.publicKey, pub, id: await kid(pub), b64: b64encode(pub) };
}

export async function sign(key: Key, t: string, payload: unknown): Promise<Envelope> {
  const p = utf8(JSON.stringify(payload));
  const s = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key.priv, signedMessage(t, p));
  return { t, k: key.id, p: b64encode(p), s: b64encode(new Uint8Array(s)) };
}

export const now = (): number => Math.floor(Date.now() / 1000);
export const random = (n: number): Uint8Array<ArrayBuffer> => crypto.getRandomValues(new Uint8Array(n));
export const nonce = (): string => b64encode(random(32));
export const box = (size = 120): string => b64encode(random(size));
export const apnsToken = (): string => hex(random(32));
export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

export interface Approver {
  presence: Key;
  transport: Key;
}

export interface Fixture {
  broker: Key;
  mac: Approver;
  phone: Approver;
}

export async function fixture(): Promise<Fixture> {
  return {
    broker: await newKey(),
    mac: { presence: await newKey(), transport: await newKey() },
    phone: { presence: await newKey(), transport: await newKey() },
  };
}

export function allowList(f: Fixture, which: ("mac" | "phone")[] = ["mac", "phone"]) {
  return which.map((name) => ({
    id: f[name].presence.id,
    transport: f[name].transport.b64,
    platform: name === "mac" ? "macos" : "ios",
  }));
}

// Client is the far end of a relay WebSocket.
export class Client {
  private readonly inbox: string[] = [];
  private readonly waiting: ((data: string) => void)[] = [];
  readonly closed: Promise<{ code: number; reason: string }>;

  constructor(readonly ws: WebSocket) {
    ws.accept();
    ws.addEventListener("message", (e) => {
      const data = e.data as string;
      const waiter = this.waiting.shift();
      if (waiter) waiter(data);
      else this.inbox.push(data);
    });
    this.closed = new Promise((resolve) => ws.addEventListener("close", (e) => resolve({ code: e.code, reason: e.reason })));
    clients.push(this);
  }

  // raw is the next message as sent.
  raw(timeout = 2000): Promise<string> {
    const queued = this.inbox.shift();
    if (queued !== undefined) return Promise.resolve(queued);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("no message")), timeout);
      this.waiting.push((data) => {
        clearTimeout(timer);
        resolve(data);
      });
    });
  }

  async next(timeout?: number): Promise<Record<string, unknown>> {
    return JSON.parse(await this.raw(timeout)) as Record<string, unknown>;
  }

  pending(): number {
    return this.inbox.length;
  }

  send(v: unknown): void {
    this.ws.send(typeof v === "string" ? v : JSON.stringify(v));
  }

  close(): void {
    try {
      this.ws.close(1000, "done");
    } catch {
      // already closed
    }
  }
}

const clients: Client[] = [];

export function closeAll(): void {
  for (const c of clients.splice(0)) c.close();
}

export async function connect(path: string): Promise<Client> {
  const res = await exports.default.fetch(`${ORIGIN}${path}`, { headers: { Upgrade: "websocket" } });
  if (res.status !== 101 || !res.webSocket) throw new Error(`upgrade: ${res.status}`);
  return new Client(res.webSocket);
}

// hello reads the relay's hello and returns its nonce.
export async function hello(c: Client): Promise<string> {
  const msg = await c.next();
  expect(msg.op).toBe("hello");
  return msg.nonce as string;
}

export async function brokerAuth(key: Key, n: string, overrides: Record<string, unknown> = {}) {
  const payload = { v: 1, role: "broker", endpoint: "socket", broker: key.id, key: key.b64, nonce: n, issued: now(), ...overrides };
  return { op: "auth", auth: await sign(key, "relay", payload) };
}

export async function approverAuth(f: Fixture, a: Approver, n: string, signer = a.transport, overrides: Record<string, unknown> = {}) {
  const payload = { v: 1, role: "approver", endpoint: "socket", broker: f.broker.id, approver: a.presence.id, nonce: n, issued: now(), ...overrides };
  return { op: "auth", auth: await sign(signer, "relay", payload) };
}

export const stub = (broker: string) => env.RELAY.getByName(broker);

export function inObject<R>(broker: string, fn: (relay: Relay, state: DurableObjectState) => R | Promise<R>): Promise<R> {
  return runInDurableObject(stub(broker), fn);
}

export function query<T extends Record<string, SqlStorageValue>>(broker: string, sql: string, ...bindings: unknown[]): Promise<T[]> {
  return inObject(broker, (_, state) => state.storage.sql.exec<T>(sql, ...bindings).toArray());
}

export async function count(broker: string, table: string): Promise<number> {
  const [row] = await query<{ n: number }>(broker, `SELECT COUNT(*) AS n FROM ${table}`);
  return row!.n;
}

// ready reads the relay's confirmation that the auth took.
export async function ready(c: Client): Promise<void> {
  expect((await c.next()).op).toBe("ready");
}

// waitAuthed waits until the relay has accepted the auth on a socket with tag.
export async function waitAuthed(broker: string, tag: string): Promise<void> {
  await vi.waitFor(async () => {
    const authed = await inObject(broker, (_, state) =>
      state.getWebSockets(tag).some((ws) => (ws.deserializeAttachment() as { authed: boolean }).authed),
    );
    expect(authed).toBe(true);
  });
}

export async function connectBroker(f: Fixture): Promise<Client> {
  const c = await connect(`/v1/b/${f.broker.id}/ws`);
  c.send(await brokerAuth(f.broker, await hello(c)));
  await ready(c);
  await waitAuthed(f.broker.id, "broker");
  return c;
}

export async function connectMac(f: Fixture): Promise<Client> {
  const c = await connect(`/v1/b/${f.broker.id}/approver/${f.mac.presence.id}`);
  c.send(await approverAuth(f, f.mac, await hello(c)));
  await ready(c);
  await waitAuthed(f.broker.id, `approver:${f.mac.presence.id}`);
  return c;
}

// setup connects a broker and gives it an allow list of the Mac and the phone.
export async function setup(): Promise<{ f: Fixture; broker: Client }> {
  const f = await fixture();
  const broker = await connectBroker(f);
  broker.send({ op: "allow", approvers: allowList(f) });
  await vi.waitFor(async () => expect(await count(f.broker.id, "approvers")).toBe(2));
  return { f, broker };
}

export async function phoneEnvelope(f: Fixture, endpoint: string, extra: Record<string, unknown> = {}, signer = f.phone.transport) {
  const payload = { v: 1, role: "approver", endpoint, broker: f.broker.id, approver: f.phone.presence.id, issued: now(), nonce: nonce(), ...extra };
  return sign(signer, "relay", payload);
}

export function post(broker: string, kind: string, body: unknown, headers: Record<string, string> = {}): Promise<Response> {
  return exports.default.fetch(`${ORIGIN}/v1/b/${broker}/${kind}`, {
    method: "POST",
    headers,
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

// enrollFrom posts an enrollment as the client at ip.
export function enrollFrom(broker: string, ip: string, body: unknown = { box: box() }): Promise<Response> {
  return post(broker, "enroll", body, { "cf-connecting-ip": ip });
}

// tables lists the object's own tables: none for an id no broker has proved.
export function tables(broker: string): Promise<string[]> {
  return inObject(broker, (_, state) =>
    state.storage.sql
      .exec<{ name: string }>(`SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE '\\_cf\\_%' ESCAPE '\\' AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'`)
      .toArray()
      .map((r) => r.name),
  );
}

export async function phonePost(f: Fixture, kind: string, extra: Record<string, unknown> = {}): Promise<Response> {
  return post(f.broker.id, kind, await phoneEnvelope(f, kind, extra));
}

export async function outbox(f: Fixture): Promise<string[]> {
  const res = await phonePost(f, "outbox");
  expect(res.status).toBe(200);
  return ((await res.json()) as { boxes: string[] }).boxes;
}

// APNs is the provider key the tests push with.
export interface Apns {
  key: Key;
  env: Partial<Env>;
}

export async function apnsKey(): Promise<Apns> {
  const key = await newKey();
  const der = new Uint8Array((await crypto.subtle.exportKey("pkcs8", key.priv)) as ArrayBuffer);
  const b64 = btoa(String.fromCharCode(...der));
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
  return { key, env: { APNS_KEY: pem, APNS_KEY_ID: "KEYID00000", APNS_TEAM_ID: "TEAM000000" } };
}

// setEnv swaps the object's env, standing in for wrangler secrets.
export async function setEnv(broker: string, patch: Partial<Env>): Promise<void> {
  await inObject(broker, (relay) => {
    (relay as unknown as { env: Env }).env = { ...env, ...patch };
  });
}

// mockApns answers every APNs request with status (and reason) and records it.
export function mockApns(status = 200, reason?: string) {
  return vi.spyOn(globalThis, "fetch").mockImplementation(async () => {
    return reason ? Response.json({ reason }, { status }) : new Response(null, { status });
  });
}

export interface ApnsCall {
  url: string;
  headers: Record<string, string>;
  body: Record<string, any>;
}

export function apnsCalls(spy: ReturnType<typeof mockApns>): ApnsCall[] {
  return spy.mock.calls.map(([input, init]) => ({
    url: String(input),
    headers: init!.headers as Record<string, string>,
    body: JSON.parse(init!.body as string) as Record<string, any>,
  }));
}

export async function registerDevice(f: Fixture, token: string, apnsEnv = "sandbox"): Promise<void> {
  const res = await phonePost(f, "devices", { apns: { token, env: apnsEnv } });
  expect(res.status).toBe(200);
}
