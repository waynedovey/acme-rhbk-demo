#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-rhbk}"
APP="${APP_FILE:-portal/app.py}"
DEPLOYMENT="${PORTAL_DEPLOYMENT:-acme-portal}"
CONFIGMAP="${PORTAL_CONFIGMAP:-acme-portal-code}"

POD="${KEYCLOAK_POD:-acme-keycloak-0}"
KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/kcadm.config
REALM=acme-demo
CLIENT_ID=acme-portal

if [[ ! -f "$APP" ]]; then
  echo "ERROR: Cannot find $APP"
  echo "Run this script from the acme-rhbk-demo repository root."
  exit 1
fi

echo
echo "======================================================"
echo " ACME Granular Consent Update"
echo "======================================================"
echo


# ============================================================
# 1. Authenticate kcadm
# ============================================================

ADMIN_USER=$(oc -n "$NS" get secret acme-keycloak-initial-admin \
  -o jsonpath='{.data.username}' | base64 -d)

ADMIN_PASS=$(oc -n "$NS" get secret acme-keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 -d)

oc -n "$NS" exec "$POD" -- \
  "$KCADM" config credentials \
  --config "$CFG" \
  --server http://localhost:8080 \
  --realm master \
  --user "$ADMIN_USER" \
  --password "$ADMIN_PASS"


kc() {
  oc -n "$NS" exec "$POD" -- \
    "$KCADM" "$@" --config "$CFG"
}


kci() {
  oc -n "$NS" exec -i "$POD" -- \
    "$KCADM" "$@" --config "$CFG"
}


# ============================================================
# 2. Find ACME Portal client
# ============================================================

CLIENT_UUID=$(
  kc get clients \
    -r "$REALM" \
    -q clientId="$CLIENT_ID" |
  jq -r '.[0].id // empty'
)

if [[ -z "$CLIENT_UUID" ]]; then
  echo "ERROR: Cannot find client $CLIENT_ID"
  exit 1
fi

echo
echo "Portal client:"
echo "  $CLIENT_ID -> $CLIENT_UUID"


# ============================================================
# 3. Create/update granular OAuth client scopes
# ============================================================

ensure_scope() {

  local NAME="$1"
  local TEXT="$2"
  local UUID

  UUID=$(
    kc get client-scopes \
      -r "$REALM" |
    jq -r --arg name "$NAME" '
      .[] |
      select(.name == $name) |
      .id
    ' |
    head -1
  )

  if [[ -z "$UUID" ]]; then

    echo "Creating client scope: $NAME"

    jq -n \
      --arg name "$NAME" \
      --arg text "$TEXT" '
      {
        name: $name,
        protocol: "openid-connect",

        attributes: {
          "include.in.token.scope": "true",
          "display.on.consent.screen": "true",
          "consent.screen.text": $text
        }
      }
      ' |
    kci create client-scopes \
      -r "$REALM" \
      -f - >/dev/null

    UUID=$(
      kc get client-scopes \
        -r "$REALM" |
      jq -r --arg name "$NAME" '
        .[] |
        select(.name == $name) |
        .id
      ' |
      head -1
    )

  else

    echo "Updating client scope: $NAME"

    kc get "client-scopes/$UUID" \
      -r "$REALM" |
    jq \
      --arg text "$TEXT" '

      .attributes = (
        (.attributes // {})
        +
        {
          "include.in.token.scope": "true",
          "display.on.consent.screen": "true",
          "consent.screen.text": $text
        }
      )

      ' |
    kci update "client-scopes/$UUID" \
      -r "$REALM" \
      -n \
      -f - >/dev/null

  fi


  # ----------------------------------------------------------
  # Attach to acme-portal as OPTIONAL scope
  # ----------------------------------------------------------

  ALREADY=$(
    kc get \
      "clients/$CLIENT_UUID/optional-client-scopes" \
      -r "$REALM" |
    jq -r --arg name "$NAME" '
      any(.[]; .name == $name)
    '
  )

  if [[ "$ALREADY" != "true" ]]; then

    echo "Attaching optional scope to $CLIENT_ID: $NAME"

    kc update \
      "clients/$CLIENT_UUID/optional-client-scopes/$UUID" \
      -r "$REALM" >/dev/null

  else

    echo "Already optional on $CLIENT_ID: $NAME"

  fi
}


ensure_scope \
  personal-details \
  "Access your ACME personal details"

ensure_scope \
  orders-history \
  "Access your ACME orders history"

ensure_scope \
  support-profile \
  "Access information required for ACME customer support"


echo
echo "Optional scopes currently assigned to $CLIENT_ID:"
echo

kc get \
  "clients/$CLIENT_UUID/optional-client-scopes" \
  -r "$REALM" |
jq -r '.[].name' |
sort


# ============================================================
# IMPORTANT:
#
# Do NOT enable consentRequired on acme-portal.
#
# This client is also used by the existing Token Exchange demo.
# The Portal itself will provide the granular consent UX while
# RHBK remains responsible for issuing/enforcing the actual
# requested OAuth scopes.
# ============================================================

echo
echo "Checking consentRequired on main Portal client..."

kc get "clients/$CLIENT_UUID" \
  -r "$REALM" |
jq '{
  clientId,
  consentRequired,
  optionalClientScopes
}'


