"""Live, fictional RHBK-as-IdP demo: two independent OIDC clients, one realm.

Deliberately separate from the existing broker / PeopleSoft / API demos.
Only redacted OIDC evidence is retained. No real DTF identity or record links.
"""
import base64
import hashlib
import html
import json
import os
import secrets
import ssl
import time
import urllib.parse
import urllib.request
from http import cookies

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "").rstrip("/")
BACKCHANNEL = os.environ.get("KEYCLOAK_BACKCHANNEL_URL", KEYCLOAK_URL).rstrip("/")
REALM = os.environ.get("REALM", "acme-demo")
TLS_CONTEXT = ssl.create_default_context() if os.environ.get("VERIFY_TLS", "false").lower() == "true" else ssl._create_unverified_context()
APPS = {
    "citizen": {"client": "acme-citizen-service", "label": "Citizen Services", "description": "Fictional citizen services application"},
    "agency": {"client": "acme-agency-service", "label": "Agency Services", "description": "Fictional agency application"},
}
FLOWS = {}
SESSIONS = {}


def escape(value):
    return html.escape(str(value if value is not None else ""), quote=True)


def cookie(environ, name):
    jar = cookies.SimpleCookie()
    try:
        jar.load(environ.get("HTTP_COOKIE", ""))
        return jar[name].value if name in jar else None
    except cookies.CookieError:
        return None


def session(environ):
    record = SESSIONS.get(cookie(environ, "idpsid"))
    if record and time.time() - record.get("created", 0) < 3600:
        return record
    return None


def claims(jwt):
    try:
        piece = jwt.split(".")[1]
        piece += "=" * (-len(piece) % 4)
        return json.loads(base64.urlsafe_b64decode(piece))
    except (ValueError, IndexError, TypeError):
        return {}


def redirect(start_response, location, extra_headers=None):
    headers = [("Location", location), ("Cache-Control", "no-store")]
    headers.extend(extra_headers or [])
    start_response("302 Found", headers)
    return [b""]


def authorize(start_response, base, kind):
    if kind not in APPS:
        return None
    state = secrets.token_urlsafe(24)
    nonce = secrets.token_urlsafe(24)
    verifier = secrets.token_urlsafe(48)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    FLOWS[state] = {"kind": kind, "nonce": nonce, "verifier": verifier, "created": time.time()}
    params = {
        "client_id": APPS[kind]["client"],
        "redirect_uri": base + "/idp-callback",
        "response_type": "code",
        "scope": "openid profile email",
        "state": state,
        "nonce": nonce,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    }
    url = f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/auth?{urllib.parse.urlencode(params)}"
    return redirect(start_response, url, [
        ("Set-Cookie", f"idpflow={state}; Path=/idp-callback; HttpOnly; Secure; SameSite=Lax; Max-Age=600")
    ])


def exchange(client_id, code, verifier, base):
    values = {
        "grant_type": "authorization_code",
        "client_id": client_id,
        "code": code,
        "redirect_uri": base + "/idp-callback",
        "code_verifier": verifier,
    }
    req = urllib.request.Request(
        f"{BACKCHANNEL}/realms/{REALM}/protocol/openid-connect/token",
        data=urllib.parse.urlencode(values).encode(),
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=15, context=TLS_CONTEXT) as res:
        return json.loads(res.read().decode())


