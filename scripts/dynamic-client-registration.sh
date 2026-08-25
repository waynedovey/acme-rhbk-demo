#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib-kcadm.sh
source "$SCRIPT_DIR/lib-kcadm.sh"

command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
acme_kcadm_login

KC_URL="https://$(oc -n "$ACME_NS" get route "$ACME_KC_NAME" -o jsonpath='{.spec.host}')"

IAT_JSON=$(acme_kcadm create clients-initial-access -r acme-demo -s count=1 -s expiration=600 -o)
IAT=$(jq -r '.token // empty' <<<"$IAT_JSON")
[[ -n "$IAT" ]] || { echo "ERROR: RHBK did not return an Initial Access Token" >&2; exit 1; }

echo "Created 10-minute / one-use Initial Access Token. Registering a client..."
RESP=$(curl -skf -X POST "$KC_URL/realms/acme-demo/clients-registrations/openid-connect" \
  -H "Authorization: Bearer $IAT" \
  -H 'Content-Type: application/json' \
  -d '{"client_name":"ACME Self-Service Demo App","redirect_uris":["https://self-service-demo.example/callback"],"grant_types":["authorization_code"],"response_types":["code"],"token_endpoint_auth_method":"client_secret_basic"}')

echo "$RESP" | jq .
