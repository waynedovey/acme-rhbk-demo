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

BACKUP="${APP}.bak.$(date +%Y%m%d%H%M%S)"
cp "$APP" "$BACKUP"

echo
echo "Backup:"
echo "  $BACKUP"
echo


# ============================================================
# Replace workload-token-test.sh
#
# This performs the REAL workload identity test:
#
#   OpenShift ServiceAccount
#          |
#          | projected JWT - 600 seconds
#          v
#   RHBK Signed JWT - Federated
#          |
#          | client_credentials
#          v
#   Short-lived OAuth access token
#
# No permanent RHBK client secret is used.
# ============================================================

cat > "$SCRIPT_DIR/workload-token-test.sh" <<'WORKLOAD'
#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-rhbk}"
KC_NAME="${KEYCLOAK_NAME:-acme-keycloak}"

SA="${SERVICE_ACCOUNT:-acme-automation}"
CLIENT_ID="${WORKLOAD_CLIENT:-acme-automation}"

TEST_POD="${TEST_POD:-acme-workload-test}"

TOKEN_PATH="/var/run/secrets/tokens/rhbk-token"

TOKEN_EXPIRATION=600


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
# Endpoints
# ============================================================

KC_PUBLIC="https://$(oc -n "$NS" get route "$KC_NAME" \
  -o jsonpath='{.spec.host}')"


PORTAL_URL="https://$(oc -n "$NS" get route acme-portal \
  -o jsonpath='{.spec.host}')"


# Browser/canonical issuer.
REALM_ISSUER="${KC_PUBLIC}/realms/acme-demo"


# Server-to-server path from the test Pod.
KC_INTERNAL="http://${KC_NAME}-service:8080"


TOKEN_URL="${KC_INTERNAL}/realms/acme-demo/protocol/openid-connect/token"


# Portal demo callback credential.
#
# This is used ONLY after the workload test has finished,
# from this local script, to update the green/orange Portal
# status.
#
# It is NOT placed inside the workload Pod.
DEMO_KEY=$(
  oc -n "$NS" get secret acme-demo-secrets \
    -o jsonpath='{.data.portal-client-secret}' |
  base64 -d
)


echo
echo "======================================================"
echo " ACME OpenShift Workload Identity Demo"
echo "======================================================"
echo

echo "Namespace:"
echo "  $NS"
echo

echo "ServiceAccount:"
echo "  $SA"
echo

echo "RHBK client:"
echo "  $CLIENT_ID"
echo

echo "Projected token audience:"
echo "  $REALM_ISSUER"
echo

echo "Projected token lifetime:"
echo "  ${TOKEN_EXPIRATION} seconds"
echo

echo "RHBK token endpoint:"
echo "  $TOKEN_URL"
echo


# ============================================================
# Verify ServiceAccount
# ============================================================

echo "STEP 1 - Verify OpenShift ServiceAccount"
echo "----------------------------------------"
echo


if ! oc -n "$NS" get sa "$SA" >/dev/null 2>&1; then

  echo "ERROR:"
  echo "ServiceAccount does not exist:"
  echo
  echo "  $NS/$SA"
  echo
  echo "Run:"
  echo
  echo "  ./scripts/configure-workload-identity.sh"
  echo

  exit 1
fi


echo "ServiceAccount exists ✓"
echo


# ============================================================
# Delete previous demo Pod
# ============================================================

oc -n "$NS" delete pod "$TEST_POD" \
  --ignore-not-found \
  --wait=true \
  >/dev/null


# ============================================================
# STEP 2
# Create workload Pod with PROJECTED ServiceAccount JWT
#
# IMPORTANT:
#
# There is deliberately no client secret in this Pod.
# ============================================================

echo "STEP 2 - Project short-lived ServiceAccount token"
echo "-------------------------------------------------"
echo


cat <<YAML | oc apply -f -
apiVersion: v1
kind: Pod

metadata:
  name: ${TEST_POD}
  namespace: ${NS}

  labels:
    app.kubernetes.io/name: acme-workload-test
    app.kubernetes.io/part-of: acme-rhbk-demo

