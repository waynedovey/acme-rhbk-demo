#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/preflight.sh
./scripts/install-operator.sh

# If Manual approval was requested and the deployment does not exist yet, stop cleanly.
if ! oc -n rhbk get deployment rhbk-operator >/dev/null 2>&1; then
  echo "RHBK Operator is not running yet. Approve its InstallPlan and rerun ./scripts/install.sh."
  exit 0
fi

./scripts/generate-secrets.sh

oc apply -f manifests/10-postgres.yaml
oc -n rhbk rollout status deployment/postgres-db --timeout=300s

./scripts/deploy-keycloak.sh

# Build the ConfigMap directly from the readable Python source, then deploy the portal.
oc -n rhbk create configmap acme-portal-code --from-file=app.py=portal/app.py \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f manifests/30-portal.yaml

# The browser-facing OIDC authorization endpoint must use the external RHBK Route.
# Set it before bootstrap so a later bootstrap failure cannot leave placeholder/broken links.
KC_HOST=$(oc -n rhbk get route acme-keycloak -o jsonpath='{.spec.host}')
KC_URL="https://${KC_HOST}"
oc -n rhbk set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" >/dev/null

# Restart on reruns so ConfigMap source and environment changes are picked up immediately.
oc -n rhbk rollout restart deployment/acme-portal >/dev/null
oc -n rhbk rollout status deployment/acme-portal --timeout=180s

oc apply -f manifests/40-workload-identity.yaml

./scripts/bootstrap-demo.sh
./scripts/demo-info.sh
