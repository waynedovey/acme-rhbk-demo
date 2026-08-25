#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-rhbk}"
APP="${APP_FILE:-portal/app.py}"
DEPLOYMENT="${PORTAL_DEPLOYMENT:-acme-portal}"
CONFIGMAP="${PORTAL_CONFIGMAP:-acme-portal-code}"
SCRIPT_DIR="scripts"

[[ -f "$APP" ]] || {
  echo "ERROR: Cannot find $APP"
  echo "Run this from the acme-rhbk-demo repository root."
  exit 1
}

[[ -f "$SCRIPT_DIR/lib-kcadm.sh" ]] || {
  echo "ERROR: Cannot find $SCRIPT_DIR/lib-kcadm.sh"
  exit 1
}

BACKUP="${APP}.bak.$(date +%Y%m%d%H%M%S)"
cp "$APP" "$BACKUP"

echo
echo "Backup:"
echo "  $BACKUP"
echo


# ============================================================
# Replace dynamic-client-registration.sh
#
# The demo deliberately separates:
#
#   1. Platform administrator -> creates constrained IAT
#   2. Developer / automation -> uses ONLY the IAT
#
# The second registration attempt proves count=1 enforcement.
# ============================================================

cat > "$SCRIPT_DIR/dynamic-client-registration.sh" <<'DCR'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# shellcheck source=lib-kcadm.sh
source "$SCRIPT_DIR/lib-kcadm.sh"


command -v curl >/dev/null || {
  echo "curl is required" >&2
  exit 1
}

command -v jq >/dev/null || {
  echo "jq is required" >&2
  exit 1
}

command -v openssl >/dev/null || {
  echo "openssl is required" >&2
  exit 1
}


# ============================================================
# Platform-side authentication
#
# This is used ONLY to create the constrained Initial Access
# Token. It is NOT used for the developer registration call.
# ============================================================

acme_kcadm_login


KC_URL="https://$(oc -n "$ACME_NS" get route "$ACME_KC_NAME" \
  -o jsonpath='{.spec.host}')"

PORTAL_URL="https://$(oc -n "$ACME_NS" get route acme-portal \
  -o jsonpath='{.spec.host}')"

REGISTRATION_ENDPOINT="${KC_URL}/realms/acme-demo/clients-registrations/openid-connect"


# Existing Portal secret is used only to authenticate the
# sanitized demo-status callback to the Portal.
#
# It is NOT used for Dynamic Client Registration.
DEMO_KEY=$(
  acme_secret_value \
    acme-demo-secrets \
    portal-client-secret
)


TMPDIR_DEMO=$(mktemp -d)

trap 'rm -rf "$TMPDIR_DEMO"' EXIT


FIRST_BODY="$TMPDIR_DEMO/first.json"
SECOND_BODY="$TMPDIR_DEMO/second.json"
VERIFY_BODY="$TMPDIR_DEMO/verify.json"


IAT_EXPIRATION=600
IAT_COUNT=1


CLIENT_SUFFIX=$(date +%Y%m%d%H%M%S)

CLIENT_NAME="ACME Self-Service Demo App ${CLIENT_SUFFIX}"

SECOND_CLIENT_NAME="ACME Reuse Attempt ${CLIENT_SUFFIX}"

REDIRECT_URI="https://self-service-demo.example/callback"


echo
echo "======================================================"
echo " ACME API-driven onboarding demo"
echo "======================================================"
echo

echo "RHBK:"
echo "  $KC_URL"
echo

echo "Registration endpoint:"
echo "  $REGISTRATION_ENDPOINT"
echo


# ============================================================
# STEP 1
# Platform administrator creates constrained IAT
# ============================================================

echo "STEP 1 - Platform administrator control"
echo "---------------------------------------"
echo

echo "Creating Initial Access Token:"
echo

echo "  Lifetime:           ${IAT_EXPIRATION} seconds"
echo "  Registration count: ${IAT_COUNT}"
echo


IAT_JSON=$(
  acme_kcadm create \
    clients-initial-access \
    -r acme-demo \
    -s count="$IAT_COUNT" \
    -s expiration="$IAT_EXPIRATION" \
    -o
)


IAT=$(
  jq -r \
    '.token // empty' \
    <<<"$IAT_JSON"
)


if [[ -z "$IAT" ]]; then

  echo "ERROR: RHBK did not return an Initial Access Token" >&2

  echo "$IAT_JSON" |
    jq . >&2 ||
    true

  exit 1
fi


