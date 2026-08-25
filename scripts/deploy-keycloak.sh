#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
NAME=acme-keycloak

APPS_DOMAIN=$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')
HOST="${NAME}-${NS}.${APPS_DOMAIN}"
URL="https://${HOST}"

sed "s|__KEYCLOAK_URL__|${URL}|g" manifests/20-keycloak-template.yaml | oc apply -f -

# The operator creates <cr-name>-service. Expose it through an edge Route using
# the OpenShift router certificate so browser WebAuthn/passkeys have HTTPS.
for i in $(seq 1 120); do
  if oc -n "$NS" get service "${NAME}-service" >/dev/null 2>&1; then break; fi
  sleep 5
done
oc -n "$NS" get service "${NAME}-service" >/dev/null

cat <<EOF | oc apply -f -
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ${NAME}
  namespace: ${NS}
  labels:
    app.kubernetes.io/part-of: acme-rhbk-demo
spec:
  host: ${HOST}
  to:
    kind: Service
    name: ${NAME}-service
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

echo "Waiting for Keycloak Ready condition..."
for i in $(seq 1 180); do
  READY=$(oc -n "$NS" get keycloak "$NAME" -o json 2>/dev/null | jq -r '.status.conditions[]? | select(.type=="Ready") | .status' | head -1 | tr '[:upper:]' '[:lower:]')
  if [[ "$READY" == "true" ]]; then
    echo "Keycloak is Ready"
    break
  fi
  if (( i % 12 == 0 )); then
    echo "Still waiting..."
    oc -n "$NS" get pods | sed 's/^/  /'
  fi
  sleep 5
done

READY=$(oc -n "$NS" get keycloak "$NAME" -o json | jq -r '.status.conditions[]? | select(.type=="Ready") | .status' | head -1 | tr '[:upper:]' '[:lower:]')
if [[ "$READY" != "true" ]]; then
  echo "ERROR: Keycloak did not become Ready." >&2
  oc -n "$NS" get pods
  oc -n "$NS" logs statefulset/acme-keycloak --tail=100 2>/dev/null || true
  exit 1
fi

echo "$URL"
