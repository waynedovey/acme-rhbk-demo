#!/usr/bin/env python3
"""mySAGOV fictional citizen portal. Real RHBK OIDC; simulated TRUMPS record claims.

Demo-only: one replica, process-local login sessions, SQLite claim ledger. The server
never matches identities on email and never gives the browser RHBK admin credentials.
"""
import base64
import hashlib
import hmac
import html
import json
import os
import secrets
import sqlite3
import time
import urllib.error
import urllib.parse
import urllib.request
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PUBLIC = os.environ["RHBK_PUBLIC_URL"].rstrip("/")
BACK = os.environ.get("RHBK_BACKCHANNEL_URL", "http://acme-keycloak-service:8080").rstrip("/")
PORTAL = os.environ["SAGOV_PORTAL_URL"].rstrip("/")
CLIENT = "mysagov"
CLIENT_SECRET = os.environ["MYSAGOV_CLIENT_SECRET"]
READER_SECRET = os.environ["SAGOV_READER_SECRET"]
TRUMPS_KEY = os.environ["TRUMPS_API_KEY"]
TRUMPS_URL = os.environ.get("TRUMPS_URL", "http://sagov-trumps:8080").rstrip("/")
DB = os.environ.get("CLAIMS_DB", "/data/claims.sqlite3")
SESSIONS = {}
PENDING = {}
SESSION_SECONDS = 1800


def request_json(url, data=None, headers=None, method=None):
    body = urllib.parse.urlencode(data).encode() if isinstance(data, dict) else data
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=8) as response:
        return json.loads(response.read(16384))


def token(realm, client, secret, grant):
    payload = dict(grant, client_id=client, client_secret=secret)
    return request_json(BACK + "/realms/" + realm + "/protocol/openid-connect/token", payload)


def admin_links(realm, subject):
    # Separate realm-scoped service-account credentials; view-users only.
    access = token(realm, "sagov-link-reader", READER_SECRET,
                   {"grant_type": "client_credentials"})["access_token"]
    url = BACK + "/admin/realms/" + realm + "/users/" + urllib.parse.quote(subject, safe="") + "/federated-identity"
    return request_json(url, headers={"Authorization": "Bearer " + access})


def upstream_subject(links, provider):
    matches = [x.get("userId", "") for x in links if x.get("identityProvider") == provider]
    return matches[0] if len(matches) == 1 and matches[0] else None


def verify_chain(sa_sub):
    """Resolve SA ID -> IDX subject -> DIT subject via *RHBK-stored* links."""
    idx_sub = upstream_subject(admin_links("sa-id", sa_sub), "idx")
    if not idx_sub:
        raise ValueError("IDX account is not linked to this SA ID")
    dit_sub = upstream_subject(admin_links("idx", idx_sub), "dit")
    if not dit_sub:
        raise ValueError("IDX has no verified DIT authentication link; choose DIT login in IDX")
    return idx_sub, dit_sub


def verify_trumps(dit_sub, licence):
    payload = json.dumps({"dit_subject": dit_sub, "licence": licence}).encode()
    return request_json(TRUMPS_URL + "/verify", data=payload, method="POST",
                        headers={"Content-Type": "application/json", "X-Demo-API-Key": TRUMPS_KEY})


def connect():
    return sqlite3.connect(DB, timeout=10)


def init_db():
    with connect() as db:
        db.execute("""CREATE TABLE IF NOT EXISTS links (
            record_id TEXT NOT NULL UNIQUE,
            sa_sub TEXT NOT NULL,
            idx_sub TEXT NOT NULL,
            dit_sub TEXT NOT NULL,
            linked_at TEXT NOT NULL
        )""")
        db.execute("""CREATE TABLE IF NOT EXISTS audit (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sa_sub TEXT NOT NULL,
            decision TEXT NOT NULL,
            record_id TEXT NOT NULL,
            at TEXT NOT NULL
        )""")


def record_event(sa_sub, decision, record_id=""):
    with connect() as db:
        db.execute("INSERT INTO audit(sa_sub,decision,record_id,at) VALUES(?,?,?,datetime('now'))",
                   (sa_sub, decision, record_id))


def save_verified_link(sa_sub, idx_sub, dit_sub, record_id):
    with connect() as db:
        owner = db.execute("SELECT sa_sub FROM links WHERE record_id=?", (record_id,)).fetchone()
        if owner and owner[0] != sa_sub:
            db.execute("INSERT INTO audit(sa_sub,decision,record_id,at) VALUES(?,?,?,datetime('now'))",
                       (sa_sub, "DENIED_RECORD_ALREADY_CLAIMED", record_id))
            return False
        db.execute("INSERT OR IGNORE INTO links VALUES(?,?,?,?,datetime('now'))",
                   (record_id, sa_sub, idx_sub, dit_sub))
        db.execute("INSERT INTO audit(sa_sub,decision,record_id,at) VALUES(?,?,?,datetime('now'))",
                   (sa_sub, "VERIFIED_LINK", record_id))
        return True


