#!/usr/bin/env bash
set -euo pipefail

for c in oc curl jq openssl python3; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: required command not found: $c" >&2; exit 1; }
done

oc whoami >/dev/null

echo "Connected as: $(oc whoami)"
echo "API server:   $(oc whoami --show-server)"
echo

if ! oc auth can-i create namespaces | grep -qx yes; then
  echo "ERROR: cluster-admin or equivalent privileges are required for this installer." >&2
  exit 1
fi

if [[ -z "$(oc get storageclass -o name 2>/dev/null | head -1)" ]]; then
  echo "ERROR: no StorageClass found; PostgreSQL PVC cannot be provisioned." >&2
  exit 1
fi

NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
echo "Nodes: $NODE_COUNT"
echo

echo "Current node allocation:"
oc describe node $(oc get nodes -o jsonpath='{.items[0].metadata.name}') 2>/dev/null | sed -n '/Allocated resources:/,/Events:/p' || true

echo
if oc adm top node >/dev/null 2>&1; then
  echo "Current actual usage:"
  oc adm top node || true
fi

echo
cat <<'EOF'
Demo resource requests (excluding the Operator):
  RHBK:       250m CPU / 1Gi memory
  PostgreSQL: 100m CPU / 256Mi memory
  Portal:      50m CPU / 64Mi memory
EOF