# ============================================================
# 4. Patch Portal
# ============================================================

BACKUP="${APP}.bak.$(date +%Y%m%d%H%M%S)"
cp "$APP" "$BACKUP"

echo
echo "Portal backup:"
echo "  $BACKUP"
echo


python3 - "$APP" <<'PY'
from pathlib import Path
import re
import sys

p = Path(sys.argv[1])
s = p.read_text()


# ============================================================
# CONSENT STATE
# ============================================================

if "CONSENT_DEMO_STATE = {}" not in s:

    block = '''

# ------------------------------------------------------------
# Granular consent demo
#
# RHBK owns and enforces the OAuth client scopes.
#
# This lightweight Portal state records which grants have been
# demonstrated so the customer can clearly see:
#
#   ORANGE -> not granted
#   GREEN  -> granted
#
# We only mark a grant successful if the RHBK access token
# returned from the authorization flow actually contains the
# requested scope.
# ------------------------------------------------------------

CONSENT_DEMO_STATE = {}
CONSENT_LAST_TOKENS = {}

CONSENT_SCOPE_INFO = {

    "personal-details": {
        "name": "Personal details",
        "description":
            "Basic ACME identity information such as "
            "name, profile and contact details.",
    },

    "orders-history": {
        "name": "Orders history",
        "description":
            "Access to the user's ACME order history "
            "and previous transaction information.",
    },

    "support-profile": {
        "name": "Support profile",
        "description":
            "Information required by ACME customer "
            "support to assist the user.",
    },
}

'''

    if "PASSKEY_DEMO_STATE = {}" in s:

        s = s.replace(
            "PASSKEY_DEMO_STATE = {}",
            "PASSKEY_DEMO_STATE = {}" + block,
            1,
        )

    elif "BROKER_AUTH_STATE = {}" in s:

        s = s.replace(
            "BROKER_AUTH_STATE = {}",
            "BROKER_AUTH_STATE = {}" + block,
            1,
        )

    elif "STATES = {}\n" in s:

        s = s.replace(
            "STATES = {}\n",
            "STATES = {}\n" + block,
            1,
        )

    else:

        raise SystemExit(
            "ERROR: Cannot find state insertion point"
        )


# ============================================================
# CSS
# ============================================================

if ".consent-granted" not in s:

    css = '''

.consent-list{{
  margin:14px 0;
}}

.consent-row{{
  display:flex;
  align-items:center;
  flex-wrap:wrap;
  gap:8px;
  margin:8px 0;
}}

a.button.consent-pending{{
  background:#ec7a08;
  color:#fff;
  min-width:260px;
}}

a.button.consent-pending:hover{{
  background:#c65d00;
}}

a.button.consent-granted{{
  background:#3e8635;
  color:#fff;
  min-width:260px;
}}

a.button.consent-granted:hover{{
  background:#2f6b29;
}}

a.consent-revoke{{
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

a.consent-revoke:hover{{
  background:#fff0f0;
}}

.consent-request{{
  border:1px solid #d2d2d2;
  border-left:5px solid #ec7a08;
  border-radius:7px;
  padding:14px;
  margin:10px 0;
  background:#fff;
}}

.consent-request strong{{
  display:block;
  margin-bottom:4px;
}}

.scope-name{{
  font-family:monospace;
  background:#f0f0f0;
  padding:2px 5px;
  border-radius:4px;
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
# HELPER
# ============================================================

if "def consent_status_button(" not in s:

    marker = "\ndef demo_dashboard("

    helper = r'''

