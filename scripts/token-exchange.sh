#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
val() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }
decode_jwt() { python3 - "$1" <<'PY'
import base64,json,sys
p=sys.argv[1].split('.')[1]; p += '='*(-len(p)%4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p)),indent=2,sort_keys=True))
PY
}

KC_URL="https://$(oc -n "$NS" get route acme-keycloak -o jsonpath='{.spec.host}')"
USER_PASS=$(val acme-demo-secrets demo-user-password)
CLIENT_SECRET=$(val acme-demo-secrets cli-client-secret)
TOKEN_EP="$KC_URL/realms/acme-demo/protocol/openid-connect/token"

USER_TOKEN=$(curl -skf -X POST "$TOKEN_EP" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=password \
  --data-urlencode client_id=acme-cli \
  --data-urlencode client_secret="$CLIENT_SECRET" \
  --data-urlencode username=alex \
  --data-urlencode password="$USER_PASS" | jq -r .access_token)

echo "Original token claims:"
decode_jwt "$USER_TOKEN"

echo
echo "Exchanging for orders-api audience..."
RESP=$(curl -skf -X POST "$TOKEN_EP" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  --data-urlencode client_id=acme-cli \
  --data-urlencode client_secret="$CLIENT_SECRET" \
  --data-urlencode subject_token="$USER_TOKEN" \
  --data-urlencode subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  --data-urlencode requested_token_type=urn:ietf:params:oauth:token-type:access_token \
  --data-urlencode audience=orders-api)

echo "$RESP" | jq '{expires_in, token_type, issued_token_type, scope}'
EXCHANGED=$(jq -r .access_token <<<"$RESP")
echo
echo "Exchanged token claims:"
decode_jwt "$EXCHANGED"
