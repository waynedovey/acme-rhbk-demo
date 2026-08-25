#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-rhbk}"
APP="${APP_FILE:-portal/app.py}"
DEPLOYMENT="${PORTAL_DEPLOYMENT:-acme-portal}"
CONFIGMAP="${PORTAL_CONFIGMAP:-acme-portal-code}"
SCRIPT_DIR="scripts"

[[ -f "$APP" ]] || {
  echo "ERROR: Cannot find $APP"
  echo "Run from the acme-rhbk-demo repository root."
  exit 1
}

BACKUP="${APP}.bak.$(date +%Y%m%d%H%M%S)"
cp "$APP" "$BACKUP"

echo
echo "Backup:"
echo "  $BACKUP"
echo


# ============================================================
# Create FAPI 2 configuration / verification script
# ============================================================

cat > "$SCRIPT_DIR/configure-fapi2.sh" <<'FAPI'
#!/usr/bin/env bash
set -euo pipefail


# ============================================================
# Configuration
# ============================================================

NS="${NAMESPACE:-rhbk}"

POD="${KEYCLOAK_POD:-acme-keycloak-0}"

KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/kcadm.config

REALM="acme-demo"

CLIENT_ID="high-assurance-api"

POLICY_NAME="acme-fapi2-high-assurance"

MARKER_ROLE="fapi2-high-assurance-marker"

ACTIVE_PROFILE="fapi-2-security-profile"


# ============================================================
# Requirements
# ============================================================

for cmd in oc jq curl; do

  command -v "$cmd" >/dev/null || {
    echo "ERROR: $cmd is required" >&2
    exit 1
  }

done


# ============================================================
# kcadm helpers
# ============================================================

ADMIN_USER=$(
  oc -n "$NS" get secret \
    acme-keycloak-initial-admin \
    -o jsonpath='{.data.username}' |
  base64 -d
)


ADMIN_PASS=$(
  oc -n "$NS" get secret \
    acme-keycloak-initial-admin \
    -o jsonpath='{.data.password}' |
  base64 -d
)


echo
echo "Logging into RHBK..."

oc -n "$NS" exec "$POD" -- \
  "$KCADM" config credentials \
  --config "$CFG" \
  --server http://localhost:8080 \
  --realm master \
  --user "$ADMIN_USER" \
  --password "$ADMIN_PASS"


kc() {

  oc -n "$NS" exec "$POD" -- \
    "$KCADM" "$@" \
    --config "$CFG"

}


kci() {

  oc -n "$NS" exec -i "$POD" -- \
    "$KCADM" "$@" \
    --config "$CFG"

}


KC_PUBLIC="https://$(oc -n "$NS" get route acme-keycloak \
  -o jsonpath='{.spec.host}')"


PORTAL_URL="https://$(oc -n "$NS" get route acme-portal \
  -o jsonpath='{.spec.host}')"


DEMO_KEY=$(
  oc -n "$NS" get secret \
    acme-demo-secrets \
    -o jsonpath='{.data.portal-client-secret}' |
  base64 -d
)


echo
echo "======================================================"
echo " ACME FAPI 2.0 High-Assurance OAuth Demo"
echo "======================================================"
echo

echo "Realm:"
echo "  $REALM"
echo

echo "Demo client:"
echo "  $CLIENT_ID"
echo

echo "Client policy:"
echo "  $POLICY_NAME"
echo

echo "Applied FAPI profile:"
echo "  $ACTIVE_PROFILE"
echo


# ============================================================
# STEP 1
# Verify RHBK built-in FAPI 2 profiles
# ============================================================

echo "STEP 1 - Verify built-in FAPI 2 profiles"
echo "----------------------------------------"
echo


PROFILES=$(
  kc get \
    client-policies/profiles \
    -r "$REALM" \
    -q include-global-profiles=true
)


echo "$PROFILES" > /tmp/acme-fapi-profiles.json


