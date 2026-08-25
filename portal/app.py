#!/usr/bin/env python3
import base64
import html
import json
import os
import secrets
import ssl
import time
import urllib.parse
import urllib.request
from http import cookies
from wsgiref.simple_server import make_server

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "").rstrip("/")
REALM = os.environ.get("REALM", "acme-demo")
CLIENT_ID = os.environ.get("CLIENT_ID", "acme-portal")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET", "")
SESSIONS = {}
STATES = {}
VERIFY_TLS = os.environ.get("VERIFY_TLS", "false").lower() == "true"
SSL_CONTEXT = ssl.create_default_context() if VERIFY_TLS else ssl._create_unverified_context()

def external_base(environ):
    proto = environ.get("HTTP_X_FORWARDED_PROTO", "http").split(",")[0].strip()
    host = environ.get("HTTP_X_FORWARDED_HOST") or environ.get("HTTP_HOST")
    return f"{proto}://{host}"

def response(start_response, body, status="200 OK", headers=None):
    h = [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "no-store")]
    if headers:
        h.extend(headers)
    start_response(status, h)
    return [body.encode()]

def layout(title, body):
    return f'''<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(title)}</title><style>
body{{font-family:Arial,Helvetica,sans-serif;margin:0;background:#f5f5f5;color:#151515}}header{{background:#151515;color:#fff;padding:22px 7vw;border-bottom:5px solid #ee0000}}main{{max-width:1050px;margin:30px auto;padding:0 24px}}.card{{background:#fff;border:1px solid #ddd;border-radius:8px;padding:24px;margin:18px 0;box-shadow:0 2px 5px #00000010}}a.button{{display:inline-block;background:#ee0000;color:#fff;padding:12px 18px;border-radius:4px;text-decoration:none;margin:6px 8px 6px 0;font-weight:bold}}a.secondary{{background:#4f5255}}code,pre{{background:#f0f0f0;padding:3px 6px;border-radius:3px}}pre{{padding:16px;overflow:auto}}.tag{{display:inline-block;background:#eee;padding:5px 9px;margin:3px;border-radius:12px;font-size:12px}}small{{color:#666}}</style></head><body>
<header><strong>ACME Digital Identity Demo</strong></header><main>{body}</main></body></html>'''

def parse_cookie(environ):
    raw = environ.get("HTTP_COOKIE", "")
    c = cookies.SimpleCookie(); c.load(raw)
    return c.get("sid").value if c.get("sid") else None

def jwt_claims(token):
    try:
        part = token.split('.')[1]
        part += '=' * (-len(part) % 4)
        return json.loads(base64.urlsafe_b64decode(part.encode()).decode())
    except Exception as e:
        return {"decode_error": str(e)}

