import { describe, expect, it } from "vitest";
import vectors from "../../approval/testdata/vectors.json";
import { pushPayload } from "../src/apns";
import { b64decode, b64encode, digest, hex, kid, signedMessage, verify, WireError, type Envelope } from "../src/wire";

const pub = (name: keyof typeof vectors.keys) => b64decode(vectors.keys[name].public);

describe("vectors made by approval/wire", () => {
  it("kids", async () => {
    for (const [name, key] of Object.entries(vectors.keys)) {
      expect(await kid(b64decode(key.public)), name).toBe(key.id);
    }
  });

  it("envelope", async () => {
    const env: Envelope = vectors.envelope.env;
    expect(hex(signedMessage(env.t, b64decode(env.p)))).toBe(vectors.envelope.signedMessageHex);
    expect(await digest(env)).toBe(vectors.envelope.digest);
    expect(await verify(env, "ask", pub("target"))).toEqual({ hello: "wörld", v: 1 });
  });

  it("rejects the tampered envelope", async () => {
    await expect(verify(vectors.envelope.tampered, "ask", pub("target"))).rejects.toThrow("bad signature");
  });

  it("rejects another key, another type", async () => {
    await expect(verify(vectors.envelope.env, "ask", pub("broker"))).rejects.toThrow(WireError);
    await expect(verify(vectors.envelope.env, "relay", pub("target"))).rejects.toThrow("envelope type");
  });

  it("relay auth", async () => {
    const payload = await verify(vectors.relayAuth, "relay", pub("phoneTransport"));
    expect(payload).toMatchObject({ v: 1, role: "approver", broker: vectors.keys.broker.id, approver: vectors.keys.phonePresence.id });
  });

  it("an approval signed by the transport key is still a valid envelope (the relay checks signers, not roles)", async () => {
    await expect(verify(vectors.approveSignedByTransport, "decision", pub("phoneTransport"))).resolves.toBeTruthy();
  });
});

describe("b64", () => {
  it("round-trips", () => {
    for (let n = 0; n < 40; n++) {
      const bytes = crypto.getRandomValues(new Uint8Array(n));
      const s = b64encode(bytes);
      expect(s).not.toMatch(/[=+/]/);
      expect(b64decode(s)).toEqual(bytes);
    }
  });

  it("accepts only the canonical encoding (unused trailing bits zero)", () => {
    const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    for (let v = 0; v < 64; v++) {
      const c = alphabet[v]!;
      // Two characters carry one byte and 4 unused bits, three carry two and 2.
      for (const [s, unused] of [[`A${c}`, 0b1111], [`AA${c}`, 0b11]] as const) {
        if (v & unused) expect(() => b64decode(s), s).toThrow("b64 trailing bits");
        else expect(b64encode(b64decode(s))).toBe(s);
      }
    }
  });

  it("is strict", () => {
    expect(b64decode("-_8")).toEqual(new Uint8Array([0xfb, 0xff]));
    for (const bad of ["AA==", "AA=", "+/8", "A", "AB", "AAB", "AA A", "AA\n", "ä"]) {
      expect(() => b64decode(bad), bad).toThrow(WireError);
    }
  });
});

describe("push payload", () => {
  const broker = vectors.keys.broker.id;
  const room = 3500 - pushPayload(broker, "").length; // ASCII: characters are bytes

  it("carries the box up to 3500 bytes", () => {
    const fits = pushPayload(broker, "A".repeat(room));
    expect(new TextEncoder().encode(fits).length).toBe(3500);
    expect(JSON.parse(fits).bka).toEqual({ b: broker, x: "A".repeat(room) });
  });

  it("leaves the box out beyond", () => {
    const over = JSON.parse(pushPayload(broker, "A".repeat(room + 1)));
    expect(over.bka).toEqual({ b: broker });
    expect(over.aps).toEqual({
      alert: { title: "Approval requested", body: "Open to review" },
      "mutable-content": 1,
      "interruption-level": "time-sensitive",
      category: "APPROVAL",
      sound: "default",
    });
  });
});
