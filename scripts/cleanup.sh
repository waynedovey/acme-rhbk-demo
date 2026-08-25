#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
cat <<EOF
This will delete namespace '$NS' and all ACME demo data in it, including PostgreSQL.
EOF
if [[ "${FORCE:-false}" != "true" ]]; then
  read -r -p "Type DELETE to continue: " answer
  [[ "$answer" == "DELETE" ]] || { echo "Cancelled"; exit 0; }
fi
oc delete namespace "$NS" --ignore-not-found

echo "Namespace deleted. Cluster-scoped RHBK CRDs are intentionally not deleted."
