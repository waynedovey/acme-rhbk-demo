#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
val() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }

KC_URL="https://$(oc -n "$NS" get route acme-keycloak -o jsonpath='{.spec.host}')"
ADMIN_USER=$(val acme-keycloak-initial-admin username)
ADMIN_PASS=$(val acme-keycloak-initial-admin password)
ADMIN_TOKEN=$(curl -skf --data-urlencode client_id=admin-cli --data-urlencode username="$ADMIN_USER" --data-urlencode password="$ADMIN_PASS" --data-urlencode grant_type=password "$KC_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token)

IAT=$(curl -skf -X POST "$KC_URL/admin/realms/acme-demo/clients-initial-access" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' \
  -d '{"count":1,"expiration":600}' | jq -r .token)

echo "Created 10-minute / one-use Initial Access Token. Registering a client..."
RESP=$(curl -skf -X POST "$KC_URL/realms/acme-demo/clients-registrations/openid-connect" \
  -H "Authorization: Bearer $IAT" -H 'Content-Type: application/json' \
  -d '{"client_name":"ACME Self-Service Demo App","redirect_uris":["https://self-service-demo.example/callback"],"grant_types":["authorization_code"],"response_types":["code"],"token_endpoint_auth_method":"client_secret_basic"}')

echo "$RESP" | jq .