def token_post(params):
    data = urllib.parse.urlencode(params).encode()
    req = urllib.request.Request(f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/token", data=data,
                                 headers={"Content-Type":"application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, context=SSL_CONTEXT, timeout=15) as r:
        return json.loads(r.read().decode())

def app(environ, start_response):
    path = environ.get("PATH_INFO", "/")
    query = urllib.parse.parse_qs(environ.get("QUERY_STRING", ""))
    base = external_base(environ)
    sid = parse_cookie(environ)
    session = SESSIONS.get(sid)

    if path == "/health":
        start_response("200 OK", [("Content-Type","text/plain")])
        return [b"ok"]

    if path == "/login":
        scope = query.get("scope", ["openid profile email"])[0]
        state = secrets.token_urlsafe(24)
        STATES[state] = {"scope": scope, "created": time.time()}
        redirect_uri = f"{base}/callback"
        params = {
            "client_id": CLIENT_ID,
            "redirect_uri": redirect_uri,
            "response_type": "code",
            "scope": scope,
            "state": state,
        }
        loc = f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/auth?{urllib.parse.urlencode(params)}"
        start_response("302 Found", [("Location", loc)])
        return [b""]

    if path == "/callback":
        if "error" in query:
            return response(start_response, layout("Login error", f"<div class=card><h2>Authorization error</h2><pre>{html.escape(json.dumps(query, indent=2))}</pre></div>"), "400 Bad Request")
        code = query.get("code", [""])[0]
        state = query.get("state", [""])[0]
        if state not in STATES:
            return response(start_response, layout("Invalid state", "<div class=card><h2>Invalid or expired state</h2></div>"), "400 Bad Request")
        redirect_uri = f"{base}/callback"
        try:
            tok = token_post({
                "grant_type": "authorization_code",
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
                "code": code,
                "redirect_uri": redirect_uri,
            })
        except Exception as e:
            return response(start_response, layout("Token error", f"<div class=card><h2>Token exchange failed</h2><pre>{html.escape(str(e))}</pre></div>"), "500 Internal Server Error")
        sid = secrets.token_urlsafe(24)
        SESSIONS[sid] = tok
        STATES.pop(state, None)
        headers = [("Location", "/"), ("Set-Cookie", f"sid={sid}; Path=/; HttpOnly; Secure; SameSite=Lax")]
        start_response("302 Found", headers)
        return [b""]

    if path == "/claims":
        if not session:
            return response(start_response, layout("Not signed in", "<div class=card><h2>Not signed in</h2><a class=button href='/'>Return</a></div>"), "401 Unauthorized")
        claims = jwt_claims(session.get("access_token", ""))
        body = f"<div class=card><h2>Current access token claims</h2><pre>{html.escape(json.dumps(claims, indent=2, sort_keys=True))}</pre><a class=button href='/exchange'>Exchange token for Orders API</a><a class='button secondary' href='/'>Back</a></div>"
        return response(start_response, layout("Token claims", body))

    if path == "/exchange":
        if not session:
            return response(start_response, layout("Not signed in", "<div class=card><h2>Not signed in</h2></div>"), "401 Unauthorized")
        try:
            original = jwt_claims(session.get("access_token", ""))
            exchanged = token_post({
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "client_id": CLIENT_ID,
                "client_secret": CLIENT_SECRET,
                "subject_token": session.get("access_token", ""),
                "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
                "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
                "audience": "orders-api",
            })
            newclaims = jwt_claims(exchanged.get("access_token", ""))
            body = f"<div class=card><h2>RFC 8693 Standard Token Exchange</h2><p>Original token:</p><pre>{html.escape(json.dumps(original, indent=2, sort_keys=True))}</pre><p>Exchanged token:</p><pre>{html.escape(json.dumps(newclaims, indent=2, sort_keys=True))}</pre><a class='button secondary' href='/'>Back</a></div>"
            return response(start_response, layout("Token exchange", body))
        except Exception as e:
            return response(start_response, layout("Token exchange error", f"<div class=card><h2>Token exchange failed</h2><pre>{html.escape(str(e))}</pre><p>Check that Standard Token Exchange is enabled on the acme-portal client and that the original token has the orders-api audience.</p></div>"), "500 Internal Server Error")

    if path == "/logout":
        if sid:
            SESSIONS.pop(sid, None)
        headers = [("Location", "/"), ("Set-Cookie", "sid=; Path=/; Max-Age=0; Secure; HttpOnly")]
        start_response("302 Found", headers)
        return [b""]

    if session:
        claims = jwt_claims(session.get("access_token", ""))
        who = html.escape(str(claims.get("preferred_username", claims.get("sub", "user"))))
        body = f'''<div class=card><h1>Welcome, {who}</h1><p>You are authenticated by ACME RHBK.</p>
<a class=button href="/claims">View token claims</a><a class=button href="/exchange">Exchange token for Orders API</a><a class="button secondary" href="/logout">Local logout</a></div>
<div class=card><h2>Consent demonstrations</h2><p>Start a fresh/private browser session for the clearest consent flow.</p>
<a class=button href="/login?scope=openid%20profile%20email%20personal-details">Personal details</a>
<a class=button href="/login?scope=openid%20profile%20email%20orders-history">Orders history</a>
<a class=button href="/login?scope=openid%20profile%20email%20personal-details%20orders-history%20support-profile">Multiple data scopes</a></div>'''
    else:
        body = '''<div class=card><h1>ACME Digital Identity</h1><p>This lightweight application demonstrates RHBK brokering, passkeys, consent and token exchange.</p>
<a class=button href="/login?scope=openid%20profile%20email">Sign in to ACME</a></div>
<div class=card><h2>Granular consent</h2><p>Request optional scopes individually to show user-facing consent.</p>
<a class=button href="/login?scope=openid%20profile%20email%20personal-details">Request personal details</a>
<a class=button href="/login?scope=openid%20profile%20email%20orders-history">Request orders history</a>
<a class=button href="/login?scope=openid%20profile%20email%20personal-details%20orders-history%20support-profile">Request multiple scopes</a></div>'''
    body += f"<div class=card><small>Realm: {html.escape(REALM)} | Identity service: {html.escape(KEYCLOAK_URL)}</small></div>"
    return response(start_response, layout("ACME Digital Identity", body))

if __name__ == "__main__":
    print("ACME Portal listening on 0.0.0.0:8080")
    with make_server("0.0.0.0", 8080, app) as httpd:
        httpd.serve_forever()
