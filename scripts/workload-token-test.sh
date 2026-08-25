#!/usr/bin/env bash
set -euo pipefail

NS="${NAMESPACE:-rhbk}"
KC_NAME="${KEYCLOAK_NAME:-acme-keycloak}"
SA="${SERVICE_ACCOUNT:-acme-automation}"
EXPECTED_CLIENT="${WORKLOAD_CLIENT:-acme-automation}"
TEST_POD="${TEST_POD:-acme-workload-test}"
TOKEN_PATH="/var/run/secrets/tokens/rhbk-token"
TOKEN_EXPIRATION=600

for cmd in oc jq curl; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd is required" >&2; exit 1; }; done

KC_PUBLIC="https://$(oc -n "$NS" get route "$KC_NAME" -o jsonpath='{.spec.host}')"
PORTAL_URL="https://$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}')"
REALM_ISSUER="${KC_PUBLIC}/realms/acme-demo"
TOKEN_URL="http://${KC_NAME}-service:8080/realms/acme-demo/protocol/openid-connect/token"
DEMO_KEY=$(oc -n "$NS" get secret acme-demo-secrets -o jsonpath='{.data.portal-client-secret}' | base64 -d)

echo
echo "======================================================"
echo " ACME OpenShift Workload Identity Demo"
echo "======================================================"
echo
echo "Namespace:                 $NS"
echo "ServiceAccount:            $SA"
echo "Expected RHBK client:      $EXPECTED_CLIENT"
echo "Projected token lifetime:  ${TOKEN_EXPIRATION} seconds"
echo

# Clear stale green demo state first.
curl -skS -o /dev/null "${PORTAL_URL}/workload-reset" || true

echo "STEP 1 - Verify OpenShift ServiceAccount"
echo "----------------------------------------"
oc -n "$NS" get sa "$SA" >/dev/null
echo "ServiceAccount exists ✓"
echo

oc -n "$NS" delete pod "$TEST_POD" --ignore-not-found --wait=true >/dev/null

echo "STEP 2 - Project short-lived ServiceAccount token"
echo "-------------------------------------------------"
cat <<YAML | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${TEST_POD}
  namespace: ${NS}
  labels:
    app.kubernetes.io/name: acme-workload-test
    app.kubernetes.io/part-of: acme-rhbk-demo
spec:
  restartPolicy: Never
  serviceAccountName: ${SA}
  automountServiceAccountToken: false
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: workload
      image: registry.access.redhat.com/ubi9/python-311:latest
      imagePullPolicy: IfNotPresent
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        capabilities:
          drop: ["ALL"]
      env:
        - name: RHBK_TOKEN_URL
          value: "${TOKEN_URL}"
        - name: EXPECTED_CLIENT_ID
          value: "${EXPECTED_CLIENT}"
        - name: TOKEN_FILE
          value: "${TOKEN_PATH}"
        - name: DEMO_NAMESPACE
          value: "${NS}"
        - name: DEMO_SERVICE_ACCOUNT
          value: "${SA}"
      command: ["/bin/bash","-c"]
      args:
        - |
          set -euo pipefail
          python3 - <<'PY'
          import base64, datetime, hashlib, json, os, urllib.error, urllib.parse, urllib.request

          def jwt_claims(token):
              try:
                  part=token.split('.')[1]; part += '='*(-len(part)%4)
                  return json.loads(base64.urlsafe_b64decode(part.encode()).decode())
              except Exception:
                  return {}

          def fp(token):
              return hashlib.sha256(token.encode()).hexdigest()[:16]

          token_file=os.environ['TOKEN_FILE']
          token_url=os.environ['RHBK_TOKEN_URL']
          expected_client=os.environ['EXPECTED_CLIENT_ID']
          namespace=os.environ['DEMO_NAMESPACE']
          service_account=os.environ['DEMO_SERVICE_ACCOUNT']

          if not os.path.exists(token_file):
              raise SystemExit('ERROR: projected token was not mounted')
          assertion=open(token_file,encoding='utf-8').read().strip()
          a=jwt_claims(assertion)
          lifetime=(a.get('exp')-a.get('iat')) if isinstance(a.get('exp'),int) and isinstance(a.get('iat'),int) else None

          print('Projected token found ✓')
          print('Kubernetes issuer:', a.get('iss'))
          print('Federated subject:', a.get('sub'))
          print('Audience:', a.get('aud'))
          print('Lifetime:', lifetime, 'seconds')
          print()
          print('Client authentication: Signed JWT - Federated')
          print('Permanent RHBK client secret: NONE')
          print('Explicit client_id parameter: NOT SENT')
          print()

          form={
              'grant_type':'client_credentials',
              'client_assertion_type':'urn:ietf:params:oauth:client-assertion-type:jwt-bearer',
              'client_assertion':assertion,
          }
          req=urllib.request.Request(token_url,data=urllib.parse.urlencode(form).encode(),headers={'Content-Type':'application/x-www-form-urlencoded'},method='POST')
          try:
              with urllib.request.urlopen(req,timeout=30) as r:
                  http_status=r.status; body=json.loads(r.read().decode())
          except urllib.error.HTTPError as exc:
              print('RHBK rejected workload authentication.')
              print('HTTP status:', exc.code)
              print(exc.read().decode(errors='replace'))
              raise SystemExit(1)

          token=body.get('access_token')
          if http_status != 200 or not token:
              raise SystemExit('ERROR: RHBK did not return an access token')
          c=jwt_claims(token)
          azp=c.get('azp') or expected_client
          if c.get('azp') and c.get('azp') != expected_client:
              raise SystemExit(f'ERROR: token azp {c.get("azp")} != {expected_client}')

          print('RHBK workload authentication successful ✓')
          print('Resolved RHBK client:', azp)
          print('OAuth HTTP status:', http_status)
          print('OAuth token lifetime:', body.get('expires_in'), 'seconds')
          print()

          evidence={
              'status':'success',
              'created_at':datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
              'namespace':namespace,
              'service_account':service_account,
              'federated_subject':a.get('sub'),
              'kubernetes_issuer':a.get('iss'),
              'assertion_audience':a.get('aud'),
              'assertion_lifetime_seconds':lifetime,
              'assertion_fingerprint':fp(assertion),
              'projected_token_path':token_file,
              'client_id':azp,
              'identity_provider':'openshift',
              'client_authentication':'Signed JWT - Federated',
              'client_secret_used':False,
              'client_id_parameter_sent':False,
              'oauth_grant_type':'client_credentials',
              'oauth_http_status':http_status,
              'access_token_type':body.get('token_type'),
              'access_token_expires_in':body.get('expires_in'),
              'access_token_scope':body.get('scope'),
              'access_token_issuer':c.get('iss'),
              'access_token_subject':c.get('sub'),
              'access_token_audience':c.get('aud'),
              'access_token_authorized_party':c.get('azp'),
              'access_token_fingerprint':fp(token),
          }
          print('WORKLOAD_EVIDENCE_JSON='+json.dumps(evidence,separators=(',',':')))
          PY
      volumeMounts:
        - name: rhbk-token
          mountPath: /var/run/secrets/tokens
          readOnly: true
  volumes:
    - name: rhbk-token
      projected:
        defaultMode: 420
        sources:
          - serviceAccountToken:
              audience: "${REALM_ISSUER}"
              expirationSeconds: ${TOKEN_EXPIRATION}
              path: rhbk-token
