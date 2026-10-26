"""Minimal OTLP/HTTP sink for scripts/test-config.sh: appends each request body (OTLP JSON) as one line to a file."""
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, out, token = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path != "/v1/logs" or self.headers.get("Authorization") != f"Bearer {token}":
            self.send_response(401 if self.path == "/v1/logs" else 404)
            self.end_headers()
            return
        with open(out, "a") as f:
            f.write(json.dumps(json.loads(body)) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