spec:

  restartPolicy: Never

  serviceAccountName: ${SA}

  automountServiceAccountToken: false


  containers:

    - name: workload

      image: registry.access.redhat.com/ubi9/python-311:latest

      imagePullPolicy: IfNotPresent

      env:

        - name: RHBK_TOKEN_URL
          value: "${TOKEN_URL}"

        - name: RHBK_CLIENT_ID
          value: "${CLIENT_ID}"

        - name: TOKEN_FILE
          value: "${TOKEN_PATH}"

        - name: DEMO_NAMESPACE
          value: "${NS}"

        - name: DEMO_SERVICE_ACCOUNT
          value: "${SA}"


      command:

        - /bin/bash
        - -c


      args:

        - |

          set -euo pipefail

          python3 - <<'PY'

          import base64
          import datetime
          import hashlib
          import json
          import os
          import urllib.error
          import urllib.parse
          import urllib.request


          def jwt_claims(token):

              parts = token.split(".")

              if len(parts) < 2:
                  return {}

              payload = parts[1]

              payload += "=" * (
                  (-len(payload)) % 4
              )

              try:

                  decoded = (
                      base64.urlsafe_b64decode(
                          payload.encode()
                      )
                  )

                  return json.loads(
                      decoded.decode()
                  )

              except Exception:

                  return {}


          def fingerprint(token):

              return hashlib.sha256(
                  token.encode()
              ).hexdigest()[:16]


          token_file = os.environ[
              "TOKEN_FILE"
          ]


          client_id = os.environ[
              "RHBK_CLIENT_ID"
          ]


          token_url = os.environ[
              "RHBK_TOKEN_URL"
          ]


          namespace = os.environ[
              "DEMO_NAMESPACE"
          ]


          service_account = os.environ[
              "DEMO_SERVICE_ACCOUNT"
          ]


          print()
          print(
              "Checking projected "
              "ServiceAccount token..."
          )


          if not os.path.exists(
              token_file
          ):

              raise SystemExit(
                  "ERROR: projected token "
                  "was not mounted"
              )


          with open(
              token_file,
              "r",
              encoding="utf-8",
          ) as handle:

              assertion = (
                  handle.read().strip()
              )


          assertion_claims = jwt_claims(
              assertion
          )


          assertion_iss = (
              assertion_claims.get(
                  "iss"
              )
          )


          assertion_sub = (
              assertion_claims.get(
                  "sub"
              )
          )


          assertion_aud = (
              assertion_claims.get(
                  "aud"
              )
          )


          assertion_iat = (
              assertion_claims.get(
                  "iat"
              )
          )


          assertion_exp = (
              assertion_claims.get(
                  "exp"
              )
          )


          assertion_lifetime = None

          if (
              isinstance(
                  assertion_iat,
                  int,
              )
              and
              isinstance(
                  assertion_exp,
                  int,
              )
          ):

              assertion_lifetime = (
                  assertion_exp
                  - assertion_iat
              )


          print(
              "Projected token found ✓"
          )

          print(
              "Kubernetes issuer:",
              assertion_iss,
          )

          print(
              "Federated subject:",
              assertion_sub,
          )

          print(
              "Audience:",
              assertion_aud,
          )

          print(
              "Lifetime:",
              assertion_lifetime,
              "seconds",
          )

          print()


          # ================================================
          # REAL federated client authentication request
          # ================================================

          print(
              "Requesting RHBK OAuth token..."
          )

          print()

          print(
              "Client authentication:"
          )

          print(
              "  Signed JWT - Federated"
          )

          print()

          print(
              "Client secret:"
          )

          print(
              "  NONE"
          )

          print()


          form = {

              "grant_type":
                  "client_credentials",

              "client_id":
                  client_id,

              "client_assertion_type":
                  "urn:ietf:params:oauth:"
                  "client-assertion-type:"
                  "jwt-bearer",

              "client_assertion":
                  assertion,
          }


          request = urllib.request.Request(

              token_url,

              data=urllib.parse.urlencode(
                  form
              ).encode(),

              headers={
                  "Content-Type":
                      "application/"
                      "x-www-form-urlencoded",
              },

              method="POST",
          )


          try:

              with urllib.request.urlopen(
                  request,
                  timeout=30,
              ) as response:

                  http_status = (
                      response.status
                  )

                  body = json.loads(
                      response.read().decode()
                  )


          except urllib.error.HTTPError as exc:

              error_body = (
                  exc.read().decode(
                      errors="replace"
                  )
              )

              print(
                  "RHBK rejected workload "
                  "authentication."
              )

              print()

              print(
                  "HTTP status:",
                  exc.code,
              )

              print()

              print(
                  error_body
              )

              raise SystemExit(1)


          if http_status != 200:

              raise SystemExit(
                  "Unexpected RHBK HTTP "
                  f"status {http_status}"
              )


          access_token = body.get(
              "access_token"
          )


          if not access_token:

              raise SystemExit(
                  "RHBK response did not "
                  "contain access_token"
              )


          access_claims = jwt_claims(
              access_token
          )


          print(
              "RHBK workload "
              "authentication successful ✓"
          )

          print()

          print(
              "OAuth HTTP status:",
              http_status,
          )

          print(
              "Token type:",
              body.get(
                  "token_type"
              ),
          )

          print(
              "OAuth token lifetime:",
              body.get(
                  "expires_in"
              ),
              "seconds",
          )

          print(
              "OAuth scope:",
              body.get(
                  "scope"
              ),
          )

          print()


          # ================================================
          # SANITIZED EVIDENCE ONLY
          #
          # Never print:
          #
          # - projected ServiceAccount JWT
          # - OAuth access token
          # ================================================

          evidence = {

              "status":
                  "success",

              "created_at":
                  datetime.datetime.now(
                      datetime.timezone.utc
                  ).strftime(
                      "%Y-%m-%dT%H:%M:%SZ"
                  ),

              "namespace":
                  namespace,

              "service_account":
                  service_account,

              "federated_subject":
                  assertion_sub,

              "kubernetes_issuer":
                  assertion_iss,

              "assertion_audience":
                  assertion_aud,

              "assertion_lifetime_seconds":
                  assertion_lifetime,

              "assertion_fingerprint":
                  fingerprint(
                      assertion
                  ),

              "projected_token_path":
                  token_file,

              "client_id":
                  client_id,

              "identity_provider":
                  "openshift",

              "client_authentication":
                  "Signed JWT - Federated",

              "client_secret_used":
                  False,

              "oauth_grant_type":
                  "client_credentials",

              "oauth_http_status":
                  http_status,

              "access_token_type":
                  body.get(
                      "token_type"
                  ),

              "access_token_expires_in":
                  body.get(
                      "expires_in"
                  ),

              "access_token_scope":
                  body.get(
                      "scope"
                  ),

              "access_token_issuer":
                  access_claims.get(
                      "iss"
                  ),

              "access_token_subject":
                  access_claims.get(
                      "sub"
                  ),

              "access_token_audience":
                  access_claims.get(
                      "aud"
                  ),

              "access_token_authorized_party":
                  access_claims.get(
                      "azp"
                  ),

              "access_token_fingerprint":
                  fingerprint(
                      access_token
                  ),
          }


          print(
              "WORKLOAD_EVIDENCE_JSON="
              + json.dumps(
                  evidence,
                  separators=(",", ":"),
              )
          )

          print()

          print(
              "============================================"
          )

          print(
              " RESULT: WORKLOAD IDENTITY SUCCESS"
          )

          print(
              "============================================"
          )

          PY


      volumeMounts:

        - name: rhbk-token

          mountPath: /var/run/secrets/tokens

          readOnly: true


  volumes:

    - name: rhbk-token

      projected:

        defaultMode: 420

        sources:

          - serviceAccountToken:

              audience: "${REALM_ISSUER}"

              expirationSeconds: ${TOKEN_EXPIRATION}

              path: rhbk-token
