#!/usr/bin/env bash
set -euo pipefail
NS="${NAMESPACE:-rhbk}"
POD="${KEYCLOAK_POD:-acme-keycloak-0}"
KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/acme-fapi2-kcadm.config
REALM=acme-demo
CLIENT_ID=high-assurance-api
POLICY_NAME=acme-fapi2-high-assurance
MARKER_ROLE=fapi2-high-assurance-marker
ACTIVE_PROFILE=fapi-2-security-profile
for cmd in oc jq curl python3; do command -v "$cmd" >/dev/null || { echo "ERROR: $cmd is required" >&2; exit 1; }; done

b64d(){ python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(),end="")'; }
ADMIN_USER=$(oc -n "$NS" get secret acme-keycloak-initial-admin -o jsonpath='{.data.username}' | b64d)
ADMIN_PASS=$(oc -n "$NS" get secret acme-keycloak-initial-admin -o jsonpath='{.data.password}' | b64d)
oc -n "$NS" exec "$POD" -- "$KCADM" config credentials --config "$CFG" --server http://localhost:8080 --realm master --user "$ADMIN_USER" --password "$ADMIN_PASS" >/dev/null
kc(){ oc -n "$NS" exec "$POD" -- "$KCADM" "$@" --config "$CFG"; }
kci(){ oc -n "$NS" exec -i "$POD" -- "$KCADM" "$@" --config "$CFG"; }
KC_PUBLIC="https://$(oc -n "$NS" get route acme-keycloak -o jsonpath='{.spec.host}')"
PORTAL_URL="https://$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}')"
DEMO_KEY=$(oc -n "$NS" get secret acme-demo-secrets -o jsonpath='{.data.portal-client-secret}' | b64d)

echo
echo "======================================================"
echo " ACME FAPI 2.0 High-Assurance OAuth Demo"
echo "======================================================"
echo "Realm: $REALM"
echo "Demo client: $CLIENT_ID"
echo "Client policy: $POLICY_NAME"
echo "Applied FAPI profile: $ACTIVE_PROFILE"
echo

echo "STEP 1 - Verify built-in FAPI 2 profiles"
echo "----------------------------------------"
PROFILES=$(kc get client-policies/profiles -r "$REALM" -q include-global-profiles=true)
FAPI_PROFILES=$(jq '[ (.globalProfiles // [])[] | select(.name | startswith("fapi-2")) ]' <<<"$PROFILES")
for REQUIRED in fapi-2-security-profile fapi-2-message-signing fapi-2-dpop-security-profile fapi-2-dpop-message-signing; do
  jq -e --arg n "$REQUIRED" 'any(.[]; .name==$n)' <<<"$FAPI_PROFILES" >/dev/null || { echo "ERROR: missing $REQUIRED" >&2; exit 1; }
done
jq -r '.[] | "  ✓ " + .name' <<<"$FAPI_PROFILES"
echo "All four built-in FAPI 2 profiles present ✓"
SECURITY_PROFILE=$(jq -c --arg n "$ACTIVE_PROFILE" 'first(.[]|select(.name==$n))' <<<"$FAPI_PROFILES")
echo; echo "Executors in $ACTIVE_PROFILE:"
jq -r '(.executors // [])[] | "  ✓ " + (.executor // "unknown")' <<<"$SECURITY_PROFILE"

echo; echo "STEP 2 - Configure high-assurance API client"
echo "--------------------------------------------"
CLIENT_UUID=$(kc get clients -r "$REALM" -q clientId="$CLIENT_ID" | jq -r '.[0].id // empty')
if [[ -z "$CLIENT_UUID" ]]; then
  jq -n '{clientId:"high-assurance-api",name:"ACME High Assurance API",description:"Demo API protected by an RHBK FAPI 2 client policy",enabled:true,protocol:"openid-connect",publicClient:false,standardFlowEnabled:true,directAccessGrantsEnabled:false,serviceAccountsEnabled:false,implicitFlowEnabled:false,redirectUris:["https://high-assurance-api.acme.example/callback"],webOrigins:["https://high-assurance-api.acme.example"]}' | kci create clients -r "$REALM" -f - >/dev/null
  CLIENT_UUID=$(kc get clients -r "$REALM" -q clientId="$CLIENT_ID" | jq -r '.[0].id // empty')
else
  echo "Client already exists ✓"
