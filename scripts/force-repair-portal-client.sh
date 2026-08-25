#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
NS=${NAMESPACE:-rhbk}
REALM=${REALM:-acme-demo}
CLIENT_ID=${CLIENT_ID:-acme-portal}

"$SCRIPT_DIR/repair-portal-client.sh"

KC_URL="https://$(oc -n "$NS" get route acme-keycloak -o jsonpath='{.spec.host}')"
PORTAL_URL="https://$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}')"
CALLBACK="$PORTAL_URL/callback"
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT

AUTH_CODE=$(curl -skS -o "$TMP" -w '%{http_code}' -G \
  "$KC_URL/realms/$REALM/protocol/openid-connect/auth" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "redirect_uri=$CALLBACK" \
  --data-urlencode 'response_type=code' \
  --data-urlencode 'scope=openid profile email personal-details' \
  --data-urlencode 'state=acme-repair-test')

if grep -qi 'Client not found' "$TMP"; then
  echo "ERROR: authorization endpoint still says Client not found" >&2
  exit 1
fi
if grep -qi 'Invalid parameter: redirect_uri\|Invalid redirect_uri' "$TMP"; then
  echo "ERROR: RHBK rejected redirect URI $CALLBACK" >&2
  exit 1
fi

echo
echo "SUCCESS: authorization endpoint HTTP $AUTH_CODE; client and redirect URI were accepted."
echo "Portal: $PORTAL_URL"
