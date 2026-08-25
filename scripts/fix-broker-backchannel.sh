#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

NS=${NAMESPACE:-rhbk}
KC_NAME=${KEYCLOAK_NAME:-acme-keycloak}
PORTAL_DEPLOYMENT=${PORTAL_DEPLOYMENT:-acme-portal}
POD=${KEYCLOAK_POD:-${KC_NAME}-0}
KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/acme-demo-kcadm.config

need() { command -v "$1" >/dev/null || { echo "ERROR: $1 is required" >&2; exit 1; }; }
need python3
need jq
need openssl

for f in portal/app.py manifests/30-portal.yaml scripts/apply-demo-update.sh scripts/bootstrap-demo.sh scripts/generate-secrets.sh scripts/repair-portal.sh; do
  [[ -f "$f" ]] || { echo "ERROR: missing $f" >&2; exit 1; }
done

stamp=$(date +%Y%m%d-%H%M%S)
backup_dir=".broker-fix-backup-$stamp"
mkdir -p "$backup_dir/portal" "$backup_dir/manifests" "$backup_dir/scripts"
cp portal/app.py "$backup_dir/portal/app.py"
cp manifests/30-portal.yaml "$backup_dir/manifests/30-portal.yaml"
cp scripts/{apply-demo-update.sh,bootstrap-demo.sh,generate-secrets.sh,repair-portal.sh} "$backup_dir/scripts/"

echo "Backup: $backup_dir"

python3 <<'PY'
from pathlib import Path
import re

p = Path("portal/app.py")
s = p.read_text()

# Separate browser-facing Keycloak URL from server-to-server token endpoint.
if "KEYCLOAK_BACKCHANNEL_URL" not in s:
    needle = 'KEYCLOAK_URL = os.environ.get("KEYCLOAK_URL", "").rstrip("/")\n'
    if needle not in s:
        raise SystemExit("ERROR: could not locate KEYCLOAK_URL in portal/app.py")
    s = s.replace(
        needle,
        needle + '\nKEYCLOAK_BACKCHANNEL_URL = os.environ.get(\n'
                 '    "KEYCLOAK_BACKCHANNEL_URL",\n'
                 '    KEYCLOAK_URL,\n'
                 ').rstrip("/")\n',
        1,
    )

# All OAuth token calls from the Portal are back-channel calls.
s = s.replace(
    'f"{KEYCLOAK_URL}/realms/{REALM}/protocol/openid-connect/token"',
    'f"{KEYCLOAK_BACKCHANNEL_URL}/realms/{REALM}/protocol/openid-connect/token"',
)

# Support the three demo IdPs.
s = re.sub(
    r'if idp in \{[^\n]*"legacy-idp"[^\n]*\}:\n\s+extras\["kc_idp_hint"\] = idp',
    'if idp in {"legacy-idp", "partner-idp", "corporate-idp"}:\n'
    '            extras["kc_idp_hint"] = idp\n'
    '            extras["prompt"] = "login"',
    s,
    count=1,
)

