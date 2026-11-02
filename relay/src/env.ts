import type { Relay } from "./relay";

declare global {
  namespace Cloudflare {
    interface Env {
      RELAY: DurableObjectNamespace<Relay>;
      // Secrets (wrangler secret put). Without the first three the relay
      // queues boxes but sends no pushes.
      APNS_KEY?: string;
      APNS_KEY_ID?: string;
      APNS_TEAM_ID?: string;
      APNS_TOPIC?: string;
      // Optional: the broker ids this relay serves (space- or comma-
      // separated). Unset, any broker that proves its key may use it.
      BROKERS?: string;
    }
  }
}

export type Env = Cloudflare.Env;
