#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib-kcadm.sh
source "$SCRIPT_DIR/lib-kcadm.sh"
acme_kcadm_login

KC_HOST=$(oc -n "$ACME_NS" get route "$ACME_KC_NAME" -o jsonpath='{.spec.host}')
PORTAL_HOST=$(oc -n "$ACME_NS" get route acme-portal -o jsonpath='{.spec.host}')
KC_URL="https://${KC_HOST}"
PORTAL_URL="https://${PORTAL_HOST}"
PORTAL_SECRET=$(acme_secret_value acme-demo-secrets portal-client-secret)

acme_kcadm get realms/acme-demo >/dev/null 2>&1 || {
  echo "Realm acme-demo does not exist; run ./scripts/bootstrap-demo.sh first." >&2
  exit 1
}

UUID=$(acme_kcadm get clients -r acme-demo -q clientId=acme-portal | jq -r '.[0].id // empty')
PAYLOAD=$(jq -n --arg s "$PORTAL_SECRET" --arg r "$PORTAL_URL/callback" --arg o "$PORTAL_URL" '{
  clientId:"acme-portal",name:"ACME Portal",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,
  clientAuthenticatorType:"client-secret",consentRequired:true,standardFlowEnabled:true,directAccessGrantsEnabled:true,
  redirectUris:[$r],webOrigins:[$o],attributes:{"standard.token.exchange.enabled":"true"}
}')

if [[ -z "$UUID" ]]; then
  echo "Creating missing acme-demo/acme-portal client..."
  printf '%s' "$PAYLOAD" | acme_kcadm_stdin create clients -r acme-demo -f - >/dev/null
  UUID=$(acme_kcadm get clients -r acme-demo -q clientId=acme-portal | jq -r '.[0].id // empty')
else
  echo "Reconciling existing acme-demo/acme-portal client..."
  CURRENT=$(acme_kcadm get "clients/$UUID" -r acme-demo)
  MERGED=$(jq -s '.[0] * .[1]' <(printf '%s' "$CURRENT") <(printf '%s' "$PAYLOAD"))
  printf '%s' "$MERGED" | acme_kcadm_stdin update "clients/$UUID" -r acme-demo -n -f - >/dev/null
fi

[[ -n "$UUID" ]] || { echo "ERROR: client still missing after repair." >&2; exit 1; }

oc -n "$ACME_NS" set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" >/dev/null
oc -n "$ACME_NS" rollout status deployment/acme-portal --timeout=180s >/dev/null

echo
echo "Portal client repaired."
echo "  RHBK:     $KC_URL"
echo "  Portal:   $PORTAL_URL"
echo "  Client:   acme-portal"
echo "  Redirect: $PORTAL_URL/callback"