# Make the broker chooser repeatable even if RHBK SSO already exists.
old_login = '''    if path == "/login":
        scope = query.get("scope", ["openid profile email"])[0]
        extras = {}
        idp = query.get("idp", [""])[0]
        if idp in {"legacy-idp", "partner-idp", "corporate-idp"}:
            extras["kc_idp_hint"] = idp
            extras["prompt"] = "login"
        return auth_redirect(start_response, base, CLIENT_ID, "/callback", scope=scope, extras=extras, purpose="portal")
'''
new_login = '''    if path == "/login":
        scope = query.get("scope", ["openid profile email"])[0]
        extras = {}
        idp = query.get("idp", [""])[0]
        force = query.get("force", ["0"])[0] == "1"

        if idp in {"legacy-idp", "partner-idp", "corporate-idp"}:
            extras["kc_idp_hint"] = idp
            extras["prompt"] = "login"
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
if old_login in s:
    s = s.replace(old_login, new_login, 1)
elif 'force = query.get("force"' not in s:
    raise SystemExit("ERROR: /login handler did not match expected code; refusing partial patch")

# Generic broker buttons: legacy / partner / corporate.
s = s.replace('href="/login">Open broker chooser</a>', 'href="/login?force=1">Open broker chooser</a>')
s = s.replace('>Microsoft Entra ID (simulated)</a>', '>Partner Identity</a>')
if 'href="/login?idp=corporate-idp"' not in s:
    marker = '<a class="button secondary" href="/login?idp=partner-idp">Partner Identity</a>'
    if marker not in s:
        raise SystemExit("ERROR: could not locate Partner Identity button")
    s = s.replace(
        marker,
        marker + '<a class="button secondary" href="/login?idp=corporate-idp">Corporate Identity</a>',
        1,
    )

# Distinguish authorization-code exchange failures from RFC 8693 token exchange failures.
s = s.replace(
    '<div class="card"><h2>Token exchange failed</h2><pre>{esc(exc)}</pre><a class="button" href="/">Back to demo</a></div>',
    '<div class="card"><h2>Login token exchange failed</h2><p>RHBK authentication completed, but the Portal could not exchange the authorization code for tokens.</p><pre>{esc(exc)}</pre><a class="button" href="/">Back to demo</a></div>',
    1,
)

p.write_text(s)
PY

python3 <<'PY'
from pathlib import Path
p = Path("manifests/30-portal.yaml")
s = p.read_text()
if "KEYCLOAK_BACKCHANNEL_URL" not in s:
    needle = '''            - name: KEYCLOAK_URL
              value: ""
'''
    replacement = '''            - name: KEYCLOAK_URL
              value: ""
            - name: KEYCLOAK_BACKCHANNEL_URL
              value: "http://acme-keycloak-service:8080"
'''
    if needle not in s:
        raise SystemExit("ERROR: could not locate KEYCLOAK_URL env in manifests/30-portal.yaml")
    s = s.replace(needle, replacement, 1)
p.write_text(s)
PY

python3 <<'PY'
from pathlib import Path
p = Path("scripts/apply-demo-update.sh")
s = p.read_text()
old = 'oc -n "$NS" set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" >/dev/null'
new = 'oc -n "$NS" set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" KEYCLOAK_BACKCHANNEL_URL="http://acme-keycloak-service:8080" >/dev/null'
if old in s:
    s = s.replace(old, new, 1)
elif "KEYCLOAK_BACKCHANNEL_URL" not in s:
    raise SystemExit("ERROR: could not patch scripts/apply-demo-update.sh")
p.write_text(s)
PY

python3 <<'PY'
from pathlib import Path
p = Path("scripts/repair-portal.sh")
s = p.read_text()
old = '''echo "Setting $PORTAL KEYCLOAK_URL=$KC_URL"
oc -n "$NS" set env deployment/$PORTAL KEYCLOAK_URL="$KC_URL"
'''
new = '''KC_INTERNAL="http://${KC_NAME}-service:8080"
echo "Setting $PORTAL browser URL:     $KC_URL"
echo "Setting $PORTAL back-channel URL: $KC_INTERNAL"
oc -n "$NS" set env deployment/$PORTAL \\
  KEYCLOAK_URL="$KC_URL" \\
  KEYCLOAK_BACKCHANNEL_URL="$KC_INTERNAL"
'''
if old in s:
    s = s.replace(old, new, 1)
# Expand final environment check.
s = s.replace("grep -E '^KEYCLOAK_URL=' || true", "grep -E '^KEYCLOAK(_BACKCHANNEL)?_URL=' || true")
p.write_text(s)
PY

python3 <<'PY'
from pathlib import Path
p = Path("scripts/generate-secrets.sh")
s = p.read_text()

if "CORPORATE_SECRET=$(randhex)" not in s:
    s = s.replace("  PARTNER_SECRET=$(randhex)\n", "  PARTNER_SECRET=$(randhex)\n  CORPORATE_SECRET=$(randhex)\n", 1)
if '--from-literal=corporate-broker-secret="$CORPORATE_SECRET"' not in s:
    s = s.replace(
        '    --from-literal=partner-broker-secret="$PARTNER_SECRET"',
        '    --from-literal=partner-broker-secret="$PARTNER_SECRET" \\\n    --from-literal=corporate-broker-secret="$CORPORATE_SECRET"',
        1,
    )

if "Added corporate-broker-secret" not in s:
    anchor = '''  if [[ -z "$(oc -n "$NS" get secret acme-demo-secrets -o jsonpath='{.data.peoplesoft-client-secret}' 2>/dev/null || true)" ]]; then
    PEOPLESOFT_SECRET=$(randhex)
    oc -n "$NS" patch secret acme-demo-secrets --type=merge \\
      -p "$(jq -n --arg s "$PEOPLESOFT_SECRET" '{stringData:{"peoplesoft-client-secret":$s}}')" >/dev/null
    echo "Added peoplesoft-client-secret to existing acme-demo-secrets"
  fi