def consent_status_button(key, label, scopes, granted):

    scope_arg = ",".join(scopes)

    encoded = urllib.parse.quote(
        scope_arg,
        safe="",
    )

    if granted:

        return f"""
        <div class="consent-row">

          <a class="button consent-granted"
             href="/consent-request?scope={encoded}">

            {esc(label)} — Granted ✓

          </a>

          <a class="consent-revoke"
             href="/consent-revoke?scope={encoded}">

            Revoke

          </a>

        </div>
        """

    return f"""
    <div class="consent-row">

      <a class="button consent-pending"
         href="/consent-request?scope={encoded}">

        {esc(label)} — Request access

      </a>

    </div>
    """

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: Cannot find demo_dashboard()"
        )

    s = s.replace(
        marker,
        helper + marker,
        1,
    )


# ============================================================
# DASHBOARD CONSENT STATUS
# ============================================================

if "personal_consent_button =" not in s:

    marker = "    ps_focus = None\n"

    code = '''    # ------------------------------------------------
    # Granular consent state
    # ------------------------------------------------

    consent_grants = set()

    if portal_user:

        consent_grants = CONSENT_DEMO_STATE.get(
            portal_user,
            set(),
        )


    personal_granted = (
        "personal-details"
        in consent_grants
    )

    orders_granted = (
        "orders-history"
        in consent_grants
    )

    multiple_scopes = {
        "personal-details",
        "orders-history",
        "support-profile",
    }

    multiple_granted = (
        multiple_scopes
        <= consent_grants
    )


    personal_consent_button = (
        consent_status_button(
            "personal-details",
            "Personal details",
            ["personal-details"],
            personal_granted,
        )
    )


    orders_consent_button = (
        consent_status_button(
            "orders-history",
            "Orders history",
            ["orders-history"],
            orders_granted,
        )
    )


    multiple_consent_button = (
        consent_status_button(
            "multiple",
            "Multiple scopes",
            [
                "personal-details",
                "orders-history",
                "support-profile",
            ],
            multiple_granted,
        )
    )


    if consent_grants:

        granted_text = ", ".join(
            sorted(consent_grants)
        )

        consent_status = f"""
        <div class="status ok">

          <strong>
            Granular consent demonstrated.
          </strong>

          <br>

          Granted optional scopes:

          <strong>
            {esc(granted_text)}
          </strong>

        </div>
        """

    else:

        consent_status = """
        <div class="status wait">

          No optional data access has been granted
          during this demo session.

        </div>
        """

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: Cannot find dashboard insertion point"
        )

    s = s.replace(
        marker,
        code + marker,
        1,
    )


# ============================================================
# REPLACE GRANULAR CONSENT CARD
# ============================================================

consent_card = '''<div id="consent" class="card primary">

<div class="kicker">
  <span class="step">4</span>
  Granular consent
</div>

<h3>
Request only the data the app needs
</h3>

<p>
Request optional scopes independently so the user sees
exactly what the application is asking to access.
</p>

{consent_status}

<div class="consent-list">

{personal_consent_button}

{orders_consent_button}

{multiple_consent_button}

</div>

<p class="tiny">

<strong>RHBK enforcement:</strong>
the application requests only explicitly selected optional
OIDC client scopes. A grant turns green only when the
returned RHBK access token actually contains that scope.

</p>

<a class="button outline"
   href="/consent-token">

  Show consent token evidence

</a>

<a class="button outline"
   href="/consent-reset">

  Reset demo status

</a>

