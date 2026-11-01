// APNs over HTTP/2 with token (JWT) authentication, written against
// Apple's "Sending notification requests to APNs".
import { MAX_COLLAPSE_ID, MAX_PUSH_PAYLOAD } from "./limits";
import type { Device } from "./store";
import { b64encode, isObject, utf8 } from "./wire";

export const DEFAULT_TOPIC = "com.fmdlabs.blitzkvm";
const HOSTS = { sandbox: "https://api.sandbox.push.apple.com", production: "https://api.push.apple.com" };
const TOKEN_LIFETIME = 50 * 60; // Apple accepts a token for an hour and refuses refreshes more often than every 20 minutes
const EXPIRATION = 120; // a request is worth nothing after the queue drops its box

export interface ApnsConfig {
  key: string; // PKCS#8 PEM, the .p8 file's contents
  keyId: string;
  teamId: string;
  topic: string;
}

export function apnsConfig(env: Cloudflare.Env): ApnsConfig | undefined {
  if (!env.APNS_KEY || !env.APNS_KEY_ID || !env.APNS_TEAM_ID) return undefined;
  return { key: env.APNS_KEY, keyId: env.APNS_KEY_ID, teamId: env.APNS_TEAM_ID, topic: env.APNS_TOPIC || DEFAULT_TOPIC };
}

const APS = {
  alert: { title: "Approval requested", body: "Open to review" },
  "mutable-content": 1,
  "interruption-level": "time-sensitive",
  category: "APPROVAL",
  sound: "default",
};

// pushPayload carries the box when it fits, so the notification service
// extension can show the request without a round trip; else the app fetches
// its outbox.
export function pushPayload(broker: string, box: string): string {
  const full = JSON.stringify({ aps: APS, bka: { b: broker, x: box } });
  if (utf8(full).length <= MAX_PUSH_PAYLOAD) return full;
  return JSON.stringify({ aps: APS, bka: { b: broker } });
}

// collapseId is the broker's collapse id when APNs takes it.
export function collapseId(push: unknown): string | undefined {
  const id = isObject(push) ? push.collapse : undefined;
  if (typeof id !== "string" || id === "" || utf8(id).length > MAX_COLLAPSE_ID) return undefined;
  return id;
}

export interface PushResult {
  status: number;
  reason?: string;
  drop: boolean; // the token is gone for good
}

export async function push(cfg: ApnsConfig, device: Device, payload: string, collapse: string | undefined, now: number): Promise<PushResult> {
  const headers: Record<string, string> = {
    authorization: `bearer ${await providerToken(cfg, now)}`,
    "apns-topic": cfg.topic,
    "apns-push-type": "alert",
    "apns-priority": "10",
    "apns-expiration": String(now + EXPIRATION),
    "content-type": "application/json",
  };
  if (collapse) headers["apns-collapse-id"] = collapse;
  const res = await fetch(`${HOSTS[device.env]}/3/device/${device.token}`, { method: "POST", headers, body: payload });
  if (res.ok) {
    await res.body?.cancel();
    return { status: res.status, drop: false };
  }
  const reason = await errorReason(res);
  if (reason === "ExpiredProviderToken" || reason === "InvalidProviderToken") cached = undefined;
  const drop = res.status === 410 || reason === "BadDeviceToken" || reason === "Unregistered";
  return { status: res.status, reason, drop };
}

async function errorReason(res: Response): Promise<string | undefined> {
  try {
    const body: unknown = await res.json();
    const reason = isObject(body) ? body.reason : undefined;
    return typeof reason === "string" ? reason : undefined;
  } catch {
    return undefined;
  }
}

// The provider token is shared by every object in the isolate.
let cached: { material: string; token: string; until: number } | undefined;

async function providerToken(cfg: ApnsConfig, now: number): Promise<string> {
  const material = `${cfg.teamId}\n${cfg.keyId}\n${cfg.key}`;
  if (cached && cached.material === material && now < cached.until) return cached.token;
  const key = await crypto.subtle.importKey("pkcs8", pemBytes(cfg.key), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const signingInput = `${b64json({ alg: "ES256", kid: cfg.keyId })}.${b64json({ iss: cfg.teamId, iat: now })}`;
  // WebCrypto's raw r || s is JOSE's ES256 signature format.
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, utf8(signingInput));
  const token = `${signingInput}.${b64encode(new Uint8Array(sig))}`;
  cached = { material, token, until: now + TOKEN_LIFETIME };
  return token;
}

function b64json(v: unknown): string {
  return b64encode(utf8(JSON.stringify(v)));
}

// pemBytes takes the .p8 file as pasted: with or without its armor lines,
// line breaks, or line breaks escaped as \n.
function pemBytes(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replace(/-----(BEGIN|END) [A-Z ]+-----/g, "")
    .replace(/\\n/g, "")
    .replace(/\s+/g, "");
  const bin = atob(body);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}
