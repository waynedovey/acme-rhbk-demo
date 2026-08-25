#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
source "$SCRIPT_DIR/lib-kcadm.sh"
for cmd in oc curl jq openssl python3; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd is required" >&2; exit 1; }; done

REALM=acme-demo
IAT_EXPIRATION=600
IAT_COUNT=1
SUFFIX=$(date +%Y%m%d%H%M%S)
CLIENT_ID="acme-self-service-${SUFFIX}"
CLIENT_NAME="ACME Self-Service Demo App ${SUFFIX}"
SECOND_CLIENT_ID="acme-reuse-attempt-${SUFFIX}"
REDIRECT_URI="https://self-service-demo.example/callback"

acme_kcadm_login
KC_PUBLIC="https://$(oc -n "$ACME_NS" get route "$ACME_KC_NAME" -o jsonpath='{.spec.host}')"
PORTAL_URL="https://$(oc -n "$ACME_NS" get route acme-portal -o jsonpath='{.spec.host}')"
DEMO_KEY=$(acme_secret_value acme-demo-secrets portal-client-secret)
TMP=$(mktemp -d); PF_PID=""
cleanup(){ [[ -n "$PF_PID" ]] && kill "$PF_PID" >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

LOCAL_PORT=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)
oc -n "$ACME_NS" port-forward "svc/${ACME_KC_NAME}-service" "${LOCAL_PORT}:8080" >"$TMP/pf.log" 2>&1 & PF_PID=$!
KC_INTERNAL="http://127.0.0.1:${LOCAL_PORT}"
for _ in $(seq 1 30); do
  [[ "$(curl -sS -o /dev/null -w '%{http_code}' "${KC_INTERNAL}/realms/${REALM}/.well-known/openid-configuration" 2>/dev/null || true)" == 200 ]] && break
  sleep 1
done
curl -sSf "${KC_INTERNAL}/realms/${REALM}/.well-known/openid-configuration" >/dev/null
REGISTRATION_ENDPOINT="${KC_INTERNAL}/realms/${REALM}/clients-registrations/default"
CANONICAL_ENDPOINT="${KC_PUBLIC}/realms/${REALM}/clients-registrations/default"

echo
echo "======================================================"
echo " ACME API-driven onboarding demo"
echo "======================================================"
echo
echo "STEP 1 - Platform administrator control"
IAT_JSON=$(acme_kcadm create clients-initial-access -r "$REALM" -s count="$IAT_COUNT" -s expiration="$IAT_EXPIRATION" -o)
IAT=$(jq -r '.token // empty' <<<"$IAT_JSON")
[[ -n "$IAT" ]] || { echo "ERROR: RHBK did not return an Initial Access Token" >&2; exit 1; }
IAT_FP=$(printf '%s' "$IAT" | openssl dgst -sha256 | awk '{print substr($NF,1,16)}')
echo "Initial Access Token created ✓"
echo "Lifetime: ${IAT_EXPIRATION}s | Count: ${IAT_COUNT} | Fingerprint: ${IAT_FP} | Value: <redacted>"

echo
echo "STEP 2 - Developer / automation"
echo "Developer credential: Initial Access Token only"
echo "Realm-admin credential: NOT used in registration request"
REQ=$(jq -n --arg cid "$CLIENT_ID" --arg name "$CLIENT_NAME" --arg redirect "$REDIRECT_URI" '{clientId:$cid,name:$name,enabled:true,protocol:"openid-connect",publicClient:false,standardFlowEnabled:true,directAccessGrantsEnabled:false,serviceAccountsEnabled:false,redirectUris:[$redirect]}')
HTTP=$(curl -sS -o "$TMP/first.json" -w '%{http_code}' -X POST "$REGISTRATION_ENDPOINT" -H "Authorization: Bearer $IAT" -H 'Content-Type: application/json' --data "$REQ")
[[ "$HTTP" =~ ^20[01]$ ]] || { echo "ERROR: registration HTTP $HTTP"; cat "$TMP/first.json"; exit 1; }
RETURNED=$(jq -r '.clientId // empty' "$TMP/first.json")
[[ "$RETURNED" == "$CLIENT_ID" ]] || { echo "ERROR: unexpected clientId $RETURNED" >&2; exit 1; }
RAT=$(jq -r '.registrationAccessToken // empty' "$TMP/first.json")
SECRET_ISSUED=$(jq -e '.secret != null and .secret != ""' "$TMP/first.json" >/dev/null && echo true || echo false)
RAT_ISSUED=$([[ -n "$RAT" ]] && echo true || echo false)
echo "Client registration successful ✓"
echo "Client ID: $CLIENT_ID"
echo "Client secret: <redacted>"
echo "Registration access token: <redacted>"

