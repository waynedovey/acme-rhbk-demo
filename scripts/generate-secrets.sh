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
  PEOPLESOFT_SECRET=$(randhex)
  CLI_SECRET=$(randhex)
  LEGACY_SECRET=$(randhex)
  PARTNER_SECRET=$(randhex)
  CORPORATE_SECRET=$(randhex)
  oc -n "$NS" create secret generic acme-demo-secrets \
    --from-literal=demo-user-password="$DEMO_PASSWORD" \
    --from-literal=portal-client-secret="$PORTAL_SECRET" \
    --from-literal=peoplesoft-client-secret="$PEOPLESOFT_SECRET" \
    --from-literal=cli-client-secret="$CLI_SECRET" \
    --from-literal=legacy-broker-secret="$LEGACY_SECRET" \
    --from-literal=partner-broker-secret="$PARTNER_SECRET" \
    --from-literal=corporate-broker-secret="$CORPORATE_SECRET"
else
  echo "Secret acme-demo-secrets already exists"

  # Upgrade path for older demo bundles. Do not rotate any existing secret;
  # only add the PeopleSoft client secret when the key is missing.
  if [[ -z "$(oc -n "$NS" get secret acme-demo-secrets -o jsonpath='{.data.peoplesoft-client-secret}' 2>/dev/null || true)" ]]; then
    PEOPLESOFT_SECRET=$(randhex)
    oc -n "$NS" patch secret acme-demo-secrets --type=merge \
      -p "$(jq -n --arg s "$PEOPLESOFT_SECRET" '{stringData:{"peoplesoft-client-secret":$s}}')" >/dev/null
    echo "Added peoplesoft-client-secret to existing acme-demo-secrets"
  fi

  if [[ -z "$(oc -n "$NS" get secret acme-demo-secrets -o jsonpath='{.data.corporate-broker-secret}' 2>/dev/null || true)" ]]; then
    CORPORATE_SECRET=$(randhex)
    oc -n "$NS" patch secret acme-demo-secrets --type=merge \
      -p "$(jq -n --arg s "$CORPORATE_SECRET" '{stringData:{"corporate-broker-secret":$s}}')" >/dev/null
    echo "Added corporate-broker-secret to existing acme-demo-secrets"
  fi
fi
