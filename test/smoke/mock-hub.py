"""Mock LogEmber hub for test/smoke/run.sh.

POST /v1/enroll  as the hub implements it (API-CONTRACT.md in the main repo): the five required
                 fields, one use per enrollment token, 201 {"ingest_key": ...}; errors as
                 {"error": {"code", "message"}}. Each request body is appended to <log> as one line.
GET  /v1/agent/config     one file source, /srv/smoke/app.log (service smoke-app), with an ETag;
                          304 on a matching If-None-Match. Needs the ingest key.
POST /v1/agent/heartbeat  204; each body is appended to heartbeat.jsonl next to <log>.
GET  /...        static files from <www>, which holds the release assets in the layout install.sh
                 expects under LOGEMBER_RELEASE_BASE: releases/download/<version>/<asset>.

Usage: mock-hub.py <port> <www> <enrollment-token> <ingest-key> <log>
"""
import json
import os
import sys
import threading
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

port, www, token, ingest_key, log = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
uses_left = 1
lock = threading.Lock()
SOURCES = json.dumps({"sources": [{"type": "file", "path": "/srv/smoke/app.log", "service_name": "smoke-app"}]}).encode()
ETAG = '"smoke-1"'


class Handler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/v1/agent/config":
            return super().do_GET()
        if self.headers.get("Authorization") != f"Bearer {ingest_key}":
            return self.reply(401, "ingest_key_invalid", "Ingest key is missing, unknown or revoked.")
        if self.headers.get("If-None-Match") == ETAG:
            self.send_response(304)
            self.send_header("ETag", ETAG)
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("ETag", ETAG)
        self.send_header("Content-Length", str(len(SOURCES)))
        self.end_headers()
        self.wfile.write(SOURCES)

    def do_POST(self):
        global uses_left
        raw = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if self.path == "/v1/agent/heartbeat":
            if self.headers.get("Authorization") != f"Bearer {ingest_key}":
                return self.reply(401, "ingest_key_invalid", "Ingest key is missing, unknown or revoked.")
            with open(os.path.join(os.path.dirname(log), "heartbeat.jsonl"), "a") as f:
                f.write(raw.decode("utf-8", "replace").strip() + "\n")
            self.send_response(204)
            self.end_headers()
            return
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
