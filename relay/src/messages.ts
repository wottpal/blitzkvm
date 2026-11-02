// The relay's messages (PROTOCOL.md, Relay): parsing what comes in, building
// what goes out.
import { isId } from "./http";
import { MAX_APPROVERS, MIN_BOX } from "./limits";
import type { Approver, Device } from "./store";
import { b64decode, importPublicKey, isB64, isObject, kid } from "./wire";

// isBox checks the shape of a sealed box; the relay can't open it.
export function isBox(v: unknown): v is string {
  if (typeof v !== "string") return false;
  try {
    return b64decode(v).length >= MIN_BOX;
  } catch {
    return false;
  }
}

export function boxMessage(box: string): string {
  return JSON.stringify({ op: "box", box });
}

// fromMessage carries a box to the broker; from is "" for an enrollment.
export function fromMessage(from: string, box: string): string {
  return JSON.stringify({ op: "from", from, box });
}

// parseAllowList takes the broker's allow message apart; undefined if any
// entry is bad, so a broken list never replaces a good one.
export async function parseAllowList(v: unknown): Promise<Approver[] | undefined> {
  if (!Array.isArray(v) || v.length > MAX_APPROVERS) return undefined;
  const out: Approver[] = [];
  const ids = new Set<string>();
  const tkids = new Set<string>();
  for (const entry of v) {
    if (!isObject(entry)) return undefined;
    const { id, transport, platform } = entry;
    if (!isId(id) || !isB64(transport, 65)) return undefined;
    if (typeof platform !== "string" || platform.length > 16) return undefined;
    const key = b64decode(transport);
    try {
      await importPublicKey(key);
    } catch {
      return undefined;
    }
    const tkid = await kid(key);
    if (ids.has(id) || tkids.has(tkid)) return undefined;
    ids.add(id);
    tkids.add(tkid);
    out.push({ id, transport, tkid, platform });
  }
  return out;
}

// parseDevice takes an APNs registration. Apple says not to assume a token
// length, so any reasonable hex goes.
export function parseDevice(v: unknown): Device | undefined {
  if (!isObject(v)) return undefined;
  const { token, env } = v;
  if (!isToken(token)) return undefined;
  if (env !== "sandbox" && env !== "production") return undefined;
  return { token: token.toLowerCase(), env };
}

// DeviceChange is what a phone's devices request asks for: register a token,
// or remove one (or, without a token, all of its own).
export type DeviceChange = { add: Device } | { remove: string | undefined };

export function parseDeviceChange(v: unknown): DeviceChange | undefined {
  if (isObject(v) && v.remove === true) {
    if (v.token === undefined) return { remove: undefined };
    return isToken(v.token) ? { remove: v.token.toLowerCase() } : undefined;
  }
  const device = parseDevice(v);
  return device ? { add: device } : undefined;
}

function isToken(v: unknown): v is string {
  return typeof v === "string" && /^(?:[0-9a-fA-F]{2}){8,100}$/.test(v);
}
