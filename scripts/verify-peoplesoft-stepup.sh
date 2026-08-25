#!/usr/bin/env bash
set -euo pipefail

NS=${NAMESPACE:-rhbk}
KC_NAME=${KEYCLOAK_NAME:-acme-keycloak}
POD=${KEYCLOAK_POD:-${KC_NAME}-0}
KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/acme-demo-kcadm-verify.config
REALM=acme-demo
FLOW_ALIAS=peoplesoft-step-up
CLIENT_ID=peoplesoft-app

need() { command -v "$1" >/dev/null || { echo "$1 is required" >&2; exit 1; }; }
need oc
need jq
need python3

oc whoami >/dev/null 2>&1 || { echo "Not logged in to OpenShift" >&2; exit 1; }
oc -n "$NS" get pod "$POD" >/dev/null 2>&1 || { echo "Keycloak pod $NS/$POD not found" >&2; exit 1; }

b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
secret_value() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }

KC_HOST=$(oc -n "$NS" get route "$KC_NAME" -o jsonpath='{.spec.host}')
KC_URL="https://${KC_HOST}"
PORTAL_HOST=$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}')
PORTAL_URL="https://${PORTAL_HOST}"
ADMIN_USER=$(secret_value "${KC_NAME}-initial-admin" username)
ADMIN_PASS=$(secret_value "${KC_NAME}-initial-admin" password)

oc -n "$NS" exec "$POD" -- \
  "$KCADM" config credentials \
  --config "$CFG" \
  --server http://localhost:8080 \
  --realm master \
  --user "$ADMIN_USER" \
  --password "$ADMIN_PASS" >/dev/null

kcadm() {
  oc -n "$NS" exec "$POD" -- "$KCADM" "$@" --config "$CFG"
}

REALM_JSON=$(kcadm get "realms/$REALM")
FLOW_JSON=$(kcadm get authentication/flows -r "$REALM")
FLOW_ID=$(jq -r --arg a "$FLOW_ALIAS" '.[] | select(.alias==$a) | .id' <<<"$FLOW_JSON" | head -1)
CLIENT_JSON=$(kcadm get clients -r "$REALM" -q clientId="$CLIENT_ID")
CLIENT_UUID=$(jq -r '.[0].id // empty' <<<"$CLIENT_JSON")
ALEX_JSON=$(kcadm get users -r "$REALM" -q username=alex)
ALEX_ID=$(jq -r '.[0].id // empty' <<<"$ALEX_JSON")

[[ -n "$FLOW_ID" ]] || { echo "FAIL: flow $FLOW_ALIAS does not exist" >&2; exit 1; }
[[ -n "$CLIENT_UUID" ]] || { echo "FAIL: client $CLIENT_ID does not exist" >&2; exit 1; }

CLIENT_REP=$(kcadm get "clients/$CLIENT_UUID" -r "$REALM")
BOUND_FLOW=$(jq -r '.authenticationFlowBindingOverrides.browser // empty' <<<"$CLIENT_REP")
EXECUTIONS=$(kcadm get "authentication/flows/$FLOW_ALIAS/executions" -r "$REALM")
PASSKEY_EXEC=$(jq -c '.[] | select(.providerId=="webauthn-authenticator-passwordless")' <<<"$EXECUTIONS" | head -1)

CRED_TYPES='[]'
if [[ -n "$ALEX_ID" ]]; then
  CRED_TYPES=$(kcadm get "users/$ALEX_ID/credentials" -r "$REALM" | jq '[.[].type] | unique')
fi

PORTAL_KEYCLOAK_URL=$(oc -n "$NS" get deployment acme-portal -o json | jq -r '.spec.template.spec.containers[] | select(.name=="portal") | .env[]? | select(.name=="KEYCLOAK_URL") | .value // empty')

ok=true
[[ "$BOUND_FLOW" == "$FLOW_ID" ]] || ok=false
[[ -n "$PASSKEY_EXEC" && "$(jq -r '.requirement' <<<"$PASSKEY_EXEC")" == "REQUIRED" ]] || ok=false
[[ "$PORTAL_KEYCLOAK_URL" == "$KC_URL" ]] || ok=false

jq -n \
  --arg status "$([[ "$ok" == true ]] && echo READY || echo NOT_READY)" \
  --arg portal "$PORTAL_URL" \
  --arg peopleSoftUrl "$PORTAL_URL/peoplesoft-home" \
  --arg realm "$REALM" \
  --arg client "$CLIENT_ID" \
  --arg flow "$FLOW_ALIAS" \
  --arg flowId "$FLOW_ID" \
  --arg boundFlow "$BOUND_FLOW" \
  --arg passkeyRequirement "$(jq -r '.requirement // "missing"' <<<"${PASSKEY_EXEC:-{}}")" \
  --arg rpName "$(jq -r '.webAuthnPolicyPasswordlessRpEntityName // ""' <<<"$REALM_JSON")" \
  --arg userVerification "$(jq -r '.webAuthnPolicyPasswordlessUserVerificationRequirement // ""' <<<"$REALM_JSON")" \
  --arg discoverable "$(jq -r '.webAuthnPolicyPasswordlessRequireResidentKey // ""' <<<"$REALM_JSON")" \
  --argjson passkeysEnabled "$(jq '.webAuthnPolicyPasswordlessPasskeysEnabled // false' <<<"$REALM_JSON")" \
  --arg portalIssuer "$PORTAL_KEYCLOAK_URL" \
  --argjson alexCredentialTypes "$CRED_TYPES" \
  '{status:$status,portal:$portal,peopleSoft:$peopleSoftUrl,realm:$realm,client:$client,clientBrowserFlowId:$boundFlow,expectedFlow:{alias:$flow,id:$flowId,passkeyExecutionRequirement:$passkeyRequirement},passwordlessPolicy:{rpEntityName:$rpName,userVerification:$userVerification,discoverableCredential:$discoverable,passkeysEnabled:$passkeysEnabled},portalKeycloakUrl:$portalIssuer,alexCredentialTypes:$alexCredentialTypes}'

if [[ "$ok" != true ]]; then
  echo >&2
  echo "PeopleSoft step-up is not ready. Re-run ./scripts/apply-demo-update.sh" >&2
  exit 1
fi

if ! jq -e 'index("webauthn-passwordless") != null' <<<"$CRED_TYPES" >/dev/null 2>&1; then
  echo >&2
  echo "CONFIGURATION READY, but alex has no webauthn-passwordless credential yet." >&2
  echo "Open the portal and click 'Register / verify passkey' before the PeopleSoft demo." >&2
fi