IAT_FINGERPRINT=$(
  printf '%s' "$IAT" |
    openssl dgst -sha256 |
    awk '{
      print substr($NF,1,16)
    }'
)


echo "Initial Access Token created."
echo

echo "Token value:"
echo "  <redacted>"

echo

echo "Token fingerprint:"
echo "  $IAT_FINGERPRINT"

echo


# ============================================================
# STEP 2
# Developer / automation uses ONLY Initial Access Token
# ============================================================

echo "STEP 2 - Developer / automation"
echo "-------------------------------"
echo

echo "Developer credential:"
echo "  Initial Access Token only"

echo

echo "Realm-admin credential:"
echo "  NOT used in this registration request"

echo

echo "Registering:"
echo "  $CLIENT_NAME"

echo


REQUEST=$(
  jq -n \
    --arg name "$CLIENT_NAME" \
    --arg redirect "$REDIRECT_URI" '
    {
      client_name: $name,

      redirect_uris: [
        $redirect
      ],

      grant_types: [
        "authorization_code"
      ],

      response_types: [
        "code"
      ],

      token_endpoint_auth_method:
        "client_secret_basic"
    }
  '
)


FIRST_HTTP=$(
  curl -skS \
    -o "$FIRST_BODY" \
    -w '%{http_code}' \
    -X POST \
    "$REGISTRATION_ENDPOINT" \
    -H "Authorization: Bearer $IAT" \
    -H 'Content-Type: application/json' \
    --data "$REQUEST"
)


if [[ ! "$FIRST_HTTP" =~ ^20[01]$ ]]; then

  echo
  echo "ERROR: Dynamic Client Registration failed."
  echo "HTTP: $FIRST_HTTP"
  echo

  cat "$FIRST_BODY"

  exit 1
fi


CLIENT_ID=$(
  jq -r \
    '.client_id // empty' \
    "$FIRST_BODY"
)


REGISTERED_NAME=$(
  jq -r \
    '.client_name // empty' \
    "$FIRST_BODY"
)


REGISTRATION_URI=$(
  jq -r \
    '.registration_client_uri // empty' \
    "$FIRST_BODY"
)


REGISTRATION_ACCESS_TOKEN=$(
  jq -r \
    '.registration_access_token // empty' \
    "$FIRST_BODY"
)


CLIENT_SECRET_ISSUED=$(
  jq -e '
    .client_secret != null
    and
    .client_secret != ""
  ' "$FIRST_BODY" >/dev/null &&
    echo true ||
    echo false
)


RAT_ISSUED=$(
  jq -e '
    .registration_access_token != null
    and
    .registration_access_token != ""
  ' "$FIRST_BODY" >/dev/null &&
    echo true ||
    echo false
)


if [[ -z "$CLIENT_ID" ]]; then

  echo
  echo "ERROR:"
  echo "Registration succeeded but RHBK returned no client_id."
  echo

  cat "$FIRST_BODY"

  exit 1
fi


echo
echo "Registration successful ✓"
echo

echo "  HTTP:"
echo "    $FIRST_HTTP"

echo

echo "  Client ID:"
echo "    $CLIENT_ID"

echo

echo "  Client name:"
echo "    ${REGISTERED_NAME:-$CLIENT_NAME}"

echo


# ============================================================
# STEP 3
# Verify client using registration management credential
#
# This is the credential RHBK returned to the newly registered
# client, not a realm-admin credential.
# ============================================================

echo "STEP 3 - Verify registered client"
echo "---------------------------------"
echo


REGISTRATION_VERIFIED=false


if [[ \
  -n "$REGISTRATION_URI" \
  && \
  -n "$REGISTRATION_ACCESS_TOKEN" \
]]; then


  VERIFY_HTTP=$(
    curl -skS \
      -o "$VERIFY_BODY" \
      -w '%{http_code}' \
      -H "Authorization: Bearer $REGISTRATION_ACCESS_TOKEN" \
      "$REGISTRATION_URI"
  )


  if [[ "$VERIFY_HTTP" == "200" ]]; then

    REGISTRATION_VERIFIED=true

    echo "Registration management GET:"
    echo "  HTTP 200 ✓"

  else

    echo "WARNING:"
    echo "Registration management GET returned:"
    echo "  HTTP $VERIFY_HTTP"

  fi

else

  echo "WARNING:"
  echo "Registration management URI/token was not returned."

fi


echo


# ============================================================
# STEP 4
# Reuse SAME IAT
#
# Because count=1 was consumed by the first registration,
# RHBK must reject the second registration.
# ============================================================

