#!/usr/bin/env bash
# Idempotent optional SA Government scenario. Existing eight ACME demos are untouched.
set -euo pipefail
cd "$(dirname "$0")/.."
NS=rhbk
for bin in oc jq openssl python3; do command -v "$bin" >/dev/null || { echo "Missing $bin" >&2; exit 1; }; done
oc whoami >/dev/null
oc -n "$NS" get keycloak acme-keycloak >/dev/null || {
  echo "Install the original ACME demo first: ./scripts/install.sh" >&2; exit 1;
}
if ! oc -n "$NS" get secret sagov-demo-secrets >/dev/null 2>&1; then
  echo "Generating isolated SA Government demo secrets"
  oc -n "$NS" create secret generic sagov-demo-secrets \
    --from-literal=mysagov-client-secret="$(openssl rand -hex 24)" \
    --from-literal=reader-client-secret="$(openssl rand -hex 24)" \
    --from-literal=idx-broker-secret="$(openssl rand -hex 24)" \
    --from-literal=dit-broker-secret="$(openssl rand -hex 24)" \
    --from-literal=myid-broker-secret="$(openssl rand -hex 24)" \
    --from-literal=dit-demo-password="$(openssl rand -hex 12)" \
    --from-literal=trumps-api-key="$(openssl rand -hex 24)"
else
  echo "Keeping existing sagov-demo-secrets (no rotation)"
fi

oc -n "$NS" create configmap sagov-portal-code --from-file=app.py=sagov/mysagov/app.py \
  --dry-run=client -o yaml | oc apply -f -
oc -n "$NS" create configmap sagov-trumps-code --from-file=app.py=sagov/trumps/app.py \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f manifests/50-sagov.yaml

KC_URL="https://$(oc -n "$NS" get route acme-keycloak -o jsonpath='{.spec.host}')"
PORTAL_URL="https://$(oc -n "$NS" get route sagov-portal -o jsonpath='{.spec.host}')"
oc -n "$NS" set env deployment/sagov-portal RHBK_PUBLIC_URL="$KC_URL" SAGOV_PORTAL_URL="$PORTAL_URL" >/dev/null
./scripts/bootstrap-sagov.sh
oc -n "$NS" rollout restart deployment/sagov-portal deployment/sagov-trumps >/dev/null
oc -n "$NS" rollout status deployment/sagov-portal --timeout=240s
oc -n "$NS" rollout status deployment/sagov-trumps --timeout=240s
oc -n "$NS" rollout status deployment/sagov-mailpit --timeout=240s

echo
echo "SA Government demo ready. Run ./scripts/sagov-demo-info.sh for URLs."
echo "WARNING: Mailpit contains synthetic sign-up/reset links. Lab use only."
