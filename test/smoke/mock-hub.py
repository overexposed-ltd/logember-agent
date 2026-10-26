"""Mock LogEmber hub for test/smoke/run.sh.

POST /v1/enroll  as the hub implements it (API-CONTRACT.md in the main repo): the five required
                 fields, one use per enrollment token, 201 {"ingest_key": ...}; errors as
                 {"error": {"code", "message"}}. Each request body is appended to <log> as one line.
GET  /...        static files from <www>, which holds the release assets in the layout install.sh
                 expects under LOGEMBER_RELEASE_BASE: releases/download/<version>/<asset>.

Usage: mock-hub.py <port> <www> <enrollment-token> <ingest-key> <log>
"""
import json
import sys
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

port, www, token, ingest_key, log = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
uses_left = 1
lock = threading.Lock()


class Handler(SimpleHTTPRequestHandler):
    def do_POST(self):
        global uses_left
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path != "/v1/enroll":
            return self.reply(404, "not_found", f"{self.path} not found")
        with open(log, "a") as f:
            f.write(raw.decode("utf-8", "replace").strip() + "\n")  # install.sh sends a trailing newline
        try:
            body = json.loads(raw)
        except ValueError:
            return self.reply(422, "validation_failed", "Body is not JSON.")
        fields = ("token", "hostname", "os", "arch", "agent_version")
        if not isinstance(body, dict) or not all(isinstance(body.get(k), str) and body[k] for k in fields):
            return self.reply(422, "validation_failed", f"Required fields: {', '.join(fields)}.")
        if len(body["hostname"]) > 253:
            return self.reply(422, "validation_failed", "hostname is longer than 253 characters.")
        if body["token"] != token:
            return self.reply(401, "enrollment_token_invalid", "Unknown enrollment token.")
        with lock:
            if uses_left < 1:
                return self.reply(410, "enrollment_token_exhausted", "Enrollment token has no uses left.")
            uses_left -= 1
        self.send_json(201, {"ingest_key": ingest_key})

    def reply(self, status, code, message):
        self.send_json(status, {"error": {"code": code, "message": message}})

    def send_json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


ThreadingHTTPServer(("0.0.0.0", port), partial(Handler, directory=www)).serve_forever()
