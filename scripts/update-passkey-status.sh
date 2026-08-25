#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-rhbk}"
APP="${APP_FILE:-portal/app.py}"
DEPLOYMENT="${PORTAL_DEPLOYMENT:-acme-portal}"
CONFIGMAP="${PORTAL_CONFIGMAP:-acme-portal-code}"

if [[ ! -f "$APP" ]]; then
  echo "ERROR: Cannot find $APP"
  echo "Run this from the acme-rhbk-demo repository root."
  exit 1
fi

BACKUP="${APP}.bak.$(date +%Y%m%d%H%M%S)"
cp "$APP" "$BACKUP"

echo
echo "Backup:"
echo "  $BACKUP"
echo

python3 - "$APP" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()


# ============================================================
# 1. PASSKEY DEMO STATE
# ============================================================

if "PASSKEY_DEMO_STATE = {}" not in s:

    block = '''

# ------------------------------------------------------------
# Passkey / WebAuthn demo state
#
# This is Portal demo state only.
# It does NOT represent the actual WebAuthn credential store.
#
# Example:
#
# PASSKEY_DEMO_STATE["alex"] = {
#     "credential": True,
#     "signin": True,
# }
# ------------------------------------------------------------

PASSKEY_DEMO_STATE = {}

'''

    # Prefer putting this after the broker provider definitions
    # if the broker-status update has already been installed.
    m = re.search(
        r'BROKER_PROVIDERS\s*=\s*\{.*?\n\}\n',
        s,
        re.S,
    )

    if m:
        s = s[:m.end()] + block + s[m.end():]

    elif "STATES = {}\n" in s:
        s = s.replace(
            "STATES = {}\n",
            "STATES = {}\n" + block,
            1,
        )

    else:
        raise SystemExit(
            "ERROR: Could not find location for PASSKEY_DEMO_STATE"
        )


# ============================================================
# 2. PASSKEY STATUS CSS
# ============================================================

if ".passkey-complete" not in s:

    css = '''
.passkey-demo-list{{
  margin:14px 0;
}}

.passkey-demo-row{{
  display:flex;
  align-items:center;
  flex-wrap:wrap;
  gap:8px;
  margin:8px 0;
}}

a.button.passkey-pending{{
  background:#ec7a08;
  color:#fff;
  min-width:270px;
}}

a.button.passkey-pending:hover{{
  background:#c65d00;
}}

a.button.passkey-complete{{
  background:#3e8635;
  color:#fff;
  min-width:270px;
}}

a.button.passkey-complete:hover{{
  background:#2f6b29;
}}

.passkey-check{{
  font-weight:900;
  margin-left:5px;
}}
'''

    marker = "@media(max-width:720px)"

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not find CSS insertion anchor"
        )

    s = s.replace(
        marker,
        css + marker,
        1,
    )


# ============================================================
# 3. BUILD PASSKEY UI STATE IN demo_dashboard()
# ============================================================

if "passkey_credential_ready =" not in s:

    marker = '''    ps_focus = None
'''

    code = '''    # ------------------------------------------------
    # Passkey / WebAuthn demo indicators
    # ------------------------------------------------

    passkey_state = {}

    if portal_user:
        passkey_state = PASSKEY_DEMO_STATE.get(
            portal_user,
            {},
        )

    passkey_credential_ready = bool(
        passkey_state.get("credential")
    )

    passkey_signin_complete = bool(
        passkey_state.get("signin")
    )

    if passkey_credential_ready:

        passkey_register_button = f"""
        <div class="passkey-demo-row">

          <a class="button passkey-complete"
             href="/passkey-register">

            Passkey credential — Ready
            <span class="passkey-check">✓</span>

          </a>

        </div>
        """

    else:

        passkey_register_button = """
        <div class="passkey-demo-row">

          <a class="button passkey-pending"
             href="/passkey-register">

            Register / verify passkey

          </a>

        </div>
        """


    if passkey_signin_complete:

        passkey_login_button = f"""
        <div class="passkey-demo-row">

          <a class="button passkey-complete"
             href="/passkey-login">

            Passwordless sign-in — Authenticated
            <span class="passkey-check">✓</span>

          </a>

        </div>
        """

    else:

        passkey_login_button = """
        <div class="passkey-demo-row">

          <a class="button passkey-pending"
             href="/passkey-login">

            Test standard passkey sign-in

          </a>

        </div>
        """


    if (
        passkey_credential_ready
        and passkey_signin_complete
    ):

        passkey_status = f"""
        <div class="status ok">
          <strong>
            Passkey / WebAuthn demo complete.
          </strong><br>
          User:
          <strong>{esc(portal_user)}</strong><br>
          Discoverable credential:
          <strong>demonstrated</strong><br>
          Passwordless authentication:
          <strong>demonstrated</strong>
        </div>
        """

    elif passkey_credential_ready:

        passkey_status = f"""
        <div class="status info">
          Passkey registration / verification completed for
          <strong>{esc(portal_user)}</strong>.
          Now test passwordless sign-in.
        </div>
        """

    else:

        passkey_status = """
        <div class="status wait">
          Passkey registration has not yet been demonstrated.
        </div>
        """

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not find demo_dashboard anchor"
        )

    s = s.replace(
        marker,
        code + marker,
        1,
    )


# ============================================================
# 4. REPLACE PASSKEY CARD
# ============================================================

passkey_card = '''<div id="passkeys" class="card primary">

