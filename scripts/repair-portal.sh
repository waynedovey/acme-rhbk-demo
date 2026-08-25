#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
KC_NAME=${KEYCLOAK_NAME:-acme-keycloak}
PORTAL=${PORTAL_DEPLOYMENT:-acme-portal}

KC_HOST=$(oc -n "$NS" get route "$KC_NAME" -o jsonpath='{.spec.host}')
if [[ -z "$KC_HOST" ]]; then
  echo "ERROR: unable to determine route/$KC_NAME host in namespace $NS" >&2
  exit 1
fi
KC_URL="https://${KC_HOST}"

echo "Setting $PORTAL KEYCLOAK_URL=$KC_URL"
oc -n "$NS" set env deployment/$PORTAL KEYCLOAK_URL="$KC_URL" KEYCLOAK_BACKCHANNEL_URL="http://acme-keycloak-service:8080"
oc -n "$NS" rollout status deployment/$PORTAL --timeout=180s

echo
echo "Portal environment:"
oc -n "$NS" set env deployment/$PORTAL --list | grep -E '^KEYCLOAK_URL=' || true

echo
echo "Portal URL: https://$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}')"
