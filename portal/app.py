#!/usr/bin/env python3
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
from wsgiref.simple_server import make_server

KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "").rstrip("/")
KEYCLOAK_BACKCHANNEL_URL = os.environ.get("KEYCLOAK_BACKCHANNEL_URL", KEYCLOAK_URL).rstrip("/")
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

BROKER_AUTH_STATE = {}
BROKER_PROVIDERS = {
    "legacy-idp": "Legacy Identity",
    "partner-idp": "Partner Identity",
    "corporate-idp": "Corporate Identity",
}
PASSKEY_DEMO_STATE = {}
CONSENT_DEMO_STATE = {}
CONSENT_LAST_TOKENS = {}
TOKEN_EXCHANGE_DEMO_STATE = {}
TOKEN_EXCHANGE_EVIDENCE = {}
WORKLOAD_DEMO_STATE = {}
ONBOARDING_DEMO_STATE = {}
FAPI2_DEMO_STATE = {}

CONSENT_SCOPE_INFO = {
    "personal-details": {
        "name": "Personal details",
        "description": "Basic ACME identity information such as name, profile and contact details.",
    },
    "orders-history": {
        "name": "Orders history",
        "description": "Access to the user's ACME order history and previous transaction information.",
    },
    "support-profile": {
        "name": "Support profile",
        "description": "Information required by ACME customer support to assist the user.",
    },
}


def external_base(environ):
    proto = environ.get("HTTP_X_FORWARDED_PROTO", "http").split(",")[0].strip()
    host = environ.get("HTTP_X_FORWARDED_HOST") or environ.get("HTTP_HOST")
    return f"{proto}://{host}"


def response(start_response, body, status="200 OK", headers=None, content_type="text/html; charset=utf-8"):
    values = [("Content-Type", content_type), ("Cache-Control", "no-store")]
    if headers:
        values.extend(headers)
    start_response(status, values)
    return [str(body).encode()]


def esc(value):
    return html.escape(str(value if value is not None else ""))


def layout(title, body):
    return f'''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{esc(title)}</title>
<style>
:root{{--red:#ee0000;--red-dark:#a30000;--ink:#151515;--muted:#6a6e73;--line:#d2d2d2;--bg:#f5f5f5;--green:#3e8635;--blue:#0066cc;--amber:#ec7a08}}
*{{box-sizing:border-box}} body{{font-family:Arial,Helvetica,sans-serif;margin:0;background:var(--bg);color:var(--ink);line-height:1.45}}
header{{background:#fff;border-top:5px solid var(--red);border-bottom:1px solid var(--line);padding:18px 5vw;position:sticky;top:0;z-index:10}}
.header-row{{max-width:1240px;margin:auto;display:flex;align-items:center;justify-content:space-between;gap:20px}}
.brand{{font-size:20px;font-weight:800}} .brand span{{color:var(--red)}} nav a{{color:#333;text-decoration:none;margin-left:14px;font-size:13px;font-weight:700}}
main{{max-width:1240px;margin:26px auto 60px;padding:0 24px}} h1{{font-size:34px;line-height:1.1;margin:0 0 10px}} h2{{font-size:23px;margin:0 0 10px}} h3{{font-size:18px;margin:0 0 8px}} h4{{margin:16px 0 8px}}
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
.demo-row{{display:flex;align-items:center;flex-wrap:wrap;gap:8px;margin:8px 0}}
a.button.pending{{background:#ec7a08;color:#fff;min-width:260px}} a.button.complete{{background:#3e8635;color:#fff;min-width:260px}} a.revoke{{display:inline-block;background:#fff;color:#a30000;border:1px solid #ee0000;border-radius:5px;padding:9px 12px;text-decoration:none;font-size:12px;font-weight:800}}
.evidence{{border:1px solid #d2d2d2;border-left:5px solid #3e8635;border-radius:7px;padding:14px;margin:14px 0;background:#fff}} .request{{border:1px solid #d2d2d2;border-left:5px solid #ec7a08;border-radius:7px;padding:14px;margin:10px 0;background:#fff}}
.token-compare{{display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:14px;margin:14px 0}} .token-panel{{border:1px solid #d2d2d2;border-radius:7px;padding:14px;background:#fff}} .token-panel.source{{border-left:5px solid #0066cc}} .token-panel.target{{border-left:5px solid #3e8635}}
.profile-grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:8px;margin:14px 0}} .profile{{border:1px solid #d2d2d2;border-radius:6px;padding:10px 12px;font-family:monospace;font-size:12px;background:#f5f5f5}} .profile.active{{border-left:5px solid #3e8635;background:#f2faf0}}
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


def token_fingerprint(token):
    return hashlib.sha256(token.encode()).hexdigest()[:16] if token else "n/a"


def token_exchange_summary(claims):
    return {
        "username": claims.get("preferred_username"),
        "subject": claims.get("sub"),
        "authorized_party": claims.get("azp"),
        "audience": claims.get("aud"),
        "scope": claims.get("scope"),
        "issued_at": claims.get("iat"),
        "expires": claims.get("exp"),
        "token_id": claims.get("jti"),
    }


def token_post(client_id, client_secret, params):
    request_params = dict(params)
    if client_id:
        request_params["client_id"] = client_id
    if client_secret:
        request_params["client_secret"] = client_secret
    data = urllib.parse.urlencode(request_params).encode()
    req = urllib.request.Request(
        f"{KEYCLOAK_BACKCHANNEL_URL}/realms/{REALM}/protocol/openid-connect/token",
        data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, context=SSL_CONTEXT, timeout=20) as result:
        return json.loads(result.read().decode())


def auth_redirect(start_response, base, client_id, callback_path, scope="openid profile email", extras=None, purpose="login"):
    state = secrets.token_urlsafe(24)
    extras = dict(extras or {})
    STATES[state] = {
        "client_id": client_id,
        "callback_path": callback_path,
        "purpose": purpose,
        "identity_provider": extras.get("kc_idp_hint"),
        "created": time.time(),
    }
    params = {
        "client_id": client_id,
        "redirect_uri": f"{base}{callback_path}",
        "response_type": "code",
        "scope": scope,
        "state": state,
    }
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


def status_button(label, href, done=False):
    css = "complete" if done else "pending"
    suffix = " — Completed ✓" if done else ""
    return f'<a class="button {css}" href="{esc(href)}">{esc(label + suffix)}</a>'


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
        if portal_session else
        '<div class="status wait">Start with ordinary ACME sign-in to establish the baseline session.</div>'
    )
    ps_status = (
        f'<div class="status ok">PeopleSoft high-assurance session established for <strong>{esc(ps_focus.get("user"))}</strong>.</div>'
        if peoplesoft_session else
        '<div class="status wait">Not demonstrated yet. Register a passkey, establish normal SSO, then open PeopleSoft.</div>'
    )

    scenario = '''
