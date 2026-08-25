#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
NS=${NAMESPACE:-rhbk}

command -v oc >/dev/null || { echo "oc is required" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

if ! oc whoami >/dev/null 2>&1; then
  echo "Not logged in to OpenShift. Run oc login first." >&2
  exit 1
fi

if ! oc -n "$NS" get keycloak acme-keycloak >/dev/null 2>&1; then
  echo "Existing ACME RHBK demo was not found in namespace $NS." >&2
  echo "For a new environment use ./scripts/install.sh instead." >&2
  exit 1
fi

./scripts/generate-secrets.sh

echo "Checking RHBK Admin CLI authentication..."
./scripts/verify-admin-cli.sh

oc -n "$NS" create configmap acme-portal-code --from-file=app.py=portal/app.py \
  --dry-run=client -o yaml | oc apply -f -
oc apply -f manifests/30-portal.yaml

KC_HOST=$(oc -n "$NS" get route acme-keycloak -o jsonpath='{.spec.host}')
KC_URL="https://${KC_HOST}"
oc -n "$NS" set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" >/dev/null

oc -n "$NS" rollout restart deployment/acme-portal >/dev/null
oc -n "$NS" rollout status deployment/acme-portal --timeout=180s

./scripts/bootstrap-demo.sh

cat <<MSG

PeopleSoft step-up update applied.

Next:
  1. Run ./scripts/demo-info.sh
  2. Open the ACME Portal
  3. Use "Register / verify passkey"
  4. Sign in normally to establish SSO
  5. Click "Open PeopleSoft — require Touch ID / passkey"
MSG