YAML


echo "Workload Pod created ✓"
echo


# ============================================================
# STEP 3
# Wait for workload test to complete
# ============================================================

echo "STEP 3 - Federated client authentication"
echo "----------------------------------------"
echo


PHASE=""

for _ in $(seq 1 90); do

  PHASE=$(
    oc -n "$NS" get pod "$TEST_POD" \
      -o jsonpath='{.status.phase}' \
      2>/dev/null ||
      true
  )


  case "$PHASE" in

    Succeeded|Failed)
      break
      ;;

  esac


  sleep 2

done


echo "Pod phase:"
echo "  ${PHASE:-Unknown}"
echo


LOGS=$(
  oc -n "$NS" logs "$TEST_POD" \
    2>&1 ||
    true
)


printf '%s\n' "$LOGS"


if [[ "$PHASE" != "Succeeded" ]]; then

  echo
  echo "ERROR:"
  echo "Workload identity test failed."
  echo

  echo "Pod details:"
  echo

  oc -n "$NS" describe pod "$TEST_POD" ||
    true

  exit 1
fi


# ============================================================
# Extract sanitized evidence
# ============================================================

EVIDENCE=$(
  printf '%s\n' "$LOGS" |
    sed -n \
      's/^WORKLOAD_EVIDENCE_JSON=//p' |
    tail -1
)


