#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-rhbk}"
APP="portal/app.py"
DEPLOYMENT="acme-portal"
CONFIGMAP="acme-portal-code"

[[ -f "$APP" ]] || {
  echo "ERROR: Cannot find $APP"
  exit 1
}

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
# 1. FAPI state
# ============================================================

if "FAPI2_DEMO_STATE = {}" not in s:

    candidates = [
        "WORKLOAD_DEMO_STATE = {}",
        "ONBOARDING_DEMO_STATE = {}",
        "TOKEN_EXCHANGE_EVIDENCE = {}",
        "CONSENT_LAST_TOKENS = {}",
        "PASSKEY_DEMO_STATE = {}",
        "BROKER_AUTH_STATE = {}",
        "STATES = {}",
    ]

    anchor = next(
        (
            candidate
            for candidate in candidates
            if candidate in s
        ),
        None,
    )

    if not anchor:
        raise SystemExit(
            "ERROR: Could not locate Portal state section"
        )

    s = s.replace(
        anchor,
        anchor + '''

# ------------------------------------------------------------
# FAPI 2.0 demo state
# ------------------------------------------------------------

FAPI2_DEMO_STATE = {}

''',
        1,
    )

    print("Added FAPI2_DEMO_STATE")


# ============================================================
# 2. CSS
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

    if marker in s:

        s = s.replace(
            marker,
            css + marker,
            1,
        )

    else:

        # Fallback: put CSS immediately before closing style tag.
        if "</style>" not in s:
            raise SystemExit(
                "ERROR: Could not locate Portal CSS"
            )

        s = s.replace(
            "</style>",
            css + "\n</style>",
            1,
        )

    print("Added FAPI CSS")


# ============================================================
# 3. Dashboard state
# ============================================================

if "fapi2_complete =" not in s:

    dashboard = re.search(
        r'(?m)^def demo_dashboard\([^)]*\):\s*$',
        s,
    )

    if not dashboard:
        raise SystemExit(
            "ERROR: Could not locate demo_dashboard()"
        )

    after = dashboard.end()

    # Find first indented executable line after function def.
    first_line = re.search(
        r'(?m)^(    [^\n]+)$',
        s[after:],
    )

    if not first_line:
        raise SystemExit(
            "ERROR: Could not locate dashboard body"
        )

    insert_at = (
        after
        + first_line.start()
    )

    block = '''
    # ------------------------------------------------
    # FAPI 2.0 demo status
    # ------------------------------------------------

    fapi2_demo = dict(
        FAPI2_DEMO_STATE
    )

    fapi2_complete = (
        fapi2_demo.get("status") == "success"
        and
        fapi2_demo.get("client_id")
        == "high-assurance-api"
        and
        fapi2_demo.get("policy_enabled")
        is True
        and
        fapi2_demo.get("active_profile")
        == "fapi-2-security-profile"
    )

    if fapi2_complete:

        fapi2_status = f"""
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

        </div>
        """

        fapi2_action = """
        <a class="button fapi-complete"
           href="/fapi2-evidence">

          FAPI 2 policy — Configured ✓

        </a>
        """

    else:

        fapi2_status = """
        <div class="status wait">

          FAPI 2.0 policy has not yet been demonstrated.

        </div>
        """

        fapi2_action = """
        <a class="button fapi-pending"
           href="/fapi2-howto">

          Configure FAPI 2 policy

        </a>
        """

'''

    s = (
        s[:insert_at]
        + block
        + s[insert_at:]
    )

    print("Added FAPI dashboard state")


# ============================================================
# 4. Replace FAPI card
# ============================================================

