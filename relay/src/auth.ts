// Relay auth (t = "relay"): how the broker and approvers prove their keys.
import { b64decode, isB64, isObject, kid, parseEnvelope, peek, verify, WireError, type Envelope } from "./wire";

// MAX_SKEW is how far `issued` may be from the relay's clock, either way.
export const MAX_SKEW = 120;

// Endpoint is what an auth is for, so one signed for an endpoint can't be
// used at another: "socket" answers a WebSocket hello.
export type Endpoint = "socket" | "inbox" | "devices" | "outbox";

export interface RelayAuth {
  v: 1;
  role: "broker" | "approver";
  endpoint: Endpoint;
  broker: string;
  key?: string;
  approver?: string;
  nonce: string;
  issued: number;
}

export interface Expected {
  role: RelayAuth["role"];
  endpoint: Endpoint;
  broker: string;
  approver?: string;
  nonce?: string;
}

// verifyRelayAuth checks a relay envelope signed by key and the fields every
// relay auth carries. It returns the whole payload too, for the fields the
// phone endpoints add.
export async function verifyRelayAuth(
  input: unknown,
  key: Uint8Array<ArrayBuffer>,
  want: Expected,
  now: number,
): Promise<{ auth: RelayAuth; payload: Record<string, unknown> }> {
  const payload = await verify(relayEnvelope(input), "relay", key);
  if (!isObject(payload)) throw new WireError("relay payload");
  const { v, role, endpoint, broker, approver, nonce, issued } = payload;
  if (v !== 1 || role !== want.role || broker !== want.broker) throw new WireError("relay payload");
  if (endpoint !== want.endpoint) throw new WireError("relay endpoint");
  if (want.approver !== undefined && approver !== want.approver) throw new WireError("relay approver");
  if (!isB64(nonce, 32) || (want.nonce !== undefined && nonce !== want.nonce)) throw new WireError("relay nonce");
  if (typeof issued !== "number" || !Number.isInteger(issued)) throw new WireError("relay payload");
  if (Math.abs(now - issued) > MAX_SKEW) throw new WireError("stale");
  const auth: RelayAuth = { v, role: want.role, endpoint: want.endpoint, broker: want.broker, nonce, issued };
  if (typeof payload.key === "string") auth.key = payload.key;
  if (typeof approver === "string") auth.approver = approver;
  return { auth, payload };
}

// verifyBrokerAuth checks the broker's answer to a hello. The relay holds no
// broker key: the payload brings it, and its kid must be the broker id the
// object belongs to (the URL's).
export async function verifyBrokerAuth(input: unknown, broker: string, nonce: string, now: number): Promise<void> {
  const env = relayEnvelope(input);
  const claimed = peek(env);
  if (!isObject(claimed) || !isB64(claimed.key, 65)) throw new WireError("broker key");
  const key = b64decode(claimed.key);
  if ((await kid(key)) !== broker) throw new WireError("broker key isn't the broker id");
  const { auth } = await verifyRelayAuth(env, key, { role: "broker", endpoint: "socket", broker, nonce }, now);
  if (auth.key !== claimed.key) throw new WireError("broker key");
}

function relayEnvelope(input: unknown): Envelope {
  const env = parseEnvelope(input);
  if (env.t !== "relay") throw new WireError("envelope type");
  return env;
}
