#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-rhbk}"
APP="${APP_FILE:-portal/app.py}"
DEPLOYMENT="${PORTAL_DEPLOYMENT:-acme-portal}"
CONFIGMAP="${PORTAL_CONFIGMAP:-acme-portal-code}"

[[ -f "$APP" ]] || {
  echo "ERROR: $APP not found. Run from repo root."
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
# Import hashlib for safe token fingerprints
# ============================================================

if "import hashlib\n" not in s:
    s = s.replace(
        "import html\n",
        "import html\nimport hashlib\n",
        1,
    )


# ============================================================
# Token Exchange demo state
# ============================================================

if "TOKEN_EXCHANGE_DEMO_STATE = {}" not in s:

    anchor = next(
        (
            x
            for x in [
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
            "ERROR: no state insertion point"
        )

    s = s.replace(
        anchor,
        anchor + '''

# ------------------------------------------------------------
# OAuth 2.0 / RFC 8693 Token Exchange demo state
#
# RHBK performs the real token exchange.
# These structures only control the Portal demo indicators.
# ------------------------------------------------------------

TOKEN_EXCHANGE_DEMO_STATE = {}
TOKEN_EXCHANGE_EVIDENCE = {}
''',
        1,
    )


# ============================================================
# Helpers
# ============================================================

if "def token_fingerprint(" not in s:

    marker = "\ndef demo_dashboard("

    helper = r'''

def token_fingerprint(token):
    return (
        hashlib.sha256(
            token.encode()
        ).hexdigest()[:16]
        if token
        else "n/a"
    )


def token_exchange_summary(claims):
    return {
        "username":
            claims.get("preferred_username"),

        "subject":
            claims.get("sub"),

        "authorized_party":
            claims.get("azp"),

        "audience":
            claims.get("aud"),

        "scope":
            claims.get("scope"),

        "issued_at":
            claims.get("iat"),

        "expires":
            claims.get("exp"),

        "token_id":
            claims.get("jti"),
    }

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: demo_dashboard() not found"
        )

    s = s.replace(
        marker,
        helper + marker,
        1,
    )


# ============================================================
# CSS
# ============================================================

if ".exchange-complete" not in s:

    marker = "@media(max-width:720px)"

    css = '''

.exchange-demo-row{{
  display:flex;
  align-items:center;
  flex-wrap:wrap;
  gap:8px;
  margin:8px 0;
}}

a.button.exchange-pending{{
  background:#ec7a08;
  color:#fff;
  min-width:270px;
}}

a.button.exchange-complete{{
  background:#3e8635;
  color:#fff;
  min-width:270px;
}}

.token-compare{{
  display:grid;
  grid-template-columns:
    repeat(auto-fit,minmax(280px,1fr));
  gap:14px;
  margin:14px 0;
}}

.token-panel{{
  border:1px solid #d2d2d2;
  border-radius:7px;
  padding:14px;
  background:#fff;
}}

.token-panel.source{{
  border-left:5px solid #0066cc;
}}

.token-panel.target{{
  border-left:5px solid #3e8635;
}}

'''

    if marker not in s:
        raise SystemExit(
            "ERROR: CSS marker not found"
        )

    s = s.replace(
        marker,
        css + marker,
        1,
    )


# ============================================================
# Dashboard state
# ============================================================

if "exchange_claims_viewed =" not in s:

    marker = "    ps_focus = None\n"

    block = """    # ------------------------------------------------
    # OAuth 2.0 Token Exchange status
    # ------------------------------------------------

    exchange_state = (
        TOKEN_EXCHANGE_DEMO_STATE.get(
            portal_user,
            {},
        )
        if portal_user
        else {}
    )

    exchange_claims_viewed = bool(
        exchange_state.get(
            "claims_viewed"
        )
    )

    exchange_complete = bool(
        exchange_state.get(
            "exchange_complete"
        )
    )


    if not portal_session:

        exchange_status = (
            '<div class="status wait">'
            'Sign in to ACME first to establish '
            'the source application token.'
            '</div>'
        )

        exchange_buttons = (
            '<div class="exchange-demo-row">'
            '<a class="button exchange-pending" '
            'href="/login">'
            'Sign in first'
            '</a>'
            '</div>'
        )


    else:

        claims_class = (
            "exchange-complete"
            if exchange_claims_viewed
            else
            "exchange-pending"
        )

        claims_label = (
            "Current claims — Viewed ✓"
            if exchange_claims_viewed
            else
            "View current claims"
        )

        exchange_class = (
            "exchange-complete"
            if exchange_complete
            else
            "exchange-pending"
        )

        exchange_label = (
            "Orders API token — Exchanged ✓"
            if exchange_complete
            else
            "Exchange for Orders API"
        )


        exchange_buttons = f'''
        <div class="exchange-demo-row">

          <a class="button {claims_class}"
             href="/claims">

            {claims_label}

          </a>

        </div>

        <div class="exchange-demo-row">

          <a class="button {exchange_class}"
             href="/exchange">

            {exchange_label}

          </a>

        </div>
        '''


        if exchange_complete:

            exchange_status = f'''
            <div class="status ok">

              <strong>
                RFC 8693 Token Exchange successful.
              </strong>

              <br>

              ACME user:
              <strong>
                {esc(portal_user)}
              </strong>

              <br>

              Requesting client:
              <strong>
                {esc(CLIENT_ID)}
              </strong>

              <br>

              Target audience:
              <strong>
                orders-api
              </strong>

            </div>
            '''


        elif exchange_claims_viewed:

            exchange_status = '''
            <div class="status info">

              Original ACME Portal token inspected.

              Now exchange it for an Orders API token.

            </div>
            '''


        else:

            exchange_status = '''
            <div class="status wait">

              Token Exchange has not yet been demonstrated.

              Start by viewing the source token claims.

            </div>
            '''

"""

    if marker not in s:
        raise SystemExit(
            "ERROR: dashboard insertion marker not found"
        )

    s = s.replace(
        marker,
        block + marker,
        1,
    )


# ============================================================
# Replace Token Exchange card
# ============================================================

card = """<div id="exchange" class="card primary">

<div class="kicker">

  <span class="step">5</span>

  OAuth 2.0 Token Exchange

</div>

<h3>
Exchange user token for an API token
</h3>

<p>
Show RFC 8693 token exchange and compare the original
application token with the Orders API token.
</p>

{exchange_status}

<div class="exchange-demo-list">

{exchange_buttons}

</div>

<p class="tiny">

<strong>Flow:</strong>

ACME Portal sends the user's access token to the RHBK
token endpoint using the RFC 8693 token-exchange grant
and requests:

<code>audience=orders-api</code>

</p>

{(
    '<a class="button outline" '
    'href="/exchange-evidence">'
    'Compare token evidence'
    '</a>'
    if exchange_complete
    else ''
)}

<a class="button outline"
   href="/exchange-reset">

  Reset demo status

</a>

</div>

</section>'''"""

if (
    '<div class="exchange-demo-list">'
    '{exchange_buttons}</div>'
    not in s
):

    pat = re.compile(
        r"<div id=\"exchange\" "
        r"class=\"card primary\">"
        r".*?"
        r"browser_cards \+= "
        r"'</div></section>'",
        re.S,
    )

    if not pat.search(s):
        raise SystemExit(
            "ERROR: Token Exchange card not found"
        )

    s = pat.sub(
        lambda m: card,
        s,
        count=1,
    )


# ============================================================
# Replace /claims route
# ============================================================

pat = re.compile(
    r'    if path == "/claims":\n'
    r'.*?'
    r'(?=    if path == "/[^\"]+":)',
    re.S,
)

claims = r"""    if path == "/claims":

        if not portal_session:

            return response(
                start_response,
                layout(
                    "Not signed in",
                    '''
                    <div class="card">

                      <h2>
                        Sign in first
                      </h2>

                      <a class="button"
                         href="/login">
                        Sign in
                      </a>

                    </div>
                    ''',
                ),
                "401 Unauthorized",
            )


        focus, access, identity = (
            claims_focus(
                portal_session
            )
        )

        user = focus.get(
            "user"
        )


        if user:

            TOKEN_EXCHANGE_DEMO_STATE.setdefault(
                user,
                {},
            )["claims_viewed"] = True


        source_token = portal_session.get(
            "access_token",
            "",
        )

        summary = token_exchange_summary(
            access
        )

        fingerprint = token_fingerprint(
            source_token
        )


        body = f'''
        <section class="hero">

          <div class="kicker">
            OAuth 2.0 Token Exchange — source token
          </div>

          <h1>
            Current ACME Portal token
          </h1>

          <p class="lead">

            This access token becomes the RFC 8693
            <code>subject_token</code>
            in the next step.

          </p>

          <div class="status ok">

            Source token inspected for
            <strong>
              {esc(user)}
            </strong>.

          </div>

        </section>


        <div class="card">

          <h2>
            Important source claims
          </h2>

          <pre>
{esc(json.dumps(summary, indent=2, sort_keys=True))}
          </pre>

          <p>

            Token fingerprint:

            <code>
              {esc(fingerprint)}
            </code>

          </p>


          <details>

            <summary>
              Full access token claims
            </summary>

            <pre>
{esc(json.dumps(access, indent=2, sort_keys=True))}
            </pre>

          </details>


          <details>

            <summary>
              Full ID token claims
            </summary>

            <pre>
{esc(json.dumps(identity, indent=2, sort_keys=True))}
            </pre>

          </details>


          <a class="button"
             href="/exchange">

            Exchange for Orders API

          </a>


          <a class="button secondary"
             href="/#exchange">

            Back to demo

          </a>

        </div>
        '''


        return response(
            start_response,
            layout(
                "Current token claims",
                body,
            ),
        )


"""

if not pat.search(s):
    raise SystemExit(
        "ERROR: /claims route not found"
    )

s = pat.sub(
    claims,
    s,
    count=1,
)


# ============================================================
# Evidence + reset routes
# ============================================================

if 'if path == "/exchange-evidence":' not in s:

    marker = '    if path == "/exchange":\n'

    routes = r"""    if path == "/exchange-evidence":

        if not portal_session:

            return response(
                start_response,
                layout(
                    "Not signed in",
                    '<div class="card">'
                    '<h2>Sign in first</h2>'
                    '</div>',
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
            TOKEN_EXCHANGE_EVIDENCE.get(
                user
            )
            if user
            else None
        )


        if not evidence:

            return response(
                start_response,
                layout(
                    "Token Exchange evidence",
                    '''
                    <div class="card">

                      <h2>
                        No Token Exchange evidence yet
                      </h2>

                      <p>
                        Run Exchange for Orders API first.
                      </p>

                      <a class="button"
                         href="/#exchange">
                        Back
                      </a>

                    </div>
                    ''',
                ),
            )


        body = f'''
        <section class="hero">

          <div class="kicker">
            RFC 8693 evidence
          </div>

          <h1>
            Original token vs Orders API token
          </h1>

          <p class="lead">

            RHBK accepted the user's access token as
            the subject token and minted a new access
            token for the requested Orders API audience.

          </p>

          <div class="status ok">
            Token Exchange completed successfully.
          </div>

        </section>


        <div class="token-compare">

          <div class="token-panel source">

            <div class="kicker">
              Original application token
            </div>

            <h2>
              ACME Portal
            </h2>

            <pre>
{esc(json.dumps(evidence["source"], indent=2, sort_keys=True))}
            </pre>

            <p>
              Fingerprint:
              <code>
                {esc(evidence["source_fingerprint"])}
              </code>
            </p>

          </div>


          <div class="token-panel target">

            <div class="kicker">
              Exchanged token
            </div>

            <h2>
              Orders API
            </h2>

            <pre>
{esc(json.dumps(evidence["target"], indent=2, sort_keys=True))}
            </pre>

            <p>
              Fingerprint:
              <code>
                {esc(evidence["target_fingerprint"])}
              </code>
            </p>

          </div>

        </div>


        <div class="card">

          <h2>
            RFC 8693 response metadata
          </h2>

          <pre>
{esc(json.dumps(evidence["response"], indent=2, sort_keys=True))}
          </pre>

          <div class="status ok">

            A different access token was minted and the
            resulting token is valid for

            <strong>
              orders-api
            </strong>.

          </div>

          <a class="button secondary"
             href="/#exchange">

            Back to demo

          </a>

        </div>
        '''


        return response(
            start_response,
            layout(
                "Token Exchange evidence",
                body,
            ),
        )


    if path == "/exchange-reset":

        if portal_session:

            focus, _, _ = claims_focus(
                portal_session
            )

            user = focus.get(
                "user"
            )

            if user:

                TOKEN_EXCHANGE_DEMO_STATE.pop(
                    user,
                    None,
                )

                TOKEN_EXCHANGE_EVIDENCE.pop(
                    user,
                    None,
                )

        else:

            TOKEN_EXCHANGE_DEMO_STATE.clear()

            TOKEN_EXCHANGE_EVIDENCE.clear()


        start_response(
            "302 Found",
            [
                (
                    "Location",
                    "/#exchange",
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
            "ERROR: /exchange route not found"
        )

    s = s.replace(
        marker,
        routes + marker,
        1,
    )


# ============================================================
# Replace actual /exchange route
# ============================================================

pat = re.compile(
    r'    if path == "/exchange":\n'
    r'.*?'
    r'(?='
    r'    if path == "/[^\"]+":'
    r'|'
    r'    return response\('
    r'start_response, '
    r'layout\("ACME Digital Identity"'
    r')',
    re.S,
)


route = r"""    if path == "/exchange":

        if not portal_session:

            return response(
                start_response,
                layout(
                    "Not signed in",
                    '''
                    <div class="card">

                      <h2>
                        Sign in first
                      </h2>

                      <a class="button"
                         href="/login">
                        Sign in
                      </a>

                    </div>
                    ''',
                ),
                "401 Unauthorized",
            )


        source_token = portal_session.get(
            "access_token",
            "",
        )


        if not source_token:

            return response(
                start_response,
                layout(
                    "Token Exchange error",
                    '''
                    <div class="card">

                      <h2>
                        No source access token
                      </h2>

                    </div>
                    ''',
                ),
                "400 Bad Request",
            )


        try:

            original = jwt_claims(
                source_token
            )


            exchanged = token_post(
                CLIENT_ID,
                CLIENT_SECRET,
                {
                    "grant_type":
                        "urn:ietf:params:oauth:"
                        "grant-type:token-exchange",

                    "subject_token":
                        source_token,

                    "subject_token_type":
                        "urn:ietf:params:oauth:"
                        "token-type:access_token",

                    "requested_token_type":
                        "urn:ietf:params:oauth:"
                        "token-type:access_token",

                    "audience":
                        "orders-api",
                },
            )


            exchanged_token = exchanged.get(
                "access_token",
                "",
            )


            if not exchanged_token:

                raise RuntimeError(
                    "RHBK response did not contain "
                    "access_token"
                )


            if exchanged_token == source_token:

                raise RuntimeError(
                    "RHBK did not mint a new token"
                )


            newclaims = jwt_claims(
                exchanged_token
            )


            aud = newclaims.get(
                "aud"
            )


            if isinstance(
                aud,
                str,
            ):

                audiences = {
                    aud
                }

            else:

                audiences = set(
                    aud or []
                )


            if "orders-api" not in audiences:

                raise RuntimeError(
                    "Exchanged token does not contain "
                    "orders-api audience: "
                    + str(aud)
                )


            focus, _, _ = claims_focus(
                portal_session
            )

            user = focus.get(
                "user"
            )


            src_fp = token_fingerprint(
                source_token
            )

            dst_fp = token_fingerprint(
                exchanged_token
            )


            response_meta = {

                "grant_type":
                    "urn:ietf:params:oauth:"
                    "grant-type:token-exchange",

                "requested_audience":
                    "orders-api",

                "issued_token_type":
                    exchanged.get(
                        "issued_token_type"
                    ),

                "token_type":
                    exchanged.get(
                        "token_type"
                    ),

                "expires_in":
                    exchanged.get(
                        "expires_in"
                    ),
            }


            if user:

                st = (
                    TOKEN_EXCHANGE_DEMO_STATE.setdefault(
                        user,
                        {},
                    )
                )

                st[
                    "claims_viewed"
                ] = True

                st[
                    "exchange_complete"
                ] = True


                TOKEN_EXCHANGE_EVIDENCE[
                    user
                ] = {

                    "source":
                        token_exchange_summary(
                            original
                        ),

                    "target":
                        token_exchange_summary(
                            newclaims
                        ),

                    "source_fingerprint":
                        src_fp,

                    "target_fingerprint":
                        dst_fp,

                    "response":
                        response_meta,
                }


            body = f'''
            <section class="hero">

              <div class="kicker">
                OAuth 2.0 Token Exchange
              </div>

              <h1>
                RFC 8693 exchange successful
              </h1>

              <p class="lead">

                RHBK accepted the ACME Portal user's
                access token and minted a new token
                for the Orders API audience.

              </p>

              <div class="status ok">

                <strong>
                  Orders API token issued ✓
                </strong>

              </div>

            </section>


            <div class="token-compare">

              <div class="token-panel source">

                <div class="kicker">
                  Source token
                </div>

                <h2>
                  ACME Portal
                </h2>

                <pre>
{esc(json.dumps(token_exchange_summary(original), indent=2, sort_keys=True))}
                </pre>

                <p>
                  Fingerprint:
                  <code>
                    {esc(src_fp)}
                  </code>
                </p>

              </div>


              <div class="token-panel target">

                <div class="kicker">
                  Exchanged token
                </div>

                <h2>
                  Orders API
                </h2>

                <pre>
{esc(json.dumps(token_exchange_summary(newclaims), indent=2, sort_keys=True))}
                </pre>

                <p>
                  Fingerprint:
                  <code>
                    {esc(dst_fp)}
                  </code>
                </p>

              </div>

            </div>


            <div class="card">

              <h2>
                RFC 8693 response metadata
              </h2>

              <pre>
{esc(json.dumps(response_meta, indent=2, sort_keys=True))}
              </pre>

              <p>

                The different fingerprints prove RHBK
                minted a new signed access token.

                The exchanged token contains:

                <code>
                  aud=orders-api
                </code>.

              </p>


              <a class="button"
                 href="/exchange-evidence">

                Compare token evidence

              </a>


              <a class="button secondary"
                 href="/#exchange">

                Back to demo

              </a>

            </div>
            '''


            return response(
                start_response,
                layout(
                    "Token Exchange",
                    body,
                ),
            )


        except Exception as exc:

            return response(
                start_response,
                layout(
                    "Token Exchange error",
                    f'''
                    <div class="card">

                      <h2>
                        Token Exchange failed
                      </h2>

                      <pre>
{esc(exc)}
                      </pre>

                      <p>

                        Check Standard Token Exchange on

                        <code>
                          acme-portal
                        </code>,

                        the

                        <code>
                          orders-api
                        </code>

                        client and

                        <code>
                          orders-api-audience
                        </code>

                        scope.

                      </p>

                      <a class="button"
                         href="/#exchange">

                        Back

                      </a>

                    </div>
                    ''',
                ),
                "500 Internal Server Error",
            )


"""


if not pat.search(s):

    raise SystemExit(
        "ERROR: /exchange route not found"
    )


s = pat.sub(
    route,
    s,
    count=1,
)


p.write_text(s)

print(
    f"Updated {p}"
)
PY


echo
echo "Checking Python syntax..."

python3 -m py_compile "$APP"

echo "Python syntax: OK"


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


PORTAL_POD=$(oc -n "$NS" get pod \
  -l app=acme-portal \
  -o jsonpath='{.items[0].metadata.name}')

PORTAL="https://$(oc -n "$NS" get route acme-portal \
  -o jsonpath='{.spec.host}')"


echo
echo "Live code check:"

oc -n "$NS" exec "$PORTAL_POD" -- \
  grep -nE \
  'TOKEN_EXCHANGE_DEMO_STATE|exchange-evidence|exchange-reset|exchange-complete' \
  /opt/app/app.py |
head -60


echo
echo "======================================================"
echo " OAuth 2.0 Token Exchange demo updated"
echo "======================================================"
echo
echo "Portal:"
echo "  $PORTAL/#exchange"
echo
echo "Demo:"
echo
echo "  1. View current claims"
echo "     -> GREEN"
echo
echo "  2. Exchange for Orders API"
echo "     -> real RFC 8693 exchange"
echo "     -> validates NEW token"
echo "     -> validates aud=orders-api"
echo "     -> GREEN"
echo
echo "  3. Compare token evidence"
echo "     -> source vs exchanged token"
echo "     -> token fingerprints"
echo "     -> RFC 8693 response metadata"
echo
echo "  4. Reset demo status"
echo "     -> both indicators return to ORANGE"
echo
