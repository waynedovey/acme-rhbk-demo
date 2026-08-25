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
PEOPLESOFT_CLIENT_ID = os.environ.get("PEOPLESOFT_CLIENT_ID", "peoplesoft-app")
PEOPLESOFT_CLIENT_SECRET = os.environ.get("PEOPLESOFT_CLIENT_SECRET", "")
VERIFY_TLS = os.environ.get("VERIFY_TLS", "false").lower() == "true"
SSL_CONTEXT = ssl.create_default_context() if VERIFY_TLS else ssl._create_unverified_context()

SESSIONS = {}
PEOPLESOFT_SESSIONS = {}
STATES = {}


def external_base(environ):
    proto = environ.get("HTTP_X_FORWARDED_PROTO", "http").split(",")[0].strip()
    host = environ.get("HTTP_X_FORWARDED_HOST") or environ.get("HTTP_HOST")
    return f"{proto}://{host}"


def response(start_response, body, status="200 OK", headers=None):
    values = [("Content-Type", "text/html; charset=utf-8"), ("Cache-Control", "no-store")]
    if headers:
        values.extend(headers)
    start_response(status, values)
    return [body.encode()]


def esc(value):
    return html.escape(str(value))


def layout(title, body):
    return f'''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(title)}</title>
<style>
:root{{--red:#ee0000;--red-dark:#a30000;--ink:#151515;--muted:#6a6e73;--line:#d2d2d2;--bg:#f5f5f5;--green:#3e8635;--blue:#0066cc;--amber:#f0ab00}}
*{{box-sizing:border-box}} body{{font-family:Arial,Helvetica,sans-serif;margin:0;background:var(--bg);color:var(--ink);line-height:1.45}}
header{{background:#fff;border-top:5px solid var(--red);border-bottom:1px solid var(--line);padding:18px 5vw;position:sticky;top:0;z-index:10}}
.header-row{{max-width:1240px;margin:auto;display:flex;align-items:center;justify-content:space-between;gap:20px}}
.brand{{font-size:20px;font-weight:800}} .brand span{{color:var(--red)}} nav a{{color:#333;text-decoration:none;margin-left:14px;font-size:13px;font-weight:700}}
main{{max-width:1240px;margin:26px auto 60px;padding:0 24px}} h1{{font-size:34px;line-height:1.1;margin:0 0 10px}} h2{{font-size:23px;margin:0 0 10px}} h3{{font-size:18px;margin:0 0 8px}}
.lead{{font-size:18px;color:#444;max-width:850px}} .hero{{background:linear-gradient(110deg,#fff 60%,#fff4f4);border:1px solid #d8d8d8;border-left:6px solid var(--red);border-radius:10px;padding:28px;margin-bottom:20px}}
.flow{{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:18px 0 4px}} .node{{background:#fff;border:1px solid #bbb;border-radius:7px;padding:10px 13px;font-weight:700}} .node.strong{{border:2px solid var(--red);background:#fff6f6}} .arrow{{font-size:20px;color:#777}}
.grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(300px,1fr));gap:16px;margin:16px 0 26px}} .card{{background:#fff;border:1px solid var(--line);border-radius:9px;padding:21px;box-shadow:0 1px 3px #0000000d}}
.card.primary{{border-top:5px solid var(--red)}} .card.high{{border:2px solid var(--red)}} .card p{{margin:7px 0 13px}} .kicker{{font-size:12px;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);font-weight:800}}
.step{{display:inline-grid;place-items:center;width:29px;height:29px;border-radius:50%;background:var(--ink);color:#fff;font-weight:800;margin-right:8px}} .badge{{display:inline-block;border-radius:999px;padding:4px 8px;font-size:11px;font-weight:800;margin-right:4px;background:#ececec}}
.badge.red{{background:#ffe4e4;color:#940000}} .badge.green{{background:#e9f7e7;color:#245f1f}} .badge.blue{{background:#e6f1fb;color:#004d99}} .badge.amber{{background:#fff3d1;color:#6b4b00}}
a.button{{display:inline-block;background:var(--red);color:#fff;padding:10px 15px;border-radius:5px;text-decoration:none;margin:5px 6px 5px 0;font-weight:800;font-size:14px}} a.button:hover{{background:var(--red-dark)}} a.secondary{{background:#4f5255}} a.outline{{background:#fff;color:var(--red);border:1px solid var(--red)}} a.blue{{background:var(--blue)}}
.status{{border-radius:7px;padding:10px 12px;margin:10px 0;font-size:13px;font-weight:700}} .status.ok{{background:#e9f7e7;border-left:4px solid var(--green)}} .status.wait{{background:#fff5d8;border-left:4px solid var(--amber)}} .status.info{{background:#eaf4ff;border-left:4px solid var(--blue)}}
code,pre{{background:#f0f0f0;border-radius:4px}} code{{padding:2px 5px}} pre{{padding:14px;overflow:auto;font-size:12px;border:1px solid #ddd}} .tiny{{font-size:12px;color:var(--muted)}} .muted{{color:var(--muted)}}
.value{{font-size:22px;font-weight:800}} .divider{{border:0;border-top:1px solid #eee;margin:15px 0}} ul.clean{{padding-left:20px;margin:8px 0}} .demo-index{{display:flex;flex-wrap:wrap;gap:7px;margin:12px 0 0}} .demo-index a{{background:#fff;border:1px solid #ccc;border-radius:999px;padding:6px 10px;color:#333;text-decoration:none;font-size:12px;font-weight:700}}
@media(max-width:720px){{nav{{display:none}} h1{{font-size:28px}} .flow .arrow{{transform:rotate(90deg)}}}}
</style>
</head>
<body>
<header><div class="header-row"><div class="brand"><span>ACME</span> Digital Identity Demo</div><nav><a href="#scenario">Scenario</a><a href="#peoplesoft">PeopleSoft</a><a href="#passkeys">Passkeys</a><a href="#platform">Platform</a></nav></div></header>
<main>{body}</main>
</body></html>'''