if [[ -z "$EVIDENCE" ]]; then

  echo
  echo "ERROR:"
  echo "No workload evidence was returned by the Pod."
  exit 1
fi


if ! jq -e '
  .status == "success"
  and
  .client_secret_used == false
  and
  .oauth_http_status == 200
' <<<"$EVIDENCE" >/dev/null; then

  echo
  echo "ERROR:"
  echo "Returned workload evidence is not valid."
  echo

  jq . <<<"$EVIDENCE"

  exit 1
fi


# ============================================================
# STEP 4
# Update Portal with SANITIZED evidence
#
# The raw SA JWT and OAuth access token NEVER leave the Pod.
# ============================================================

echo
echo "STEP 4 - Update Portal evidence"
echo "-------------------------------"
echo


PORTAL_HTTP=$(
  curl -skS \
    -o /dev/null \
    -w '%{http_code}' \
    -X POST \
    "${PORTAL_URL}/api/demo/workload" \
    -H "X-ACME-Demo-Key: ${DEMO_KEY}" \
    -H 'Content-Type: application/json' \
    --data "$EVIDENCE"
)


if [[ "$PORTAL_HTTP" != "200" ]]; then

  echo "WARNING:"
  echo "Workload identity succeeded but Portal callback returned:"
  echo
  echo "  HTTP $PORTAL_HTTP"
  echo

else

  echo "Portal status updated ✓"
  echo

fi


echo
echo "======================================================"
echo " OpenShift Workload Identity SUCCESS"
echo "======================================================"
echo

echo "OpenShift identity:"
echo "  system:serviceaccount:${NS}:${SA}"
echo

echo "RHBK client:"
echo "  $CLIENT_ID"
echo

echo "Authentication:"
echo "  Signed JWT - Federated"
echo

echo "Client secret:"
echo "  NONE ✓"
echo

echo "Projected token:"
echo "  ${TOKEN_EXPIRATION} seconds"
echo

echo "RHBK OAuth access token:"
echo "  short-lived ✓"
echo

echo "Portal:"
echo "  ${PORTAL_URL}/#workload"
echo

echo "Sensitive values intentionally NOT displayed:"
echo "  Projected Kubernetes ServiceAccount JWT"
echo "  RHBK OAuth access token"
echo
WORKLOAD


chmod +x \
  "$SCRIPT_DIR/workload-token-test.sh"


# ============================================================
# Patch Portal
# ============================================================

python3 - "$APP" <<'PY'
from pathlib import Path
import json
import re
import sys


p = Path(sys.argv[1])

s = p.read_text()


# ============================================================
# 1. Workload demo state
# ============================================================

