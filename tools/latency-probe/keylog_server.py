#!/usr/bin/env python3
"""Serves this folder on 127.0.0.1:8777 and logs each key the probe page sees.

Run it on the remote computer and open http://127.0.0.1:8777/latency_motion.html
there: every key's arrival goes to keys.log as "<server time> <page wall clock ms>
<handling ms> <count>". With the probe report's sent_unix, the difference (up
to the two clocks' constant offset) is the input's delay, apart from the
picture's.
"""
import http.server, os, time

DIR = os.path.dirname(os.path.abspath(__file__))
LOG = os.path.join(DIR, "keys.log")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=DIR, **kwargs)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with open(LOG, "a") as f:
            f.write(f"{time.time():.4f} {body}\n")
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", 8777), Handler).serve_forever()
