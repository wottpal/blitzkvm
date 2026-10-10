#!/usr/bin/env python3
"""Client for kvmd.py: kvm.py OP [json-args | key=value ...]"""
import json, socket, sys

PORT = 8799
req = {"op": sys.argv[1]}
for arg in sys.argv[2:]:
    if arg.startswith("{"):
        req.update(json.loads(arg))
    else:
        k, _, v = arg.partition("=")
        try:
            req[k] = json.loads(v)
        except ValueError:
            req[k] = v
c = socket.create_connection(("127.0.0.1", PORT))
c.sendall((json.dumps(req) + "\n").encode())
buf = b""
while not buf.endswith(b"\n"):
    chunk = c.recv(65536)
    if not chunk:
        break
    buf += chunk
print(buf.decode().strip())