VERIFIED=false
if [[ -n "$RAT" ]]; then
  VHTTP=$(curl -sS -o "$TMP/verify.json" -w '%{http_code}' -H "Authorization: Bearer $RAT" "${REGISTRATION_ENDPOINT}/${CLIENT_ID}")
  [[ "$VHTTP" == 200 ]] && VERIFIED=true
fi
echo
echo "STEP 3 - Verify registered client"
echo "Registration management verified: $VERIFIED"

echo
echo "STEP 4 - Prove one-use enforcement"
REQ2=$(jq -n --arg cid "$SECOND_CLIENT_ID" --arg redirect "$REDIRECT_URI" '{clientId:$cid,name:"ACME IAT Reuse Attempt",enabled:true,protocol:"openid-connect",publicClient:false,standardFlowEnabled:true,redirectUris:[$redirect]}')
SECOND_HTTP=$(curl -sS -o "$TMP/second.json" -w '%{http_code}' -X POST "$REGISTRATION_ENDPOINT" -H "Authorization: Bearer $IAT" -H 'Content-Type: application/json' --data "$REQ2")
[[ ! "$SECOND_HTTP" =~ ^2 ]] || { echo "ERROR: count=1 IAT was reused" >&2; exit 1; }
echo "Second registration rejected ✓ (HTTP $SECOND_HTTP)"

EVIDENCE=$(jq -n --arg created "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" --arg cid "$CLIENT_ID" --arg name "$CLIENT_NAME" --arg redirect "$REDIRECT_URI" --arg endpoint "$CANONICAL_ENDPOINT" --arg fp "$IAT_FP" --arg second "$SECOND_HTTP" --argjson rat "$RAT_ISSUED" --argjson secret "$SECRET_ISSUED" --argjson verified "$VERIFIED" '{status:"success",created_at:$created,client_id:$cid,client_name:$name,redirect_uris:[$redirect],grant_types:["authorization_code"],response_types:["code"],token_endpoint_auth_method:"client_secret_basic",iat_expiration_seconds:600,iat_count:1,iat_fingerprint:$fp,registration_endpoint:$endpoint,registration_provider:"default",registration_transport:"temporary internal port-forward",registration_access_token_issued:$rat,client_secret_issued:$secret,registration_verified:$verified,second_registration_http_status:$second,second_registration_blocked:true}')
PHTTP=$(curl -skS -o /dev/null -w '%{http_code}' -X POST "${PORTAL_URL}/api/demo/onboarding" -H "X-ACME-Demo-Key: ${DEMO_KEY}" -H 'Content-Type: application/json' --data "$EVIDENCE")
[[ "$PHTTP" == 200 ]] || { echo "ERROR: Portal callback HTTP $PHTTP" >&2; exit 1; }

echo
echo "======================================================"
echo " API-driven onboarding SUCCESS"
echo "======================================================"
echo "Registered client: $CLIENT_ID"
echo "IAT: 600 seconds / one registration"
echo "Developer registration credential: IAT only ✓"
echo "Second registration: BLOCKED ✓"
echo "Portal: ${PORTAL_URL}/#onboarding"
