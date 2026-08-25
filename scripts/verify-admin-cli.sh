#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
KC_NAME=${KEYCLOAK_NAME:-acme-keycloak}
POD=${KEYCLOAK_POD:-${KC_NAME}-0}
KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/acme-demo-kcadm-check.config
b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
ADMIN_USER=$(oc -n "$NS" get secret "${KC_NAME}-initial-admin" -o jsonpath='{.data.username}' | b64d)
ADMIN_PASS=$(oc -n "$NS" get secret "${KC_NAME}-initial-admin" -o jsonpath='{.data.password}' | b64d)
oc -n "$NS" exec "$POD" -- "$KCADM" config credentials --config "$CFG" --server http://localhost:8080 --realm master --user "$ADMIN_USER" --password "$ADMIN_PASS" >/dev/null
oc -n "$NS" exec "$POD" -- "$KCADM" get serverinfo --config "$CFG" | jq '{systemInfo:{version:.systemInfo.version},providers:(.providers | keys | length)}'
echo "Admin CLI authentication: OK"
