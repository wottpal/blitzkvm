#!/usr/bin/env python3
"""Persistent KVM session over blitzkvm-engine with a control API on 127.0.0.1.

kvmd.py ENGINE ADDRESS PORT [--h265]
Commands (JSON lines): key {combo}, paste {text}, rel {dx,dy,buttons}, click,
abs {x,y,buttons}, snap {path}, rpc {method,params}, stats, record {path,seconds},
reconnect {h265}, quit.
"""
import json, os, socket, struct, subprocess, sys, threading, time

engine, address, sock_path = sys.argv[1], sys.argv[2], sys.argv[3]
h265 = "--h265" in sys.argv

USAGE = {"cmd": 0xE3, "shift": 0xE1, "ctrl": 0xE0, "alt": 0xE2, "space": 0x2C, "enter": 0x28, "esc": 0x29,
         "tab": 0x2B, "backspace": 0x2A, "left": 0x50, "right": 0x4F, "up": 0x52, "down": 0x51, "f": 0x09}
for i, ch in enumerate("abcdefghijklmnopqrstuvwxyz"):
    USAGE[ch] = 0x04 + i
for i, ch in enumerate("1234567890"):
    USAGE[ch] = 0x1E + i


class Session:
    def __init__(self):
        self.lock = threading.Lock()
        self.cond = threading.Condition()
        self.gop = []          # AUs since the last keyframe (bytes)
        self.codec = None
        self.snapshot = {}
        self.stats = {}
        self.results = {}
        self.next_id = 100
        self.recording = None  # (file, until)
        self.au_log = []       # (time, size, keyframe) for the last ~10 s
        self.start(h265)

    def start(self, offer_h265):
        self.proc = subprocess.Popen([engine], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=self.reader, args=(self.proc,), daemon=True).start()
        self.cmd({"id": 1, "cmd": "connect", "baseURL": address, "offerH265": offer_h265})

    def send(self, typ, payload):
        with self.lock:
            self.proc.stdin.write(struct.pack(">IB", len(payload) + 1, typ) + payload)
            self.proc.stdin.flush()

    def cmd(self, obj):
        self.send(0x10, json.dumps(obj).encode())

    def call(self, obj, timeout=35):
        with self.cond:
            self.next_id += 1
            cid = self.next_id
        obj["id"] = cid
        self.cmd(obj)
        deadline = time.time() + timeout
        with self.cond:
            while cid not in self.results and time.time() < deadline:
                self.cond.wait(0.2)
            return self.results.pop(cid, {"error": "timeout"})

    def reader(self, proc):
        f = proc.stdout
        while True:
            hdr = f.read(4)
            if len(hdr) < 4:
                return
            n = struct.unpack(">I", hdr)[0]
            frame = f.read(n)
            typ, payload = frame[0], frame[1:]
            if typ == 0x02:
                codec, flags, ts, nanos = struct.unpack(">BBIQ", payload[:14])
                data = payload[14:]
                now = time.time()
                with self.cond:
                    self.codec = "h265" if codec == 2 else "h264"
                    if flags & 1:
                        self.gop = [data]
                    elif self.gop:
                        self.gop.append(data)
                    self.au_log.append((now, len(data), flags & 1))
                    self.au_log = [a for a in self.au_log if now - a[0] < 10]
                    if self.recording:
                        rf, until = self.recording
                        rf.write(data)
                        if now > until:
                            rf.close()
                            self.recording = None
                    self.cond.notify_all()
            elif typ == 0x01:
                ev = json.loads(payload)
                if ev["type"] == "snapshot":
                    self.snapshot = ev["snapshot"]
                elif ev["type"] == "stats":
                    self.stats = ev["stats"]
            elif typ in (0x03, 0x04):
                r = json.loads(payload)
                with self.cond:
                    self.results[r["id"]] = r
                    self.cond.notify_all()

    def key(self, combo):
        parts = combo.lower().split("+")
        usages = [USAGE[p] for p in parts]
        for u in usages:
            self.send(0x11, bytes([u, 1]))
            time.sleep(0.03)
        for u in reversed(usages):
            self.send(0x11, bytes([u, 0]))
            time.sleep(0.03)

    def snap(self, path, settle=0.0):
        time.sleep(settle)
        with self.cond:
            gop = list(self.gop)
            codec = self.codec
        if not gop:
            return {"error": "no video"}
        tmp = path + "." + codec
        with open(tmp, "wb") as f:
            for au in gop:
                f.write(au)
        r = subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", tmp, "-update", "1", path], capture_output=True)
        os.unlink(tmp)
        return {"ok": r.returncode == 0, "frames": len(gop), "err": r.stderr.decode()[-300:]}