echo "STEP 4 - Prove one-use enforcement"
echo "----------------------------------"
echo

echo "Attempting a SECOND registration with the SAME IAT..."
echo


SECOND_REQUEST=$(
  jq -n \
    --arg name "$SECOND_CLIENT_NAME" \
    --arg redirect "$REDIRECT_URI" '
    {
      client_name: $name,

      redirect_uris: [
        $redirect
      ],

      grant_types: [
        "authorization_code"
      ],

      response_types: [
        "code"
      ],

      token_endpoint_auth_method:
        "client_secret_basic"
    }
  '
)


SECOND_HTTP=$(
  curl -skS \
    -o "$SECOND_BODY" \
    -w '%{http_code}' \
    -X POST \
    "$REGISTRATION_ENDPOINT" \
    -H "Authorization: Bearer $IAT" \
    -H 'Content-Type: application/json' \
    --data "$SECOND_REQUEST"
)


if [[ "$SECOND_HTTP" =~ ^2 ]]; then

  echo
  echo "ERROR:"
  echo "The one-use Initial Access Token was reused successfully."
  echo

  echo "Expected RHBK to reject the second registration."

  echo

  cat "$SECOND_BODY"

  exit 1
fi


SECOND_BLOCKED=true


echo "Second registration rejected ✓"
echo

echo "HTTP:"
echo "  $SECOND_HTTP"

echo

echo "The count=1 Initial Access Token cannot be reused."

echo


# ============================================================
# STEP 5
# Send SANITIZED proof to Portal
#
# Never send:
#
#   - Initial Access Token
#   - client secret
#   - registration access token
#   - admin credentials
# ============================================================

echo "STEP 5 - Update Portal evidence"
echo "-------------------------------"
echo


CREATED_AT=$(
  date -u \
    '+%Y-%m-%dT%H:%M:%SZ'
)


EVIDENCE=$(
  jq -n \
    --arg created_at "$CREATED_AT" \
    --arg client_id "$CLIENT_ID" \
    --arg client_name "${REGISTERED_NAME:-$CLIENT_NAME}" \
    --arg redirect "$REDIRECT_URI" \
    --arg registration_endpoint "$REGISTRATION_ENDPOINT" \
    --arg iat_fingerprint "$IAT_FINGERPRINT" \
    --arg second_http "$SECOND_HTTP" \
    --argjson rat_issued "$RAT_ISSUED" \
    --argjson secret_issued "$CLIENT_SECRET_ISSUED" \
    --argjson verified "$REGISTRATION_VERIFIED" '
    {
      status:
        "success",

      created_at:
        $created_at,

      client_id:
        $client_id,

      client_name:
        $client_name,

      redirect_uris: [
        $redirect
      ],

      grant_types: [
        "authorization_code"
      ],

      response_types: [
        "code"
      ],

      token_endpoint_auth_method:
        "client_secret_basic",

      iat_expiration_seconds:
        600,

      iat_count:
        1,

      iat_fingerprint:
        $iat_fingerprint,

      registration_endpoint:
        $registration_endpoint,

      registration_access_token_issued:
        $rat_issued,

      client_secret_issued:
        $secret_issued,

      registration_verified:
        $verified,

      second_registration_http_status:
        $second_http,

      second_registration_blocked:
        true
    }
  '
)


PORTAL_HTTP=$(
  curl -skS \
    -o /dev/null \
    -w '%{http_code}' \
    -X POST \
    "${PORTAL_URL}/api/demo/onboarding" \
    -H "X-ACME-Demo-Key: ${DEMO_KEY}" \
    -H 'Content-Type: application/json' \
    --data "$EVIDENCE"
)


if [[ "$PORTAL_HTTP" != "200" ]]; then

  echo "WARNING:"
  echo "Client registration succeeded but Portal status callback"
  echo "returned HTTP $PORTAL_HTTP."

else

  echo "Portal status updated ✓"

fi


echo
echo "======================================================"
echo " API-driven onboarding SUCCESS"
echo "======================================================"
echo

echo "Registered client:"
echo "  $CLIENT_ID"

echo

echo "Initial Access Token policy:"
echo "  Lifetime: 600 seconds"
echo "  Count:    1 registration"

echo

echo "Developer registration:"
echo "  Initial Access Token only ✓"

echo

echo "Registration verification:"
if [[ "$REGISTRATION_VERIFIED" == "true" ]]; then
  echo "  Verified ✓"
else
  echo "  Not verified by registration management GET"
fi

echo

