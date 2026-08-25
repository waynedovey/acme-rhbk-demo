#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib-kcadm.sh
source "$SCRIPT_DIR/lib-kcadm.sh"
SA=acme-automation

decode_claim() { python3 - "$1" "$2" <<'PY'
import base64,json,sys
p=sys.argv[1].split('.')[1]; p += '='*(-len(p)%4)
print(json.loads(base64.urlsafe_b64decode(p))[sys.argv[2]])
PY
}

acme_kcadm_login
KC_URL="https://$(oc -n "$ACME_NS" get route "$ACME_KC_NAME" -o jsonpath='{.spec.host}')"

SA_TOKEN=$(oc -n "$ACME_NS" create token "$SA" --duration=10m)
K8S_ISSUER=$(decode_claim "$SA_TOKEN" iss)
K8S_SUB=$(decode_claim "$SA_TOKEN" sub)

echo "Kubernetes issuer: $K8S_ISSUER"
echo "ServiceAccount sub: $K8S_SUB"

if ! acme_kcadm get identity-provider/instances/openshift -r acme-demo >/dev/null 2>&1; then
  PAYLOAD=$(jq -n --arg i "$K8S_ISSUER" '{alias:"openshift",displayName:"OpenShift Workload Identity",providerId:"kubernetes",enabled:true,trustEmail:false,storeToken:false,config:{issuer:$i}}')
  printf '%s' "$PAYLOAD" | acme_kcadm_stdin create identity-provider/instances -r acme-demo -f - >/dev/null
  echo "Created Kubernetes identity provider 'openshift'"
else
  echo "Kubernetes identity provider 'openshift' already exists"
fi

CLIENT=$(acme_kcadm get clients -r acme-demo -q clientId=acme-automation | jq '.[0]')
UUID=$(jq -r '.id // empty' <<<"$CLIENT")
[[ -n "$UUID" ]] || { echo "ERROR: acme-automation client not found" >&2; exit 1; }
UPDATED=$(jq --arg sub "$K8S_SUB" '.clientAuthenticatorType="federated-jwt" | .serviceAccountsEnabled=true | .publicClient=false | .attributes=((.attributes // {}) + {"jwt.credential.issuer":"openshift","jwt.credential.sub":$sub})' <<<"$CLIENT")
printf '%s' "$UPDATED" | acme_kcadm_stdin update "clients/$UUID" -r acme-demo -n -f - >/dev/null

echo "Configured acme-automation for Signed JWT - Federated"
exec "$SCRIPT_DIR/workload-token-test.sh"