def cookie_value(environ, name):
    raw = environ.get("HTTP_COOKIE", "")
    jar = cookies.SimpleCookie()
    jar.load(raw)
    return jar.get(name).value if jar.get(name) else None


def jwt_claims(token):
    try:
        part = token.split(".")[1]
        part += "=" * (-len(part) % 4)
        return json.loads(base64.urlsafe_b64decode(part.encode()).decode())
    except Exception as exc:
        return {"decode_error": str(exc)}


def token_post(client_id, client_secret, params):
    request_params = dict(params)
    request_params["client_id"] = client_id
    if client_secret:
        request_params["client_secret"] = client_secret
    data = urllib.parse.urlencode(request_params).encode()
    req = urllib.request.Request(
        f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/token",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, context=SSL_CONTEXT, timeout=15) as result:
        return json.loads(result.read().decode())


def auth_redirect(start_response, base, client_id, callback_path, scope="openid profile email", extras=None, purpose="login"):
    state = secrets.token_urlsafe(24)
    STATES[state] = {"client_id": client_id, "callback_path": callback_path, "purpose": purpose, "created": time.time()}
    params = {
        "client_id": client_id,
        "redirect_uri": f"{base}{callback_path}",
        "response_type": "code",
        "scope": scope,
        "state": state,
    }
    if extras:
        params.update(extras)
    location = f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/auth?{urllib.parse.urlencode(params)}"
    start_response("302 Found", [("Location", location), ("Cache-Control", "no-store")])
    return [b""]


def claims_focus(tokens):
    access = jwt_claims(tokens.get("access_token", ""))
    identity = jwt_claims(tokens.get("id_token", "")) if tokens.get("id_token") else {}
    return {
        "user": access.get("preferred_username") or identity.get("preferred_username") or access.get("sub"),
        "client": access.get("azp") or identity.get("azp"),
        "acr": identity.get("acr", access.get("acr")),
        "auth_time": identity.get("auth_time", access.get("auth_time")),
        "audience": access.get("aud"),
        "scope": access.get("scope"),
    }, access, identity


def demo_dashboard(portal_session, peoplesoft_session):
    portal_user = None
    if portal_session:
        focus, _, _ = claims_focus(portal_session)
        portal_user = focus.get("user")

    ps_focus = None
    if peoplesoft_session:
        ps_focus, _, _ = claims_focus(peoplesoft_session)

    portal_status = (
        f'<div class="status ok">Standard ACME session active as <strong>{esc(portal_user)}</strong>.</div>'
        if portal_session
        else '<div class="status wait">Start with ordinary ACME sign-in to establish the baseline session.</div>'
    )
    ps_status = (
        f'<div class="status ok">PeopleSoft high-assurance session established for <strong>{esc(ps_focus.get("user"))}</strong>. Client: <code>{esc(ps_focus.get("client"))}</code>.</div>'
        if peoplesoft_session
        else '<div class="status wait">Not demonstrated yet. Register a passkey, establish normal SSO, then open PeopleSoft.</div>'
    )

    scenario = f'''
<section id="scenario" class="hero">
<div class="kicker">Customer scenario</div>
<h1>Protect PeopleSoft PI data with client-specific step-up authentication</h1>
<p class="lead">Normal applications can use brokered corporate SSO. When the same user opens the sensitive PeopleSoft application, RHBK applies a stronger client policy and requires a passkey again.</p>
<div class="flow">
  <div class="node">PeopleSoft</div><div class="arrow">→</div>
  <div class="node">Oracle Access Manager<br><span class="tiny">represented in demo</span></div><div class="arrow">→</div>
  <div class="node strong">RHBK<br><span class="tiny">policy + brokering + step-up</span></div><div class="arrow">→</div>
  <div class="node">Microsoft Entra ID<br><span class="tiny">upstream identity</span></div>
</div>
<div class="demo-index">
<a href="#broker">1 Broker</a><a href="#passkeys">2 Passkey</a><a href="#peoplesoft">3 PeopleSoft step-up</a><a href="#consent">4 Consent</a><a href="#exchange">5 Token exchange</a><a href="#workload">6 Workload identity</a><a href="#onboarding">7 Client onboarding</a><a href="#fapi">8 FAPI 2.0</a>
</div>
</section>'''

    peoplesoft = f'''
<section id="peoplesoft" class="card high">
<div class="kicker"><span class="step">3</span>Primary customer demo</div>
<h2>PeopleSoft — sensitive PI application</h2>
<p><span class="badge red">High assurance</span><span class="badge blue">Client-specific policy</span><span class="badge green">Passkey required</span></p>
<p><strong>What happens:</strong> the PeopleSoft OIDC client is bound to its own RHBK browser authentication flow. That flow requires <code>WebAuthn Passwordless Authenticator</code>, so an existing ordinary SSO session does not silently grant access.</p>
{portal_status}
{ps_status}
<a class="button" href="/peoplesoft">Open PeopleSoft — require Touch ID / passkey</a>
<a class="button outline" href="/passkey-register">Register / verify passkey first</a>
'''
    if peoplesoft_session:
        peoplesoft += '<a class="button secondary" href="/peoplesoft-home">Open PeopleSoft HR</a><a class="button outline" href="/peoplesoft-claims">Show token</a>'
    peoplesoft += '''<hr class="divider"><p class="tiny"><strong>Talking point:</strong> “The user already has SSO, but this application contains sensitive personal information, so RHBK applies a stronger control specifically for PeopleSoft.”</p></section>'''

    browser_cards = f'''
<section class="grid">
<div id="broker" class="card primary">
<div class="kicker"><span class="step">1</span>Identity brokering</div><h3>Legacy / partner / corporate identity</h3>
<p>Applications trust one ACME issuer while RHBK brokers authentication to external identity providers and links them to the same local identity.</p>
<a class="button" href="/login">Open broker chooser</a><a class="button secondary" href="/login?idp=legacy-idp">Legacy Identity</a><a class="button secondary" href="/login?idp=partner-idp">Microsoft Entra ID (simulated)</a>
<p class="tiny">After login, use the Account Console to show linked identities.</p>
<a class="button outline" href="{esc(KEYCLOAK_URL)}/realms/{esc(REALM)}/account/">Account Console</a>
</div>
<div id="passkeys" class="card primary">
<div class="kicker"><span class="step">2</span>Passkeys / WebAuthn</div><h3>Passwordless authentication</h3>
<p>Register a discoverable passwordless credential using Touch ID, Windows Hello, a mobile passkey or a hardware security key.</p>
<a class="button" href="/passkey-register">Register / verify passkey</a><a class="button secondary" href="/login">Test standard passkey sign-in</a>
<p class="tiny">RHBK policy: user verification required; discoverable credential required.</p>
</div>
<div id="consent" class="card primary">
<div class="kicker"><span class="step">4</span>Granular consent</div><h3>Request only the data the app needs</h3>
<p>Request optional scopes independently so the user sees exactly what the application is asking to access.</p>
<a class="button" href="/login?scope=openid%20profile%20email%20personal-details">Personal details</a>
<a class="button secondary" href="/login?scope=openid%20profile%20email%20orders-history">Orders history</a>
<a class="button secondary" href="/login?scope=openid%20profile%20email%20personal-details%20orders-history%20support-profile">Multiple scopes</a>
</div>
<div id="exchange" class="card primary">
<div class="kicker"><span class="step">5</span>OAuth 2.0 Token Exchange</div><h3>Exchange user token for an API token</h3>
<p>Show RFC 8693 token exchange and compare the original application token with the Orders API token.</p>
'''
    if portal_session:
        browser_cards += '<a class="button" href="/claims">View current claims</a><a class="button secondary" href="/exchange">Exchange for Orders API</a>'
    else:
        browser_cards += '<a class="button" href="/login">Sign in first</a>'
    browser_cards += '</div></section>'

    platform = f'''
<section id="platform"><div class="kicker">Platform and automation demonstrations</div><h2>Everything else is visible from the same portal</h2>
<div class="grid">
<div id="workload" class="card"><div class="kicker"><span class="step">6</span>OpenShift workload identity</div><h3>No permanent RHBK client secret</h3><p>Use a projected Kubernetes ServiceAccount token as federated client authentication and receive a short-lived OAuth token.</p><pre>./scripts/configure-workload-identity.sh
./scripts/workload-token-test.sh</pre><span class="badge blue">CLI demo</span><span class="badge green">Short-lived identity</span></div>
<div id="onboarding" class="card"><div class="kicker"><span class="step">7</span>API-driven onboarding</div><h3>Controlled self-service client registration</h3><p>Use a short-lived, count-limited Initial Access Token to register an application without giving developers realm-admin access.</p><pre>./scripts/dynamic-client-registration.sh</pre><span class="badge blue">CLI demo</span><span class="badge amber">Governed onboarding</span></div>
<div id="fapi" class="card"><div class="kicker"><span class="step">8</span>FAPI 2.0</div><h3>High-assurance OAuth/OIDC policy</h3><p>Show built-in FAPI client profiles and position them for APIs requiring tighter OAuth controls.</p><a class="button outline" href="{esc(KEYCLOAK_URL)}/admin/">Open RHBK Admin Console</a><p class="tiny">Demo client: <code>high-assurance-api</code></p></div>
</div></section>'''

    session_bar = '<section class="card"><h3>Demo session controls</h3>'
    if portal_session:
        session_bar += f'<span class="badge green">ACME signed in: {esc(portal_user)}</span> '
    else:
        session_bar += '<span class="badge amber">ACME not signed in</span> '
    if peoplesoft_session:
        session_bar += '<span class="badge green">PeopleSoft step-up complete</span> '
    else:
        session_bar += '<span class="badge amber">PeopleSoft step-up not complete</span> '
    session_bar += '<p><a class="button secondary" href="/logout">Clear local demo sessions</a></p><p class="tiny">Clearing local portal cookies does not terminate the RHBK SSO session. That is useful when demonstrating that PeopleSoft still asks for its stronger passkey control.</p></section>'

    footer = f'<section class="card"><p class="tiny">Realm: <code>{esc(REALM)}</code> &nbsp; RHBK: <code>{esc(KEYCLOAK_URL)}</code> &nbsp; Standard client: <code>{esc(CLIENT_ID)}</code> &nbsp; PeopleSoft client: <code>{esc(PEOPLESOFT_CLIENT_ID)}</code></p></section>'
    return scenario + peoplesoft + browser_cards + platform + session_bar + footer


def app(environ, start_response):
    path = environ.get("PATH_INFO", "/")
    query = urllib.parse.parse_qs(environ.get("QUERY_STRING", ""))
    base = external_base(environ)

    sid = cookie_value(environ, "sid")
    psid = cookie_value(environ, "psid")
    portal_session = SESSIONS.get(sid)
    peoplesoft_session = PEOPLESOFT_SESSIONS.get(psid)

    if path == "/health":
        start_response("200 OK", [("Content-Type", "text/plain")])
        return [b"ok"]

    if path == "/login":
        scope = query.get("scope", ["openid profile email"])[0]
        extras = {}
        idp = query.get("idp", [""])[0]
        if idp in {"legacy-idp", "partner-idp"}:
            extras["kc_idp_hint"] = idp
        return auth_redirect(start_response, base, CLIENT_ID, "/callback", scope=scope, extras=extras, purpose="portal")

    if path == "/passkey-register":
        return auth_redirect(
            start_response,
            base,
            CLIENT_ID,
            "/callback",
            extras={"kc_action": "webauthn-register-passwordless:skip_if_exists"},
            purpose="passkey-register",
        )

    if path == "/peoplesoft":
        return auth_redirect(
            start_response,
            base,
            PEOPLESOFT_CLIENT_ID,
            "/peoplesoft-callback",
            extras={"prompt": "login", "max_age": "0"},
            purpose="peoplesoft",
        )

    if path in {"/callback", "/peoplesoft-callback"}:
        if "error" in query:
            return response(start_response, layout("Authorization error", f'<div class="card"><h2>Authorization error</h2><pre>{esc(json.dumps(query, indent=2))}</pre><a class="button" href="/">Back to demo</a></div>'), "400 Bad Request")
        code = query.get("code", [""])[0]
        state = query.get("state", [""])[0]
        state_data = STATES.get(state)
        if not state_data or state_data.get("callback_path") != path:
            return response(start_response, layout("Invalid state", '<div class="card"><h2>Invalid or expired state</h2><a class="button" href="/">Back to demo</a></div>'), "400 Bad Request")

        is_peoplesoft = state_data.get("client_id") == PEOPLESOFT_CLIENT_ID
        client_id = PEOPLESOFT_CLIENT_ID if is_peoplesoft else CLIENT_ID
        client_secret = PEOPLESOFT_CLIENT_SECRET if is_peoplesoft else CLIENT_SECRET
        redirect_uri = f"{base}{path}"
        try:
            tokens = token_post(client_id, client_secret, {
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect_uri,
            })
        except Exception as exc:
            return response(start_response, layout("Token error", f'<div class="card"><h2>Token exchange failed</h2><pre>{esc(exc)}</pre><a class="button" href="/">Back to demo</a></div>'), "500 Internal Server Error")

        STATES.pop(state, None)
        new_id = secrets.token_urlsafe(24)
        if is_peoplesoft:
            PEOPLESOFT_SESSIONS[new_id] = tokens
            headers = [("Location", "/peoplesoft-home"), ("Set-Cookie", f"psid={new_id}; Path=/; HttpOnly; Secure; SameSite=Lax")]
        else:
            SESSIONS[new_id] = tokens
            headers = [("Location", "/"), ("Set-Cookie", f"sid={new_id}; Path=/; HttpOnly; Secure; SameSite=Lax")]
        start_response("302 Found", headers)
        return [b""]

    if path == "/peoplesoft-home":
        if not peoplesoft_session:
            return response(start_response, layout("PeopleSoft", '<div class="card"><h2>High-assurance authentication required</h2><p>PeopleSoft is protected by the passkey step-up flow.</p><a class="button" href="/peoplesoft">Authenticate to PeopleSoft</a></div>'), "401 Unauthorized")
        focus, _, _ = claims_focus(peoplesoft_session)
        body = f'''<section class="hero"><div class="kicker">PeopleSoft HR — simulated sensitive application</div><h1>Employee Profile</h1><p class="lead">Access granted after the PeopleSoft-specific RHBK passkey control completed successfully.</p><div class="status ok">High-assurance authentication verified for <strong>{esc(focus.get("user"))}</strong>.</div></section>
<section class="grid"><div class="card high"><div class="kicker">Protected personal information</div><h2>Alex Demo</h2><p><strong>Employee ID:</strong> ACME-1042</p><p><strong>Email:</strong> alex@acme.example</p><p><strong>Payroll profile:</strong> Protected record available</p><p><strong>Emergency contact:</strong> Protected record available</p><p class="tiny">Fictional demo data only. This screen represents the PeopleSoft PI workload described in the customer scenario.</p></div>
<div class="card"><div class="kicker">Why access was allowed</div><h2>RHBK policy evidence</h2><p><span class="badge red">peoplesoft-app</span><span class="badge green">Passkey required</span></p><ul class="clean"><li>Separate OIDC client for PeopleSoft</li><li>Client browser-flow override: <code>peoplesoft-step-up</code></li><li>Required execution: <code>WebAuthn Passwordless Authenticator</code></li><li>Authorization request forces re-authentication</li></ul><a class="button" href="/peoplesoft-claims">View token evidence</a><a class="button secondary" href="/#peoplesoft">Back to demo dashboard</a></div></section>'''
        return response(start_response, layout("PeopleSoft HR", body))

    if path == "/claims":
        if not portal_session:
            return response(start_response, layout("Not signed in", '<div class="card"><h2>Sign in first</h2><a class="button" href="/login">Sign in</a></div>'), "401 Unauthorized")
        focus, access, identity = claims_focus(portal_session)
        body = f'''<div class="card"><div class="kicker">Standard ACME session</div><h2>Current token claims</h2><pre>{esc(json.dumps(focus, indent=2, sort_keys=True))}</pre><details><summary>Full access token claims</summary><pre>{esc(json.dumps(access, indent=2, sort_keys=True))}</pre></details><details><summary>Full ID token claims</summary><pre>{esc(json.dumps(identity, indent=2, sort_keys=True))}</pre></details><a class="button" href="/exchange">Exchange for Orders API</a><a class="button secondary" href="/">Back</a></div>'''
        return response(start_response, layout("Token claims", body))

    if path == "/peoplesoft-claims":
        if not peoplesoft_session:
            return response(start_response, layout("No PeopleSoft session", '<div class="card"><h2>PeopleSoft step-up has not been completed</h2><a class="button" href="/peoplesoft">Open PeopleSoft</a></div>'), "401 Unauthorized")
        focus, access, identity = claims_focus(peoplesoft_session)
        body = f'''<div class="card high"><div class="kicker">PeopleSoft high-assurance session</div><h2>Step-up completed</h2><p>The PeopleSoft client issued this authorization only after its dedicated passkey authentication flow succeeded.</p><pre>{esc(json.dumps(focus, indent=2, sort_keys=True))}</pre><details><summary>Full access token claims</summary><pre>{esc(json.dumps(access, indent=2, sort_keys=True))}</pre></details><details><summary>Full ID token claims</summary><pre>{esc(json.dumps(identity, indent=2, sort_keys=True))}</pre></details><a class="button secondary" href="/#peoplesoft">Back to demo</a></div>'''
        return response(start_response, layout("PeopleSoft step-up", body))

    if path == "/exchange":
        if not portal_session:
            return response(start_response, layout("Not signed in", '<div class="card"><h2>Sign in first</h2></div>'), "401 Unauthorized")
        try:
            original = jwt_claims(portal_session.get("access_token", ""))
            exchanged = token_post(CLIENT_ID, CLIENT_SECRET, {
                "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
                "subject_token": portal_session.get("access_token", ""),
                "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
                "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
                "audience": "orders-api",
            })
            newclaims = jwt_claims(exchanged.get("access_token", ""))
            body = f'''<div class="card"><div class="kicker">Demo 5</div><h2>RFC 8693 Standard Token Exchange</h2><h3>Original ACME Portal token</h3><pre>{esc(json.dumps(original, indent=2, sort_keys=True))}</pre><h3>Exchanged Orders API token</h3><pre>{esc(json.dumps(newclaims, indent=2, sort_keys=True))}</pre><a class="button secondary" href="/#exchange">Back to demo</a></div>'''
            return response(start_response, layout("Token exchange", body))
        except Exception as exc:
            return response(start_response, layout("Token exchange error", f'<div class="card"><h2>Token exchange failed</h2><pre>{esc(exc)}</pre><p>Check Standard Token Exchange and the <code>orders-api</code> audience.</p></div>'), "500 Internal Server Error")

    if path == "/logout":
        if sid:
            SESSIONS.pop(sid, None)
        if psid:
            PEOPLESOFT_SESSIONS.pop(psid, None)
        headers = [
            ("Location", "/"),
            ("Set-Cookie", "sid=; Path=/; Max-Age=0; Secure; HttpOnly"),
            ("Set-Cookie", "psid=; Path=/; Max-Age=0; Secure; HttpOnly"),
        ]
        start_response("302 Found", headers)
        return [b""]

    return response(start_response, layout("ACME Digital Identity", demo_dashboard(portal_session, peoplesoft_session)))


if __name__ == "__main__":
    print("ACME Portal listening on 0.0.0.0:8080")
    with make_server("0.0.0.0", 8080, app) as httpd:
        httpd.serve_forever()