echo "Second registration with same token:"
echo "  HTTP $SECOND_HTTP - BLOCKED ✓"

echo

echo "Portal evidence:"
echo "  ${PORTAL_URL}/#onboarding"

echo

echo "Sensitive values deliberately NOT displayed:"
echo "  Initial Access Token"
echo "  Client secret"
echo "  Registration access token"

echo
DCR


chmod +x \
  "$SCRIPT_DIR/dynamic-client-registration.sh"


# ============================================================
# Update Portal
# ============================================================

python3 - "$APP" <<'PY'
from pathlib import Path
import re
import sys


p = Path(sys.argv[1])

s = p.read_text()


# ============================================================
# 1. API onboarding demo state
# ============================================================

if "ONBOARDING_DEMO_STATE = {}" not in s:

    anchor = next(
        (
            x
            for x in [
                "TOKEN_EXCHANGE_EVIDENCE = {}",
                "CONSENT_LAST_TOKENS = {}",
                "PASSKEY_DEMO_STATE = {}",
                "BROKER_AUTH_STATE = {}",
                "STATES = {}",
            ]
            if x in s
        ),
        None,
    )


    if not anchor:

        raise SystemExit(
            "ERROR: Could not find state insertion point"
        )


    s = s.replace(
        anchor,
        anchor + '''

# ------------------------------------------------------------
# API-driven onboarding demo state
#
# The real RHBK client registration is performed by the CLI.
#
# The Portal stores sanitized evidence only.
# ------------------------------------------------------------

ONBOARDING_DEMO_STATE = {}

''',
        1,
    )


# ============================================================
# 2. UI styles
# ============================================================

if ".onboarding-complete" not in s:

    css = '''

.onboarding-demo-row{{
  display:flex;
  align-items:center;
  flex-wrap:wrap;
  gap:8px;
  margin:10px 0;
}}

a.button.onboarding-pending{{
  background:#ec7a08;
  color:#fff;
  min-width:270px;
}}

a.button.onboarding-complete{{
  background:#3e8635;
  color:#fff;
  min-width:270px;
}}

.onboarding-proof{{
  border:1px solid #d2d2d2;
  border-left:5px solid #3e8635;
  border-radius:7px;
  padding:14px;
  margin:12px 0;
  background:#fff;
}}

'''


    marker = "@media(max-width:720px)"


    if marker not in s:

        raise SystemExit(
            "ERROR: Could not find CSS insertion point"
        )


    s = s.replace(
        marker,
        css + marker,
        1,
    )


# ============================================================
# 3. Dashboard status
# ============================================================

if "onboarding_demo = dict(" not in s:

    marker = "    ps_focus = None\n"


    block = """    # ------------------------------------------------
    # API-driven onboarding status
    # ------------------------------------------------

    onboarding_demo = dict(
        ONBOARDING_DEMO_STATE
    )


    onboarding_complete = (
        onboarding_demo.get(
            "status"
        ) == "success"

        and bool(
            onboarding_demo.get(
                "client_id"
            )
        )

        and onboarding_demo.get(
            "second_registration_blocked"
        ) is True
    )


    if onboarding_complete:

        onboarding_status = f'''
        <div class="status ok">

          <strong>
            Controlled client registration successful ✓
          </strong>

          <br>

          Registered client:

          <code>
            {esc(onboarding_demo.get("client_id"))}
          </code>

          <br>

          Initial Access Token:

          <strong>
            {esc(onboarding_demo.get("iat_count"))} use /
            {esc(onboarding_demo.get("iat_expiration_seconds"))}
            seconds
          </strong>

          <br>

          Second registration attempt:

          <strong>
            blocked ✓
          </strong>

        </div>
        '''


        onboarding_action = '''
        <a class="button onboarding-complete"
           href="/onboarding-evidence">

          Client registered — Verified ✓

        </a>
        '''


    else:

        onboarding_status = '''
        <div class="status wait">

          API-driven client onboarding has not yet been
          demonstrated.

        </div>
        '''


        onboarding_action = '''
        <a class="button onboarding-pending"
           href="/onboarding-howto">

          Run controlled client onboarding

        </a>
        '''


"""


    if marker not in s:

        raise SystemExit(
            "ERROR: Could not find dashboard insertion point"
        )


    s = s.replace(
        marker,
        block + marker,
        1,
    )


# ============================================================
# 4. Replace Section 7
# ============================================================