FAPI_PROFILES=$(
  echo "$PROFILES" |
  jq '
    [
      (.globalProfiles // [])[]
      |
      select(
        .name
        |
        startswith("fapi-2")
      )
    ]
  '
)


echo "RHBK global FAPI 2 profiles:"
echo

echo "$FAPI_PROFILES" |
jq -r '
  .[]
  |
  "  ✓ " + .name
'


echo


for REQUIRED in \
  fapi-2-security-profile \
  fapi-2-message-signing \
  fapi-2-dpop-security-profile \
  fapi-2-dpop-message-signing

do

  if ! echo "$FAPI_PROFILES" |
       jq -e \
       --arg name "$REQUIRED" \
       'any(.[]; .name == $name)' \
       >/dev/null
  then

    echo "ERROR:"
    echo "Required global profile missing:"
    echo
    echo "  $REQUIRED"
    echo

    exit 1

  fi

done


echo
echo "All four built-in FAPI 2 profiles present ✓"
echo


# ============================================================
# Display actual executors from RHBK
#
# We do NOT hardcode what the profile enforces.
# We ask this running RHBK instance.
# ============================================================

echo "Executors in:"
echo "  $ACTIVE_PROFILE"
echo


SECURITY_PROFILE=$(
  echo "$FAPI_PROFILES" |
  jq -c \
    --arg name "$ACTIVE_PROFILE" '
      first(
        .[]
        |
        select(
          .name == $name
        )
      )
    '
)


echo "$SECURITY_PROFILE" |
jq -r '
  (.executors // [])[]
  |
  "  ✓ " + (.executor // "unknown")
'


echo


# ============================================================
# STEP 2
# Ensure high-assurance-api exists
# ============================================================

echo "STEP 2 - Configure high-assurance API client"
echo "--------------------------------------------"
echo


CLIENT_UUID=$(
  kc get clients \
    -r "$REALM" \
    -q clientId="$CLIENT_ID" |
  jq -r '.[0].id // empty'
)


if [[ -z "$CLIENT_UUID" ]]; then

  echo "Creating:"
  echo "  $CLIENT_ID"
  echo


  jq -n '
    {
      clientId:
        "high-assurance-api",

      name:
        "ACME High Assurance API",

      description:
        "Demo API protected by an RHBK FAPI 2 client policy",

      enabled:
        true,

      protocol:
        "openid-connect",

      publicClient:
        false,

      standardFlowEnabled:
        true,

      directAccessGrantsEnabled:
        false,

      serviceAccountsEnabled:
        false,

      implicitFlowEnabled:
        false,

      redirectUris: [
        "https://high-assurance-api.acme.example/callback"
      ],

      webOrigins: [
        "https://high-assurance-api.acme.example"
      ]
    }
  ' |
  kci create clients \
    -r "$REALM" \
    -f - \
    >/dev/null


  CLIENT_UUID=$(
    kc get clients \
      -r "$REALM" \
      -q clientId="$CLIENT_ID" |
    jq -r '.[0].id // empty'
  )


else

  echo "Client already exists ✓"

fi


if [[ -z "$CLIENT_UUID" ]]; then

  echo "ERROR:"
  echo "Unable to locate $CLIENT_ID"
  exit 1

fi


echo "Client UUID:"
echo "  $CLIENT_UUID"
echo


# ============================================================
# STEP 3
# Add marker role to target ONLY this client
#
# Red Hat recommends a Client Role condition as a good way
# to select specific clients for a Client Policy.
# ============================================================

echo "STEP 3 - Mark client for FAPI 2 policy"
echo "--------------------------------------"
echo


if kc get \
    "clients/$CLIENT_UUID/roles/$MARKER_ROLE" \
    -r "$REALM" \
    >/dev/null 2>&1
then

  echo "Marker role already exists ✓"

else

  echo "Creating marker role:"
  echo "  $MARKER_ROLE"
  echo


  jq -n \
    --arg role "$MARKER_ROLE" '
    {
      name: $role,

      description:
        "Marker role selecting this client for the ACME FAPI 2 client policy"
    }
  ' |
  kci create \
    "clients/'"$CLIENT_UUID"'/roles" \
    -r "$REALM" \
    -f - \
    >/dev/null


  echo "Marker role created ✓"

fi


echo


# ============================================================
# STEP 4
# Create/update realm Client Policy
#
# This associates:
#
#   client role condition
#            +
#   fapi-2-security-profile
#
# We preserve all unrelated existing policies.
# ============================================================

echo "STEP 4 - Apply FAPI 2 Client Policy"
echo "-----------------------------------"
echo


CURRENT_POLICIES=$(
  kc get \
    client-policies/policies \
    -r "$REALM"
)


POLICY=$(
  jq -n \
    --arg name "$POLICY_NAME" \
    --arg role "$MARKER_ROLE" \
    --arg profile "$ACTIVE_PROFILE" '
    {
      name:
        $name,

      description:
        "Apply the RHBK FAPI 2.0 Security Profile Final to ACME high-assurance clients",

      enabled:
        true,

      conditions: [
        {
          condition:
            "client-roles",

          configuration: {
            "is-negative-logic":
              false,

            roles: [
              $role
            ]
          }
        }
      ],

      profiles: [
        $profile
      ]
    }
  '
)


UPDATED_POLICIES=$(
  echo "$CURRENT_POLICIES" |
  jq \
    --arg name "$POLICY_NAME" \
    --argjson policy "$POLICY" '

      .policies = (

        (
          .policies
          // []
        )

        |

        map(
          select(
            .name != $name
          )
        )

        +

        [
          $policy
        ]
      )

      |

      del(
        .globalPolicies
      )

    '
)


printf '%s\n' "$UPDATED_POLICIES" |
kci update \
  client-policies/policies \
  -r "$REALM" \
  -f - \
  >/dev/null


echo "Client Policy applied ✓"
echo


# ============================================================
# STEP 5
# Verify configuration by reading it back from RHBK
# ============================================================

echo "STEP 5 - Verify FAPI policy"
echo "---------------------------"
echo


VERIFIED_POLICIES=$(
  kc get \
    client-policies/policies \
    -r "$REALM"
)


VERIFIED_POLICY=$(
  echo "$VERIFIED_POLICIES" |
  jq -c \
    --arg name "$POLICY_NAME" '
      first(
        (.policies // [])[]
        |
        select(
          .name == $name
        )
      )
    '
)


if [[ \
  -z "$VERIFIED_POLICY" \
  || \
  "$VERIFIED_POLICY" == "null" \
 ]]; then

  echo "ERROR:"
  echo "FAPI Client Policy was not found after update."

  exit 1

fi


if ! echo "$VERIFIED_POLICY" |
     jq -e \
       --arg profile "$ACTIVE_PROFILE" '
       .enabled == true
       and
       (
         .profiles
         |
         index($profile)
       ) != null
     ' \
     >/dev/null
then

  echo "ERROR:"
  echo "FAPI policy is not correctly enabled."

  echo "$VERIFIED_POLICY" |
    jq .

  exit 1

fi


if ! kc get \
    "clients/$CLIENT_UUID/roles/$MARKER_ROLE" \
    -r "$REALM" \
    >/dev/null
then

  echo "ERROR:"
  echo "FAPI marker role cannot be verified."

  exit 1

fi


echo "Policy:"
echo "$VERIFIED_POLICY" |
jq .


echo
echo "Policy verification successful ✓"
echo


# ============================================================
# STEP 6
# Build SANITIZED Portal evidence
#
# No client secret or admin token is sent to the Portal.
# ============================================================

echo "STEP 6 - Update Portal status"
echo "-----------------------------"
echo


PROFILE_NAMES=$(
  echo "$FAPI_PROFILES" |
  jq '[.[].name]'
)


PROFILE_EXECUTORS=$(
  echo "$SECURITY_PROFILE" |
  jq '
    [
      (.executors // [])[]
      |
      (.executor // "unknown")
    ]
  '
)


POLICY_CONDITIONS=$(
  echo "$VERIFIED_POLICY" |
  jq '.conditions // []'
)


EVIDENCE=$(
  jq -n \
    --arg client_id "$CLIENT_ID" \
    --arg policy "$POLICY_NAME" \
    --arg marker "$MARKER_ROLE" \
    --arg active "$ACTIVE_PROFILE" \
    --arg rhbk_version "26.6" \
    --argjson profiles "$PROFILE_NAMES" \
    --argjson executors "$PROFILE_EXECUTORS" \
    --argjson conditions "$POLICY_CONDITIONS" '
    {
      status:
        "success",

      client_id:
        $client_id,

      rhbk_version:
        $rhbk_version,

      policy_name:
        $policy,

      policy_enabled:
        true,

      marker_role:
        $marker,

      active_profile:
        $active,

      fapi2_specification:
        "FAPI 2.0 Security Profile Final",

      global_profiles:
        $profiles,

      active_profile_executors:
        $executors,

      policy_conditions:
        $conditions,

      client_secret_exposed:
        false,

      admin_credential_exposed:
        false
    }
  '
)


PORTAL_HTTP=$(
  curl -skS \
    -o /dev/null \
    -w '%{http_code}' \
    -X POST \
    "${PORTAL_URL}/api/demo/fapi2" \
    -H "X-ACME-Demo-Key: ${DEMO_KEY}" \
    -H 'Content-Type: application/json' \
    --data "$EVIDENCE"
)


if [[ "$PORTAL_HTTP" != "200" ]]; then

  echo "ERROR:"
  echo "RHBK policy is configured but Portal callback returned:"
  echo
  echo "  HTTP $PORTAL_HTTP"

  exit 1

fi


echo "Portal status updated ✓"
echo


# ============================================================
# Result
# ============================================================

echo "======================================================"
echo " FAPI 2.0 POLICY CONFIGURED SUCCESSFULLY"
echo "======================================================"
echo

echo "Demo client:"
echo "  $CLIENT_ID"
echo

echo "Client Policy:"
echo "  $POLICY_NAME"
echo

echo "Applied profile:"
echo "  $ACTIVE_PROFILE"
echo

echo "Specification:"
echo "  FAPI 2.0 Security Profile Final"
echo

echo "Available RHBK FAPI 2 profiles:"
echo

echo "$PROFILE_NAMES" |
jq -r '.[] | "  ✓ " + .'

echo

echo "Policy selection:"
echo "  Client Role:"
echo "  $MARKER_ROLE"
echo

echo "Portal:"
echo "  ${PORTAL_URL}/#fapi"
echo

echo "Admin Console:"
echo "  ${KC_PUBLIC}/admin/"
echo

echo "RHBK navigation:"
echo "  Realm Settings"
echo "    -> Client Policies"
echo "       -> Profiles"
echo "       -> Policies"
echo
FAPI


chmod +x \
  "$SCRIPT_DIR/configure-fapi2.sh"


# ============================================================
# Patch Portal
# ============================================================

python3 - "$APP" <<'PY'
from pathlib import Path
import re
import sys


p = Path(sys.argv[1])

s = p.read_text()


# ============================================================
# State
# ============================================================

if "FAPI2_DEMO_STATE = {}" not in s:

    anchor = next(
        (
            value
            for value in [
                "WORKLOAD_DEMO_STATE = {}",
                "ONBOARDING_DEMO_STATE = {}",
                "TOKEN_EXCHANGE_EVIDENCE = {}",
                "CONSENT_LAST_TOKENS = {}",
                "PASSKEY_DEMO_STATE = {}",
                "BROKER_AUTH_STATE = {}",
                "STATES = {}",
            ]
            if value in s
        ),
        None,
    )


    if not anchor:

        raise SystemExit(
            "ERROR: Could not find Portal state anchor"
        )


    s = s.replace(
        anchor,
        anchor + '''

# ------------------------------------------------------------
# FAPI 2.0 demo state
#
# Contains sanitized verification data from RHBK only.
# ------------------------------------------------------------

FAPI2_DEMO_STATE = {}

''',
        1,
    )


# ============================================================
# CSS
# ============================================================

if ".fapi-complete" not in s:

    css = '''

.fapi-demo-row{{
  display:flex;
  align-items:center;
  flex-wrap:wrap;
  gap:8px;
  margin:10px 0;
}}

a.button.fapi-pending{{
  background:#ec7a08;
  color:#fff;
  min-width:280px;
}}

a.button.fapi-complete{{
  background:#3e8635;
  color:#fff;
  min-width:280px;
}}

.fapi-profile-grid{{
  display:grid;
  grid-template-columns:
    repeat(auto-fit,minmax(250px,1fr));
  gap:8px;
  margin:14px 0;
}}

.fapi-profile{{
  border:1px solid #d2d2d2;
  border-radius:6px;
  padding:10px 12px;
  font-family:monospace;
  font-size:12px;
  background:#f5f5f5;
}}

.fapi-profile.active{{
  border-left:5px solid #3e8635;
  background:#f2faf0;
}}

.fapi-evidence{{
  border:1px solid #d2d2d2;
  border-left:5px solid #3e8635;
  border-radius:7px;
  padding:14px;
  margin:14px 0;
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
# Dashboard state
# ============================================================

if "fapi2_demo = dict(" not in s:

    marker = "    ps_focus = None\n"


    block = """    # ------------------------------------------------
    # FAPI 2.0 status
    # ------------------------------------------------

    fapi2_demo = dict(
        FAPI2_DEMO_STATE
    )


    fapi2_complete = (

        fapi2_demo.get(
            "status"
        )
        == "success"

        and
        fapi2_demo.get(
            "client_id"
        )
        == "high-assurance-api"

        and
        fapi2_demo.get(
            "policy_enabled"
        )
        is True

        and
        fapi2_demo.get(
            "active_profile"
        )
        == "fapi-2-security-profile"
    )


    if fapi2_complete:

        fapi2_status = f'''
        <div class="status ok">

          <strong>
            FAPI 2.0 high-assurance policy configured ✓
          </strong>

          <br>

          Demo client:

          <code>
            {esc(fapi2_demo.get("client_id"))}
          </code>

          <br>

          Client Policy:

          <strong>
            {esc(fapi2_demo.get("policy_name"))}
          </strong>

          <br>

          Active profile:

          <strong>
            {esc(fapi2_demo.get("active_profile"))}
          </strong>

          <br>

          Specification:

          <strong>
            FAPI 2.0 Security Profile Final
          </strong>

        </div>
        '''


        fapi2_action = '''
        <a class="button fapi-complete"
           href="/fapi2-evidence">

          FAPI 2 policy — Configured ✓

        </a>
        '''


    else:

        fapi2_status = '''
        <div class="status wait">

          FAPI 2.0 policy has not yet been demonstrated.

        </div>
        '''


        fapi2_action = '''
        <a class="button fapi-pending"
           href="/fapi2-howto">

          Configure FAPI 2 policy

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
# Replace Section 8 card
# ============================================================

card = '''<div id="fapi" class="card primary">

<div class="kicker">

  <span class="step">8</span>

  FAPI 2.0

</div>


<h3>
High-assurance OAuth/OIDC policy
</h3>


<p>

Show RHBK's built-in FAPI 2 client profiles and apply the
FAPI 2.0 Security Profile to APIs requiring tighter OAuth
controls.

</p>


{fapi2_status}


<div class="fapi-demo-row">

{fapi2_action}

</div>


<h4>
Built-in RHBK FAPI 2 profiles
</h4>


<div class="fapi-profile-grid">

  <div class="fapi-profile active">
    fapi-2-security-profile
  </div>

  <div class="fapi-profile">
    fapi-2-message-signing
  </div>

  <div class="fapi-profile">
    fapi-2-dpop-security-profile
  </div>

  <div class="fapi-profile">
    fapi-2-dpop-message-signing
  </div>

</div>


<p class="tiny">

<strong>Demo client:</strong>
<code>high-assurance-api</code>

<br>

<strong>Applied profile:</strong>
<code>fapi-2-security-profile</code>

<br>

The other built-in profiles demonstrate Message Signing
and DPoP-based FAPI 2 deployment options.

</p>


<pre>./scripts/configure-fapi2.sh</pre>


<a class="button"
   href="{esc(KEYCLOAK_URL)}/admin/">

  Open RHBK Admin Console

</a>


{(
    '<a class="button outline" '
    'href="/fapi2-evidence">'
    'View FAPI policy evidence'
    '</a>'
    if fapi2_complete
    else ''
)}


<a class="button outline"
   href="/fapi2-reset">

  Reset demo status

</a>


</div>
'''


pattern = re.compile(
    r'<div id="fapi" class="card[^"]*">'
    r'.*'
    r'</div>'
    r'(?=\s*</section>)',
    re.S,
)


if not pattern.search(s):

    raise SystemExit(
        "ERROR: Could not locate Section 8 FAPI card"
    )


s = pattern.sub(
    lambda _:
        card,
    s,
    count=1,
)


# ============================================================
# Routes
# ============================================================

if 'if path == "/api/demo/fapi2":' not in s:

    # ------------------------------------------------
    # Dynamically locate the first route inside def app().
    #
    # The Portal now has many demo routes, so /login is no
    # longer a safe insertion anchor.
    # ------------------------------------------------

    app_match = re.search(
        r'(?m)^def app\([^)]*\):\s*$',
        s,
    )

    if not app_match:

        raise SystemExit(
            "ERROR: Could not locate def app() "
            "inside portal/app.py"
        )


    app_text = s[
        app_match.end():
    ]


    route_match = re.search(
        r'(?m)^    if path(?:\s*==|\s+in\b).*?:\s*$',
        app_text,
    )


    if not route_match:

        raise SystemExit(
            "ERROR: Could not locate any "
            "'if path ...' route inside def app()"
        )


    marker = (
        route_match.group(0)
        + "\n"
    )


    print(
        "FAPI routes will be inserted before:"
    )

    print(
        "  "
        + route_match.group(0).strip()
    )


    routes = '''    # ==================================================
    # FAPI 2.0
    # ==================================================

    if path == "/api/demo/fapi2":

        if environ.get(
            "REQUEST_METHOD",
            "GET",
        ).upper() != "POST":

            return response(
                start_response,
                "Method not allowed",
                "405 Method Not Allowed",
            )


        supplied_key = environ.get(
            "HTTP_X_ACME_DEMO_KEY",
            "",
        )


        if (
            not CLIENT_SECRET
            or
            not supplied_key
            or
            not secrets.compare_digest(
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
            )
            != "success"

            or
            payload.get(
                "client_id"
            )
            != "high-assurance-api"

            or
            payload.get(
                "policy_enabled"
            )
            is not True

            or
            payload.get(
                "active_profile"
            )
            != "fapi-2-security-profile"

            or
            "fapi-2-security-profile"
            not in payload.get(
                "global_profiles",
                [],
            )
        ):

            return response(
                start_response,
                "Invalid FAPI 2 evidence",
                "400 Bad Request",
            )


        allowed = {

            "status",

            "client_id",

            "rhbk_version",

            "policy_name",

            "policy_enabled",

            "marker_role",

            "active_profile",

            "fapi2_specification",

            "global_profiles",

            "active_profile_executors",

            "policy_conditions",

            "client_secret_exposed",

            "admin_credential_exposed",
        }


        FAPI2_DEMO_STATE.clear()


        FAPI2_DEMO_STATE.update({

            key: value

            for key, value
            in payload.items()

            if key in allowed
        })


        return response(
            start_response,
            "FAPI 2 evidence recorded",
        )



    if path == "/fapi2-howto":

        body = """
        <section class="hero">

          <div class="kicker">
            FAPI 2.0
          </div>


          <h1>
            High-assurance OAuth/OIDC policy
          </h1>


          <p class="lead">

            Apply RHBK's built-in FAPI 2.0 Security
            Profile to the ACME high-assurance API.

          </p>

        </section>


        <div class="card">

          <h2>
            Run the demo
          </h2>


          <pre>./scripts/configure-fapi2.sh</pre>


          <p>

            The script verifies the built-in FAPI 2
            profiles, creates the high-assurance API
            client if required, and applies a realm
            Client Policy using:

          </p>


          <pre>Client:   high-assurance-api
Policy:   acme-fapi2-high-assurance
Profile:  fapi-2-security-profile</pre>


          <p>

            In the RHBK Admin Console go to:

          </p>


          <pre>Realm Settings
  -> Client Policies
     -> Profiles
     -> Policies</pre>


          <a class="button secondary"
             href="/#fapi">

            Back to demo

          </a>

        </div>
        """


        return response(
            start_response,
            layout(
                "FAPI 2.0",
                body,
            ),
        )



    if path == "/fapi2-evidence":

        evidence = dict(
            FAPI2_DEMO_STATE
        )


        if evidence.get(
            "status"
        ) != "success":

            return response(
                start_response,
                layout(
                    "FAPI 2 evidence",
                    """
                    <div class="card">

                      <h2>
                        No FAPI 2 evidence yet
                      </h2>

                      <pre>./scripts/configure-fapi2.sh</pre>

                      <a class="button"
                         href="/#fapi">

                        Back

                      </a>

                    </div>
                    """,
                ),
            )


        profiles = (
            evidence.get(
                "global_profiles",
                [],
            )
        )


        executors = (
            evidence.get(
                "active_profile_executors",
                [],
            )
        )


        profile_html = "".join(

            (
                '<li><code>'
                + esc(profile)
                + '</code></li>'
            )

            for profile in profiles
        )


        executor_html = "".join(

            (
                '<li><code>'
                + esc(executor)
                + '</code></li>'
            )

            for executor in executors
        )


        body = f"""
        <section class="hero">

          <div class="kicker">
            FAPI 2.0 policy evidence
          </div>


          <h1>
            High-assurance OAuth controls
          </h1>


          <p class="lead">

            The ACME high-assurance client is selected
            by an RHBK Client Policy and associated with
            the built-in FAPI 2.0 Security Profile.

          </p>


          <div class="status ok">

            <strong>
              FAPI 2 policy configured ✓
            </strong>

            <br>

            Client:

            <code>
              {esc(evidence.get("client_id"))}
            </code>

            <br>

            Policy:

            <code>
              {esc(evidence.get("policy_name"))}
            </code>

            <br>

            Profile:

            <code>
              {esc(evidence.get("active_profile"))}
            </code>

          </div>

        </section>


        <div class="fapi-evidence">

          <h2>
            Built-in RHBK FAPI 2 profiles
          </h2>

          <ul>
            {profile_html}
          </ul>

        </div>


        <div class="fapi-evidence">

          <h2>
            Active Security Profile executors
          </h2>

          <p>

            These are read directly from the running
            RHBK global client profile rather than being
            hard-coded into the demo.

          </p>

          <ul>
            {executor_html}
          </ul>

        </div>


        <div class="card">

          <h2>
            Policy evidence
          </h2>


          <pre>
{esc(json.dumps(evidence, indent=2, sort_keys=True))}
          </pre>


          <h3>
            What this proves
          </h3>


          <ul>

            <li>
              RHBK provides built-in FAPI 2 profiles.
            </li>

            <li>
              The ACME realm has an enabled Client Policy.
            </li>

            <li>

              <code>
                high-assurance-api
              </code>

              is selected using a marker Client Role.

            </li>

            <li>

              The policy applies

              <code>
                fapi-2-security-profile
              </code>.

            </li>

            <li>

              The profile corresponds to the final
              FAPI 2.0 Security Profile.

            </li>

          </ul>


          <div class="status info">

            This demonstrates RHBK policy enforcement
            configuration. It does not claim that the
            demo application itself has independently
            completed an external FAPI certification
            programme.

          </div>


          <a class="button secondary"
             href="/#fapi">

            Back to demo

          </a>

        </div>
        """


        return response(
            start_response,
            layout(
                "FAPI 2 policy evidence",
                body,
            ),
        )



    if path == "/fapi2-reset":

        FAPI2_DEMO_STATE.clear()


        start_response(
            "302 Found",
            [
                (
                    "Location",
                    "/#fapi",
                ),

                (
                    "Cache-Control",
                    "no-store",
                ),
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

echo
echo "Checking syntax..."

python3 -m py_compile \
  "$APP"

bash -n \
  "$SCRIPT_DIR/configure-fapi2.sh"

echo "Syntax: OK"


# ============================================================
# Deploy Portal
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


PORTAL="https://$(oc -n "$NS" get route acme-portal \
  -o jsonpath='{.spec.host}')"


echo
echo "======================================================"
echo " FAPI 2 Portal update complete"
echo "======================================================"
echo

echo "Portal:"
echo "  $PORTAL/#fapi"
echo

echo "Now run:"
echo
echo "  ./scripts/configure-fapi2.sh"
echo