<section id="scenario" class="hero">
<div class="kicker">ACME scenario</div>
<h1>Modern identity controls with Red Hat build of Keycloak</h1>
<p class="lead">One compact portal demonstrates identity brokering, passkeys, client-specific step-up, granular OAuth scopes, token exchange, workload identity, API-driven onboarding and FAPI 2 policy.</p>
<div class="demo-index"><a href="#broker">1 Broker</a><a href="#passkeys">2 Passkey</a><a href="#peoplesoft">3 PeopleSoft step-up</a><a href="#consent">4 Consent</a><a href="#exchange">5 Token exchange</a><a href="#workload">6 Workload identity</a><a href="#onboarding">7 Client onboarding</a><a href="#fapi">8 FAPI 2.0</a></div>
</section>'''

    peoplesoft = f'''
<section id="peoplesoft" class="card high">
<div class="kicker"><span class="step">3</span>Client-specific step-up</div>
<h2>PeopleSoft — sensitive PI application</h2>
<p><span class="badge red">High assurance</span><span class="badge blue">Client-specific policy</span><span class="badge green">Passkey required</span></p>
<p>The <code>peoplesoft-app</code> client is bound to its own RHBK browser authentication flow. An existing ordinary SSO session does not silently grant access.</p>
{portal_status}{ps_status}
<a class="button" href="/peoplesoft">Open PeopleSoft — require Touch ID / passkey</a>
<a class="button outline" href="/passkey-register">Register / verify passkey first</a>'''
    if peoplesoft_session:
        peoplesoft += '<a class="button secondary" href="/peoplesoft-home">Open PeopleSoft HR</a><a class="button outline" href="/peoplesoft-claims">Show token</a>'
    peoplesoft += '<hr class="divider"><p class="tiny">Talking point: the user may already have SSO, but RHBK applies a stronger authentication control specifically to the sensitive application.</p></section>'

    # Broker state
    broker_grants = BROKER_AUTH_STATE.get(portal_user, set()) if portal_user else set()
    broker_rows = []
    for alias, label in BROKER_PROVIDERS.items():
        done = alias in broker_grants
        if done:
            broker_rows.append(f'<div class="demo-row"><a class="button complete" href="/login?idp={esc(alias)}">{esc(label)} — Authenticated ✓</a><a class="revoke" href="/broker-revoke?provider={esc(alias)}">Revoke</a></div>')
        else:
            broker_rows.append(f'<div class="demo-row"><a class="button pending" href="/login?idp={esc(alias)}">{esc(label)} — Authenticate</a></div>')
    via = portal_session.get("_broker_provider") if portal_session else None
    broker_status = (
        f'<div class="status ok">Current ACME session authenticated via <strong>{esc(BROKER_PROVIDERS.get(via, via))}</strong>.</div>'
        if via in BROKER_PROVIDERS else
        '<div class="status wait">Authenticate through any upstream identity to demonstrate brokering.</div>'
    )

    # Passkey state
    pass_state = PASSKEY_DEMO_STATE.get(portal_user, {}) if portal_user else {}
    pass_reg = bool(pass_state.get("credential"))
    pass_login = bool(pass_state.get("signin"))
    if pass_login:
        pass_status = f'<div class="status ok"><strong>Passkey / WebAuthn demo complete</strong><br>User: {esc(portal_user)}<br>Discoverable credential: demonstrated<br>Passwordless sign-in route: demonstrated</div>'
    elif pass_reg:
        pass_status = f'<div class="status info">Passkey registration / verification completed for <strong>{esc(portal_user)}</strong>. Now test passwordless sign-in.</div>'
    else:
        pass_status = '<div class="status wait">Passkey registration has not yet been demonstrated.</div>'

    # Consent state
    consent_grants = CONSENT_DEMO_STATE.get(portal_user, set()) if portal_user else set()
    def consent_row(label, scopes):
        granted = set(scopes) <= set(consent_grants)
        encoded = urllib.parse.quote(",".join(scopes), safe="")
        if granted:
            return f'<div class="demo-row"><a class="button complete" href="/consent-request?scope={encoded}">{esc(label)} — Granted ✓</a><a class="revoke" href="/consent-revoke?scope={encoded}">Revoke</a></div>'
        return f'<div class="demo-row"><a class="button pending" href="/consent-request?scope={encoded}">{esc(label)} — Request access</a></div>'
    consent_status = (
        f'<div class="status ok">Granted optional scopes: <strong>{esc(", ".join(sorted(consent_grants)))}</strong></div>'
        if consent_grants else
        '<div class="status wait">No optional data access has been granted during this demo session.</div>'
    )

    # Token exchange state
    exchange_state = TOKEN_EXCHANGE_DEMO_STATE.get(portal_user, {}) if portal_user else {}
    claims_viewed = bool(exchange_state.get("claims_viewed"))
    exchange_complete = bool(exchange_state.get("exchange_complete"))
    if not portal_session:
        exchange_status = '<div class="status wait">Sign in to ACME first to establish the source application token.</div>'
        exchange_buttons = status_button("Sign in first", "/login", False)
    else:
        if exchange_complete:
            exchange_status = f'<div class="status ok"><strong>RFC 8693 Token Exchange successful.</strong><br>ACME user: <strong>{esc(portal_user)}</strong><br>Target audience: <strong>orders-api</strong></div>'
        elif claims_viewed:
            exchange_status = '<div class="status info">Original ACME Portal token inspected. Now exchange it for an Orders API token.</div>'
        else:
            exchange_status = '<div class="status wait">Token Exchange has not yet been demonstrated.</div>'
        exchange_buttons = f'<div class="demo-row">{status_button("Current claims — Viewed" if claims_viewed else "View current claims", "/claims", claims_viewed)}</div><div class="demo-row">{status_button("Orders API token — Exchanged" if exchange_complete else "Exchange for Orders API", "/exchange", exchange_complete)}</div>'

    # Workload state
    workload = dict(WORKLOAD_DEMO_STATE)
    workload_complete = workload.get("status") == "success" and workload.get("oauth_http_status") == 200 and workload.get("client_secret_used") is False
    workload_status = (
        f'<div class="status ok"><strong>OpenShift workload authentication successful ✓</strong><br>ServiceAccount: <code>{esc(workload.get("federated_subject"))}</code><br>RHBK client: <strong>{esc(workload.get("client_id"))}</strong><br>Authentication: <strong>Signed JWT - Federated</strong><br>Permanent RHBK client secret: <strong>NONE ✓</strong></div>'
        if workload_complete else
        '<div class="status wait">OpenShift workload identity has not yet been demonstrated.</div>'
    )

    # Onboarding state
    onboarding = dict(ONBOARDING_DEMO_STATE)
    onboarding_complete = onboarding.get("status") == "success" and bool(onboarding.get("client_id")) and onboarding.get("second_registration_blocked") is True
    onboarding_status = (
        f'<div class="status ok"><strong>Controlled client registration successful ✓</strong><br>Registered client: <code>{esc(onboarding.get("client_id"))}</code><br>Initial Access Token: <strong>{esc(onboarding.get("iat_count"))} use / {esc(onboarding.get("iat_expiration_seconds"))} seconds</strong><br>Second registration attempt: <strong>blocked ✓</strong></div>'
        if onboarding_complete else
        '<div class="status wait">API-driven client onboarding has not yet been demonstrated.</div>'
    )

    # FAPI state
    fapi = dict(FAPI2_DEMO_STATE)
    fapi_complete = fapi.get("status") == "success" and fapi.get("client_id") == "high-assurance-api" and fapi.get("policy_enabled") is True and fapi.get("active_profile") == "fapi-2-security-profile"
    fapi_status = (
        f'<div class="status ok"><strong>FAPI 2.0 high-assurance policy configured ✓</strong><br>Demo client: <code>{esc(fapi.get("client_id"))}</code><br>Client Policy: <strong>{esc(fapi.get("policy_name"))}</strong><br>Active profile: <strong>{esc(fapi.get("active_profile"))}</strong></div>'
        if fapi_complete else
        '<div class="status wait">FAPI 2.0 policy has not yet been demonstrated.</div>'
    )

    cards = f'''