</div>
'''

pattern = re.compile(
    r'<div id="consent" class="card primary">'
    r'.*?'
    r'(?=<div id="exchange" class="card primary">'
    r'|<div id="workload" class="card primary">'
    r'|<div id="fapi" class="card primary">'
    r'|</section>)',
    re.S,
)

if not pattern.search(s):

    raise SystemExit(
        "ERROR: Could not locate Granular Consent card"
    )

s = pattern.sub(
    lambda match: consent_card,
    s,
    count=1,
)


# ============================================================
# CONSENT ROUTES
# ============================================================

if 'if path == "/consent-request":' not in s:

    marker = '    if path == "/login":\n'

    routes = r'''    # ==================================================
    # GRANULAR CONSENT
    # ==================================================

    if path == "/consent-request":

        raw = query.get(
            "scope",
            [""],
        )[0]

        requested = [
            value.strip()
            for value in raw.split(",")
            if value.strip()
        ]

        requested = list(
            dict.fromkeys(requested)
        )

        invalid = [
            value
            for value in requested
            if value not in CONSENT_SCOPE_INFO
        ]

        if not requested or invalid:

            return response(
                start_response,
                layout(
                    "Invalid consent request",
                    f"""
                    <div class="card">

                      <h2>
                        Invalid consent request
                      </h2>

                      <pre>
{esc(", ".join(invalid) if invalid else "No scopes requested")}
                      </pre>

                      <a class="button"
                         href="/#consent">
                        Back
                      </a>

                    </div>
                    """,
                ),
                "400 Bad Request",
            )


        rows = ""

        for scope in requested:

            info = CONSENT_SCOPE_INFO[
                scope
            ]

            rows += f"""
            <div class="consent-request">

              <strong>
                {esc(info["name"])}
              </strong>

              <span class="scope-name">
                {esc(scope)}
              </span>

              <p>
                {esc(info["description"])}
              </p>

            </div>
            """


        encoded = urllib.parse.quote(
            ",".join(requested),
            safe="",
        )


        body = f"""
        <section class="hero">

          <div class="kicker">
            Granular consent
          </div>

          <h1>
            ACME is requesting access
          </h1>

          <p class="lead">

            Review exactly which categories of data
            this application is asking to access.

          </p>

        </section>


        <div class="card high">

          <h2>
            Requested data
          </h2>

          {rows}

          <div class="status info">

            Only the optional scopes shown above will
            be requested from RHBK.

          </div>

          <a class="button"
             href="/consent-authorize?scope={encoded}">

            Grant requested access

          </a>

          <a class="button secondary"
             href="/#consent">

            Deny / cancel

          </a>

        </div>
        """

        return response(
            start_response,
            layout(
                "Granular consent",
                body,
            ),
        )


    if path == "/consent-authorize":

        raw = query.get(
            "scope",
            [""],
        )[0]

        requested = [
            value.strip()
            for value in raw.split(",")
            if value.strip()
        ]

        requested = list(
            dict.fromkeys(requested)
        )

        invalid = [
            value
            for value in requested
            if value not in CONSENT_SCOPE_INFO
        ]

        if not requested or invalid:

            return response(
                start_response,
                layout(
                    "Invalid consent request",
                    """
                    <div class="card">
                      <h2>
                        Invalid consent request
                      </h2>
                    </div>
                    """,
                ),
                "400 Bad Request",
            )


        requested_scope = (
            "openid profile email "
            + " ".join(requested)
        )


        return auth_redirect(
            start_response,
            base,
            CLIENT_ID,
            "/callback",
            scope=requested_scope,
            purpose=(
                "consent:"
                + ",".join(requested)
            ),
        )


    if path == "/consent-revoke":

        raw = query.get(
            "scope",
            [""],
        )[0]

        requested = {
            value.strip()
            for value in raw.split(",")
            if value.strip()
        }

        requested = {
            value
            for value in requested
            if value in CONSENT_SCOPE_INFO
        }


        if portal_session:

            focus, _, _ = claims_focus(
                portal_session
            )

            user = focus.get(
                "user"
            )

            if user:

                grants = (
                    CONSENT_DEMO_STATE.setdefault(
                        user,
                        set(),
                    )
                )

                grants.difference_update(
                    requested
                )


        start_response(
            "302 Found",
            [
                (
                    "Location",
                    "/#consent",
                ),
                (
                    "Cache-Control",
                    "no-store",
                ),
            ],
        )

        return [b""]


    if path == "/consent-reset":

        if portal_session:

            focus, _, _ = claims_focus(
                portal_session
            )

            user = focus.get(
                "user"
            )

            if user:

                CONSENT_DEMO_STATE.pop(
                    user,
                    None,
                )

                CONSENT_LAST_TOKENS.pop(
                    user,
                    None,
                )

        else:

            CONSENT_DEMO_STATE.clear()
            CONSENT_LAST_TOKENS.clear()


        start_response(
            "302 Found",
            [
                (
                    "Location",
                    "/#consent",
                ),
                (
                    "Cache-Control",
                    "no-store",
                ),
            ],
        )

        return [b""]


    if path == "/consent-token":

        if not portal_session:

            return response(
                start_response,
                layout(
                    "Consent evidence",
                    """
                    <div class="card">

                      <h2>
                        Sign in first
                      </h2>

                      <a class="button"
                         href="/login">
                        Sign in
                      </a>

                    </div>
                    """,
                ),
                "401 Unauthorized",
            )


        focus, _, _ = claims_focus(
            portal_session
        )

        user = focus.get(
            "user"
        )

        evidence = (
            CONSENT_LAST_TOKENS.get(
                user
            )
            if user
            else None
        )


        if not evidence:

            return response(
                start_response,
                layout(
                    "Consent evidence",
                    """
                    <div class="card">

                      <h2>
                        No granular consent token yet
                      </h2>

                      <p>
                        Request Personal details,
                        Orders history or Multiple scopes
                        first.
                      </p>

                      <a class="button"
                         href="/#consent">
                        Back to consent demo
                      </a>

                    </div>
                    """,
                ),
            )


        body = f"""
        <div class="card">

          <div class="kicker">
            RHBK token evidence
          </div>

          <h2>
            Granular scope authorization
          </h2>

          <p>
            The Portal requested:
          </p>

          <pre>
{esc(json.dumps(evidence["requested"], indent=2))}
          </pre>

          <p>
            RHBK returned the following OAuth
            scope claim:
          </p>

          <pre>
{esc(evidence["scope_claim"])}
          </pre>

          <p>
            Relevant access-token claims:
          </p>

          <pre>
{esc(json.dumps(evidence["claims"], indent=2, sort_keys=True))}
          </pre>

          <a class="button secondary"
             href="/#consent">
            Back to consent demo
          </a>

        </div>
        """

        return response(
            start_response,
            layout(
                "Consent token evidence",
                body,
            ),
        )


