#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
KC_URL="https://$(oc -n "$NS" get route acme-keycloak -o jsonpath='{.spec.host}')"
AUD="$KC_URL/realms/acme-demo"

oc -n "$NS" delete pod acme-workload-test --ignore-not-found >/dev/null
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: acme-workload-test
  namespace: $NS
  labels:
    app.kubernetes.io/part-of: acme-rhbk-demo
spec:
  restartPolicy: Never
  serviceAccountName: acme-automation
  containers:
    - name: test
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["/bin/bash","-c"]
      args:
        - |
          TOKEN=$(cat /var/run/secrets/tokens/rhbk-token)
          echo "Requesting RHBK token with projected OpenShift ServiceAccount assertion..."
          curl -skf -X POST '$KC_URL/realms/acme-demo/protocol/openid-connect/token' \\
            -H 'Content-Type: application/x-www-form-urlencoded' \\
            --data-urlencode grant_type=client_credentials \\
            --data-urlencode client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer \\
            --data-urlencode client_assertion="$TOKEN"
      volumeMounts:
        - name: aud-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
  volumes:
    - name: aud-token
      projected:
        defaultMode: 420
        sources:
          - serviceAccountToken:
              audience: '$AUD'
              expirationSeconds: 600
              path: rhbk-token
EOF

oc -n "$NS" wait --for=condition=Ready pod/acme-workload-test --timeout=120s >/dev/null 2>&1 || true
for i in $(seq 1 60); do
  PHASE=$(oc -n "$NS" get pod acme-workload-test -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [[ "$PHASE" == "Succeeded" || "$PHASE" == "Failed" ]] && break
  sleep 2
done
oc -n "$NS" logs acme-workload-test
