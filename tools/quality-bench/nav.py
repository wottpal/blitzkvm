#!/usr/bin/env python3
"""Closed-loop pointer control over kvmd (relative mouse + video feedback).

nav.py locate            -> prints the cursor tip (x, y) on the captured screen
nav.py goto X Y          -> steers the cursor tip to (X, Y)
nav.py click             -> left click
"""
import json, os, socket, sys, time
import numpy as np
from PIL import Image

import score  # noqa: E402 (creates the output folders)
S = score.S


def call(**req):
    c = socket.create_connection(("127.0.0.1", 8799))
    c.sendall((json.dumps(req) + "\n").encode())
    buf = b""
    while not buf.endswith(b"\n"):
        chunk = c.recv(65536)
        if not chunk:
            break
        buf += chunk
    return json.loads(buf)


def frame(name, settle=0.35):
    path = f"{S}/shots/nav_{name}.png"
    call(op="snap", path=path, settle=settle)
    return np.asarray(Image.open(path).convert("L"), dtype=np.int16)


def move(dx, dy, step=4, pause=0.008):
    """Moves in small reports so macOS applies little acceleration."""
    sx = 1 if dx > 0 else -1
    sy = 1 if dy > 0 else -1
    ax, ay = abs(dx), abs(dy)
    while ax > 0 or ay > 0:
        mx = min(step, ax)
        my = min(step, ay)
        call(op="rel", dx=sx * mx, dy=sy * my)
        ax -= mx
        ay -= my
        time.sleep(pause)


def clusters(mask):
    ys, xs = np.nonzero(mask)
    if len(xs) == 0:
        return []
    pts = sorted(zip(xs.tolist(), ys.tolist()))
    groups = []
    for x, y in pts:
        for g in groups:
            if abs(g["cx"] - x) < 30 and abs(g["cy"] - y) < 30:
                g["pts"].append((x, y))
                g["cx"] = sum(p[0] for p in g["pts"]) / len(g["pts"])
                g["cy"] = sum(p[1] for p in g["pts"]) / len(g["pts"])
                break
        else:
            groups.append({"pts": [(x, y)], "cx": x, "cy": y})
    return [g for g in groups if len(g["pts"]) >= 8]


def locate():
    a = frame("a")
    move(24, 24)
    b = frame("b")
    groups = clusters(np.abs(a - b) > 45)
    if not groups:
        return None
    # The cursor moved down-right: the new position is the later cluster.
    g = max(groups, key=lambda g: g["cx"] + g["cy"])
    xs = [p[0] for p in g["pts"]]
    ys = [p[1] for p in g["pts"]]
    return min(xs), min(ys)


def goto(tx, ty, tolerance=2, rounds=10):
    pos = locate()
    gain = [2.4, 2.4]  # report units per screen pixel (slow moves are decelerated)
    for _ in range(rounds):
        if pos is None:
            print("cursor not found")
            return None
        ex, ey = tx - pos[0], ty - pos[1]
        print("at", pos, "error", (ex, ey), "gain", [round(g, 2) for g in gain])
        if abs(ex) <= tolerance and abs(ey) <= tolerance:
            return pos
        before = frame("g0", settle=0.2)
        cx = int(round(ex * gain[0])) or (1 if ex > 0 else -1 if ex < 0 else 0)
        cy = int(round(ey * gain[1])) or (1 if ey > 0 else -1 if ey < 0 else 0)
        move(cx, cy)
        after = frame("g1", settle=0.3)
        groups = clusters(np.abs(before - after) > 45)
        if not groups:
            pos = locate()
            continue
        # New position: the cluster nearest the target.
        g = min(groups, key=lambda g: (g["cx"] - tx) ** 2 + (g["cy"] - ty) ** 2)
        new = (min(p[0] for p in g["pts"]), min(p[1] for p in g["pts"]))
        for i, (c, d) in enumerate(((cx, new[0] - pos[0]), (cy, new[1] - pos[1]))):
            if abs(c) >= 8 and d != 0 and (c > 0) == (d > 0):
                gain[i] = min(max(0.5 * gain[i] + 0.5 * c / d, 0.5), 6)
        pos = new
    return pos


if __name__ == "__main__":
    op = sys.argv[1]
    if op == "locate":
        print(locate())
    elif op == "goto":
        print(goto(int(sys.argv[2]), int(sys.argv[3])))
    elif op == "click":
        print(call(op="click"))
    elif op == "move":
        move(int(sys.argv[2]), int(sys.argv[3]))
