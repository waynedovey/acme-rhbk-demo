#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-rhbk}"
APP="${APP_FILE:-portal/app.py}"
DEPLOYMENT="${PORTAL_DEPLOYMENT:-acme-portal}"
CONFIGMAP="${PORTAL_CONFIGMAP:-acme-portal-code}"

if [[ ! -f "$APP" ]]; then
  echo "ERROR: Cannot find $APP"
  echo "Run this script from the acme-rhbk-demo repository root."
  exit 1
fi

BACKUP="${APP}.bak.$(date +%Y%m%d%H%M%S)"
cp "$APP" "$BACKUP"

echo "Backup created:"
echo "  $BACKUP"
echo

python3 - "$APP" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()


# ============================================================
# 1. Broker authentication demo state
# ============================================================

if "BROKER_AUTH_STATE = {}" not in s:
    anchor = "STATES = {}\n"

    addition = '''STATES = {}

# Demo-only state.
#
# Records which upstream identity providers have successfully
# authenticated a local ACME user during the current Portal
# process.
#
# This does NOT remove or change the real federated identity
# link stored in RHBK.
BROKER_AUTH_STATE = {}

BROKER_PROVIDERS = {
    "legacy-idp": "Legacy Identity",
    "partner-idp": "Partner Identity",
    "corporate-idp": "Corporate Identity",
}
'''

    if anchor not in s:
        raise SystemExit(
            "ERROR: Could not find STATES = {} anchor"
        )

    s = s.replace(
        anchor,
        addition,
        1,
    )


# ============================================================
# 2. Broker status CSS
# ============================================================

if ".broker-authenticated" not in s:

    css = '''
.broker-list{{margin:14px 0}}

.broker-row{{
  display:flex;
  align-items:center;
  flex-wrap:wrap;
  gap:8px;
  margin:8px 0;
}}

a.button.broker-pending{{
  background:#ec7a08;
  color:#fff;
  min-width:255px;
}}

a.button.broker-pending:hover{{
  background:#c65d00;
}}

a.button.broker-authenticated{{
  background:#3e8635;
  color:#fff;
  min-width:255px;
}}

a.button.broker-authenticated:hover{{
  background:#2f6b29;
}}

a.broker-revoke{{
  display:inline-block;
  background:#fff;
  color:#a30000;
  border:1px solid #ee0000;
  border-radius:5px;
  padding:9px 12px;
  text-decoration:none;
  font-size:12px;
  font-weight:800;
}}

a.broker-revoke:hover{{
  background:#fff0f0;
}}

.broker-check{{
  font-weight:900;
  margin-left:5px;
}}
'''

    marker = "@media(max-width:720px)"

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not find CSS media-query anchor"
        )

    s = s.replace(
        marker,
        css + marker,
        1,
    )


# ============================================================
# 3. Helper for rendering broker buttons
# ============================================================

if "def broker_status_button(" not in s:

    marker = (
        "\ndef demo_dashboard("
        "portal_session, peoplesoft_session):\n"
    )

    helper = r"""

def broker_status_button(provider, authenticated):
    label = BROKER_PROVIDERS[provider]

    if authenticated:
        return f'''
        <div class="broker-row">

          <a class="button broker-authenticated"
             href="/login?idp={esc(provider)}">

            {esc(label)} — Authenticated
            <span class="broker-check">✓</span>

          </a>

          <a class="broker-revoke"
             href="/broker-revoke?provider={esc(provider)}">

            Revoke

          </a>

        </div>
        '''

    return f'''
    <div class="broker-row">

      <a class="button broker-pending"
         href="/login?idp={esc(provider)}">

        {esc(label)} — Authenticate

      </a>

    </div>
    '''
"""

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not find demo_dashboard()"
        )

    s = s.replace(
        marker,
        helper + marker,
        1,
    )


# ============================================================
# 4. Update auth_redirect()
#
# Remember which IdP was requested in OAuth state so the
# callback can mark that provider as authenticated.
# ============================================================

pattern = re.compile(
    r'def auth_redirect'
    r'\(start_response, base, client_id, callback_path, '
    r'scope="openid profile email", extras=None, '
    r'purpose="login"\):\n'
    r'.*?\n\n'
    r'(?=def claims_focus)',
    re.S,
)