new_card = '''<div id="fapi" class="card primary">

<div class="kicker">
  <span class="step">8</span>
  FAPI 2.0
</div>

<h3>
High-assurance OAuth/OIDC policy
</h3>

<p>
Show RHBK's built-in FAPI 2 client profiles and apply
the FAPI 2.0 Security Profile to APIs requiring tighter
OAuth controls.
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


# FAPI is the final demo card, so replace from its opening
# div through the closing </section>.
fapi_start = re.search(
    r'<div id="fapi"\s+class="card[^"]*">',
    s,
)

if not fapi_start:
    raise SystemExit(
        "ERROR: Could not locate existing FAPI card"
    )


section_end = s.find(
    "</section>",
    fapi_start.start(),
)

if section_end < 0:
    raise SystemExit(
        "ERROR: Could not locate </section> after FAPI card"
    )


s = (
    s[:fapi_start.start()]
    + new_card
    + "\n"
    + s[section_end:]
)

print("Replaced Section 8 FAPI card")


# ============================================================
# 5. Locate def app() reliably
# ============================================================

app_match = re.search(
    r'(?m)^def app\([^)]*\):\s*$',
    s,
)

if not app_match:
    raise SystemExit(
        "ERROR: Could not locate def app()"
    )


# Find ANY top-level route inside app().
app_tail = s[
    app_match.end():
]

route_match = re.search(
    r'(?m)^    if\s+path\b.*:\s*$',
    app_tail,
)

if not route_match:

    # Diagnostic dump.
    print()
    print("Possible lines containing 'path':")

    for number, line in enumerate(
        s.splitlines(),
        1,
    ):
        if "path" in line and "if " in line:
            print(
                f"{number}: {line}"
            )

    raise SystemExit(
        "ERROR: Could not find any if path route "
        "inside def app()"
    )


route_position = (
    app_match.end()
    + route_match.start()
)


print(
    "FAPI routes will be inserted before:"
)

print(
    "  "
    + route_match.group(0).strip()
)


# ============================================================
# 6. Add routes
# ============================================================

if 'if path == "/api/demo/fapi2":' not in s:

    routes = '''    # ==================================================
    # FAPI 2.0 DEMO
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
                raw.decode("utf-8")
            )

        except Exception as exc:

            return response(
                start_response,
                "Invalid JSON: "
                + str(exc),
                "400 Bad Request",
            )


        if (
            payload.get("status")
            != "success"

            or
            payload.get("client_id")
            != "high-assurance-api"

            or
            payload.get("policy_enabled")
            is not True

            or
            payload.get("active_profile")
            != "fapi-2-security-profile"
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

            Apply RHBK's built-in FAPI 2 Security Profile
            to the ACME high-assurance API.

          </p>

        </section>


        <div class="card">

          <h2>
            Run the demo
          </h2>

          <pre>./scripts/configure-fapi2.sh</pre>

          <pre>Client:
  high-assurance-api

Policy:
  acme-fapi2-high-assurance

Profile:
  fapi-2-security-profile</pre>

          <p>
            Then inspect the configuration in:
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

                      <pre>
./scripts/configure-fapi2.sh
                      </pre>

                      <a class="button"
                         href="/#fapi">

                        Back

                      </a>

                    </div>
                    """,
                ),
            )


        profiles = evidence.get(
            "global_profiles",
            [],
        )

        executors = evidence.get(
            "active_profile_executors",
            [],
        )


        profile_html = "".join(
            "<li><code>"
            + esc(profile)
            + "</code></li>"
            for profile in profiles
        )


        executor_html = "".join(
            "<li><code>"
            + esc(executor)
            + "</code></li>"
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
            Active profile executors
          </h2>

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

          <div class="status info">

            This demonstrates RHBK FAPI policy configuration.
            It does not claim independent certification of
            the ACME demo application.

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

    s = (
        s[:route_position]
        + routes
        + s[route_position:]
    )

    print("Added FAPI routes")

else:

    print("FAPI routes already present")


# ============================================================
# Save
# ============================================================

p.write_text(s)

print()
print(
    "Updated:",
    p
)
PY


echo
echo "Checking Python syntax..."

python3 -m py_compile "$APP"

echo "Python syntax: OK"


echo
echo "Checking important FAPI code..."

grep -nE \
  'FAPI2_DEMO_STATE|fapi2_complete|api/demo/fapi2|fapi2-evidence|fapi-2-security-profile' \
  "$APP" |
head -50


echo
echo "Updating ConfigMap..."

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
echo " FAPI 2 Portal repair complete"
echo "======================================================"
echo

echo "Portal:"
echo "  $PORTAL/#fapi"
echo

echo "Next:"
echo "  ./scripts/configure-fapi2.sh"
echo
