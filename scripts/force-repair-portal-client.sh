#!/usr/bin/env bash
set -euo pipefail

NS=${NAMESPACE:-rhbk}
KC_NAME=${KEYCLOAK_NAME:-acme-keycloak}
REALM=${REALM:-acme-demo}
CLIENT_ID=${CLIENT_ID:-acme-portal}

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
for c in oc curl jq python3; do need "$c"; done

b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
secret_value() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }

KC_HOST=$(oc -n "$NS" get route "$KC_NAME" -o jsonpath='{.spec.host}')
PORTAL_HOST=$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}')
KC_URL="https://${KC_HOST}"
PORTAL_URL="https://${PORTAL_HOST}"
CALLBACK="${PORTAL_URL}/callback"

ADMIN_USER=$(secret_value "${KC_NAME}-initial-admin" username)
ADMIN_PASS=$(secret_value "${KC_NAME}-initial-admin" password)
PORTAL_SECRET=$(secret_value acme-demo-secrets portal-client-secret)

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

request() {
  local method=$1 url=$2 outfile=$3; shift 3
  curl -skS -o "$outfile" -w '%{http_code}' -X "$method" "$@" "$url"
}

echo "RHBK:   $KC_URL"
echo "Portal: $PORTAL_URL"
echo

echo "[1/7] Checking realm discovery endpoint..."
DISC_CODE=$(request GET "$KC_URL/realms/$REALM/.well-known/openid-configuration" "$TMP/discovery")
if [[ "$DISC_CODE" != "200" ]]; then
  echo "ERROR: realm discovery returned HTTP $DISC_CODE" >&2
  cat "$TMP/discovery" >&2
  exit 1
fi
echo "      Realm $REALM is reachable."

echo "[2/7] Getting an admin token..."
TOKEN_CODE=$(curl -skS -o "$TMP/token" -w '%{http_code}' \
  --data-urlencode client_id=admin-cli \
  --data-urlencode username="$ADMIN_USER" \
  --data-urlencode password="$ADMIN_PASS" \
  --data-urlencode grant_type=password \
  "$KC_URL/realms/master/protocol/openid-connect/token")
if [[ "$TOKEN_CODE" != "200" ]]; then
  echo "ERROR: admin token request returned HTTP $TOKEN_CODE" >&2
  cat "$TMP/token" | jq . 2>/dev/null || cat "$TMP/token"
  exit 1
fi
ADMIN_TOKEN=$(jq -r '.access_token // empty' "$TMP/token")
[[ -n "$ADMIN_TOKEN" ]] || { echo "ERROR: no admin access token returned" >&2; exit 1; }
echo "      Admin authentication OK."

admin_request() {
  local method=$1 path=$2 outfile=$3; shift 3
  request "$method" "$KC_URL$path" "$outfile" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H 'Content-Type: application/json' "$@"
}

echo "[3/7] Looking for $REALM/$CLIENT_ID..."
LOOKUP_CODE=$(admin_request GET "/admin/realms/$REALM/clients?clientId=$CLIENT_ID" "$TMP/lookup")
if [[ "$LOOKUP_CODE" != "200" ]]; then
  echo "ERROR: client lookup returned HTTP $LOOKUP_CODE" >&2
  cat "$TMP/lookup" >&2
  exit 1
fi
UUID=$(jq -r '.[0].id // empty' "$TMP/lookup")

PAYLOAD=$(jq -n \
  --arg id "$CLIENT_ID" --arg s "$PORTAL_SECRET" --arg cb "$CALLBACK" --arg origin "$PORTAL_URL" \
  '{clientId:$id,name:"ACME Portal",enabled:true,protocol:"openid-connect",publicClient:false,clientAuthenticatorType:"client-secret",secret:$s,standardFlowEnabled:true,directAccessGrantsEnabled:false,serviceAccountsEnabled:false,consentRequired:true,rootUrl:$origin,baseUrl:$origin,redirectUris:[$cb],webOrigins:[$origin],attributes:{"standard.token.exchange.enabled":"true"}}')

if [[ -z "$UUID" ]]; then
  echo "      Client is genuinely missing. Creating it now..."
  CREATE_CODE=$(admin_request POST "/admin/realms/$REALM/clients" "$TMP/create" -d "$PAYLOAD")
  if [[ "$CREATE_CODE" != "201" && "$CREATE_CODE" != "204" ]]; then
    echo "ERROR: client create returned HTTP $CREATE_CODE" >&2
    cat "$TMP/create" >&2
    exit 1
  fi
  LOOKUP_CODE=$(admin_request GET "/admin/realms/$REALM/clients?clientId=$CLIENT_ID" "$TMP/lookup2")
  UUID=$(jq -r '.[0].id // empty' "$TMP/lookup2")
else
  echo "      Found UUID: $UUID. Replacing demo-critical settings..."
  GET_CODE=$(admin_request GET "/admin/realms/$REALM/clients/$UUID" "$TMP/current")
  [[ "$GET_CODE" == "200" ]] || { echo "ERROR: could not read client HTTP $GET_CODE" >&2; cat "$TMP/current" >&2; exit 1; }
  MERGED=$(jq -s '.[0] * .[1]' "$TMP/current" <(printf '%s' "$PAYLOAD"))
  PUT_CODE=$(admin_request PUT "/admin/realms/$REALM/clients/$UUID" "$TMP/update" -d "$MERGED")
  if [[ "$PUT_CODE" != "204" ]]; then
    echo "ERROR: client update returned HTTP $PUT_CODE" >&2
    cat "$TMP/update" >&2
    exit 1
  fi