YAML

echo "Workload Pod created ✓"
echo

echo "STEP 3 - Federated client authentication"
echo "----------------------------------------"
PHASE=""
for _ in $(seq 1 90); do
  PHASE=$(oc -n "$NS" get pod "$TEST_POD" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  case "$PHASE" in Succeeded|Failed) break;; esac
  sleep 2
done
LOGS=$(oc -n "$NS" logs "$TEST_POD" 2>&1 || true)
printf '%s\n' "$LOGS"
if [[ "$PHASE" != "Succeeded" ]]; then
  echo; echo "WORKLOAD IDENTITY FAILED - Portal remains ORANGE."; exit 1
fi

EVIDENCE=$(printf '%s\n' "$LOGS" | sed -n 's/^WORKLOAD_EVIDENCE_JSON=//p' | tail -1)
jq -e '.status=="success" and .oauth_http_status==200 and .client_secret_used==false and .client_id_parameter_sent==false' <<<"$EVIDENCE" >/dev/null

echo
echo "STEP 4 - Update Portal evidence"
echo "-------------------------------"
PORTAL_HTTP=$(curl -skS -o /dev/null -w '%{http_code}' -X POST "${PORTAL_URL}/api/demo/workload" -H "X-ACME-Demo-Key: ${DEMO_KEY}" -H 'Content-Type: application/json' --data "$EVIDENCE")
[[ "$PORTAL_HTTP" == "200" ]] || { echo "ERROR: Portal evidence callback HTTP $PORTAL_HTTP" >&2; exit 1; }
echo "Portal status updated to GREEN ✓"
echo

echo "======================================================"
echo " OpenShift Workload Identity SUCCESS"
echo "======================================================"
echo "OpenShift identity:             $(jq -r '.federated_subject' <<<"$EVIDENCE")"
echo "RHBK client:                    $EXPECTED_CLIENT"
echo "Authentication:                 Signed JWT - Federated"
echo "Projected ServiceAccount JWT:   ${TOKEN_EXPIRATION} seconds"
echo "RHBK OAuth access token:        $(jq -r '.access_token_expires_in' <<<"$EVIDENCE") seconds"
echo "Permanent RHBK client secret:   NONE ✓"
echo "Explicit client_id sent:        NO ✓"
echo "Portal:                         ${PORTAL_URL}/#workload"