def section(environ):
    record = session(environ) or {}
    apps = record.get("apps", {})
    boxes = []
    for kind, meta in APPS.items():
        signed = kind in apps
        marker = '<span class="badge green">Signed in with RHBK ✓</span>' if signed else '<span class="badge amber">Not signed in</span>'
        boxes.append(
            f'<div class="card primary"><div class="kicker">Independent OIDC client</div>'
            f'<h3>{escape(meta["label"])}</h3><p>{escape(meta["description"])}</p>'
            f'<p>Client ID: <code>{escape(meta["client"])}</code></p><p>{marker}</p>'
            f'<a class="button" href="/idp-app?app={escape(kind)}">{"View app and token evidence" if signed else "Open and sign in"}</a></div>'
        )
    both = all(key in apps for key in APPS)
    match = both and apps["citizen"]["sub"] == apps["agency"]["sub"]
    note = (
        '<div class="status ok">Both apps received independent OIDC tokens for the same RHBK identity ✓</div>'
        if match else
        '<div class="status wait">Open Citizen Services, then Agency Services in the same browser using the same identity.</div>'
    )
    discovery = f"{KEYCLOAK_URL}/realms/{REALM}/.well-known/openid-configuration"
    return f"""<section id="idp-service" class="card high">
      <div class="kicker"><span class="step">9</span>RHBK as Identity Provider (IdP)</div>
      <h2>One identity provider, multiple applications</h2>
      <p><strong>RHBK is the IdP:</strong> it authenticates the user and issues OIDC tokens directly to
      two fictional government-style applications. Each app has its own RHBK client registration,
      but both trust the same central identity provider and can use its browser SSO session.</p>
      <div class="flow"><span class="node">Citizen</span><span class="arrow">→</span>
      <span class="node strong">RHBK IdP ({escape(REALM)})</span><span class="arrow">→</span>
      <span class="node">Citizen Services</span><span class="node">Agency Services</span></div>
      {note}<div class="grid">{''.join(boxes)}</div>
      <a class="button outline" href="/idp-evidence">Compare client-specific OIDC evidence</a>
      <a class="button outline" href="{escape(discovery)}" target="_blank" rel="noopener noreferrer">Live OIDC discovery metadata</a>
      <a class="button secondary" href="/idp-reset">Clear local example sessions</a>
      <hr class="divider"><h3>IdP vs broker: different RHBK roles</h3>
      <p>In this example, <strong>RHBK issues tokens itself</strong>. In the existing
      <a href="/#broker">identity brokering demo</a>, RHBK redirects to a fictional external IdP
      and then issues a token to the portal. <a href="/login?idp=legacy-idp">Try Legacy Identity login</a>.</p>
      <div class="status info"><strong>DTF future-state idea (not implemented):</strong> a dedicated SA ID realm
      could become the citizen IdP, while IDX brokers DIT Identity and myID.
      TRUMPS ownership verification, account linking, delegated access and audit controls need separate integration.
      This lab has <strong>no SA ID self-registration, real IDX/DIT/myID connection or TRUMPS record linking</strong>.</div>
      <p class="tiny">Real OIDC authorization-code flow with mandatory PKCE S256, two registered public demo clients,
      one realm issuer, and sanitized ID/access token claims. Both fictional apps are views in this portal,
      not separately deployed applications.</p></section>"""


def page_for_app(kind, environ):
    meta = APPS[kind]
    data = (session(environ) or {}).get("apps", {}).get(kind)
    if data:
        content = (
            f'<div class="status ok">Authenticated by RHBK as <strong>{escape(data.get("username") or data["sub"])}</strong> ✓</div>'
            f'<h3>Sanitized OIDC evidence</h3><pre>{escape(json.dumps(data, sort_keys=True, indent=2))}</pre>'
            '<p class="tiny">No bearer or ID tokens are displayed or stored here.</p>'
            '<a class="button outline" href="/idp-evidence">Compare both applications</a>'
        )
    else:
        content = (
            '<div class="status wait">No OIDC session has been established for this client yet.</div>'
            f'<a class="button" href="/idp-login?app={escape(kind)}">Sign in with RHBK</a>'
        )
    return (
        f'<section class="hero"><div class="kicker">Fictional app — independent OIDC client</div>'
        f'<h1>{escape(meta["label"])}</h1><p class="lead">{escape(meta["description"])}</p></section>'
        f'<div class="card"><p>OIDC client: <code>{escape(meta["client"])}</code></p>'
        f'<p>Trusted IdP issuer: <code>{escape(KEYCLOAK_URL)}/realms/{escape(REALM)}</code></p>'
        f'{content}<hr class="divider"><a class="button secondary" href="/idp">Back to IdP examples</a></div>'
    )


def evidence_page(environ):
    apps = (session(environ) or {}).get("apps", {})
    panels = []
    for kind, meta in APPS.items():
        if kind in apps:
            body = f'<pre>{escape(json.dumps(apps[kind], indent=2, sort_keys=True))}</pre>'
        else:
            body = f'<div class="status wait">Not signed in yet</div><a class="button" href="/idp-app?app={escape(kind)}">Open app</a>'
        panels.append(f'<div class="token-panel {"source" if kind == "citizen" else "target"}"><h2>{escape(meta["label"])}</h2>{body}</div>')
    same = all(k in apps for k in APPS) and apps["citizen"]["sub"] == apps["agency"]["sub"]
    message = ('Same RHBK user subject. Each application has its own OIDC client and tokens ✓'
               if same else 'Sign into both applications with the same account to complete the comparison.')
    return (
        f'<section class="hero"><h1>RHBK Identity Provider — evidence</h1>'
        f'<p class="lead">One central issuer; distinct OIDC client IDs and ID-token audiences.</p>'
        f'<div class="status {"ok" if same else "wait"}">{message}</div></section>'
        f'<div class="token-compare">{"".join(panels)}</div>'
        '<div class="card"><p class="tiny">Matching subject IDs show the same user account; '
        'RHBK manages browser SSO. The two demo clients do not share tokens.</p>'
        '<a class="button secondary" href="/idp">Back</a></div>'
    )