replacement = '''def auth_redirect(
    start_response,
    base,
    client_id,
    callback_path,
    scope="openid profile email",
    extras=None,
    purpose="login",
):
    state = secrets.token_urlsafe(24)

    identity_provider = None

    if extras:
        identity_provider = extras.get(
            "kc_idp_hint"
        )

    STATES[state] = {
        "client_id": client_id,
        "callback_path": callback_path,
        "purpose": purpose,
        "identity_provider": identity_provider,
        "created": time.time(),
    }

    params = {
        "client_id": client_id,
        "redirect_uri": f"{base}{callback_path}",
        "response_type": "code",
        "scope": scope,
        "state": state,
    }

    if extras:
        params.update(extras)

    location = (
        f"{KEYCLOAK_URL}"
        f"/realms/{REALM}"
        f"/protocol/openid-connect/auth?"
        f"{urllib.parse.urlencode(params)}"
    )

    start_response(
        "302 Found",
        [
            ("Location", location),
            ("Cache-Control", "no-store"),
        ],
    )

    return [b""]


'''

if not pattern.search(s):
    raise SystemExit(
        "ERROR: Could not locate auth_redirect()"
    )

s = pattern.sub(
    replacement,
    s,
    count=1,
)


# ============================================================
# 5. Prepare broker status for demo_dashboard()
# ============================================================

if "broker_authenticated = set()" not in s:

    marker = '''    ps_focus = None
'''

    insert = '''    broker_authenticated = set()
    current_broker = "local"

    if portal_session and portal_user:

        broker_authenticated = (
            BROKER_AUTH_STATE.get(
                portal_user,
                set(),
            )
        )

        current_broker = portal_session.get(
            "_broker_provider",
            "local",
        )

    legacy_broker = broker_status_button(
        "legacy-idp",
        "legacy-idp" in broker_authenticated,
    )

    partner_broker = broker_status_button(
        "partner-idp",
        "partner-idp" in broker_authenticated,
    )

    corporate_broker = broker_status_button(
        "corporate-idp",
        "corporate-idp" in broker_authenticated,
    )

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not find ps_focus dashboard anchor"
        )

    s = s.replace(
        marker,
        insert + marker,
        1,
    )


# ============================================================
# 6. Show which broker created the current Portal session
# ============================================================

if "current_broker_status =" not in s:

    marker = '''    ps_status = (
'''

    insert = '''    current_broker_status = ""

    if (
        portal_session
        and current_broker in BROKER_PROVIDERS
    ):
        current_broker_status = (
            '<div class="status ok">'
            'Current ACME session authenticated via '
            f'<strong>'
            f'{esc(BROKER_PROVIDERS[current_broker])}'
            f'</strong>.'
            '</div>'
        )

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not find ps_status anchor"
        )

    s = s.replace(
        marker,
        insert + marker,
        1,
    )


if "{current_broker_status}" not in s:

    s = s.replace(
        "{portal_status}\n{ps_status}",
        (
            "{portal_status}\n"
            "{current_broker_status}\n"
            "{ps_status}"
        ),
        1,
    )


# ============================================================
# 7. Replace Identity Brokering card
# ============================================================

broker_card = '''<div id="broker" class="card primary">

<div class="kicker">
  <span class="step">1</span>
  Identity brokering
</div>

<h3>
Legacy / partner / corporate identity
</h3>

<p>
Applications trust one ACME issuer while RHBK brokers
authentication to external identity providers and links
them to the same local identity.
</p>

<a class="button"
   href="/login?force=1">
  Open broker chooser
</a>

<div class="broker-list">

{legacy_broker}

{partner_broker}

{corporate_broker}

</div>

<p class="tiny">
<strong>Demo status:</strong>
orange means the upstream identity has not yet been
demonstrated. Green means that provider successfully
authenticated the current ACME identity.
<strong>Revoke</strong> resets only this demo indicator.
</p>

<a class="button outline"
   href="{esc(KEYCLOAK_URL)}/realms/{esc(REALM)}/account/">

  Manage Linked Identities

</a>

</div>
'''

card_pattern = re.compile(
    r'<div id="broker" class="card primary">'
    r'.*?'
    r'(?=<div id="passkeys" class="card primary">)',
    re.S,
)

if not card_pattern.search(s):
    raise SystemExit(
        "ERROR: Could not locate Identity Brokering card"
    )

s = card_pattern.sub(
    lambda match: broker_card,
    s,
    count=1,
)


# ============================================================
# 8. Update /login route
#
# Supports all 3 IdPs.
#
# prompt=login and max_age=0 make the customer demo explicit
# instead of silently reusing an existing RHBK SSO session.
# ============================================================

login_pattern = re.compile(
    r'    if path == "/login":\n'
    r'.*?'
    r'(?=    if path == "/passkey-register":)',
    re.S,
)

