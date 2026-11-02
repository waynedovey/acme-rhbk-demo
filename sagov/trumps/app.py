#!/usr/bin/env python3
"""Fictional TRUMPS record verification stub. No government systems or real records."""
import hmac
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Stable synthetic DIT subject IDs are seeded by bootstrap-sagov.sh.
RECORDS = {
    "DEMO-LIC-001": {"record_id": "TRUMPS-1001", "dit_subject": "11111111-1111-4111-8111-111111111111"},
    "DEMO-LIC-002": {"record_id": "TRUMPS-1002", "dit_subject": "22222222-2222-4222-8222-222222222222"},
}
SHARED_KEY = os.environ.get("TRUMPS_API_KEY", "")
if len(SHARED_KEY) < 24:
    raise RuntimeError("TRUMPS_API_KEY must be a generated secret (24+ chars)")


def verify_record(dit_subject, licence):
    """Return a record ID only for a proven DIT-subject/record match."""
    item = RECORDS.get(licence)
    if not item or not isinstance(dit_subject, str):
        return None
    return item["record_id"] if hmac.compare_digest(item["dit_subject"], dit_subject) else None


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Never log incoming bearer keys or record payloads.
        pass

    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            return self.reply(200, {"status": "ok", "data": "FICTIONAL"})
        return self.reply(404, {"error": "not_found"})

    def do_POST(self):
        if self.path != "/verify":
            return self.reply(404, {"error": "not_found"})
        key = self.headers.get("X-Demo-API-Key", "")
        if not hmac.compare_digest(key, SHARED_KEY):
            return self.reply(401, {"verified": False, "reason": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 1 <= length <= 4096:
                return self.reply(400, {"verified": False, "reason": "invalid_size"})
            data = json.loads(self.rfile.read(length))
            subject = data.get("dit_subject", "")
            licence = data.get("licence", "")
            if not isinstance(licence, str) or len(licence) > 80:
                raise ValueError("invalid licence")
        except (ValueError, TypeError, json.JSONDecodeError):
            return self.reply(400, {"verified": False, "reason": "invalid_payload"})
        record_id = verify_record(subject, licence)
        return self.reply(200, {"verified": bool(record_id), "record_id": record_id})


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
