"""Minimal OTLP/HTTP sink for the scripts in scripts/ and test/: appends each request body (OTLP JSON) as one line to a file.

Usage: otlp-sink.py PORT OUT TOKEN [PLAN [ACCESS_LOG]]
PLAN (optional) is a file with one scripted response per line, used up from the top for the next
requests ("429 3" = 429 with Retry-After: 3, "503" = 503 without Retry-After); once it is empty
every request gets 200. Rejected requests are not written to OUT. ACCESS_LOG gets one
"<unix time> <status>" line per request.
"""
import json
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, out, token = int(sys.argv[1]), sys.argv[2], sys.argv[3]
plan_file = sys.argv[4] if len(sys.argv) > 4 else None
access_log = sys.argv[5] if len(sys.argv) > 5 else None
lock = threading.Lock()


def next_planned():
    """Pops the first line of the plan file: (status, retry_after) or None."""
    if not plan_file:
        return None
    try:
        with open(plan_file) as f:
            lines = [line for line in f.read().splitlines() if line.strip()]
    except FileNotFoundError:
        return None
    if not lines:
        return None
    with open(plan_file, "w") as f:
        f.write("".join(line + "\n" for line in lines[1:]))
    parts = lines[0].split()
    return int(parts[0]), (parts[1] if len(parts) > 1 else None)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path != "/v1/logs" or self.headers.get("Authorization") != f"Bearer {token}":
            self.respond(401 if self.path == "/v1/logs" else 404)
            return
        with lock:
            planned = next_planned()
            if planned:
                self.respond(*planned)
                return
            with open(out, "a") as f:
                f.write(json.dumps(json.loads(body)) + "\n")
            self.respond(200, body=b"{}")

    def respond(self, status, retry_after=None, body=b""):
        self.send_response(status)
        if retry_after is not None:
            self.send_header("Retry-After", retry_after)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        if access_log:
            with open(access_log, "a") as f:
                f.write(f"{time.time():.3f} {status}\n")

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