card = '''<div id="onboarding" class="card">

<div class="kicker">

  <span class="step">7</span>

  API-driven onboarding

</div>


<h3>
Controlled self-service client registration
</h3>


<p>

Use a short-lived, count-limited Initial Access Token to
register an application without giving developers realm-admin
access.

</p>


{onboarding_status}


<div class="onboarding-demo-row">

{onboarding_action}

</div>


<pre>./scripts/dynamic-client-registration.sh</pre>


<p class="tiny">

<strong>Demo controls:</strong>

the platform step mints a 10-minute, one-use Initial Access
Token. The developer registration request uses only that token.

The script then reuses the same token and proves the second
registration is rejected.

</p>


{(
    '<a class="button outline" '
    'href="/onboarding-evidence">'
    'View registration evidence'
    '</a>'
    if onboarding_complete
    else ''
)}


<a class="button outline"
   href="/onboarding-reset">

  Reset demo status

</a>


</div>
'''


pattern = re.compile(
    r'<div id="onboarding" class="card">'
    r'.*?'
    r'(?=<div id="fapi" class="card">)',
    re.S,
)


if not pattern.search(s):

    raise SystemExit(
        "ERROR: Could not locate Section 7 onboarding card"
    )


s = pattern.sub(
    lambda _:
        card,
    s,
    count=1,
)


# ============================================================
# 5. Portal API + evidence routes
# ============================================================

if 'if path == "/api/demo/onboarding":' not in s:

    marker = '    if path == "/login":\n'


    routes = """    # ==================================================
    # API-DRIVEN CLIENT ONBOARDING
    # ==================================================

    if path == "/api/demo/onboarding":

        if environ.get(
            "REQUEST_METHOD",
            "GET",
        ).upper() != "POST":

            return response(
                start_response,
                "Method not allowed",
                "405 Method Not Allowed",
            )


        # The CLI callback uses the existing Portal client
        # secret only to authenticate this demo-status update.
        #
        # No RHBK admin credential or IAT is posted here.

        supplied_key = environ.get(
            "HTTP_X_ACME_DEMO_KEY",
            "",
        )


        if (
            not CLIENT_SECRET
            or not supplied_key
            or not secrets.compare_digest(
                supplied_key,
                CLIENT_SECRET,
            )
        ):

            return response(
                start_response,
                "Forbidden",
                "403 Forbidden",
            )


        try:

            length = int(
                environ.get(
                    "CONTENT_LENGTH"
                )
                or "0"
            )


            raw = environ[
                "wsgi.input"
            ].read(
                length
            )


            payload = json.loads(
                raw.decode(
                    "utf-8"
                )
            )


        except Exception as exc:

            return response(
                start_response,
                "Invalid JSON: "
                + esc(exc),
                "400 Bad Request",
            )


        if (
            payload.get(
                "status"
            ) != "success"

            or not payload.get(
                "client_id"
            )

            or payload.get(
                "second_registration_blocked"
            ) is not True
        ):

            return response(
                start_response,
                "Invalid onboarding evidence",
                "400 Bad Request",
            )


        # Only sanitized evidence is accepted.

        allowed = {

            "status",

            "created_at",

            "client_id",

            "client_name",

            "redirect_uris",

            "grant_types",

            "response_types",

            "token_endpoint_auth_method",

            "iat_expiration_seconds",

            "iat_count",

            "iat_fingerprint",

            "registration_endpoint",

            "registration_access_token_issued",

            "client_secret_issued",

            "registration_verified",

            "second_registration_http_status",

            "second_registration_blocked",
        }


        ONBOARDING_DEMO_STATE.clear()


        ONBOARDING_DEMO_STATE.update({

            key: value

            for key, value
            in payload.items()

            if key in allowed
        })


        return response(
            start_response,
            "Onboarding evidence recorded",
        )



    if path == "/onboarding-howto":

        body = '''
        <section class="hero">

          <div class="kicker">
            API-driven onboarding
          </div>


          <h1>
            Controlled self-service client registration
          </h1>


          <p class="lead">

            RHBK can delegate client creation with an Initial
            Access Token instead of giving a developer
            realm-admin access.

          </p>

        </section>


        <div class="card">

          <h2>
            Run the demo
          </h2>


          <pre>./scripts/dynamic-client-registration.sh</pre>


          <ol>

            <li>

              <strong>
                Platform administrator:
              </strong>

              creates a 10-minute Initial Access Token with a
              maximum registration count of one.

            </li>


            <li>

              <strong>
                Developer / automation:
              </strong>

              calls the OIDC Dynamic Client Registration
              endpoint using only that Initial Access Token.

            </li>

          </ol>


          <p>

            The script deliberately attempts a second client
            registration with the same token.

            That request must fail, proving the count limit is
            enforced.

          </p>


          <a class="button secondary"
             href="/#onboarding">

            Back to demo

          </a>

        </div>
        '''


        return response(
            start_response,
            layout(
                "API-driven onboarding",
                body,
            ),
        )



    if path == "/onboarding-evidence":

        evidence = dict(
            ONBOARDING_DEMO_STATE
        )


        if evidence.get(
            "status"
        ) != "success":

            return response(
                start_response,
                layout(
                    "Onboarding evidence",
                    '''
                    <div class="card">

                      <h2>
                        No onboarding evidence yet
                      </h2>


                      <p>

                        Run the dynamic client registration
                        script first.

                      </p>


                      <pre>./scripts/dynamic-client-registration.sh</pre>


                      <a class="button"
                         href="/#onboarding">

                        Back

                      </a>

                    </div>
                    ''',
                ),
            )


        body = f'''
        <section class="hero">

          <div class="kicker">

            Dynamic Client Registration evidence

          </div>


          <h1>

            Application onboarded without realm-admin access

          </h1>


          <p class="lead">

            The developer-side registration request used a
            short-lived Initial Access Token rather than an
            administrator credential.

          </p>


          <div class="status ok">

            <strong>
              Client registration successful ✓
            </strong>

            <br>

            Client:

            <code>
              {esc(evidence.get("client_id"))}
            </code>

            <br>

            One-use Initial Access Token consumed ✓

            <br>

            Second registration blocked ✓

          </div>

        </section>


        <div class="onboarding-proof">

          <h2>
            Registration evidence
          </h2>


          <pre>
{esc(json.dumps(evidence, indent=2, sort_keys=True))}
          </pre>

        </div>


        <div class="card">

          <h2>
            What this proves
          </h2>


          <ul>

            <li>

              Registration used the OIDC Dynamic Client
              Registration API.

            </li>


            <li>

              The Initial Access Token lifetime was
              600 seconds.

            </li>


            <li>

              The registration count was limited to one.

            </li>


            <li>

              Reusing the same token for a second registration
              was rejected.

            </li>


            <li>

              No administrator token, client secret or
              registration access token is displayed here.

            </li>

          </ul>


          <a class="button secondary"
             href="/#onboarding">

            Back to demo

          </a>

        </div>
        '''


        return response(
            start_response,
            layout(
                "Client onboarding evidence",
                body,
            ),
        )



    if path == "/onboarding-reset":

        # Portal demo state only.
        #
        # The real dynamically registered RHBK client remains
        # in the realm as evidence that registration occurred.

        ONBOARDING_DEMO_STATE.clear()


        start_response(
            "302 Found",
            [
                (
                    "Location",
                    "/#onboarding",
                ),

                (
                    "Cache-Control",
                    "no-store",
                ),
            ],
        )


        return [b""]



"""


    if marker not in s:

        raise SystemExit(
            "ERROR: Could not find /login route"
        )


    s = s.replace(
        marker,
        routes + marker,
        1,
    )


