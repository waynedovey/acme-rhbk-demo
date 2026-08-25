#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
KC_NAME=${KEYCLOAK_NAME:-acme-keycloak}

b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
secret_value() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }

KC_HOST=$(oc -n "$NS" get route "$KC_NAME" -o jsonpath='{.spec.host}')
PORTAL_HOST=$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}')
KC_URL="https://${KC_HOST}"
PORTAL_URL="https://${PORTAL_HOST}"
ADMIN_USER=$(secret_value "${KC_NAME}-initial-admin" username)
ADMIN_PASS=$(secret_value "${KC_NAME}-initial-admin" password)
PORTAL_SECRET=$(secret_value acme-demo-secrets portal-client-secret)

ADMIN_TOKEN=$(curl -skf \
  --data-urlencode client_id=admin-cli \
  --data-urlencode username="$ADMIN_USER" \
  --data-urlencode password="$ADMIN_PASS" \
  --data-urlencode grant_type=password \
  "$KC_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token)

api() {
  local method=$1 path=$2; shift 2
  curl -skf -X "$method" -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H 'Content-Type: application/json' "$@" "$KC_URL$path"
}

if ! api GET /admin/realms/acme-demo >/dev/null 2>&1; then
  echo "Realm acme-demo does not exist; run ./scripts/bootstrap-demo.sh first." >&2
  exit 1
fi

UUID=$(api GET '/admin/realms/acme-demo/clients?clientId=acme-portal' | jq -r '.[0].id // empty')
PAYLOAD=$(jq -n --arg s "$PORTAL_SECRET" --arg r "$PORTAL_URL/callback" --arg o "$PORTAL_URL" '{
  clientId:"acme-portal",
  name:"ACME Portal",
  enabled:true,
  protocol:"openid-connect",
  publicClient:false,
  secret:$s,
  clientAuthenticatorType:"client-secret",
  consentRequired:true,
  standardFlowEnabled:true,
  directAccessGrantsEnabled:true,
  redirectUris:[$r],
  webOrigins:[$o],
  attributes:{"standard.token.exchange.enabled":"true"}
}')

if [[ -z "$UUID" ]]; then
  echo "Creating missing acme-demo/acme-portal client..."
  api POST /admin/realms/acme-demo/clients -d "$PAYLOAD" >/dev/null
  UUID=$(api GET '/admin/realms/acme-demo/clients?clientId=acme-portal' | jq -r '.[0].id // empty')
else
  echo "Reconciling existing acme-demo/acme-portal client..."
  CURRENT=$(api GET "/admin/realms/acme-demo/clients/$UUID")
  MERGED=$(jq -s '.[0] * .[1]' <(printf '%s' "$CURRENT") <(printf '%s' "$PAYLOAD"))
  api PUT "/admin/realms/acme-demo/clients/$UUID" -d "$MERGED" >/dev/null
fi

if [[ -z "$UUID" ]]; then
  echo "ERROR: client still missing after repair." >&2
  exit 1
fi

# Keep the running Portal pointed at the same Keycloak Route.
oc -n "$NS" set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" >/dev/null
oc -n "$NS" rollout status deployment/acme-portal --timeout=180s >/dev/null

echo
echo "Portal client repaired."
echo "  RHBK:     $KC_URL"
echo "  Portal:   $PORTAL_URL"
echo "  Client:   acme-portal"
echo "  Redirect: $PORTAL_URL/callback"