if "WORKLOAD_DEMO_STATE = {}" not in s:

    anchor = next(
        (
            value
            for value in [
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
# OpenShift Workload Identity demo
#
# The real authentication occurs in workload-token-test.sh.
#
# This state contains sanitized evidence only.
# ------------------------------------------------------------

WORKLOAD_DEMO_STATE = {}

''',
        1,
    )


# ============================================================
# 2. CSS
# ============================================================

if ".workload-complete" not in s:

    css = '''

.workload-demo-row{{
  display:flex;
  align-items:center;
  flex-wrap:wrap;
  gap:8px;
  margin:10px 0;
}}

a.button.workload-pending{{
  background:#ec7a08;
  color:#fff;
  min-width:290px;
}}

a.button.workload-complete{{
  background:#3e8635;
  color:#fff;
  min-width:290px;
}}

.workload-evidence{{
  border:1px solid #d2d2d2;
  border-left:5px solid #3e8635;
  border-radius:7px;
  padding:14px;
  margin:14px 0;
  background:#fff;
}}

.workload-flow{{
  font-family:monospace;
  white-space:pre-wrap;
  background:#f5f5f5;
  border-radius:7px;
  padding:14px;
  margin:12px 0;
}}

'''


    marker = "@media(max-width:720px)"


    if marker not in s:

        raise SystemExit(
            "ERROR: Could not find CSS anchor"
        )


    s = s.replace(
        marker,
        css + marker,
        1,
    )


# ============================================================
# 3. Dashboard state
# ============================================================

if "workload_demo = dict(" not in s:

    marker = "    ps_focus = None\n"


    block = """    # ------------------------------------------------
    # OpenShift workload identity status
    # ------------------------------------------------

    workload_demo = dict(
        WORKLOAD_DEMO_STATE
    )


    workload_complete = (

        workload_demo.get(
            "status"
        )
        == "success"

        and
        workload_demo.get(
            "oauth_http_status"
        )
        == 200

        and
        workload_demo.get(
            "client_secret_used"
        )
        is False
    )


    if workload_complete:

        workload_status = f'''
        <div class="status ok">

          <strong>
            OpenShift workload authentication successful ✓
          </strong>

          <br>

          ServiceAccount:

          <code>
            {esc(workload_demo.get("federated_subject"))}
          </code>

          <br>

          RHBK client:

          <strong>
            {esc(workload_demo.get("client_id"))}
          </strong>

          <br>

          Authentication:

          <strong>
            Signed JWT - Federated
          </strong>

          <br>

          Permanent RHBK client secret:

          <strong>
            NONE ✓
          </strong>

        </div>
        '''


        workload_action = '''
        <a class="button workload-complete"
           href="/workload-evidence">

          Federated workload token — Issued ✓

        </a>
        '''


    else:

        workload_status = '''
        <div class="status wait">

          OpenShift workload identity has not yet been
          demonstrated.

        </div>
        '''


        workload_action = '''
        <a class="button workload-pending"
           href="/workload-howto">

          Run workload identity test

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
# 4. Replace Section 6 card
# ============================================================

card = '''<div id="workload" class="card primary">

<div class="kicker">

  <span class="step">6</span>

  OpenShift workload identity

</div>


<h3>
No permanent RHBK client secret
</h3>


<p>

Use a projected Kubernetes ServiceAccount token as federated
client authentication and receive a short-lived OAuth token.

</p>


{workload_status}


<div class="workload-demo-row">

{workload_action}

</div>


<pre>./scripts/configure-workload-identity.sh
./scripts/workload-token-test.sh</pre>


<p class="tiny">

<strong>Flow:</strong>

OpenShift projects a short-lived ServiceAccount JWT.
RHBK validates the Kubernetes issuer and ServiceAccount
subject through the <strong>openshift</strong> identity
provider, authenticates <strong>acme-automation</strong>
using <strong>Signed JWT - Federated</strong>, and issues
a short-lived OAuth access token.

</p>


{(
    '<a class="button outline" '
    'href="/workload-evidence">'
    'View workload identity evidence'
    '</a>'
    if workload_complete
    else ''
)}


<a class="button outline"
   href="/workload-reset">

  Reset demo status

</a>


</div>
'''


pattern = re.compile(
    r'<div id="workload" class="card[^"]*">'
    r'.*?'
    r'(?='
    r'<div id="onboarding" class="card'
    r'|'
    r'<div id="fapi" class="card'
    r'|'
    r'</section>'
    r')',
    re.S,
)


if not pattern.search(s):

    raise SystemExit(
        "ERROR: Could not locate Section 6 workload card"
    )


s = pattern.sub(
    lambda _:
        card,
    s,
    count=1,
)


# ============================================================
# 5. Portal API and evidence routes
# ============================================================

if 'if path == "/api/demo/workload":' not in s:

    marker = '    if path == "/login":\n'


    routes = '''    # ==================================================
    # OPENSHIFT WORKLOAD IDENTITY
    # ==================================================

    if path == "/api/demo/workload":

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
                "oauth_http_status"
            )
            != 200

            or
            payload.get(
                "client_secret_used"
            )
            is not False

            or
            payload.get(
                "client_id"
            )
            != "acme-automation"

            or
            payload.get(
                "identity_provider"
            )
            != "openshift"
        ):

            return response(
                start_response,
                "Invalid workload identity evidence",
                "400 Bad Request",
            )


        # Only sanitized evidence is stored.
        #
        # Raw ServiceAccount and OAuth tokens are deliberately
        # excluded from the accepted field list.

        allowed = {

            "status",

            "created_at",

            "namespace",

            "service_account",

            "federated_subject",

            "kubernetes_issuer",

            "assertion_audience",

            "assertion_lifetime_seconds",

            "assertion_fingerprint",

            "projected_token_path",

            "client_id",

            "identity_provider",

            "client_authentication",

            "client_secret_used",

            "oauth_grant_type",

            "oauth_http_status",

            "access_token_type",

            "access_token_expires_in",

            "access_token_scope",

            "access_token_issuer",

            "access_token_subject",

            "access_token_audience",

            "access_token_authorized_party",

            "access_token_fingerprint",
        }


        WORKLOAD_DEMO_STATE.clear()


        WORKLOAD_DEMO_STATE.update({

            key: value

            for key, value
            in payload.items()

            if key in allowed
        })


        return response(
            start_response,
            "Workload identity evidence recorded",
        )



    if path == "/workload-howto":

        body = """
        <section class="hero">

          <div class="kicker">

            OpenShift workload identity

          </div>


          <h1>

            Authenticate a workload without a client secret

          </h1>


          <p class="lead">

            Configure the Kubernetes trust relationship,
            then run a Pod using a short-lived projected
            ServiceAccount token.

          </p>

        </section>


        <div class="card">

          <h2>
            Run the demo
          </h2>


          <pre>./scripts/configure-workload-identity.sh
./scripts/workload-token-test.sh</pre>


          <div class="workload-flow">OpenShift ServiceAccount
        |
        | projected JWT
        | 600 seconds
        v
RHBK Kubernetes Identity Provider
        |
        | Signed JWT - Federated
        v
acme-automation
        |
        | client_credentials
        v
Short-lived OAuth Access Token</div>


          <p>

            There is no permanent RHBK client secret in
            the workload.

          </p>


          <a class="button secondary"
             href="/#workload">

            Back to demo

          </a>

        </div>
        """


        return response(
            start_response,
            layout(
                "OpenShift workload identity",
                body,
            ),
        )



    if path == "/workload-evidence":

        evidence = dict(
            WORKLOAD_DEMO_STATE
        )


        if evidence.get(
            "status"
        ) != "success":

            return response(
                start_response,
                layout(
                    "Workload identity evidence",
                    """
                    <div class="card">

                      <h2>
                        No workload identity evidence yet
                      </h2>


                      <p>
                        Run:
                      </p>


                      <pre>./scripts/configure-workload-identity.sh
./scripts/workload-token-test.sh</pre>


                      <a class="button"
                         href="/#workload">

                        Back

                      </a>

                    </div>
                    """,
                ),
            )


        body = f"""
        <section class="hero">

          <div class="kicker">

            Federated workload authentication evidence

          </div>


          <h1>

            OpenShift ServiceAccount authenticated to RHBK

          </h1>


          <p class="lead">

            A short-lived Kubernetes ServiceAccount JWT
            authenticated the RHBK client without a
            permanent client secret.

          </p>


          <div class="status ok">

            <strong>
              Workload authentication successful ✓
            </strong>

            <br>

            Federated subject:

            <code>
              {esc(evidence.get("federated_subject"))}
            </code>

            <br>

            RHBK client:

            <strong>
              {esc(evidence.get("client_id"))}
            </strong>

            <br>

            Permanent client secret:

            <strong>
              NONE ✓
            </strong>

          </div>

        </section>


        <div class="workload-flow">OpenShift ServiceAccount
        |
        | projected JWT
        | {esc(evidence.get("assertion_lifetime_seconds"))} seconds
        v
Kubernetes issuer
{esc(evidence.get("kubernetes_issuer"))}
        |
        v
RHBK Identity Provider: openshift
        |
        | Signed JWT - Federated
        v
RHBK client: {esc(evidence.get("client_id"))}
        |
        | client_credentials
        v
OAuth Access Token
Lifetime: {esc(evidence.get("access_token_expires_in"))} seconds</div>


        <div class="workload-evidence">

          <h2>
            Sanitized evidence
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

              The workload ran as the OpenShift
              <strong>acme-automation</strong>
              ServiceAccount.

            </li>


            <li>

              OpenShift projected a short-lived
              ServiceAccount JWT into the Pod.

            </li>


            <li>

              The JWT subject was

              <code>
                {esc(evidence.get("federated_subject"))}
              </code>.

            </li>


            <li>

              RHBK used the

              <strong>
                openshift
              </strong>

              Kubernetes identity provider.

            </li>


            <li>

              Client authentication was

              <strong>
                Signed JWT - Federated
              </strong>.

            </li>


            <li>

              The workload supplied

              <strong>
                no permanent RHBK client secret
              </strong>.

            </li>


            <li>

              RHBK returned a short-lived OAuth
              access token.

            </li>


            <li>

              Raw ServiceAccount and OAuth tokens are
              deliberately not displayed.

            </li>

          </ul>


          <a class="button secondary"
             href="/#workload">

            Back to demo

          </a>

        </div>
        """


        return response(
            start_response,
            layout(
                "Workload identity evidence",
                body,
            ),
        )



    if path == "/workload-reset":

        # Portal demo state only.
        #
        # This does NOT remove:
        #
        # - ServiceAccount
        # - Kubernetes Identity Provider
        # - RHBK client
        # - federated authentication configuration

        WORKLOAD_DEMO_STATE.clear()


        start_response(
            "302 Found",
            [
                (
                    "Location",
                    "/#workload",
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

echo
echo "Checking syntax..."


python3 -m py_compile \
  "$APP"


bash -n \
  "$SCRIPT_DIR/workload-token-test.sh"


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
  'WORKLOAD_DEMO_STATE|api/demo/workload|workload-evidence|workload-complete' \
  /opt/app/app.py |
head -60


echo
echo "======================================================"
echo " OpenShift Workload Identity Portal update complete"
echo "======================================================"
echo

echo "Portal:"
echo "  $PORTAL/#workload"
echo

echo "Now run:"
echo
echo "  ./scripts/configure-workload-identity.sh"
echo "  ./scripts/workload-token-test.sh"
echo

echo "Expected result:"
echo
echo "  OpenShift ServiceAccount"
echo "      -> projected 600-second JWT"
echo "      -> Signed JWT - Federated"
echo "      -> acme-automation"
echo "      -> short-lived OAuth token"
echo "      -> NO client secret"
echo "      -> Portal turns GREEN"
echo
