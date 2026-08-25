#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}

randhex() { openssl rand -hex 18; }

if ! oc -n "$NS" get secret keycloak-db-secret >/dev/null 2>&1; then
  DB_PASSWORD=$(randhex)
  oc -n "$NS" create secret generic keycloak-db-secret \
    --from-literal=username=keycloak \
    --from-literal=password="$DB_PASSWORD"
else
  echo "Secret keycloak-db-secret already exists"
fi

if ! oc -n "$NS" get secret acme-demo-secrets >/dev/null 2>&1; then
  DEMO_PASSWORD=$(randhex)
  PORTAL_SECRET=$(randhex)
  CLI_SECRET=$(randhex)
  LEGACY_SECRET=$(randhex)
  PARTNER_SECRET=$(randhex)
  oc -n "$NS" create secret generic acme-demo-secrets \
    --from-literal=demo-user-password="$DEMO_PASSWORD" \
    --from-literal=portal-client-secret="$PORTAL_SECRET" \
    --from-literal=cli-client-secret="$CLI_SECRET" \
    --from-literal=legacy-broker-secret="$LEGACY_SECRET" \
    --from-literal=partner-broker-secret="$PARTNER_SECRET"
else
  echo "Secret acme-demo-secrets already exists"
fi
