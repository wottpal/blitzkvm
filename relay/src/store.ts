// The relay's state for one broker, in its Durable Object's SQLite.
import { ENROLLS_PER_PAIRING, MAX_DEVICES, MAX_OBJECT_BYTES, MAX_PAIRINGS, MAX_QUEUED, MAX_QUEUED_BYTES } from "./limits";
import { hex } from "./wire";

// BROKER is the queue's recipient for boxes to the broker (approver ids are
// hex, so it can't collide with one).
export const BROKER = "broker";

export type Approver = { id: string; transport: string; tkid: string; platform: string };
export type ApnsEnv = "sandbox" | "production";
export type Device = { token: string; env: ApnsEnv };
export type Queued = { seq: number; sender: string; box: string };
export type Limit = { key: string; limit: number; window: number };

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)`,
  // The broker's allow list; tkid is kid(transport), how phone requests name their key.
  `CREATE TABLE IF NOT EXISTS approvers (id TEXT PRIMARY KEY, transport TEXT NOT NULL,
     tkid TEXT NOT NULL UNIQUE, platform TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS devices (approver TEXT NOT NULL, token TEXT NOT NULL, env TEXT NOT NULL,
     updated INTEGER NOT NULL, PRIMARY KEY (approver, token))`,
  // recipient is an approver id or BROKER; sender is BROKER, an approver id, or "" (enroll).
  `CREATE TABLE IF NOT EXISTS queue (seq INTEGER PRIMARY KEY AUTOINCREMENT, recipient TEXT NOT NULL,
     sender TEXT NOT NULL, box TEXT NOT NULL, size INTEGER NOT NULL, expires INTEGER NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS queue_recipient ON queue (recipient, seq)`,
  `CREATE TABLE IF NOT EXISTS nonces (nonce TEXT PRIMARY KEY, expires INTEGER NOT NULL)`,
  // Fixed-window rate limits: count events until reset.
  `CREATE TABLE IF NOT EXISTS counters (key TEXT PRIMARY KEY, count INTEGER NOT NULL, reset INTEGER NOT NULL)`,
  // Pairings the broker announced (hash of the QR code's token): only these take enrollments.
  `CREATE TABLE IF NOT EXISTS pairings (hash TEXT PRIMARY KEY, expires INTEGER NOT NULL, uses INTEGER NOT NULL)`,
];

export class Store {
  private constructor(private readonly sql: SqlStorage) {
    for (const statement of SCHEMA) sql.exec(statement);
  }

  // open returns the store of a broker that has authenticated here before,
  // else undefined: nothing is written for an id nobody has proved.
  static open(sql: SqlStorage): Store | undefined {
    const known = sql.exec(`SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'meta'`).toArray().length > 0;
    return known ? new Store(sql) : undefined;
  }

  // create makes the store, once the broker has authenticated.
  static create(sql: SqlStorage, broker: string): Store {
    const store = new Store(sql);
    store.sql.exec(`INSERT INTO meta (key, value) VALUES ('broker', ?) ON CONFLICT (key) DO NOTHING`, broker);
    return store;
  }

  meta(key: string): string | undefined {
    return this.sql.exec<{ value: string }>(`SELECT value FROM meta WHERE key = ?`, key).toArray()[0]?.value;
  }

  setMeta(key: string, value: string | undefined): void {
    if (value === undefined) this.sql.exec(`DELETE FROM meta WHERE key = ?`, key);
    else this.sql.exec(`INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value`, key, value);
  }

  // salt keys the hash of client addresses: an unsalted IPv4 hash reverses
  // in seconds.
  salt(): string {
    let salt = this.meta("salt");
    if (!salt) {
      salt = hex(crypto.getRandomValues(new Uint8Array(16)));
      this.setMeta("salt", salt);
    }
    return salt;
  }

  // seen is when the broker was last connected (Unix seconds).
  seen(): number {
    return Number(this.meta("seen") ?? 0);
  }

  setSeen(now: number): void {
    this.setMeta("seen", String(now));
  }

  approver(id: string): Approver | undefined {
    return this.sql.exec<Approver>(`SELECT id, transport, tkid, platform FROM approvers WHERE id = ?`, id).toArray()[0];
  }

  approverByTransport(tkid: string): Approver | undefined {
    return this.sql.exec<Approver>(`SELECT id, transport, tkid, platform FROM approvers WHERE tkid = ?`, tkid).toArray()[0];
  }

  // replaceApprovers sets the allow list. It forgets the devices and queues
  // of the approvers it drops, and returns their ids and the ids of those
  // whose transport key changed.
  replaceApprovers(list: Approver[]): { removed: string[]; rekeyed: string[] } {
    const next = new Map(list.map((a) => [a.id, a]));
    const removed: string[] = [];
    const rekeyed: string[] = [];
    for (const { id, transport } of this.sql.exec<{ id: string; transport: string }>(`SELECT id, transport FROM approvers`)) {
      const entry = next.get(id);
      if (!entry) removed.push(id);
      else if (entry.transport !== transport) rekeyed.push(id);
    }
    this.sql.exec(`DELETE FROM approvers`);
    for (const a of list) {
      this.sql.exec(`INSERT INTO approvers (id, transport, tkid, platform) VALUES (?, ?, ?, ?)`, a.id, a.transport, a.tkid, a.platform);
    }
    for (const id of removed) {
      this.sql.exec(`DELETE FROM devices WHERE approver = ?`, id);
      this.sql.exec(`DELETE FROM queue WHERE recipient = ? OR sender = ?`, id, id);
    }
    return { removed, rekeyed };
  }

  // addDevice registers an APNs token, keeping the approver's newest few.
  addDevice(approver: string, device: Device, now: number): void {
    this.sql.exec(
      `INSERT INTO devices (approver, token, env, updated) VALUES (?, ?, ?, ?)
       ON CONFLICT (approver, token) DO UPDATE SET env = excluded.env, updated = excluded.updated`,
      approver,
      device.token,
      device.env,
      now,
    );
    this.sql.exec(
      `DELETE FROM devices WHERE approver = ? AND token NOT IN
         (SELECT token FROM devices WHERE approver = ? ORDER BY updated DESC, rowid DESC LIMIT ?)`,
      approver,
      approver,
      MAX_DEVICES,
    );
  }

  devices(approver: string): Device[] {
    return this.sql.exec<Device>(`SELECT token, env FROM devices WHERE approver = ? ORDER BY updated DESC`, approver).toArray();
  }

  dropDevice(approver: string, token: string): void {
    this.sql.exec(`DELETE FROM devices WHERE approver = ? AND token = ?`, approver, token);
  }

  dropDevices(approver: string): void {
    this.sql.exec(`DELETE FROM devices WHERE approver = ?`, approver);
  }

  // addPairing records a pairing the broker announced, keeping the newest.
  addPairing(hash: string, expires: number): void {
    this.sql.exec(`INSERT INTO pairings (hash, expires, uses) VALUES (?, ?, 0) ON CONFLICT (hash) DO NOTHING`, hash, expires);
    this.sql.exec(
      `DELETE FROM pairings WHERE hash NOT IN (SELECT hash FROM pairings ORDER BY expires DESC, rowid DESC LIMIT ?)`,
      MAX_PAIRINGS,
    );
  }

  // usePairing counts an enrollment against a live pairing; false when there
  // is none, or it took its share.
  usePairing(hash: string, now: number): boolean {
    return (
      this.sql.exec(`UPDATE pairings SET uses = uses + 1 WHERE hash = ? AND expires > ? AND uses < ?`, hash, now, ENROLLS_PER_PAIRING)
        .rowsWritten > 0
    );
  }

  // enqueue keeps the newest boxes within every cap: MAX_QUEUED per
  // recipient and sender, MAX_QUEUED_BYTES per recipient, MAX_OBJECT_BYTES in
  // all. What matters to a recipient is the latest messages.
  enqueue(recipient: string, sender: string, box: string, now: number, expires: number): void {
    this.sql.exec(`DELETE FROM queue WHERE expires <= ?`, now);
    this.sql.exec(
      `INSERT INTO queue (recipient, sender, box, size, expires) VALUES (?, ?, ?, ?, ?)`,
      recipient,
      sender,
      box,
      box.length, // b64: characters are bytes
      expires,
    );
    this.sql.exec(
      `DELETE FROM queue WHERE seq IN (SELECT seq FROM (SELECT seq,
         ROW_NUMBER() OVER (PARTITION BY recipient, sender ORDER BY seq DESC) AS n,
         SUM(size) OVER (PARTITION BY recipient ORDER BY seq DESC) AS recipient_bytes,
         SUM(size) OVER (ORDER BY seq DESC) AS bytes
       FROM queue) WHERE n > ? OR recipient_bytes > ? OR bytes > ?)`,
      MAX_QUEUED,
      MAX_QUEUED_BYTES,
      MAX_OBJECT_BYTES,
    );
  }

  // queued iterates a recipient's live boxes, oldest first, without loading
  // them all.
  queued(recipient: string, now: number): Iterable<Queued> {
    return this.sql.exec<Queued>(`SELECT seq, sender, box FROM queue WHERE recipient = ? AND expires > ? ORDER BY seq`, recipient, now);
  }

  // dequeue removes a recipient's boxes up to and including seq.
  dequeue(recipient: string, seq: number): void {
    this.sql.exec(`DELETE FROM queue WHERE recipient = ? AND seq <= ?`, recipient, seq);
  }

  // useNonce records a nonce; false if it was seen before.
  useNonce(nonce: string, expires: number): boolean {
    return this.sql.exec(`INSERT INTO nonces (nonce, expires) VALUES (?, ?) ON CONFLICT DO NOTHING`, nonce, expires).rowsWritten > 0;
  }

  // spend counts one event against each limit (a count per fixed window),
  // all or nothing: false, and nothing counted, when any limit is reached.
  spend(limits: Limit[], now: number): boolean {
    const counts = limits.map(({ key }) => {
      const row = this.sql.exec<{ count: number; reset: number }>(`SELECT count, reset FROM counters WHERE key = ?`, key).toArray()[0];
      return row && row.reset > now ? row.count : 0;
    });
    if (limits.some((l, i) => counts[i]! >= l.limit)) return false;
    limits.forEach(({ key, window }, i) => {
      if (counts[i] === 0) {
        this.sql.exec(
          `INSERT INTO counters (key, count, reset) VALUES (?, 1, ?)
           ON CONFLICT (key) DO UPDATE SET count = 1, reset = excluded.reset`,
          key,
          now + window,
        );
      } else {
        this.sql.exec(`UPDATE counters SET count = count + 1 WHERE key = ?`, key);
      }
    });
    return true;
  }

  purge(now: number): void {
    this.sql.exec(`DELETE FROM queue WHERE expires <= ?`, now);
    this.sql.exec(`DELETE FROM nonces WHERE expires <= ?`, now);
    this.sql.exec(`DELETE FROM counters WHERE reset <= ?`, now);
    this.sql.exec(`DELETE FROM pairings WHERE expires <= ?`, now);
  }

  // nextExpiry is when purge next has something to do.
  nextExpiry(): number | undefined {
    const row = this.sql
      .exec<{ at: number | null }>(
        `SELECT MIN(at) AS at FROM (SELECT MIN(expires) AS at FROM queue UNION ALL
           SELECT MIN(expires) FROM nonces UNION ALL SELECT MIN(reset) FROM counters UNION ALL
           SELECT MIN(expires) FROM pairings)`,
      )
      .one();
    return row.at ?? undefined;
  }
}
