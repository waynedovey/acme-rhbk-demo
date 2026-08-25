#!/usr/bin/env bash
set -euo pipefail

NS="${RHBK_NAMESPACE:-rhbk}"
DEPLOY="postgres-db"
PVC="postgres-data"

cat <<'EOF'
WARNING: This is a destructive DEMO recovery.
It deletes the PostgreSQL PVC and therefore removes all RHBK database data.
Use it only when the ACME demo database is disposable.
EOF

if [[ "${1:-}" != "--yes" ]]; then
  echo
  echo "Re-run with: ./scripts/reset-postgres.sh --yes"
  exit 2
fi

echo "Scaling PostgreSQL to zero..."
oc -n "$NS" scale deployment/$DEPLOY --replicas=0
oc -n "$NS" wait --for=delete pod -l app=postgres-db --timeout=120s 2>/dev/null || true

echo "Deleting damaged demo PVC $PVC..."
oc -n "$NS" delete pvc "$PVC" --ignore-not-found

echo "Re-applying PostgreSQL with Recreate strategy..."
oc apply -f manifests/10-postgres.yaml

echo "Waiting for PostgreSQL..."
oc -n "$NS" rollout status deployment/$DEPLOY --timeout=300s

echo "Restarting Keycloak so it reconnects to the clean database..."
oc -n "$NS" delete pod acme-keycloak-0 --ignore-not-found

echo
cat <<'EOF'
PostgreSQL has been rebuilt.
Because the Keycloak database was reset, wait for RHBK to become Ready and then re-run:

  ./scripts/bootstrap-demo.sh

Then verify with:

  ./scripts/demo-info.sh
EOF