login_block = '''    if path == "/login":

        scope = query.get(
            "scope",
            ["openid profile email"],
        )[0]

        extras = {}

        idp = query.get(
            "idp",
            [""],
        )[0]

        force = (
            query.get(
                "force",
                ["0"],
            )[0]
            == "1"
        )

        if idp in BROKER_PROVIDERS:

            extras["kc_idp_hint"] = idp

            # Make this an explicit broker authentication
            # rather than silently reusing the existing SSO
            # session.
            extras["prompt"] = "login"
            extras["max_age"] = "0"

        elif force:

            extras["prompt"] = "login"

        return auth_redirect(
            start_response,
            base,
            CLIENT_ID,
            "/callback",
            scope=scope,
            extras=extras,
            purpose="portal",
        )

'''

if not login_pattern.search(s):
    raise SystemExit(
        "ERROR: Could not locate /login route"
    )

s = login_pattern.sub(
    login_block,
    s,
    count=1,
)


# ============================================================
# 9. Mark broker green after successful authentication
# ============================================================

if "# Identity broker demo status" not in s:

    marker = '''        STATES.pop(state, None)
        new_id = secrets.token_urlsafe(24)
'''

    insert = '''        # Identity broker demo status.
        #
        # This records successful use of an upstream IdP.
        # It does NOT modify the persistent federated identity
        # link stored in RHBK.

        broker_provider = state_data.get(
            "identity_provider"
        )

        if broker_provider in BROKER_PROVIDERS:

            focus, _, _ = claims_focus(tokens)

            broker_user = focus.get(
                "user"
            )

            if broker_user:

                BROKER_AUTH_STATE.setdefault(
                    broker_user,
                    set(),
                ).add(
                    broker_provider
                )

            tokens["_broker_provider"] = (
                broker_provider
            )

        else:

            tokens["_broker_provider"] = "local"

        STATES.pop(state, None)

        new_id = secrets.token_urlsafe(24)
'''

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not locate callback success anchor"
        )

    s = s.replace(
        marker,
        insert,
        1,
    )


# ============================================================
# 10. Add Revoke route
#
# This resets the demo status from GREEN -> ORANGE.
#
# It deliberately does NOT delete the RHBK federated identity.
# ============================================================

if 'if path == "/broker-revoke":' not in s:

    marker = '''    if path == "/logout":
'''

    route = '''    if path == "/broker-revoke":

        provider = query.get(
            "provider",
            [""],
        )[0]

        if provider not in BROKER_PROVIDERS:

            return response(
                start_response,
                layout(
                    "Invalid provider",
                    (
                        '<div class="card">'
                        '<h2>Unknown identity provider</h2>'
                        '<a class="button" href="/#broker">'
                        'Back to demo'
                        '</a>'
                        '</div>'
                    ),
                ),
                "400 Bad Request",
            )

        if not portal_session:

            return response(
                start_response,
                layout(
                    "Not signed in",
                    (
                        '<div class="card">'
                        '<h2>No ACME session</h2>'
                        '<p>'
                        'Sign in before changing broker '
                        'demo state.'
                        '</p>'
                        '<a class="button" href="/">'
                        'Back to demo'
                        '</a>'
                        '</div>'
                    ),
                ),
                "401 Unauthorized",
            )

        focus, _, _ = claims_focus(
            portal_session
        )

        portal_user = focus.get(
            "user"
        )

        if portal_user:

            BROKER_AUTH_STATE.setdefault(
                portal_user,
                set(),
            ).discard(
                provider
            )

        # If the current portal session was established using
        # this provider, remove that display indicator too.
        if (
            portal_session.get(
                "_broker_provider"
            )
            == provider
        ):
            portal_session[
                "_broker_provider"
            ] = "local"

        start_response(
            "302 Found",
            [
                ("Location", "/#broker"),
                ("Cache-Control", "no-store"),
            ],
        )

        return [b""]

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: Could not find /logout route"
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
  'BROKER_AUTH_STATE|broker-revoke|broker-authenticated|corporate-idp' \
  /opt/app/app.py |
head -40


PORTAL="https://$(oc -n "$NS" get route acme-portal \
  -o jsonpath='{.spec.host}')"

echo
echo "======================================================"
echo " Identity Brokering UI update complete"
echo "======================================================"
echo
echo "Portal:"
echo "  $PORTAL"
echo
echo "Test:"
echo
echo "  1. Legacy Identity"
echo "  2. Authenticate"
echo "  3. Return to Portal"
echo "  4. Legacy should be GREEN"
echo "  5. Click Revoke"
echo "  6. Legacy should return to ORANGE"
echo
echo "Then repeat with Partner and Corporate Identity."
echo
