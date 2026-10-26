"""Mock of the hub's agent API for scripts/test-sync.sh (API-CONTRACT.md in the main repo, "Internal").

GET /v1/agent/config serves <dir>/config.json with an ETag derived from the body (304 on a matching
If-None-Match), or the HTTP status in <dir>/config.status if that file exists. POST /v1/agent/heartbeat
validates the body as the hub does and answers 204. Every request is appended to <dir>/requests.jsonl.
"""
import hashlib
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port, workdir, key = int(sys.argv[1]), sys.argv[2], sys.argv[3]


class Handler(BaseHTTPRequestHandler):
    def handle_one(self, method):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(workdir, "requests.jsonl"), "a") as f:
            headers = {k.lower(): v for k, v in self.headers.items()}
            f.write(json.dumps({"method": method, "path": self.path, "headers": headers, "body": body.decode()}) + "\n")
        if self.headers.get("Authorization") != f"Bearer {key}":
            return self.error(401, "ingest_key_invalid", "Ingest key is missing, unknown or revoked.")
        if (method, self.path) == ("GET", "/v1/agent/config"):
            return self.config()
        if (method, self.path) == ("POST", "/v1/agent/heartbeat"):
            return self.heartbeat(body)
        return self.error(404, "not_found", "Not found.")

    def config(self):
        status = os.path.join(workdir, "config.status")
        if os.path.exists(status):
            return self.error(int(open(status).read()), "server_error", "Mock hub error.")
        with open(os.path.join(workdir, "config.json"), "rb") as f:
            body = f.read()
        etag = '"%s"' % hashlib.sha256(body).hexdigest()[:16]
        if self.headers.get("If-None-Match") == etag:
            self.send_response(304)
            self.send_header("ETag", etag)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("ETag", etag)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def heartbeat(self, body):
        try:
            hb = json.loads(body)
            ok = (
                isinstance(hb.get("agent_version"), str) and hb["agent_version"]
                and isinstance(hb.get("status"), str) and hb["status"]
                and type(hb.get("buffer_bytes")) is int and hb["buffer_bytes"] >= 0
            )
        except ValueError:
            ok = False
        if not ok:
            return self.error(422, "validation_failed", "Invalid heartbeat.")
        self.send_response(204)
        self.end_headers()

    def error(self, code, error, message):
        body = json.dumps({"error": {"code": error, "message": message}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.handle_one("GET")

    def do_POST(self):
        self.handle_one("POST")

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
