#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
APPROVAL=${INSTALL_PLAN_APPROVAL:-Automatic}

oc apply -f manifests/00-namespace.yaml

if oc -n "$NS" get deployment rhbk-operator >/dev/null 2>&1; then
  echo "RHBK Operator already installed in $NS"
  exit 0
fi

if ! oc get packagemanifest rhbk-operator -n openshift-marketplace >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: package manifest rhbk-operator was not found in openshift-marketplace.
Install 'Red Hat build of Keycloak' from OperatorHub into namespace rhbk, then rerun ./scripts/install.sh.
EOF
  exit 1
fi

if [[ -n "${RHBK_CHANNEL:-}" ]]; then
  CHANNEL="$RHBK_CHANNEL"
else
  CHANNEL=$(oc get packagemanifest rhbk-operator -n openshift-marketplace -o json | jq -r '
    [.status.channels[].name | select(test("26\\.6"))][0] // .status.defaultChannel')
fi

if [[ -z "$CHANNEL" || "$CHANNEL" == "null" ]]; then
  echo "ERROR: unable to determine RHBK Operator channel" >&2
  exit 1
fi

echo "Installing rhbk-operator channel=$CHANNEL approval=$APPROVAL"

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: rhbk-operator-group
  namespace: $NS
spec:
  targetNamespaces:
    - $NS
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhbk-operator
  namespace: $NS
spec:
  channel: $CHANNEL
  name: rhbk-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: $APPROVAL
EOF

if [[ "$APPROVAL" == "Manual" ]]; then
  echo "Subscription created with Manual approval. Approve the InstallPlan, then rerun this script/install.sh."
  exit 0
fi

echo "Waiting for RHBK CRD..."
for i in $(seq 1 120); do
  if oc get crd keycloaks.k8s.keycloak.org >/dev/null 2>&1; then break; fi
  sleep 5
done
oc get crd keycloaks.k8s.keycloak.org >/dev/null

for i in $(seq 1 120); do
  if oc -n "$NS" get deployment rhbk-operator >/dev/null 2>&1; then break; fi
  sleep 5
done
oc -n "$NS" wait --for=condition=Available deployment/rhbk-operator --timeout=300s