'''

    if marker not in s:

        raise SystemExit(
            "ERROR: Could not find /login route"
        )

    s = s.replace(
        marker,
        routes + marker,
        1,
    )


# ============================================================
# CALLBACK:
#
# Only mark a consent GREEN after RHBK returns an access
# token that actually contains ALL requested scopes.
# ============================================================

if "# Granular consent token verification" not in s:

    # Put this before broker/passkey status processing if
    # those previous demo enhancements exist.

    possible_markers = [

        "        # Identity broker demo status",
        "        # ------------------------------------------------\n"
        "        # Passkey / WebAuthn demo status",

        "        STATES.pop(state, None)",
    ]

    marker = None

    for candidate in possible_markers:

        if candidate in s:
            marker = candidate
            break

    if not marker:

        raise SystemExit(
            "ERROR: Could not find callback insertion point"
        )


    code = '''        # ------------------------------------------------
        # Granular consent token verification
        # ------------------------------------------------

        consent_purpose = state_data.get(
            "purpose",
            "",
        )

        if consent_purpose.startswith(
            "consent:"
        ):

            requested = {
                value.strip()
                for value in (
                    consent_purpose[
                        len("consent:"):
                    ]
                ).split(",")
                if value.strip()
            }


            token_scope = tokens.get(
                "scope",
                "",
            )

            access_claims = jwt_claims(
                tokens.get(
                    "access_token",
                    "",
                )
            )

            if not token_scope:

                token_scope = access_claims.get(
                    "scope",
                    "",
                )


            granted = set(
                token_scope.split()
            )


            missing = (
                requested
                - granted
            )


            consent_focus, _, _ = (
                claims_focus(tokens)
            )

            consent_user = (
                consent_focus.get(
                    "user"
                )
            )


            if missing:

                STATES.pop(
                    state,
                    None,
                )

                return response(
                    start_response,
                    layout(
                        "Consent scope error",
                        (
                            '<div class="card">'
                            '<h2>'
                            'RHBK did not grant all '
                            'requested scopes'
                            '</h2>'
                            '<p>Missing:</p>'
                            '<pre>'
                            + esc(
                                ", ".join(
                                    sorted(missing)
                                )
                            )
                            + '</pre>'
                            '<p>Returned scope claim:</p>'
                            '<pre>'
                            + esc(token_scope)
                            + '</pre>'
                            '<a class="button" '
                            'href="/#consent">'
                            'Back to consent demo'
                            '</a>'
                            '</div>'
                        ),
                    ),
                    "400 Bad Request",
                )


            if consent_user:

                CONSENT_DEMO_STATE.setdefault(
                    consent_user,
                    set(),
                ).update(
                    requested
                )


                CONSENT_LAST_TOKENS[
                    consent_user
                ] = {

                    "requested":
                        sorted(requested),

                    "scope_claim":
                        token_scope,

                    "claims": {
                        "preferred_username":
                            access_claims.get(
                                "preferred_username"
                            ),

                        "azp":
                            access_claims.get(
                                "azp"
                            ),

                        "aud":
                            access_claims.get(
                                "aud"
                            ),

                        "scope":
                            access_claims.get(
                                "scope"
                            ),
                    },
                }


            STATES.pop(
                state,
                None,
            )


            # Preserve the existing baseline Portal session.
            #
            # If this consent request was the user's first
            # interaction, establish a normal Portal session.
            if portal_session:

                start_response(
                    "302 Found",
                    [
                        (
                            "Location",
                            "/#consent",
                        ),
                        (
                            "Cache-Control",
                            "no-store",
                        ),
                    ],
                )

                return [b""]


            consent_sid = (
                secrets.token_urlsafe(24)
            )

            SESSIONS[
                consent_sid
            ] = tokens

            start_response(
                "302 Found",
                [
                    (
                        "Location",
                        "/#consent",
                    ),
                    (
                        "Set-Cookie",
                        (
                            f"sid={consent_sid}; "
                            "Path=/; "
                            "HttpOnly; "
                            "Secure; "
                            "SameSite=Lax"
                        ),
                    ),
                    (
                        "Cache-Control",
                        "no-store",
                    ),
                ],
            )

            return [b""]