def linked_records(sa_sub):
    with connect() as db:
        return db.execute("SELECT record_id,linked_at FROM links WHERE sa_sub=? ORDER BY linked_at DESC",
                          (sa_sub,)).fetchall()


def audit_records(sa_sub):
    with connect() as db:
        return db.execute("SELECT decision,record_id,at FROM audit WHERE sa_sub=? ORDER BY id DESC LIMIT 12",
                          (sa_sub,)).fetchall()


def webauth_url(state, challenge, action=None):
    query = {"client_id": CLIENT, "redirect_uri": PORTAL + "/callback",
             "response_type": "code", "scope": "openid profile email",
             "state": state, "code_challenge": challenge, "code_challenge_method": "S256"}
    if action:
        query["kc_action"] = action
    return PUBLIC + "/realms/sa-id/protocol/openid-connect/auth?" + urllib.parse.urlencode(query)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def esc(s):
    return html.escape(str(s), quote=True)


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Paths may contain OAuth authorization codes; never log them.
        pass

    def respond(self, status, body, headers=None, content_type="text/html; charset=utf-8"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; base-uri 'none'")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, url, cookie=None, flow=None):
        headers = {"Location": url}
        if cookie is not None:
            headers["Set-Cookie"] = "sagov_session=" + cookie + "; Path=/; Max-Age=1800; Secure; HttpOnly; SameSite=Lax"
        elif flow is not None:
            headers["Set-Cookie"] = "sagov_flow=" + flow + "; Path=/; Max-Age=600; Secure; HttpOnly; SameSite=Lax"
        self.respond(303, b"", headers)

    def current(self):
        jar = SimpleCookie()
        try:
            jar.load(self.headers.get("Cookie", ""))
            sid = jar["sagov_session"].value
        except (KeyError, Exception):
            return None, None
        session = SESSIONS.get(sid)
        if not session or session["expires"] <= time.time():
            SESSIONS.pop(sid, None)
            return None, None
        return sid, session

    def page(self, title, body):
        style = """body{font:16px system-ui;background:#f6f8fb;color:#202c39;max-width:850px;margin:45px auto;padding:0 20px}
        main{background:#fff;border-radius:12px;padding:25px;box-shadow:0 2px 18px #dce4ed}
        a,button{display:inline-block;margin:6px 5px 6px 0;padding:9px 14px;background:#2462a7;color:white;border:0;border-radius:6px;text-decoration:none;font:inherit;cursor:pointer}
        input{padding:10px;margin:8px 0} .warn{background:#fff3ce;padding:12px;border-radius:6px}
        .ok{background:#e6f5eb;padding:12px;border-radius:6px} table{border-collapse:collapse;width:100%}td,th{padding:8px;border-bottom:1px solid #ddd;text-align:left} small{color:#506070}"""
        doc = ('<!doctype html><html lang="en"><head><meta charset="utf-8"><title>' + esc(title)
               + '</title><style>' + style + '</style></head><body><main><h1>mySAGOV — fictional demo</h1>'
               + '<p><small>Educational simulation. No government records or systems are connected.</small></p>'
               + body + '</main></body></html>')
        self.respond(200, doc)

    def do_GET(self):
        path = urllib.parse.urlparse(self.path).path
        if path == "/health":
            return self.respond(200, "ok", content_type="text/plain")
        if path in ("/login", "/connect-dit"):
            _, session = self.current()
            if path == "/connect-dit" and not session:
                return self.redirect("/")
            state = secrets.token_urlsafe(24)
            verifier = secrets.token_urlsafe(48)
            challenge = b64url(hashlib.sha256(verifier.encode()).digest())
            flow_nonce = secrets.token_urlsafe(24)
            PENDING[state] = {"expires": time.time() + 600, "verifier": verifier,
                              "flow_nonce": flow_nonce,
                              "expected_sub": session["sub"] if path == "/connect-dit" else None}
            return self.redirect(webauth_url(state, challenge, "idp_link:idx" if path == "/connect-dit" else None),
                                 flow=flow_nonce)
        if path == "/callback":
            args = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            state = args.get("state", [""])[0]
            entry = PENDING.pop(state, None)
            cookie_jar = SimpleCookie()
            try:
                cookie_jar.load(self.headers.get("Cookie", ""))
                flow_cookie = cookie_jar["sagov_flow"].value
            except (KeyError, ValueError):
                flow_cookie = ""
            if (not entry or entry["expires"] <= time.time() or "code" not in args
                    or not hmac.compare_digest(entry["flow_nonce"], flow_cookie)):
                return self.page("Sign-in failed", "<p class='warn'>Invalid or expired login attempt. Please try again.</p><a href='/'>Home</a>")
            try:
                t = token("sa-id", CLIENT, CLIENT_SECRET,
                          {"grant_type": "authorization_code", "code": args["code"][0],
                           "redirect_uri": PORTAL + "/callback", "code_verifier": entry["verifier"]})
                user = request_json(BACK + "/realms/sa-id/protocol/openid-connect/userinfo",
                                    headers={"Authorization": "Bearer " + t["access_token"]})
                sub = user["sub"]
                if entry["expected_sub"] and not hmac.compare_digest(entry["expected_sub"], sub):
                    return self.page("Account mismatch", "<p class='warn'>Account switching during linking was blocked.</p><a href='/'>Home</a>")
                session_id = secrets.token_urlsafe(32)
                SESSIONS[session_id] = {"sub": sub, "display": user.get("preferred_username", "citizen"),
                                        "csrf": secrets.token_urlsafe(24), "expires": time.time() + SESSION_SECONDS}
                return self.redirect("/", session_id)
            except (KeyError, ValueError, urllib.error.URLError):
                return self.page("Sign-in failed", "<p class='warn'>Identity provider sign-in could not be completed.</p><a href='/'>Try again</a>")
        if path == "/logout":
            sid, _ = self.current()
            if sid:
                SESSIONS.pop(sid, None)
            url = PUBLIC + "/realms/sa-id/protocol/openid-connect/logout?" + urllib.parse.urlencode(
                {"client_id": CLIENT, "post_logout_redirect_uri": PORTAL + "/"})
            return self.redirect(url, "")
        sid, session = self.current()
        if not session:
            return self.page("Welcome", "<h2>Independent South Australian ID</h2>"
                             "<p>Create a new citizen account without an existing DIT or TRUMPS record.</p>"
                             "<a href='/login'>Sign in / Register new SA ID</a>"
                             "<p><small>Select Register on the RHBK login page. You can enrol a passkey from your RHBK Account Console.</small></p>")
        sub = session["sub"]
        claims = linked_records(sub)
        rows = "".join("<tr><td>" + esc(a) + "</td><td>" + esc(b) + "</td></tr>" for a, b in claims)
        events = "".join("<tr><td>" + esc(a) + "</td><td>" + esc(b) + "</td><td>" + esc(c)
                         + "</td></tr>" for a, b, c in audit_records(sub))
        form = ('<form action="/claim" method="post"><label>Fictional licence number '
                '<input name="licence" required maxlength="80" placeholder="DEMO-LIC-001"></label>'
                '<input type="hidden" name="csrf" value="' + esc(session["csrf"]) + '">'
                '<button type="submit">Verify and claim licence</button></form>')
        return self.page("Dashboard", "<p class='ok'>Signed in as <b>" + esc(session["display"]) + "</b> through SA ID.</p>"
                         "<a href='/connect-dit'>1. Connect DIT identity through IDX</a><h3>2. Claim a fictional driver's licence</h3>"
                         "<p>Authenticate with DIT in IDX first. Email matching is never used for proof.</p>"
                         + form + "<h3>My authorised records</h3><table><tr><th>Record</th><th>Linked at (UTC)</th></tr>"
                         + rows + "</table><h3>My audit events</h3><table><tr><th>Decision</th><th>Record</th><th>UTC</th></tr>"
                         + events + "</table><a href='/logout'>Sign out</a>")

    def do_POST(self):
        if urllib.parse.urlparse(self.path).path != "/claim":
            return self.respond(404, "Not found")
        _, session = self.current()
        if not session:
            return self.respond(401, "Login required")
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 1 <= length <= 2048:
                raise ValueError()
            data = urllib.parse.parse_qs(self.rfile.read(length).decode())
            csrf = data.get("csrf", [""])[0]
            if not hmac.compare_digest(csrf, session["csrf"]):
                return self.respond(403, "CSRF rejected")
            licence = data.get("licence", [""])[0].strip().upper()
            if not 1 <= len(licence) <= 80:
                raise ValueError()
        except (ValueError, UnicodeDecodeError):
            return self.respond(400, "Bad request")
        sa_sub = session["sub"]
        try:
            idx_sub, dit_sub = verify_chain(sa_sub)
            result = verify_trumps(dit_sub, licence)
            if not result.get("verified") or not result.get("record_id"):
                record_event(sa_sub, "DENIED_RECORD_MISMATCH")
                return self.page("Not verified", "<p class='warn'>DIT identity does not own that fictional record.</p><a href='/'>Back</a>")
            ok = save_verified_link(sa_sub, idx_sub, dit_sub, result["record_id"])
            return self.page("Claim result", ("<p class='ok'>Verified and linked.</p>" if ok else
                        "<p class='warn'>This record is already claimed by another SA ID. No second link was created.</p>") + "<a href='/'>Dashboard</a>")
        except ValueError as err:
            record_event(sa_sub, "DENIED_UNLINKED_IDENTITY")
            return self.page("More verification required", "<p class='warn'>" + esc(err) + "</p><a href='/'>Back</a>")
        except (urllib.error.URLError, KeyError, json.JSONDecodeError):
            record_event(sa_sub, "ERROR_UPSTREAM_UNAVAILABLE")
            return self.page("Service unavailable", "<p class='warn'>A verification dependency is unavailable. No claim was created.</p><a href='/'>Back</a>")


if __name__ == "__main__":
    init_db()
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