s = Session()
srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sock_path)))
srv.listen(4)


def handle(conn):
    with conn:
        data = b""
        while not data.endswith(b"\n"):
            chunk = conn.recv(65536)
            if not chunk:
                break
            data += chunk
        req = json.loads(data or b"{}")
        op = req.get("op")
        try:
            if op == "key":
                s.key(req["combo"]); out = {"ok": True}
            elif op == "paste":
                out = s.call({"cmd": "paste", "text": req["text"], "delay": req.get("delay", 20)}, timeout=120)
            elif op == "rel":
                dx, dy, b = req.get("dx", 0), req.get("dy", 0), req.get("buttons", 0)
                s.send(0x13, struct.pack(">hhB", dx, dy, b)); out = {"ok": True}
            elif op == "click":
                s.send(0x13, struct.pack(">hhB", 0, 0, 1)); time.sleep(0.06)
                s.send(0x13, struct.pack(">hhB", 0, 0, 0)); out = {"ok": True}
            elif op == "abs":
                s.send(0x12, struct.pack(">iiB", req["x"], req["y"], req.get("buttons", 0))); out = {"ok": True}
            elif op == "snap":
                out = s.snap(req["path"], req.get("settle", 0.0))
            elif op == "rpc":
                obj = {"cmd": "rpc", "method": req["method"]}
                if "params" in req:
                    obj["params"] = req["params"]
                out = s.call(obj)
            elif op == "stats":
                with s.cond:
                    log = list(s.au_log)
                dur = (log[-1][0] - log[0][0]) if len(log) > 1 else 0
                out = {"snapshot": {k: s.snapshot.get(k) for k in ["Phase", "Status", "VideoWidth", "VideoHeight", "VideoFPS", "Quality"]},
                       "stats": s.stats.get("stats", {}), "codec": s.codec,
                       "aus": len(log), "fps": len(log) / dur if dur else 0,
                       "kbps": sum(a[1] for a in log) * 8 / 1000 / dur if dur else 0,
                       "keyframes": [a[1] for a in log if a[2]][-5:]}
            elif op == "record":
                with s.cond:
                    rf = open(req["path"], "wb")
                    # Start with the current GOP so the clip decodes from its first byte.
                    for au in s.gop:
                        rf.write(au)
                    s.recording = (rf, time.time() + req.get("seconds", 5))
                    t0 = time.time()
                time.sleep(req.get("seconds", 5) + 0.3)
                with s.cond:
                    log = [a for a in s.au_log if a[0] >= t0]
                dur = (log[-1][0] - log[0][0]) if len(log) > 1 else 0
                out = {"ok": True, "aus": len(log), "fps": round(len(log) / dur, 2) if dur else 0,
                       "kbps": round(sum(a[1] for a in log) * 8 / 1000 / dur) if dur else 0,
                       "max_au": max((a[1] for a in log), default=0), "keyframes": sum(a[2] for a in log)}
            elif op == "reconnect":
                s.cmd({"id": 2, "cmd": "disconnect"}); time.sleep(0.3)
                s.proc.stdin.close(); s.proc.wait(timeout=5)
                with s.cond:
                    s.gop = []
                s.start(req.get("h265", False)); time.sleep(req.get("wait", 3))
                out = {"ok": True}
            elif op == "quit":
                conn.sendall(b'{"ok": true}\n')
                os._exit(0)
            else:
                out = {"error": f"unknown op {op}"}
        except Exception as e:  # report, keep serving
            out = {"error": repr(e)}
        conn.sendall((json.dumps(out) + "\n").encode())


while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