'''

    s = s.replace(
        marker,
        code + marker,
        1,
    )


p.write_text(s)

print(f"Updated {p}")
PY


# ============================================================
# 5. Validate Python
# ============================================================

echo
echo "Checking Python syntax..."

python3 -m py_compile "$APP"

echo "Python syntax: OK"


# ============================================================
# 6. Update live Portal
# ============================================================

echo
echo "Updating Portal ConfigMap..."

oc -n "$NS" create configmap "$CONFIGMAP" \
  --from-file=app.py="$APP" \
  --dry-run=client \
  -o yaml |
oc apply -f -


echo
echo "Restarting Portal..."

oc -n "$NS" rollout restart \
  deployment/"$DEPLOYMENT"

oc -n "$NS" rollout status \
  deployment/"$DEPLOYMENT"


# ============================================================
# 7. Verify live code
# ============================================================

PORTAL_POD=$(
  oc -n "$NS" get pod \
    -l app=acme-portal \
    -o jsonpath='{.items[0].metadata.name}'
)

echo
echo "Live Portal:"
echo "  $PORTAL_POD"
echo

oc -n "$NS" exec "$PORTAL_POD" -- \
  grep -nE \
  'CONSENT_DEMO_STATE|consent-request|consent-authorize|consent-revoke|consent-granted' \
  /opt/app/app.py |
head -60


PORTAL="https://$(oc -n "$NS" get route acme-portal \
  -o jsonpath='{.spec.host}')"


echo
echo "======================================================"
echo " Granular Consent update complete"
echo "======================================================"
echo
echo "Portal:"
echo "  $PORTAL/#consent"
echo
echo
echo "Demo sequence:"
echo
echo "  1. Personal details"
echo "     ORANGE -> review requested data"
echo "     -> Grant requested access"
echo "     -> RHBK token must contain personal-details"
echo "     -> GREEN"
echo
echo "  2. Orders history"
echo "     ORANGE -> review requested data"
echo "     -> RHBK token must contain orders-history"
echo "     -> GREEN"
echo
echo "  3. Multiple scopes"
echo "     Requests:"
echo "       personal-details"
echo "       orders-history"
echo "       support-profile"
echo "     -> all must be present in RHBK token"
echo "     -> GREEN"
echo
echo "  4. Show consent token evidence"
echo "     -> demonstrates actual RHBK scope claim"
echo
echo "  5. Revoke"
echo "     -> selected demo grant returns to ORANGE"
echo
echo "  6. Reset demo status"
echo "     -> all consent indicators return to ORANGE"
echo