'''
    extra = anchor + '''

  if [[ -z "$(oc -n "$NS" get secret acme-demo-secrets -o jsonpath='{.data.corporate-broker-secret}' 2>/dev/null || true)" ]]; then
    CORPORATE_SECRET=$(randhex)
    oc -n "$NS" patch secret acme-demo-secrets --type=merge \\
      -p "$(jq -n --arg s "$CORPORATE_SECRET" '{stringData:{"corporate-broker-secret":$s}}')" >/dev/null
    echo "Added corporate-broker-secret to existing acme-demo-secrets"
  fi
'''
    if anchor not in s:
        raise SystemExit("ERROR: could not locate upgrade block in scripts/generate-secrets.sh")
    s = s.replace(anchor, extra, 1)

p.write_text(s)
PY

python3 <<'PY'
from pathlib import Path
import re
p = Path("scripts/bootstrap-demo.sh")
s = p.read_text()

if 'KC_INTERNAL="http://${KC_NAME}-service:8080"' not in s:
    s = s.replace('KC_URL="https://${KC_HOST}"\n', 'KC_URL="https://${KC_HOST}"\nKC_INTERNAL="http://${KC_NAME}-service:8080"\n', 1)

s = s.replace(
    'oc -n "$NS" set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" >/dev/null',
    'oc -n "$NS" set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" KEYCLOAK_BACKCHANNEL_URL="$KC_INTERNAL" >/dev/null',
    1,
)

if 'CORPORATE_SECRET=$(secret_value acme-demo-secrets corporate-broker-secret)' not in s:
    s = s.replace(
        'PARTNER_SECRET=$(secret_value acme-demo-secrets partner-broker-secret)\n',
        'PARTNER_SECRET=$(secret_value acme-demo-secrets partner-broker-secret)\nCORPORATE_SECRET=$(secret_value acme-demo-secrets corporate-broker-secret)\n',
        1,
    )

new_func = r'''ensure_idp() {
  local alias=$1 display=$2 provider_realm=$3 secret=$4
  local payload

  payload=$(jq -n \
    --arg a "$alias" \
    --arg d "$display" \
    --arg s "$secret" \
    --arg public "$KC_URL" \
    --arg internal "$KC_INTERNAL" \
    --arg pr "$provider_realm" \
    '{
      alias:$a,
      displayName:$d,
      providerId:"keycloak-oidc",
      enabled:true,
      trustEmail:true,
      storeToken:true,
      linkOnly:false,
      hideOnLogin:false,
      firstBrokerLoginFlowAlias:"first broker login",
      config:{
        clientId:"acme-broker",
        clientSecret:$s,
        authorizationUrl:($public+"/realms/"+$pr+"/protocol/openid-connect/auth"),
        tokenUrl:($internal+"/realms/"+$pr+"/protocol/openid-connect/token"),
        logoutUrl:($public+"/realms/"+$pr+"/protocol/openid-connect/logout"),
        userInfoUrl:($internal+"/realms/"+$pr+"/protocol/openid-connect/userinfo"),
        jwksUrl:($internal+"/realms/"+$pr+"/protocol/openid-connect/certs"),
        issuer:($public+"/realms/"+$pr),
        useJwksUrl:"true",
        validateSignature:"true",
        syncMode:"IMPORT",
        showInAccountConsole:"ALWAYS"
      }
    }')

  if kcadm get "identity-provider/instances/$alias" -r acme-demo >/dev/null 2>&1; then
    printf '%s' "$payload" | kcadm_stdin update "identity-provider/instances/$alias" -r acme-demo -n -f - >/dev/null
    echo "Reconciled identity provider: $alias -> $display"
  else
    printf '%s' "$payload" | kcadm_stdin create identity-provider/instances -r acme-demo -f - >/dev/null
    echo "Created identity provider: $alias"
  fi
}
'''

pattern = re.compile(r'ensure_idp\(\) \{.*?\n\}\n\n(?=flow_id\(\))', re.S)
if not pattern.search(s):
    raise SystemExit("ERROR: could not locate ensure_idp() in scripts/bootstrap-demo.sh")
s = pattern.sub(new_func + '\n', s, count=1)

if 'ensure_realm corporate-idp "Corporate Identity"' not in s:
    s = s.replace('ensure_realm partner-idp "Partner Identity"\n', 'ensure_realm partner-idp "Partner Identity"\nensure_realm corporate-idp "Corporate Identity"\n', 1)
if 'ensure_user corporate-idp alex alex@acme.example "$DEMO_PASS"' not in s:
    s = s.replace('ensure_user partner-idp alex alex@acme.example "$DEMO_PASS"\n', 'ensure_user partner-idp alex alex@acme.example "$DEMO_PASS"\nensure_user corporate-idp alex alex@acme.example "$DEMO_PASS"\n', 1)

partner_client = 'ensure_client partner-idp acme-broker "$(jq -n --arg s "$PARTNER_SECRET" --arg r "$BROKER_REDIRECT_BASE/partner-idp/endpoint" \'{clientId:"acme-broker",name:"ACME Broker",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,standardFlowEnabled:true,redirectUris:[$r]}\')"\n'
if 'ensure_client corporate-idp acme-broker' not in s:
    corporate_client = 'ensure_client corporate-idp acme-broker "$(jq -n --arg s "$CORPORATE_SECRET" --arg r "$BROKER_REDIRECT_BASE/corporate-idp/endpoint" \'{clientId:"acme-broker",name:"ACME Broker",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,standardFlowEnabled:true,redirectUris:[$r]}\')"\n'
    if partner_client not in s:
        raise SystemExit("ERROR: could not locate partner broker client line")
    s = s.replace(partner_client, partner_client + corporate_client, 1)

s = s.replace('ensure_idp partner-idp "Microsoft Entra ID (simulated)" partner-idp "$PARTNER_SECRET"', 'ensure_idp partner-idp "Partner Identity" partner-idp "$PARTNER_SECRET"')
if 'ensure_idp corporate-idp "Corporate Identity"' not in s:
    marker = 'ensure_idp partner-idp "Partner Identity" partner-idp "$PARTNER_SECRET"\n'
    if marker not in s:
        raise SystemExit("ERROR: could not locate partner ensure_idp call")
    s = s.replace(marker, marker + 'ensure_idp corporate-idp "Corporate Identity" corporate-idp "$CORPORATE_SECRET"\n', 1)

p.write_text(s)
PY

chmod +x scripts/*.sh

echo "Source patch complete."

if [[ "${PATCH_ONLY:-0}" == "1" ]]; then
  echo "PATCH_ONLY=1: not touching OpenShift."
  exit 0
fi

need oc
oc whoami >/dev/null 2>&1 || { echo "ERROR: not logged in to OpenShift" >&2; exit 1; }

echo "Ensuring secrets..."
./scripts/generate-secrets.sh

KC_HOST=$(oc -n "$NS" get route "$KC_NAME" -o jsonpath='{.spec.host}')
KC_URL="https://${KC_HOST}"
KC_INTERNAL="http://${KC_NAME}-service:8080"
PORTAL_HOST=$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}')
PORTAL_URL="https://${PORTAL_HOST}"

echo "Applying Portal code and deployment..."
oc -n "$NS" create configmap acme-portal-code --from-file=app.py=portal/app.py --dry-run=client -o yaml | oc apply -f -
oc apply -f manifests/30-portal.yaml >/dev/null
oc -n "$NS" set env deployment/$PORTAL_DEPLOYMENT \
  KEYCLOAK_URL="$KC_URL" \
  KEYCLOAK_BACKCHANNEL_URL="$KC_INTERNAL" >/dev/null
oc -n "$NS" rollout restart deployment/$PORTAL_DEPLOYMENT >/dev/null
oc -n "$NS" rollout status deployment/$PORTAL_DEPLOYMENT --timeout=180s

# Authenticate kcadm for a targeted broker reconciliation only.
b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
secret_value() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }

ADMIN_USER=$(secret_value "${KC_NAME}-initial-admin" username)
ADMIN_PASS=$(secret_value "${KC_NAME}-initial-admin" password)
DEMO_PASS=$(secret_value acme-demo-secrets demo-user-password)
LEGACY_SECRET=$(secret_value acme-demo-secrets legacy-broker-secret)
PARTNER_SECRET=$(secret_value acme-demo-secrets partner-broker-secret)
CORPORATE_SECRET=$(secret_value acme-demo-secrets corporate-broker-secret)

oc -n "$NS" exec "$POD" -- \
  "$KCADM" config credentials \
  --config "$CFG" \
  --server http://localhost:8080 \
  --realm master \
  --user "$ADMIN_USER" \
  --password "$ADMIN_PASS" >/dev/null

kcadm() { oc -n "$NS" exec "$POD" -- "$KCADM" "$@" --config "$CFG"; }
kcadm_stdin() { oc -n "$NS" exec -i "$POD" -- "$KCADM" "$@" --config "$CFG"; }

ensure_realm_live() {
  local realm=$1 display=$2
  if ! kcadm get "realms/$realm" >/dev/null 2>&1; then
    jq -n --arg r "$realm" --arg d "$display" '{realm:$r,displayName:$d,enabled:true,registrationAllowed:false,resetPasswordAllowed:true,rememberMe:true}' |
      kcadm_stdin create realms -f - >/dev/null
    echo "Created realm: $realm"
  fi
}

ensure_user_live() {
  local realm=$1
  local id
  id=$(kcadm get users -r "$realm" -q username=alex | jq -r '.[0].id // empty')
  if [[ -z "$id" ]]; then
    jq -n --arg p "$DEMO_PASS" '{username:"alex",email:"alex@acme.example",emailVerified:true,enabled:true,firstName:"Alex",lastName:"Demo",credentials:[{type:"password",value:$p,temporary:false}]}' |
      kcadm_stdin create users -r "$realm" -f - >/dev/null
    echo "Created user: $realm/alex"
  fi
}

client_uuid_live() {
  kcadm get clients -r "$1" -q clientId="$2" | jq -r '.[0].id // empty'
}

ensure_broker_client_live() {
  local realm=$1 alias=$2 secret=$3
  local callback="$KC_URL/realms/acme-demo/broker/$alias/endpoint"
  local payload uuid current merged
  payload=$(jq -n --arg s "$secret" --arg r "$callback" '{clientId:"acme-broker",name:"ACME Broker",enabled:true,protocol:"openid-connect",publicClient:false,clientAuthenticatorType:"client-secret",secret:$s,standardFlowEnabled:true,directAccessGrantsEnabled:false,serviceAccountsEnabled:false,redirectUris:[$r]}')
  uuid=$(client_uuid_live "$realm" acme-broker)
  if [[ -z "$uuid" ]]; then
    printf '%s' "$payload" | kcadm_stdin create clients -r "$realm" -f - >/dev/null
    echo "Created broker client: $realm/acme-broker"
  else
    current=$(kcadm get "clients/$uuid" -r "$realm")
    merged=$(jq -s '.[0] * .[1]' <(printf '%s' "$current") <(printf '%s' "$payload"))
    printf '%s' "$merged" | kcadm_stdin update "clients/$uuid" -r "$realm" -n -f - >/dev/null
    echo "Reconciled broker client: $realm/acme-broker"
  fi
}

ensure_idp_live() {
  local alias=$1 display=$2 provider_realm=$3 secret=$4
  local payload
  payload=$(jq -n \
    --arg a "$alias" --arg d "$display" --arg s "$secret" \
    --arg public "$KC_URL" --arg internal "$KC_INTERNAL" --arg pr "$provider_realm" '
    {
      alias:$a,displayName:$d,providerId:"keycloak-oidc",enabled:true,
      trustEmail:true,storeToken:true,linkOnly:false,hideOnLogin:false,
      firstBrokerLoginFlowAlias:"first broker login",
      config:{
        clientId:"acme-broker",clientSecret:$s,
        authorizationUrl:($public+"/realms/"+$pr+"/protocol/openid-connect/auth"),
        tokenUrl:($internal+"/realms/"+$pr+"/protocol/openid-connect/token"),
        logoutUrl:($public+"/realms/"+$pr+"/protocol/openid-connect/logout"),
        userInfoUrl:($internal+"/realms/"+$pr+"/protocol/openid-connect/userinfo"),
        jwksUrl:($internal+"/realms/"+$pr+"/protocol/openid-connect/certs"),
        issuer:($public+"/realms/"+$pr),
        useJwksUrl:"true",validateSignature:"true",syncMode:"IMPORT",showInAccountConsole:"ALWAYS"
      }
    }')

  if kcadm get "identity-provider/instances/$alias" -r acme-demo >/dev/null 2>&1; then
    printf '%s' "$payload" | kcadm_stdin update "identity-provider/instances/$alias" -r acme-demo -n -f - >/dev/null
    echo "Reconciled IdP: $alias"
  else
    printf '%s' "$payload" | kcadm_stdin create identity-provider/instances -r acme-demo -f - >/dev/null
    echo "Created IdP: $alias"
  fi
}

for spec in "legacy-idp|Legacy Identity" "partner-idp|Partner Identity" "corporate-idp|Corporate Identity"; do
  realm=${spec%%|*}
  display=${spec#*|}
  ensure_realm_live "$realm" "$display"
  ensure_user_live "$realm"
done

ensure_broker_client_live legacy-idp legacy-idp "$LEGACY_SECRET"
ensure_broker_client_live partner-idp partner-idp "$PARTNER_SECRET"
ensure_broker_client_live corporate-idp corporate-idp "$CORPORATE_SECRET"

ensure_idp_live legacy-idp "Legacy Identity" legacy-idp "$LEGACY_SECRET"
ensure_idp_live partner-idp "Partner Identity" partner-idp "$PARTNER_SECRET"
ensure_idp_live corporate-idp "Corporate Identity" corporate-idp "$CORPORATE_SECRET"

echo
echo "Verification"
echo "============"
PORTAL_POD=$(oc -n "$NS" get pod -l app=acme-portal -o jsonpath='{.items[0].metadata.name}')

echo
echo "Portal environment:"
oc -n "$NS" exec "$PORTAL_POD" -- env | grep -E '^KEYCLOAK(_BACKCHANNEL)?_URL='

echo
echo "Internal RHBK discovery from Portal pod:"
oc -n "$NS" exec "$PORTAL_POD" -- python3 -c \
  'import urllib.request; u="http://acme-keycloak-service:8080/realms/acme-demo/.well-known/openid-configuration"; r=urllib.request.urlopen(u,timeout=10); print("HTTP",r.status)'

echo
echo "Broker endpoints:"
kcadm get identity-provider/instances -r acme-demo | jq -r '.[] | select(.alias=="legacy-idp" or .alias=="partner-idp" or .alias=="corporate-idp") | [.alias,.config.authorizationUrl,.config.tokenUrl] | @tsv'

echo
echo "Portal broker redirects:"
for alias in legacy-idp partner-idp corporate-idp; do
  printf '%-18s ' "$alias"
  curl -sk -D - -o /dev/null "$PORTAL_URL/login?idp=$alias" | awk 'BEGIN{IGNORECASE=1} /^location:/ {print; exit}'
done

echo
echo "Fix complete."
echo "Start each browser test from: $PORTAL_URL"
echo "Do not reuse old /callback?code=... URLs; authorization codes are single-use."
