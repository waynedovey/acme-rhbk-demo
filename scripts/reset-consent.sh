#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
val() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }
KC_URL="https://$(oc -n "$NS" get route acme-keycloak -o jsonpath='{.spec.host}')"
ADMIN_USER=$(val acme-keycloak-initial-admin username)
ADMIN_PASS=$(val acme-keycloak-initial-admin password)
ADMIN_TOKEN=$(curl -skf --data-urlencode client_id=admin-cli --data-urlencode username="$ADMIN_USER" --data-urlencode password="$ADMIN_PASS" --data-urlencode grant_type=password "$KC_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token)
api() { local method=$1 path=$2; shift 2; curl -skf -X "$method" -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' "$@" "$KC_URL$path"; }
USER_ID=$(api GET '/admin/realms/acme-demo/users?username=alex&exact=true' | jq -r '.[0].id')
CLIENT_UUID=$(api GET '/admin/realms/acme-demo/clients?clientId=acme-portal' | jq -r '.[0].id')
api DELETE "/admin/realms/acme-demo/users/$USER_ID/consents/$CLIENT_UUID" >/dev/null 2>&1 || true
echo "Cleared saved acme-portal consent for user alex. The next authorization request can show consent again."
