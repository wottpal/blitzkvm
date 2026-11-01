// Approval protocol v1 (approval/PROTOCOL.md): the parts the relay needs,
// b64, kids and signed envelopes. approval/wire is the Go side.

export class WireError extends Error {}

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
const LOOKUP = new Int8Array(128).fill(-1);
for (let i = 0; i < ALPHABET.length; i++) LOOKUP[ALPHABET.charCodeAt(i)] = i;

// b64encode is base64url without padding.
export function b64encode(bytes: Uint8Array): string {
  let out = "";
  let acc = 0;
  let bits = 0;
  for (const byte of bytes) {
    acc = (acc << 8) | byte;
    bits += 8;
    while (bits >= 6) {
      bits -= 6;
      out += ALPHABET[(acc >> bits) & 63];
    }
    acc &= (1 << bits) - 1;
  }
  if (bits > 0) out += ALPHABET[(acc << (6 - bits)) & 63];
  return out;
}

// b64decode is strict like Go's RawURLEncoding.Strict(): no padding, no
// standard alphabet, no whitespace, and unused trailing bits must be zero.
export function b64decode(s: string): Uint8Array<ArrayBuffer> {
  if (s.length % 4 === 1) throw new WireError("b64 length");
  const out = new Uint8Array(Math.floor((s.length * 6) / 8));
  let acc = 0;
  let bits = 0;
  let j = 0;
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i);
    const v = c < 128 ? LOOKUP[c]! : -1;
    if (v < 0) throw new WireError("b64 character");
    acc = (acc << 6) | v;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out[j++] = (acc >> bits) & 0xff;
    }
    acc &= (1 << bits) - 1;
  }
  if (acc !== 0) throw new WireError("b64 trailing bits");
  return out;
}

// isB64 reports whether s is strict b64 of exactly n bytes (any length when
// n is undefined).
export function isB64(s: unknown, n?: number): s is string {
  if (typeof s !== "string") return false;
  try {
    const bytes = b64decode(s);
    return n === undefined || bytes.length === n;
  } catch {
    return false;
  }
}

export function hex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

const encoder = new TextEncoder();

export function utf8(s: string): Uint8Array<ArrayBuffer> {
  return encoder.encode(s) as Uint8Array<ArrayBuffer>; // always a fresh ArrayBuffer
}

export async function sha256(data: Uint8Array<ArrayBuffer>): Promise<Uint8Array<ArrayBuffer>> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
}

// kid is a key's id: hex of the first 12 bytes of SHA-256 of its X9.63 bytes.
export async function kid(x963: Uint8Array<ArrayBuffer>): Promise<string> {
  return hex((await sha256(x963)).subarray(0, 12));
}

// importPublicKey takes an X9.63 uncompressed P-256 key only, as Go does.
export async function importPublicKey(x963: Uint8Array<ArrayBuffer>): Promise<CryptoKey> {
  if (x963.length !== 65 || x963[0] !== 4) throw new WireError("public key");
  try {
    return await crypto.subtle.importKey("raw", x963, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
  } catch {
    throw new WireError("public key");
  }
}

export interface Envelope {
  t: string;
  k: string;
  p: string;
  s: string;
}

// parseEnvelope checks an envelope's shape, not its signature.
export function parseEnvelope(v: unknown): Envelope {
  if (!isObject(v)) throw new WireError("envelope");
  const { t, k, p, s } = v;
  if (typeof t !== "string" || typeof k !== "string" || !isB64(p) || !isB64(s)) throw new WireError("envelope");
  return { t, k, p, s };
}

export function signedMessage(type: string, payload: Uint8Array): Uint8Array<ArrayBuffer> {
  const head = utf8(`BKA1 ${type}\n`);
  const msg = new Uint8Array(head.length + payload.length);
  msg.set(head);
  msg.set(payload, head.length);
  return msg;
}

// digest is SHA-256 of the signed message, in hex.
export async function digest(env: Envelope): Promise<string> {
  return hex(await sha256(signedMessage(env.t, b64decode(env.p))));
}

// verify checks that env is a type envelope signed by pub (X9.63) and only
// then parses its payload: what was signed is what is read.
export async function verify(env: Envelope, type: string, pub: Uint8Array<ArrayBuffer>): Promise<unknown> {
  if (env.t !== type) throw new WireError("envelope type");
  if (env.k !== (await kid(pub))) throw new WireError("signed by an unexpected key");
  const key = await importPublicKey(pub);
  const sig = b64decode(env.s);
  const payload = b64decode(env.p);
  // WebCrypto's ECDSA signature is raw r || s already, the protocol's format.
  const ok =
    sig.length === 64 &&
    (await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, sig, signedMessage(type, payload)));
  if (!ok) throw new WireError("bad signature");
  return parseJSON(payload);
}

// peek parses the payload without checking the signature: only to find
// which key to check it with.
export function peek(env: Envelope): unknown {
  return parseJSON(b64decode(env.p));
}

const decoder = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true });

function parseJSON(bytes: Uint8Array): unknown {
  try {
    return JSON.parse(decoder.decode(bytes));
  } catch {
    throw new WireError("payload JSON");
  }
}

export function isObject(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