<section class="grid">
<div id="broker" class="card primary"><div class="kicker"><span class="step">1</span>Identity brokering</div><h3>Legacy / partner / corporate identity</h3><p>Applications trust one ACME issuer while RHBK brokers authentication to external providers and resolves them to the same local identity.</p>{broker_status}{''.join(broker_rows)}<a class="button outline" href="{esc(KEYCLOAK_URL)}/realms/{esc(REALM)}/account/">Account Console</a></div>
<div id="passkeys" class="card primary"><div class="kicker"><span class="step">2</span>Passkeys / WebAuthn</div><h3>Passwordless authentication</h3><p>Register a discoverable passwordless credential using Touch ID, Windows Hello, a mobile passkey or hardware security key.</p>{pass_status}<div class="demo-row">{status_button("Passkey credential — Ready" if pass_reg else "Register / verify passkey", "/passkey-register", pass_reg)}</div><div class="demo-row">{status_button("Passwordless sign-in — Authenticated" if pass_login else "Test standard passkey sign-in", "/passkey-login", pass_login)}</div><a class="button outline" href="{esc(KEYCLOAK_URL)}/realms/{esc(REALM)}/account/">Manage Passkeys</a><a class="button outline" href="/passkey-reset">Reset demo status</a><p class="tiny">RHBK policy: user verification required; discoverable credential required. For standard sign-in, select “Sign in with Passkey” in the RHBK login UI.</p></div>
<div id="consent" class="card primary"><div class="kicker"><span class="step">4</span>Granular consent</div><h3>Request only the data the app needs</h3><p>Request optional scopes independently so the user sees exactly what the application is asking to access.</p>{consent_status}{consent_row("Personal details", ["personal-details"])}{consent_row("Orders history", ["orders-history"])}{consent_row("Multiple scopes", ["personal-details","orders-history","support-profile"])}<a class="button outline" href="/consent-token">Show consent token evidence</a><a class="button outline" href="/consent-reset">Reset demo status</a><p class="tiny">The Portal provides the review UX; RHBK issues and enforces the actual optional OAuth scopes.</p></div>
<div id="exchange" class="card primary"><div class="kicker"><span class="step">5</span>OAuth 2.0 Token Exchange</div><h3>Exchange user token for an API token</h3><p>Show RFC 8693 token exchange and compare the original application token with the Orders API token.</p>{exchange_status}{exchange_buttons}{'<a class="button outline" href="/exchange-evidence">Compare token evidence</a>' if exchange_complete else ''}<a class="button outline" href="/exchange-reset">Reset demo status</a></div>
</section>
<section id="platform"><div class="kicker">Platform and automation demonstrations</div><h2>Workload, onboarding and high-assurance policy</h2><div class="grid">
<div id="workload" class="card primary"><div class="kicker"><span class="step">6</span>OpenShift workload identity</div><h3>No permanent RHBK client secret</h3><p>Use a projected Kubernetes ServiceAccount token as federated client authentication and receive a short-lived OAuth token.</p>{workload_status}<div class="demo-row">{status_button("Federated workload token — Issued" if workload_complete else "Run workload identity test", "/workload-evidence" if workload_complete else "/workload-howto", workload_complete)}</div><pre>./scripts/configure-workload-identity.sh
./scripts/workload-token-test.sh</pre>{'<a class="button outline" href="/workload-evidence">View workload identity evidence</a>' if workload_complete else ''}<a class="button outline" href="/workload-reset">Reset demo status</a></div>
<div id="onboarding" class="card primary"><div class="kicker"><span class="step">7</span>API-driven onboarding</div><h3>Controlled self-service client registration</h3><p>Use a short-lived, count-limited Initial Access Token to register an application without giving developers realm-admin access.</p>{onboarding_status}<div class="demo-row">{status_button("Client registered — Verified" if onboarding_complete else "Run controlled client onboarding", "/onboarding-evidence" if onboarding_complete else "/onboarding-howto", onboarding_complete)}</div><pre>./scripts/dynamic-client-registration.sh</pre>{'<a class="button outline" href="/onboarding-evidence">View registration evidence</a>' if onboarding_complete else ''}<a class="button outline" href="/onboarding-reset">Reset demo status</a></div>
<div id="fapi" class="card primary"><div class="kicker"><span class="step">8</span>FAPI 2.0</div><h3>High-assurance OAuth/OIDC policy</h3><p>Show RHBK's built-in FAPI 2 client profiles and apply the FAPI 2.0 Security Profile to APIs requiring tighter OAuth controls.</p>{fapi_status}<div class="demo-row">{status_button("FAPI 2 policy — Configured" if fapi_complete else "Configure FAPI 2 policy", "/fapi2-evidence" if fapi_complete else "/fapi2-howto", fapi_complete)}</div><div class="profile-grid"><div class="profile active">fapi-2-security-profile</div><div class="profile">fapi-2-message-signing</div><div class="profile">fapi-2-dpop-security-profile</div><div class="profile">fapi-2-dpop-message-signing</div></div><pre>./scripts/configure-fapi2.sh</pre><a class="button" href="{esc(KEYCLOAK_URL)}/admin/">Open RHBK Admin Console</a>{'<a class="button outline" href="/fapi2-evidence">View FAPI policy evidence</a>' if fapi_complete else ''}<a class="button outline" href="/fapi2-reset">Reset demo status</a></div>
</div></section>'''

    session_bar = '<section class="card"><h3>Demo session controls</h3>'
    session_bar += f'<span class="badge green">ACME signed in: {esc(portal_user)}</span> ' if portal_session else '<span class="badge amber">ACME not signed in</span> '
    session_bar += '<span class="badge green">PeopleSoft step-up complete</span> ' if peoplesoft_session else '<span class="badge amber">PeopleSoft step-up not complete</span> '
    session_bar += '<p><a class="button secondary" href="/logout">Clear local demo sessions</a></p></section>'

    footer = f'<section class="card"><p class="tiny">Realm: <code>{esc(REALM)}</code> &nbsp; RHBK: <code>{esc(KEYCLOAK_URL)}</code> &nbsp; Standard client: <code>{esc(CLIENT_ID)}</code> &nbsp; PeopleSoft client: <code>{esc(PEOPLESOFT_CLIENT_ID)}</code></p></section>'
    return scenario + peoplesoft + cards + session_bar + footer


def app(environ, start_response):
    path = environ.get("PATH_INFO", "/")
    query = urllib.parse.parse_qs(environ.get("QUERY_STRING", ""))
    base = external_base(environ)

    sid = cookie_value(environ, "sid")
    psid = cookie_value(environ, "psid")
    portal_session = SESSIONS.get(sid)
    peoplesoft_session = PEOPLESOFT_SESSIONS.get(psid)

    if path == "/health":
        return response(start_response, "ok", content_type="text/plain")

    # Status ingestion APIs: sanitized evidence only.
    if path in {"/api/demo/workload", "/api/demo/onboarding", "/api/demo/fapi2"}:
        if environ.get("REQUEST_METHOD", "GET").upper() != "POST":
            return response(start_response, "Method not allowed", "405 Method Not Allowed", content_type="text/plain")
        supplied = environ.get("HTTP_X_ACME_DEMO_KEY", "")
        if not CLIENT_SECRET or not supplied or not secrets.compare_digest(supplied, CLIENT_SECRET):
            return response(start_response, "Forbidden", "403 Forbidden", content_type="text/plain")
        try:
            length = int(environ.get("CONTENT_LENGTH") or "0")
            payload = json.loads(environ["wsgi.input"].read(length).decode("utf-8"))
        except Exception as exc:
            return response(start_response, f"Invalid JSON: {exc}", "400 Bad Request", content_type="text/plain")

        if path.endswith("workload"):
            if not (payload.get("status") == "success" and payload.get("oauth_http_status") == 200 and payload.get("client_secret_used") is False and payload.get("client_id") == "acme-automation" and payload.get("identity_provider") == "openshift"):
                return response(start_response, "Invalid workload evidence", "400 Bad Request", content_type="text/plain")
            allowed = {"status","created_at","namespace","service_account","federated_subject","kubernetes_issuer","assertion_audience","assertion_lifetime_seconds","assertion_fingerprint","projected_token_path","client_id","identity_provider","client_authentication","client_secret_used","client_id_parameter_sent","oauth_grant_type","oauth_http_status","access_token_type","access_token_expires_in","access_token_scope","access_token_issuer","access_token_subject","access_token_audience","access_token_authorized_party","access_token_fingerprint"}
            WORKLOAD_DEMO_STATE.clear(); WORKLOAD_DEMO_STATE.update({k:v for k,v in payload.items() if k in allowed})
            return response(start_response, "Workload identity evidence recorded", content_type="text/plain")

        if path.endswith("onboarding"):
            if not (payload.get("status") == "success" and payload.get("client_id") and payload.get("second_registration_blocked") is True):
                return response(start_response, "Invalid onboarding evidence", "400 Bad Request", content_type="text/plain")
            allowed = {"status","created_at","client_id","client_name","redirect_uris","grant_types","response_types","token_endpoint_auth_method","iat_expiration_seconds","iat_count","iat_fingerprint","registration_endpoint","registration_provider","registration_transport","registration_access_token_issued","client_secret_issued","registration_verified","second_registration_http_status","second_registration_blocked"}
            ONBOARDING_DEMO_STATE.clear(); ONBOARDING_DEMO_STATE.update({k:v for k,v in payload.items() if k in allowed})
            return response(start_response, "Onboarding evidence recorded", content_type="text/plain")

        if not (payload.get("status") == "success" and payload.get("client_id") == "high-assurance-api" and payload.get("policy_enabled") is True and payload.get("active_profile") == "fapi-2-security-profile"):
            return response(start_response, "Invalid FAPI 2 evidence", "400 Bad Request", content_type="text/plain")
        allowed = {"status","client_id","rhbk_version","policy_name","policy_enabled","marker_role","active_profile","fapi2_specification","global_profiles","active_profile_executors","policy_conditions","client_secret_exposed","admin_credential_exposed"}
        FAPI2_DEMO_STATE.clear(); FAPI2_DEMO_STATE.update({k:v for k,v in payload.items() if k in allowed})
        return response(start_response, "FAPI 2 evidence recorded", content_type="text/plain")

    if path == "/login":
        scope = query.get("scope", ["openid profile email"])[0]
        extras = {}
        idp = query.get("idp", [""])[0]
        if idp in BROKER_PROVIDERS:
            extras.update({"kc_idp_hint": idp, "prompt": "login", "max_age": "0"})
        return auth_redirect(start_response, base, CLIENT_ID, "/callback", scope=scope, extras=extras, purpose="portal")

    if path == "/passkey-register":
        return auth_redirect(start_response, base, CLIENT_ID, "/callback", extras={"kc_action":"webauthn-register-passwordless:skip_if_exists"}, purpose="passkey-register")

    if path == "/passkey-login":
        return auth_redirect(start_response, base, CLIENT_ID, "/callback", extras={"prompt":"login","max_age":"0"}, purpose="passkey-login")

    if path == "/peoplesoft":
        return auth_redirect(start_response, base, PEOPLESOFT_CLIENT_ID, "/peoplesoft-callback", extras={"prompt":"login","max_age":"0"}, purpose="peoplesoft")

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
        try:
            tokens = token_post(client_id, client_secret, {"grant_type":"authorization_code","code":code,"redirect_uri":f"{base}{path}"})
        except Exception as exc:
            return response(start_response, layout("Token error", f'<div class="card"><h2>Token exchange failed</h2><pre>{esc(exc)}</pre><a class="button" href="/">Back to demo</a></div>'), "500 Internal Server Error")

        STATES.pop(state, None)
        if is_peoplesoft:
            new_id = secrets.token_urlsafe(24); PEOPLESOFT_SESSIONS[new_id] = tokens
            start_response("302 Found", [("Location","/peoplesoft-home"),("Set-Cookie",f"psid={new_id}; Path=/; HttpOnly; Secure; SameSite=Lax"),("Cache-Control","no-store")]); return [b""]

        focus, access, _ = claims_focus(tokens)
        user = focus.get("user")
        purpose = state_data.get("purpose", "portal")
        broker_provider = state_data.get("identity_provider")
        target = "/"
        if broker_provider in BROKER_PROVIDERS and user:
            BROKER_AUTH_STATE.setdefault(user, set()).add(broker_provider)
            tokens["_broker_provider"] = broker_provider
            target = "/#broker"
        if purpose == "passkey-register" and user:
            PASSKEY_DEMO_STATE.setdefault(user, {})["credential"] = True
            target = "/#passkeys"
        elif purpose == "passkey-login" and user:
            PASSKEY_DEMO_STATE.setdefault(user, {})["signin"] = True
            target = "/#passkeys"
        elif purpose.startswith("consent:"):
            requested = {v for v in purpose[len("consent:"):].split(",") if v}
            token_scope = tokens.get("scope") or access.get("scope", "") or ""
            granted = set(token_scope.split())
            missing = requested - granted
            if missing:
                return response(start_response, layout("Consent scope error", f'<div class="card"><h2>RHBK did not grant all requested scopes</h2><p>Missing:</p><pre>{esc(", ".join(sorted(missing)))}</pre><p>Returned scope:</p><pre>{esc(token_scope)}</pre><a class="button" href="/#consent">Back</a></div>'), "400 Bad Request")
            if user:
                CONSENT_DEMO_STATE.setdefault(user, set()).update(requested)
                CONSENT_LAST_TOKENS[user] = {"requested":sorted(requested),"scope_claim":token_scope,"claims":{"preferred_username":access.get("preferred_username"),"azp":access.get("azp"),"aud":access.get("aud"),"scope":access.get("scope")}}
            target = "/#consent"

        new_id = secrets.token_urlsafe(24); SESSIONS[new_id] = tokens
        start_response("302 Found", [("Location",target),("Set-Cookie",f"sid={new_id}; Path=/; HttpOnly; Secure; SameSite=Lax"),("Cache-Control","no-store")]); return [b""]

    if path == "/broker-revoke":
        provider = query.get("provider", [""])[0]
        if portal_session:
            user = claims_focus(portal_session)[0].get("user")
            if user and provider in BROKER_PROVIDERS:
                BROKER_AUTH_STATE.setdefault(user, set()).discard(provider)
                if portal_session.get("_broker_provider") == provider:
                    portal_session.pop("_broker_provider", None)
        start_response("302 Found", [("Location","/#broker"),("Cache-Control","no-store")]); return [b""]

    if path == "/passkey-reset":
        if portal_session:
            user = claims_focus(portal_session)[0].get("user")
            if user: PASSKEY_DEMO_STATE.pop(user, None)
        start_response("302 Found", [("Location","/#passkeys"),("Cache-Control","no-store")]); return [b""]

    if path == "/consent-request":
        requested = list(dict.fromkeys(v.strip() for v in query.get("scope", [""])[0].split(",") if v.strip()))
        invalid = [v for v in requested if v not in CONSENT_SCOPE_INFO]
        if not requested or invalid:
            return response(start_response, layout("Invalid consent request", f'<div class="card"><h2>Invalid consent request</h2><pre>{esc(", ".join(invalid) if invalid else "No scopes requested")}</pre></div>'), "400 Bad Request")
        rows = "".join(f'<div class="request"><strong>{esc(CONSENT_SCOPE_INFO[s]["name"])}</strong><br><code>{esc(s)}</code><p>{esc(CONSENT_SCOPE_INFO[s]["description"])}</p></div>' for s in requested)
        encoded = urllib.parse.quote(",".join(requested), safe="")
        body = f'<section class="hero"><div class="kicker">Granular consent</div><h1>ACME is requesting access</h1><p class="lead">Review exactly which categories of data this application is asking to access.</p></section><div class="card"><h2>Requested data</h2>{rows}<div class="status info">Only the optional scopes shown above will be requested from RHBK.</div><a class="button" href="/consent-authorize?scope={encoded}">Grant requested access</a><a class="button secondary" href="/#consent">Deny / cancel</a></div>'
        return response(start_response, layout("Granular consent", body))

    if path == "/consent-authorize":
        requested = list(dict.fromkeys(v.strip() for v in query.get("scope", [""])[0].split(",") if v.strip()))
        invalid = [v for v in requested if v not in CONSENT_SCOPE_INFO]
        if not requested or invalid:
            return response(start_response, layout("Invalid consent request", '<div class="card"><h2>Invalid consent request</h2></div>'), "400 Bad Request")
        return auth_redirect(start_response, base, CLIENT_ID, "/callback", scope="openid profile email " + " ".join(requested), purpose="consent:" + ",".join(requested))

    if path == "/consent-revoke":
        requested = {v.strip() for v in query.get("scope", [""])[0].split(",") if v.strip() in CONSENT_SCOPE_INFO}
        if portal_session:
            user = claims_focus(portal_session)[0].get("user")
            if user: CONSENT_DEMO_STATE.setdefault(user, set()).difference_update(requested)
        start_response("302 Found", [("Location","/#consent"),("Cache-Control","no-store")]); return [b""]

    if path == "/consent-reset":
        if portal_session:
            user = claims_focus(portal_session)[0].get("user")
            if user: CONSENT_DEMO_STATE.pop(user, None); CONSENT_LAST_TOKENS.pop(user, None)
        else:
            CONSENT_DEMO_STATE.clear(); CONSENT_LAST_TOKENS.clear()
        start_response("302 Found", [("Location","/#consent"),("Cache-Control","no-store")]); return [b""]

    if path == "/consent-token":
        if not portal_session:
            return response(start_response, layout("Consent evidence", '<div class="card"><h2>Sign in first</h2><a class="button" href="/login">Sign in</a></div>'), "401 Unauthorized")
        user = claims_focus(portal_session)[0].get("user")
        evidence = CONSENT_LAST_TOKENS.get(user)
        if not evidence:
            return response(start_response, layout("Consent evidence", '<div class="card"><h2>No granular consent token yet</h2><p>Request one of the optional scope sets first.</p><a class="button" href="/#consent">Back</a></div>'))
        return response(start_response, layout("Consent token evidence", f'<div class="card"><div class="kicker">RHBK token evidence</div><h2>Granular scope authorization</h2><p>Requested:</p><pre>{esc(json.dumps(evidence["requested"], indent=2))}</pre><p>RHBK scope claim:</p><pre>{esc(evidence["scope_claim"])}</pre><p>Relevant claims:</p><pre>{esc(json.dumps(evidence["claims"], indent=2, sort_keys=True))}</pre><a class="button secondary" href="/#consent">Back</a></div>'))

    if path == "/claims":
        if not portal_session:
            return response(start_response, layout("Not signed in", '<div class="card"><h2>Sign in first</h2><a class="button" href="/login">Sign in</a></div>'), "401 Unauthorized")
        focus, access, identity = claims_focus(portal_session)
        user = focus.get("user")
        if user: TOKEN_EXCHANGE_DEMO_STATE.setdefault(user, {})["claims_viewed"] = True
        summary = token_exchange_summary(access)
        fp = token_fingerprint(portal_session.get("access_token", ""))
        body = f'<section class="hero"><div class="kicker">OAuth 2.0 Token Exchange — source token</div><h1>Current ACME Portal token</h1><p class="lead">This access token becomes the RFC 8693 <code>subject_token</code>.</p></section><div class="card"><h2>Important source claims</h2><pre>{esc(json.dumps(summary, indent=2, sort_keys=True))}</pre><p>Token fingerprint: <code>{esc(fp)}</code></p><details><summary>Full access token claims</summary><pre>{esc(json.dumps(access, indent=2, sort_keys=True))}</pre></details><details><summary>Full ID token claims</summary><pre>{esc(json.dumps(identity, indent=2, sort_keys=True))}</pre></details><a class="button" href="/exchange">Exchange for Orders API</a><a class="button secondary" href="/#exchange">Back</a></div>'
        return response(start_response, layout("Current token claims", body))

    if path == "/exchange":
        if not portal_session:
            return response(start_response, layout("Not signed in", '<div class="card"><h2>Sign in first</h2></div>'), "401 Unauthorized")
        try:
            source_token = portal_session.get("access_token", "")
            original = jwt_claims(source_token)
            exchanged = token_post(CLIENT_ID, CLIENT_SECRET, {"grant_type":"urn:ietf:params:oauth:grant-type:token-exchange","subject_token":source_token,"subject_token_type":"urn:ietf:params:oauth:token-type:access_token","requested_token_type":"urn:ietf:params:oauth:token-type:access_token","audience":"orders-api"})
            exchanged_token = exchanged.get("access_token", "")
            if not exchanged_token or exchanged_token == source_token:
                raise RuntimeError("RHBK did not mint a new access token")
            newclaims = jwt_claims(exchanged_token)
            aud = newclaims.get("aud")
            audiences = {aud} if isinstance(aud, str) else set(aud or [])
            if "orders-api" not in audiences:
                raise RuntimeError(f"Exchanged token does not contain orders-api audience: {aud}")
            user = claims_focus(portal_session)[0].get("user")
            meta = {"grant_type":"urn:ietf:params:oauth:grant-type:token-exchange","requested_audience":"orders-api","issued_token_type":exchanged.get("issued_token_type"),"token_type":exchanged.get("token_type"),"expires_in":exchanged.get("expires_in")}
            evidence = {"source":token_exchange_summary(original),"target":token_exchange_summary(newclaims),"source_fingerprint":token_fingerprint(source_token),"target_fingerprint":token_fingerprint(exchanged_token),"response":meta}
            if user:
                TOKEN_EXCHANGE_DEMO_STATE.setdefault(user, {}).update({"claims_viewed":True,"exchange_complete":True}); TOKEN_EXCHANGE_EVIDENCE[user] = evidence
            body = f'<section class="hero"><div class="kicker">OAuth 2.0 Token Exchange</div><h1>RFC 8693 exchange successful</h1><div class="status ok"><strong>Orders API token issued ✓</strong></div></section><div class="token-compare"><div class="token-panel source"><h2>ACME Portal</h2><pre>{esc(json.dumps(evidence["source"], indent=2, sort_keys=True))}</pre><p>Fingerprint: <code>{esc(evidence["source_fingerprint"])}</code></p></div><div class="token-panel target"><h2>Orders API</h2><pre>{esc(json.dumps(evidence["target"], indent=2, sort_keys=True))}</pre><p>Fingerprint: <code>{esc(evidence["target_fingerprint"])}</code></p></div></div><div class="card"><h2>RFC 8693 response metadata</h2><pre>{esc(json.dumps(meta, indent=2, sort_keys=True))}</pre><a class="button" href="/exchange-evidence">Compare token evidence</a><a class="button secondary" href="/#exchange">Back</a></div>'
            return response(start_response, layout("Token Exchange", body))
        except Exception as exc:
            return response(start_response, layout("Token Exchange error", f'<div class="card"><h2>Token Exchange failed</h2><pre>{esc(exc)}</pre><a class="button" href="/#exchange">Back</a></div>'), "500 Internal Server Error")

    if path == "/exchange-evidence":
        if not portal_session:
            return response(start_response, layout("Not signed in", '<div class="card"><h2>Sign in first</h2></div>'), "401 Unauthorized")
        user = claims_focus(portal_session)[0].get("user")
        ev = TOKEN_EXCHANGE_EVIDENCE.get(user)
        if not ev:
            return response(start_response, layout("Token Exchange evidence", '<div class="card"><h2>No Token Exchange evidence yet</h2><a class="button" href="/#exchange">Back</a></div>'))
        body = f'<section class="hero"><div class="kicker">RFC 8693 evidence</div><h1>Original token vs Orders API token</h1><div class="status ok">Token Exchange completed successfully.</div></section><div class="token-compare"><div class="token-panel source"><h2>Original application token</h2><pre>{esc(json.dumps(ev["source"], indent=2, sort_keys=True))}</pre><p>Fingerprint: <code>{esc(ev["source_fingerprint"])}</code></p></div><div class="token-panel target"><h2>Exchanged Orders API token</h2><pre>{esc(json.dumps(ev["target"], indent=2, sort_keys=True))}</pre><p>Fingerprint: <code>{esc(ev["target_fingerprint"])}</code></p></div></div><div class="card"><pre>{esc(json.dumps(ev["response"], indent=2, sort_keys=True))}</pre><a class="button secondary" href="/#exchange">Back</a></div>'
        return response(start_response, layout("Token Exchange evidence", body))

    if path == "/exchange-reset":
        if portal_session:
            user = claims_focus(portal_session)[0].get("user")
            if user: TOKEN_EXCHANGE_DEMO_STATE.pop(user, None); TOKEN_EXCHANGE_EVIDENCE.pop(user, None)
        else:
            TOKEN_EXCHANGE_DEMO_STATE.clear(); TOKEN_EXCHANGE_EVIDENCE.clear()
        start_response("302 Found", [("Location","/#exchange"),("Cache-Control","no-store")]); return [b""]

    if path == "/peoplesoft-home":
        if not peoplesoft_session:
            return response(start_response, layout("PeopleSoft", '<div class="card"><h2>High-assurance authentication required</h2><p>PeopleSoft is protected by the passkey step-up flow.</p><a class="button" href="/peoplesoft">Authenticate to PeopleSoft</a></div>'), "401 Unauthorized")
        focus, _, _ = claims_focus(peoplesoft_session)
        body = f'<section class="hero"><div class="kicker">PeopleSoft HR — simulated sensitive application</div><h1>Employee Profile</h1><div class="status ok">High-assurance authentication verified for <strong>{esc(focus.get("user"))}</strong>.</div></section><section class="grid"><div class="card high"><h2>Alex Demo</h2><p><strong>Employee ID:</strong> ACME-1042</p><p><strong>Email:</strong> alex@acme.example</p><p><strong>Payroll profile:</strong> Protected record available</p><p class="tiny">Fictional demo data only.</p></div><div class="card"><h2>RHBK policy evidence</h2><ul><li>Client: <code>peoplesoft-app</code></li><li>Browser-flow override: <code>peoplesoft-step-up</code></li><li>Required execution: <code>WebAuthn Passwordless Authenticator</code></li></ul><a class="button" href="/peoplesoft-claims">View token evidence</a><a class="button secondary" href="/#peoplesoft">Back</a></div></section>'
        return response(start_response, layout("PeopleSoft HR", body))

    if path == "/peoplesoft-claims":
        if not peoplesoft_session:
            return response(start_response, layout("No PeopleSoft session", '<div class="card"><h2>PeopleSoft step-up has not been completed</h2></div>'), "401 Unauthorized")
        focus, access, identity = claims_focus(peoplesoft_session)
        return response(start_response, layout("PeopleSoft step-up", f'<div class="card high"><h2>Step-up completed</h2><pre>{esc(json.dumps(focus, indent=2, sort_keys=True))}</pre><details><summary>Full access token claims</summary><pre>{esc(json.dumps(access, indent=2, sort_keys=True))}</pre></details><details><summary>Full ID token claims</summary><pre>{esc(json.dumps(identity, indent=2, sort_keys=True))}</pre></details><a class="button secondary" href="/#peoplesoft">Back</a></div>'))

    # Workload / onboarding / FAPI evidence pages.
    if path == "/workload-howto":
        return response(start_response, layout("OpenShift workload identity", '<section class="hero"><h1>Authenticate a workload without a client secret</h1></section><div class="card"><pre>./scripts/configure-workload-identity.sh\n./scripts/workload-token-test.sh</pre><pre>OpenShift ServiceAccount\n  -> projected 600-second JWT\n  -> RHBK Signed JWT - Federated\n  -> client_credentials\n  -> short-lived OAuth token</pre><a class="button secondary" href="/#workload">Back</a></div>'))

    if path == "/workload-evidence":
        ev = dict(WORKLOAD_DEMO_STATE)
        if ev.get("status") != "success":
            return response(start_response, layout("Workload identity evidence", '<div class="card"><h2>No workload identity evidence yet</h2><pre>./scripts/configure-workload-identity.sh\n./scripts/workload-token-test.sh</pre><a class="button" href="/#workload">Back</a></div>'))
        flow = f'OpenShift ServiceAccount\n  | projected JWT ({esc(ev.get("assertion_lifetime_seconds"))} seconds)\n  v\n{esc(ev.get("kubernetes_issuer"))}\n  v\nRHBK Identity Provider: openshift\n  | Signed JWT - Federated\n  v\nRHBK client: {esc(ev.get("client_id"))}\n  | client_credentials\n  v\nOAuth access token ({esc(ev.get("access_token_expires_in"))} seconds)'
        return response(start_response, layout("Workload identity evidence", f'<section class="hero"><h1>OpenShift ServiceAccount authenticated to RHBK</h1><div class="status ok"><strong>Workload authentication successful ✓</strong><br>Permanent client secret: <strong>NONE ✓</strong></div></section><div class="evidence"><pre>{flow}</pre><h2>Sanitized evidence</h2><pre>{esc(json.dumps(ev, indent=2, sort_keys=True))}</pre><a class="button secondary" href="/#workload">Back</a></div>'))

    if path == "/workload-reset":
        WORKLOAD_DEMO_STATE.clear(); start_response("302 Found", [("Location","/#workload"),("Cache-Control","no-store")]); return [b""]

    if path == "/onboarding-howto":
        return response(start_response, layout("API-driven onboarding", '<section class="hero"><h1>Controlled self-service client registration</h1></section><div class="card"><pre>./scripts/dynamic-client-registration.sh</pre><ol><li>Platform administrator creates a 10-minute, one-use Initial Access Token.</li><li>Developer/automation calls the RHBK Client Registration Service using only that IAT.</li><li>The same IAT is deliberately reused and must be rejected.</li></ol><a class="button secondary" href="/#onboarding">Back</a></div>'))

    if path == "/onboarding-evidence":
        ev = dict(ONBOARDING_DEMO_STATE)
        if ev.get("status") != "success":
            return response(start_response, layout("Onboarding evidence", '<div class="card"><h2>No onboarding evidence yet</h2><pre>./scripts/dynamic-client-registration.sh</pre><a class="button" href="/#onboarding">Back</a></div>'))
        return response(start_response, layout("Client onboarding evidence", f'<section class="hero"><h1>Application onboarded without realm-admin access</h1><div class="status ok"><strong>Client registration successful ✓</strong><br>Client: <code>{esc(ev.get("client_id"))}</code><br>One-use Initial Access Token consumed ✓<br>Second registration blocked ✓</div></section><div class="evidence"><h2>Sanitized registration evidence</h2><pre>{esc(json.dumps(ev, indent=2, sort_keys=True))}</pre><a class="button secondary" href="/#onboarding">Back</a></div>'))

    if path == "/onboarding-reset":
        ONBOARDING_DEMO_STATE.clear(); start_response("302 Found", [("Location","/#onboarding"),("Cache-Control","no-store")]); return [b""]

    if path == "/fapi2-howto":
        return response(start_response, layout("FAPI 2.0", '<section class="hero"><h1>High-assurance OAuth/OIDC policy</h1></section><div class="card"><pre>./scripts/configure-fapi2.sh</pre><pre>Client:  high-assurance-api\nPolicy:  acme-fapi2-high-assurance\nProfile: fapi-2-security-profile</pre><p>Then inspect <strong>Realm Settings → Client Policies → Profiles / Policies</strong> in the RHBK Admin Console.</p><a class="button secondary" href="/#fapi">Back</a></div>'))

    if path == "/fapi2-evidence":
        ev = dict(FAPI2_DEMO_STATE)
        if ev.get("status") != "success":
            return response(start_response, layout("FAPI 2 evidence", '<div class="card"><h2>No FAPI 2 evidence yet</h2><pre>./scripts/configure-fapi2.sh</pre><a class="button" href="/#fapi">Back</a></div>'))
        profile_html = "".join(f'<li><code>{esc(v)}</code></li>' for v in ev.get("global_profiles", []))
        executor_html = "".join(f'<li><code>{esc(v)}</code></li>' for v in ev.get("active_profile_executors", []))
        return response(start_response, layout("FAPI 2 policy evidence", f'<section class="hero"><h1>High-assurance OAuth controls</h1><div class="status ok"><strong>FAPI 2 policy configured ✓</strong><br>Client: <code>{esc(ev.get("client_id"))}</code><br>Policy: <code>{esc(ev.get("policy_name"))}</code><br>Profile: <code>{esc(ev.get("active_profile"))}</code></div></section><div class="evidence"><h2>Built-in RHBK FAPI 2 profiles</h2><ul>{profile_html}</ul><h2>Active profile executors</h2><ul>{executor_html}</ul></div><div class="card"><h2>Policy evidence</h2><pre>{esc(json.dumps(ev, indent=2, sort_keys=True))}</pre><div class="status info">This proves RHBK FAPI policy configuration; it does not claim independent certification of the ACME demo application.</div><a class="button secondary" href="/#fapi">Back</a></div>'))

    if path == "/fapi2-reset":
        FAPI2_DEMO_STATE.clear(); start_response("302 Found", [("Location","/#fapi"),("Cache-Control","no-store")]); return [b""]

    if path == "/logout":
        if sid: SESSIONS.pop(sid, None)
        if psid: PEOPLESOFT_SESSIONS.pop(psid, None)
        start_response("302 Found", [("Location","/"),("Set-Cookie","sid=; Path=/; Max-Age=0; Secure; HttpOnly"),("Set-Cookie","psid=; Path=/; Max-Age=0; Secure; HttpOnly")]); return [b""]

    return response(start_response, layout("ACME Digital Identity", demo_dashboard(portal_session, peoplesoft_session)))


if __name__ == "__main__":
    print("ACME Portal listening on 0.0.0.0:8080")
    with make_server("0.0.0.0", 8080, app) as httpd:
        httpd.serve_forever()