def handle(environ, start_response, base, layout, response):
    """Return a WSGI result for /idp* routes, or None for other portal paths."""
    path = environ.get("PATH_INFO", "/")
    if not path.startswith("/idp"):
        return None
    query = urllib.parse.parse_qs(environ.get("QUERY_STRING", ""))
    kind = query.get("app", [""])[0]
    if path == "/idp":
        return response(start_response, layout("RHBK IdP examples", section(environ)))
    if path == "/idp-app":
        if kind not in APPS:
            return response(start_response, "Unknown application", "404 Not Found", content_type="text/plain")
        return response(start_response, layout(APPS[kind]["label"], page_for_app(kind, environ)))
    if path == "/idp-login":
        result = authorize(start_response, base, kind)
        if result is None:
            return response(start_response, "Unknown application", "400 Bad Request", content_type="text/plain")
        return result
    if path == "/idp-callback":
        state = query.get("state", [""])[0]
        flow = FLOWS.get(state)
        browser_state = cookie(environ, "idpflow") or ""
        if not flow or not state or not secrets.compare_digest(browser_state, state) or time.time() - flow["created"] > 600:
            return response(start_response, layout("Invalid OIDC response",
                '<div class="card"><h2>Invalid or expired authentication state</h2><a class="button" href="/idp">Try again</a></div>'),
                "400 Bad Request")
        FLOWS.pop(state, None)
        if "error" in query:
            return response(start_response, layout("Sign-in cancelled",
                '<div class="card"><h2>RHBK sign-in was cancelled</h2><a class="button" href="/idp">Try again</a></div>'),
                "400 Bad Request")
        code = query.get("code", [""])[0]
        if not code:
            return response(start_response, "Missing OIDC code", "400 Bad Request", content_type="text/plain")
        client_id = APPS[flow["kind"]]["client"]
        try:
            tokens = exchange(client_id, code, flow["verifier"], base)
            identity = claims(tokens.get("id_token", ""))
            access = claims(tokens.get("access_token", ""))
            aud = identity.get("aud")
            audience = {aud} if isinstance(aud, str) else set(aud or [])
            if (identity.get("iss") != f"{KEYCLOAK_URL}/realms/{REALM}" or
                client_id not in audience or identity.get("nonce") != flow["nonce"] or
                not identity.get("sub")):
                raise ValueError("RHBK OIDC issuer, audience, nonce or subject verification failed")
        except Exception:
            return response(start_response, layout("RHBK sign-in failed",
                '<div class="card"><h2>RHBK did not complete the OIDC exchange</h2>'
                '<p>Check the client registrations and login configuration.</p><a class="button" href="/idp">Try again</a></div>'),
                "400 Bad Request")
        old = session(environ)
        record = old if old and old["sub"] == identity["sub"] else {"sub": identity["sub"], "apps": {}, "created": time.time()}
        record["apps"][flow["kind"]] = {
            "application": APPS[flow["kind"]]["label"],
            "client_id": client_id,
            "issuer": identity["iss"],
            "sub": identity["sub"],
            "username": identity.get("preferred_username") or access.get("preferred_username"),
            "id_token_audience": aud,
            "access_token_authorized_party": access.get("azp"),
            "scope": tokens.get("scope") or access.get("scope"),
            "auth_time": identity.get("auth_time"),
            "access_token_fingerprint": hashlib.sha256(tokens.get("access_token", "").encode()).hexdigest()[:16],
        }
        sid = cookie(environ, "idpsid") if old and old["sub"] == identity["sub"] else secrets.token_urlsafe(24)
        SESSIONS[sid] = record
        return redirect(start_response, f'/idp-app?app={flow["kind"]}', [
            ("Set-Cookie", f"idpsid={sid}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=3600"),
            ("Set-Cookie", "idpflow=; Path=/idp-callback; HttpOnly; Secure; SameSite=Lax; Max-Age=0"),
        ])
    if path == "/idp-evidence":
        return response(start_response, layout("RHBK IdP OIDC evidence", evidence_page(environ)))
    if path == "/idp-reset":
        sid = cookie(environ, "idpsid")
        if sid:
            SESSIONS.pop(sid, None)
        return redirect(start_response, "/idp", [
            ("Set-Cookie", "idpsid=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0"),
        ])
    return response(start_response, "Unknown IdP demo page", "404 Not Found", content_type="text/plain")
