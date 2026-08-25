#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
KC_NAME=acme-keycloak
SA=acme-automation

b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
val() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }
decode_claim() { python3 - "$1" "$2" <<'PY'
import base64,json,sys
p=sys.argv[1].split('.')[1]; p += '='*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p))[sys.argv[2]])
PY
}

KC_URL="https://$(oc -n "$NS" get route "$KC_NAME" -o jsonpath='{.spec.host}')"
ADMIN_USER=$(val "${KC_NAME}-initial-admin" username)
ADMIN_PASS=$(val "${KC_NAME}-initial-admin" password)

SA_TOKEN=$(oc -n "$NS" create token "$SA" --duration=10m)
K8S_ISSUER=$(decode_claim "$SA_TOKEN" iss)
K8S_SUB=$(decode_claim "$SA_TOKEN" sub)

echo "Kubernetes issuer: $K8S_ISSUER"
echo "ServiceAccount sub: $K8S_SUB"

ADMIN_TOKEN=$(curl -skf \
  --data-urlencode client_id=admin-cli \
  --data-urlencode username="$ADMIN_USER" \
  --data-urlencode password="$ADMIN_PASS" \
  --data-urlencode grant_type=password \
  "$KC_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token)

api() { local method=$1 path=$2; shift 2; curl -skf -X "$method" -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Content-Type: application/json' "$@" "$KC_URL$path"; }

if ! api GET /admin/realms/acme-demo/identity-provider/instances/openshift >/dev/null 2>&1; then
  api POST /admin/realms/acme-demo/identity-provider/instances -d "$(jq -n --arg i "$K8S_ISSUER" '{alias:"openshift",displayName:"OpenShift Workload Identity",providerId:"kubernetes",enabled:true,trustEmail:false,storeToken:false,config:{issuer:$i}}')" >/dev/null
  echo "Created Kubernetes identity provider 'openshift'"
else
  echo "Kubernetes identity provider 'openshift' already exists"
fi

CLIENT=$(api GET '/admin/realms/acme-demo/clients?clientId=acme-automation' | jq '.[0]')
UUID=$(jq -r .id <<<"$CLIENT")
UPDATED=$(jq --arg sub "$K8S_SUB" '.clientAuthenticatorType="federated-jwt" | .serviceAccountsEnabled=true | .publicClient=false | .attributes=((.attributes // {}) + {"jwt.credential.issuer":"openshift","jwt.credential.sub":$sub})' <<<"$CLIENT")
api PUT "/admin/realms/acme-demo/clients/$UUID" -d "$UPDATED" >/dev/null

echo "Configured acme-automation for Signed JWT - Federated"
exec "$(dirname "$0")/workload-token-test.sh"