p.write_text(s)

print(
    f"Updated {p}"
)
PY


# ============================================================
# Validate
# ============================================================

echo "Checking syntax..."

python3 -m py_compile \
  "$APP"

bash -n \
  "$SCRIPT_DIR/dynamic-client-registration.sh"

echo "Syntax: OK"


# ============================================================
# Deploy Portal update
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


PORTAL_POD=$(
  oc -n "$NS" get pod \
    -l app=acme-portal \
    -o jsonpath='{.items[0].metadata.name}'
)


PORTAL="https://$(oc -n "$NS" get route acme-portal \
  -o jsonpath='{.spec.host}')"


echo
echo "Live Portal code check:"


oc -n "$NS" exec "$PORTAL_POD" -- \
  grep -nE \
  'ONBOARDING_DEMO_STATE|api/demo/onboarding|onboarding-evidence|onboarding-complete' \
  /opt/app/app.py |
head -60


echo
echo "======================================================"
echo " API-driven onboarding Portal update complete"
echo "======================================================"
echo

echo "Portal:"
echo "  $PORTAL/#onboarding"

echo

echo "Now run:"
echo "  ./scripts/dynamic-client-registration.sh"

echo

echo "Expected result:"
echo "  - 10-minute / one-use IAT created"
echo "  - client registered using IAT only"
echo "  - registration verified"
echo "  - second registration with same IAT blocked"
echo "  - Portal section turns GREEN"

echo