fi
[[ -n "$CLIENT_UUID" ]] || { echo "ERROR: client not found" >&2; exit 1; }
echo "Client UUID: $CLIENT_UUID"

echo; echo "STEP 3 - Mark client for FAPI 2 policy"
echo "--------------------------------------"
if kc get "clients/$CLIENT_UUID/roles/$MARKER_ROLE" -r "$REALM" >/dev/null 2>&1; then
  echo "Marker role already exists ✓"
else
  jq -n --arg role "$MARKER_ROLE" '{name:$role,description:"Marker role selecting this client for the ACME FAPI 2 client policy"}' | kci create "clients/$CLIENT_UUID/roles" -r "$REALM" -f - >/dev/null
  echo "Marker role created ✓"
fi

echo; echo "STEP 4 - Apply FAPI 2 Client Policy"
echo "-----------------------------------"
CURRENT=$(kc get client-policies/policies -r "$REALM")
POLICY=$(jq -n --arg name "$POLICY_NAME" --arg role "$MARKER_ROLE" --arg profile "$ACTIVE_PROFILE" '{name:$name,description:"Apply the RHBK FAPI 2.0 Security Profile Final to ACME high-assurance clients",enabled:true,conditions:[{condition:"client-roles",configuration:{"is-negative-logic":false,roles:[$role]}}],profiles:[$profile]}')
UPDATED=$(jq --arg name "$POLICY_NAME" --argjson policy "$POLICY" '.policies=((.policies // [])|map(select(.name != $name))+[$policy]) | del(.globalPolicies)' <<<"$CURRENT")
printf '%s\n' "$UPDATED" | kci update client-policies/policies -r "$REALM" -f - >/dev/null
echo "Client Policy applied ✓"

echo; echo "STEP 5 - Verify FAPI policy"
echo "---------------------------"
VERIFIED=$(kc get client-policies/policies -r "$REALM")
VP=$(jq -c --arg name "$POLICY_NAME" 'first((.policies // [])[]|select(.name==$name))' <<<"$VERIFIED")
[[ -n "$VP" && "$VP" != null ]] || { echo "ERROR: policy not found" >&2; exit 1; }
jq -e --arg profile "$ACTIVE_PROFILE" '.enabled==true and (.profiles|index($profile)) != null' <<<"$VP" >/dev/null || { echo "ERROR: policy verification failed" >&2; exit 1; }
kc get "clients/$CLIENT_UUID/roles/$MARKER_ROLE" -r "$REALM" >/dev/null
echo "Policy verification successful ✓"

PROFILE_NAMES=$(jq '[.[].name]' <<<"$FAPI_PROFILES")
EXECUTORS=$(jq '[ (.executors // [])[] | (.executor // "unknown") ]' <<<"$SECURITY_PROFILE")
CONDITIONS=$(jq '.conditions // []' <<<"$VP")
EVIDENCE=$(jq -n --arg cid "$CLIENT_ID" --arg policy "$POLICY_NAME" --arg marker "$MARKER_ROLE" --arg active "$ACTIVE_PROFILE" --argjson profiles "$PROFILE_NAMES" --argjson executors "$EXECUTORS" --argjson conditions "$CONDITIONS" '{status:"success",client_id:$cid,rhbk_version:"26.6",policy_name:$policy,policy_enabled:true,marker_role:$marker,active_profile:$active,fapi2_specification:"FAPI 2.0 Security Profile Final",global_profiles:$profiles,active_profile_executors:$executors,policy_conditions:$conditions,client_secret_exposed:false,admin_credential_exposed:false}')
PHTTP=$(curl -skS -o /dev/null -w '%{http_code}' -X POST "${PORTAL_URL}/api/demo/fapi2" -H "X-ACME-Demo-Key: ${DEMO_KEY}" -H 'Content-Type: application/json' --data "$EVIDENCE")
[[ "$PHTTP" == 200 ]] || { echo "ERROR: Portal callback HTTP $PHTTP" >&2; exit 1; }

echo; echo "======================================================"
echo " FAPI 2.0 POLICY CONFIGURED SUCCESSFULLY"
echo "======================================================"
echo "Demo client:      $CLIENT_ID"
echo "Client Policy:    $POLICY_NAME"
echo "Applied profile:  $ACTIVE_PROFILE"
echo "Portal:           ${PORTAL_URL}/#fapi"
echo "Admin Console:    ${KC_PUBLIC}/admin/"