<div class="kicker">
  <span class="step">2</span>
  Passkeys / WebAuthn
</div>

<h3>
Passwordless authentication
</h3>

<p>
Register a discoverable passwordless credential using
Touch ID, Windows Hello, a mobile passkey or a hardware
security key.
</p>

{passkey_status}

<div class="passkey-demo-list">

{passkey_register_button}

{passkey_login_button}

</div>

<p class="tiny">
<strong>RHBK policy:</strong>
user verification required;
discoverable credential required.
</p>

<p class="tiny">
For the passwordless test, choose
<strong>Sign in with Passkey</strong>
on the RHBK login screen rather than entering the password.
</p>

<a class="button outline"
   href="{esc(KEYCLOAK_URL)}/realms/{esc(REALM)}/account/">

  Manage Passkeys

</a>

<a class="button outline"
   href="/passkey-reset">

  Reset demo status

</a>

</div>
'''

pattern = re.compile(
    r'<div id="passkeys" class="card primary">'
    r'.*?'
    r'(?=<div id="consent" class="card primary">)',
    re.S,
)

if not pattern.search(s):
    raise SystemExit(
        "ERROR: Could not locate Passkeys card"
    )

s = pattern.sub(
    lambda match: passkey_card,
    s,
    count=1,
)


# ============================================================
# 5. KEEP EXISTING PASSKEY REGISTRATION ROUTE
#
# Existing route uses:
#
# kc_action =
# webauthn-register-passwordless:skip_if_exists
#
# which is what we want.
# ============================================================

if 'if path == "/passkey-register":' not in s:
    raise SystemExit(
        "ERROR: Existing /passkey-register route not found"
    )


# ============================================================
# 6. ADD DEDICATED PASSKEY LOGIN TEST
#
# prompt=login + max_age=0 forces RHBK to present an
# authentication interaction rather than silently using the
# existing SSO cookie.
#
# The presenter should click "Sign in with Passkey".
# ============================================================

if 'if path == "/passkey-login":' not in s:

    marker = '''    if path == "/peoplesoft":
'''

    route = '''    if path == "/passkey-login":

        return auth_redirect(
            start_response,
            base,
            CLIENT_ID,
            "/callback",
            extras={
                "prompt": "login",
                "max_age": "0",
            },
            purpose="passkey-login",
        )

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not find /peoplesoft route"
        )

    s = s.replace(
        marker,
        route + marker,
        1,
    )


# ============================================================
# 7. RECORD SUCCESSFUL PASSKEY DEMO CALLBACKS
#
# passkey-register:
#   registration happened, OR skip_if_exists confirmed the
#   user already had the passwordless credential.
#
# passkey-login:
#   the explicit passkey test returned successfully.
#
# Note:
# The presenter must actually select "Sign in with Passkey"
# on that login page. The normal browser flow still has a
# password fallback.
# ============================================================

