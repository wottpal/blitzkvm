// BlitzKVM's approval relay (approval/PROTOCOL.md, Relay): it carries sealed
// boxes between a broker and its approvers and wakes phones with APNs. It
// authenticates every party by key and never sees inside a box.
import type { Env } from "./env";
import { error, isSocket, parseRoute } from "./http";

export { Relay } from "./relay";

export default {
  async fetch(request, env): Promise<Response> {
    const route = parseRoute(new URL(request.url).pathname);
    if (!route) return error(404, "not found");
    if (isSocket(route)) {
      if (request.method !== "GET" || request.headers.get("upgrade")?.toLowerCase() !== "websocket") {
        return error(426, "WebSocket only");
      }
    } else if (request.method !== "POST") {
      return error(405, "POST only");
    }
    if (env.BROKERS && !env.BROKERS.split(/[\s,]+/).includes(route.broker)) return error(404, "not found");
    return env.RELAY.getByName(route.broker).fetch(request);
  },
} satisfies ExportedHandler<Env>;
