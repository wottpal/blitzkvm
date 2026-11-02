// Routes and HTTP helpers shared by the Worker and the Durable Object.
import { hex, sha256, utf8 } from "./wire";

const ID = "[0-9a-f]{24}";
const ROUTE = new RegExp(`^/v1/b/(${ID})/(?:(ws)|approver/(${ID})|(inbox|devices|outbox|enroll))$`);

export type PostKind = "inbox" | "devices" | "outbox" | "enroll";
export type Route =
  | { kind: "broker"; broker: string }
  | { kind: "approver"; broker: string; approver: string }
  | { kind: PostKind; broker: string };

export function parseRoute(path: string): Route | undefined {
  const m = ROUTE.exec(path);
  if (!m) return undefined;
  const broker = m[1]!;
  if (m[2]) return { kind: "broker", broker };
  if (m[3]) return { kind: "approver", broker, approver: m[3] };
  return { kind: m[4] as PostKind, broker };
}

export function isSocket(route: Route): route is Extract<Route, { kind: "broker" | "approver" }> {
  return route.kind === "broker" || route.kind === "approver";
}

export function isId(v: unknown): v is string {
  return typeof v === "string" && /^[0-9a-f]{24}$/.test(v);
}

// clientKey names the client's network for rate limits: its IPv4 address or
// its IPv6 /64 (one host gets a whole /64), hashed with the object's salt so
// no address is stored or recoverable.
export async function clientKey(request: Request, salt: string): Promise<string> {
  const ip = request.headers.get("cf-connecting-ip") ?? "unknown";
  return hex((await sha256(utf8(`${salt}\n${ipv6Prefix(ip) ?? ip}`))).subarray(0, 16));
}

function ipv6Prefix(ip: string): string | undefined {
  if (!ip.includes(":")) return undefined;
  const [head = "", tail, extra] = ip.toLowerCase().split("::");
  if (extra !== undefined) return undefined;
  const front = head ? head.split(":") : [];
  const back = tail ? tail.split(":") : [];
  const groups = tail === undefined ? front : [...front, ...Array<string>(Math.max(0, 8 - front.length - back.length)).fill("0"), ...back];
  return `${groups
    .slice(0, 4)
    .map((g) => g.replace(/^0+(?=.)/, ""))
    .join(":")}::/64`;
}

export function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
}

export function error(status: number, message: string): Response {
  return json({ error: message }, status);
}

// readBody reads at most limit bytes; undefined if the body is larger.
export async function readBody(request: Request, limit: number): Promise<Uint8Array | undefined> {
  if (Number(request.headers.get("content-length") ?? 0) > limit) return undefined;
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > limit) {
      await reader.cancel();
      return undefined;
    }
    chunks.push(value);
  }
  const out = new Uint8Array(size);
  let at = 0;
  for (const chunk of chunks) {
    out.set(chunk, at);
    at += chunk.byteLength;
  }
  return out;
}