if "# Passkey / WebAuthn demo status" not in s:

    marker = '''        STATES.pop(state, None)
'''

    code = '''        # ------------------------------------------------
        # Passkey / WebAuthn demo status
        # ------------------------------------------------

        purpose = state_data.get(
            "purpose"
        )

        if purpose in {
            "passkey-register",
            "passkey-login",
        }:

            passkey_focus, _, _ = claims_focus(
                tokens
            )

            passkey_user = passkey_focus.get(
                "user"
            )

            if passkey_user:

                demo_state = (
                    PASSKEY_DEMO_STATE.setdefault(
                        passkey_user,
                        {},
                    )
                )

                if purpose == "passkey-register":

                    demo_state[
                        "credential"
                    ] = True

                elif purpose == "passkey-login":

                    demo_state[
                        "signin"
                    ] = True

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not locate callback state anchor"
        )

    s = s.replace(
        marker,
        code + marker,
        1,
    )


# ============================================================
# 8. ADD PASSKEY DEMO RESET ROUTE
#
# This does NOT delete the actual RHBK WebAuthn credential.
# It only resets the green/orange Portal indicators.
# ============================================================

if 'if path == "/passkey-reset":' not in s:

    # Put it before broker revoke if present, otherwise logout.
    if '    if path == "/broker-revoke":' in s:
        marker = '''    if path == "/broker-revoke":
'''
    else:
        marker = '''    if path == "/logout":
'''

    route = '''    if path == "/passkey-reset":

        if portal_session:

            passkey_focus, _, _ = claims_focus(
                portal_session
            )

            passkey_user = passkey_focus.get(
                "user"
            )

            if passkey_user:

                PASSKEY_DEMO_STATE.pop(
                    passkey_user,
                    None,
                )

        else:

            # Demo convenience:
            # if no Portal session exists, reset any stored
            # passkey demonstration indicators.
            PASSKEY_DEMO_STATE.clear()

        start_response(
            "302 Found",
            [
                ("Location", "/#passkeys"),
                ("Cache-Control", "no-store"),
            ],
        )

        return [b""]

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not find route insertion point"
        )

    s = s.replace(
        marker,
        route + marker,
        1,
    )


p.write_text(s)

print(f"Updated {p}")
PY


echo
echo "Checking Python syntax..."

python3 -m py_compile "$APP"

echo "Python syntax: OK"


echo
echo "Updating OpenShift ConfigMap..."

oc -n "$NS" create configmap "$CONFIGMAP" \
  --from-file=app.py="$APP" \
  --dry-run=client \
  -o yaml |
oc apply -f -


echo
echo "Restarting ACME Portal..."

oc -n "$NS" rollout restart \
  deployment/"$DEPLOYMENT"

oc -n "$NS" rollout status \
  deployment/"$DEPLOYMENT"


echo
echo "Verifying live Portal code..."

PORTAL_POD=$(oc -n "$NS" get pod \
  -l app=acme-portal \
  -o jsonpath='{.items[0].metadata.name}')

echo
echo "Portal pod:"
echo "  $PORTAL_POD"
echo

oc -n "$NS" exec "$PORTAL_POD" -- \
  grep -nE \
  'PASSKEY_DEMO_STATE|passkey-login|passkey-reset|passkey-complete' \
  /opt/app/app.py |
head -50


PORTAL="https://$(oc -n "$NS" get route acme-portal \
  -o jsonpath='{.spec.host}')"

echo
echo "======================================================"
echo " Passkeys / WebAuthn Portal update complete"
echo "======================================================"
echo
echo "Portal:"
echo "  $PORTAL/#passkeys"
echo
echo "Demo sequence:"
echo
echo "  1. Register / verify passkey"
echo "     -> complete Touch ID / Windows Hello / security key"
echo "     -> button becomes GREEN"
echo
echo "  2. Test standard passkey sign-in"
echo "     -> choose 'Sign in with Passkey' in RHBK"
echo "     -> complete Touch ID / passkey"
echo "     -> button becomes GREEN"
echo
echo "  3. Reset demo status"
echo "     -> indicators return to ORANGE"
echo "     -> real RHBK passkey is NOT deleted"
echo
echo "  4. Manage Passkeys"
echo "     -> opens actual RHBK Account Console"
echo