fi

[[ -n "$UUID" ]] || { echo "ERROR: create succeeded but client lookup is still empty" >&2; exit 1; }
echo "      Client UUID: $UUID"

echo "[4/7] Ensuring optional consent scopes exist and are attached..."
ensure_scope() {
  local name=$1 text=$2
  local code sid
  code=$(admin_request GET "/admin/realms/$REALM/client-scopes" "$TMP/scopes")
  [[ "$code" == "200" ]] || { echo "ERROR: scope list HTTP $code" >&2; exit 1; }
  sid=$(jq -r --arg n "$name" '.[] | select(.name==$n) | .id' "$TMP/scopes" | head -1)
  if [[ -z "$sid" ]]; then
    SP=$(jq -n --arg n "$name" --arg t "$text" '{name:$n,protocol:"openid-connect",attributes:{"display.on.consent.screen":"true","consent.screen.text":$t,"include.in.token.scope":"true"}}')
    sc=$(admin_request POST "/admin/realms/$REALM/client-scopes" "$TMP/scope-create" -d "$SP")
    [[ "$sc" == "201" || "$sc" == "204" ]] || { echo "ERROR: create scope $name HTTP $sc" >&2; cat "$TMP/scope-create" >&2; exit 1; }
    admin_request GET "/admin/realms/$REALM/client-scopes" "$TMP/scopes" >/dev/null
    sid=$(jq -r --arg n "$name" '.[] | select(.name==$n) | .id' "$TMP/scopes" | head -1)
  fi
  [[ -n "$sid" ]] || { echo "ERROR: could not resolve scope UUID for $name" >&2; exit 1; }
  ac=$(admin_request PUT "/admin/realms/$REALM/clients/$UUID/optional-client-scopes/$sid" "$TMP/attach-$name" -d '{}')
  if [[ "$ac" != "204" && "$ac" != "409" ]]; then
    echo "ERROR: attach scope $name HTTP $ac" >&2
    cat "$TMP/attach-$name" >&2
    exit 1
  fi
}
ensure_scope personal-details 'Read your basic ACME profile details'
ensure_scope orders-history 'Read your ACME order history'
ensure_scope support-profile 'Read information required for customer support'
echo "      Consent scopes OK."

echo "[5/7] Verifying the client from the Admin API..."
VERIFY_CODE=$(admin_request GET "/admin/realms/$REALM/clients/$UUID" "$TMP/client")
[[ "$VERIFY_CODE" == "200" ]] || { echo "ERROR: verify client HTTP $VERIFY_CODE" >&2; exit 1; }
jq '{clientId,enabled,protocol,publicClient,standardFlowEnabled,consentRequired,redirectUris,webOrigins}' "$TMP/client"

if [[ "$(jq -r '.clientId' "$TMP/client")" != "$CLIENT_ID" || "$(jq -r '.enabled' "$TMP/client")" != "true" ]]; then
  echo "ERROR: client exists but is not enabled as expected" >&2
  exit 1
fi

echo "[6/7] Reconciling the running Portal configuration..."
oc -n "$NS" set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" REALM="$REALM" CLIENT_ID="$CLIENT_ID" >/dev/null
oc -n "$NS" rollout status deployment/acme-portal --timeout=180s >/dev/null
echo "      Portal deployment OK."

echo "[7/7] Testing the exact OIDC authorization request..."
AUTH_CODE=$(curl -skS -o "$TMP/auth" -w '%{http_code}' -G \
  "$KC_URL/realms/$REALM/protocol/openid-connect/auth" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "redirect_uri=$CALLBACK" \
  --data-urlencode 'response_type=code' \
  --data-urlencode 'scope=openid profile email personal-details' \
  --data-urlencode 'state=acme-repair-test')

if grep -qi 'Client not found' "$TMP/auth"; then
  echo "ERROR: RHBK still says 'Client not found' even though Admin API returned UUID $UUID." >&2
  echo "HTTP $AUTH_CODE" >&2
  echo "This strongly suggests the browser Route is reaching a different Keycloak backend/configuration than the Admin API call." >&2
  exit 1
fi

if grep -qi 'Invalid parameter: redirect_uri\|Invalid redirect_uri' "$TMP/auth"; then
  echo "ERROR: client is found, but RHBK rejected the redirect URI: $CALLBACK" >&2
  exit 1
fi

echo "      Authorization endpoint returned HTTP $AUTH_CODE and DID NOT return 'Client not found'."
echo
echo "SUCCESS"
echo "  Client:   $REALM/$CLIENT_ID"
echo "  UUID:     $UUID"
echo "  Callback: $CALLBACK"
echo "  Portal:   $PORTAL_URL"
echo
echo "Open the Portal in a fresh/private browser window:"
echo "  $PORTAL_URL"
