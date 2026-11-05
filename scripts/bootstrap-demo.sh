#!/usr/bin/env bash
set -euo pipefail

NS=${NAMESPACE:-rhbk}
KC_NAME=${KEYCLOAK_NAME:-acme-keycloak}
POD=${KEYCLOAK_POD:-${KC_NAME}-0}
KCADM=/opt/keycloak/bin/kcadm.sh
CFG=/tmp/acme-demo-kcadm.config
PEOPLESOFT_FLOW_ALIAS=peoplesoft-step-up

need() { command -v "$1" >/dev/null || { echo "$1 is required" >&2; exit 1; }; }
need oc
need jq
need python3

b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
secret_value() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }

oc whoami >/dev/null 2>&1 || { echo "Not logged in to OpenShift" >&2; exit 1; }
oc -n "$NS" get pod "$POD" >/dev/null 2>&1 || {
  echo "Keycloak pod $NS/$POD was not found" >&2
  exit 1
}

KC_HOST=$(oc -n "$NS" get route "$KC_NAME" -o jsonpath='{.spec.host}')
KC_URL="https://${KC_HOST}"
PORTAL_HOST=$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}')
PORTAL_URL="https://${PORTAL_HOST}"
KC_INTERNAL="http://${KC_NAME}-service:8080"

# Always repair the portal issuer URL before touching realm configuration.
oc -n "$NS" set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" KEYCLOAK_BACKCHANNEL_URL="$KC_INTERNAL" >/dev/null
oc -n "$NS" rollout status deployment/acme-portal --timeout=180s >/dev/null

ADMIN_USER=$(secret_value "${KC_NAME}-initial-admin" username)
ADMIN_PASS=$(secret_value "${KC_NAME}-initial-admin" password)
DEMO_PASS=$(secret_value acme-demo-secrets demo-user-password)
PORTAL_SECRET=$(secret_value acme-demo-secrets portal-client-secret)
PEOPLESOFT_SECRET=$(secret_value acme-demo-secrets peoplesoft-client-secret)
CLI_SECRET=$(secret_value acme-demo-secrets cli-client-secret)
LEGACY_SECRET=$(secret_value acme-demo-secrets legacy-broker-secret)
PARTNER_SECRET=$(secret_value acme-demo-secrets partner-broker-secret)
CORPORATE_SECRET=$(secret_value acme-demo-secrets corporate-broker-secret)

# Use Admin CLI from inside the Keycloak pod. This is intentionally different
# from obtaining an admin token through the public OIDC token endpoint: temporary
# bootstrap admins are reliable with kcadm in this deployment and this keeps the
# administrative traffic on localhost inside the RHBK pod.
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

kcadm_stdin() {
  oc -n "$NS" exec -i "$POD" -- "$KCADM" "$@" --config "$CFG"
}

ensure_realm() {
  local realm=$1 display=$2 payload
  if kcadm get "realms/$realm" >/dev/null 2>&1; then
    echo "Realm exists: $realm"
  else
    echo "Creating realm: $realm"
    payload=$(jq -n --arg r "$realm" --arg d "$display" '{realm:$r,displayName:$d,enabled:true,registrationAllowed:false,resetPasswordAllowed:true,rememberMe:true}')
    printf '%s' "$payload" | kcadm_stdin create realms -f - >/dev/null
  fi
}

client_uuid() {
  local realm=$1 cid=$2
  kcadm get clients -r "$realm" -q clientId="$cid" | jq -r '.[0].id // empty'
}

ensure_client() {
  local realm=$1 cid=$2 payload=$3
  local uuid current merged
  uuid=$(client_uuid "$realm" "$cid")
  if [[ -z "$uuid" ]]; then
    echo "Creating client: $realm/$cid"
    printf '%s' "$payload" | kcadm_stdin create clients -r "$realm" -f - >/dev/null
  else
    echo "Reconciling client: $realm/$cid"
    current=$(kcadm get "clients/$uuid" -r "$realm")
    merged=$(jq -s '.[0] * .[1]' <(printf '%s' "$current") <(printf '%s' "$payload"))
    printf '%s' "$merged" | kcadm_stdin update "clients/$uuid" -r "$realm" -n -f - >/dev/null
  fi
}

ensure_user() {
  local realm=$1 username=$2 email=$3 pass=$4
  local id payload
  id=$(kcadm get users -r "$realm" -q username="$username" | jq -r '.[0].id // empty')
  if [[ -n "$id" ]]; then
    echo "User exists: $realm/$username"
    return
  fi
  echo "Creating user: $realm/$username"
  payload=$(jq -n --arg u "$username" --arg e "$email" --arg p "$pass" '{username:$u,email:$e,emailVerified:true,enabled:true,firstName:"Alex",lastName:"Demo",credentials:[{type:"password",value:$p,temporary:false}]}')
  printf '%s' "$payload" | kcadm_stdin create users -r "$realm" -f - >/dev/null
}

scope_uuid() {
  local realm=$1 name=$2
  kcadm get client-scopes -r "$realm" | jq -r --arg n "$name" '.[] | select(.name==$n) | .id' | head -1
}

ensure_scope() {
  local realm=$1 name=$2 text=$3 payload
  if [[ -n "$(scope_uuid "$realm" "$name")" ]]; then
    echo "Client scope exists: $realm/$name"
  else
    payload=$(jq -n --arg n "$name" --arg t "$text" '{name:$n,protocol:"openid-connect",attributes:{"display.on.consent.screen":"true","consent.screen.text":$t,"include.in.token.scope":"true"}}')
    printf '%s' "$payload" | kcadm_stdin create client-scopes -r "$realm" -f - >/dev/null
    echo "Created client scope: $realm/$name"
  fi
}

attach_optional_scope() {
  local realm=$1 cid=$2 scope=$3
  local cu su
  cu=$(client_uuid "$realm" "$cid")
  su=$(scope_uuid "$realm" "$scope")
  [[ -n "$cu" && -n "$su" ]] || return 0
  printf '{}' | kcadm_stdin update "clients/$cu/optional-client-scopes/$su" -r "$realm" -n -f - >/dev/null 2>&1 || true
}

attach_default_scope() {
  local realm=$1 cid=$2 scope=$3
  local cu su
  cu=$(client_uuid "$realm" "$cid")
  su=$(scope_uuid "$realm" "$scope")
  [[ -n "$cu" && -n "$su" ]] || return 0
  printf '{}' | kcadm_stdin update "clients/$cu/default-client-scopes/$su" -r "$realm" -n -f - >/dev/null 2>&1 || true
}

ensure_idp() {
  local alias=$1 display=$2 provider_realm=$3 secret=$4
  local current updated payload
  if current=$(kcadm get "identity-provider/instances/$alias" -r acme-demo 2>/dev/null); then
    updated=$(jq \
      --arg d "$display" --arg s "$secret" --arg u "$KC_URL" --arg bi "$KC_INTERNAL" --arg pr "$provider_realm" \
      '.displayName=$d | .enabled=true | .trustEmail=true | .storeToken=true | .config=((.config // {}) + {clientId:"acme-broker",clientSecret:$s,authorizationUrl:($u+"/realms/"+$pr+"/protocol/openid-connect/auth"),tokenUrl:($bi+"/realms/"+$pr+"/protocol/openid-connect/token"),logoutUrl:($u+"/realms/"+$pr+"/protocol/openid-connect/logout"),userInfoUrl:($bi+"/realms/"+$pr+"/protocol/openid-connect/userinfo"),jwksUrl:($bi+"/realms/"+$pr+"/protocol/openid-connect/certs"),issuer:($u+"/realms/"+$pr),useJwksUrl:"true",validateSignature:"true",syncMode:"IMPORT",showInAccountConsole:"ALWAYS"})' <<<"$current")
    printf '%s' "$updated" | kcadm_stdin update "identity-provider/instances/$alias" -r acme-demo -n -f - >/dev/null
    echo "Reconciled identity provider: $alias -> $display"
    return
  fi

  payload=$(jq -n \
    --arg a "$alias" --arg d "$display" --arg s "$secret" --arg u "$KC_URL" --arg bi "$KC_INTERNAL" --arg pr "$provider_realm" \
    '{alias:$a,displayName:$d,providerId:"keycloak-oidc",enabled:true,trustEmail:true,storeToken:true,linkOnly:false,hideOnLogin:false,firstBrokerLoginFlowAlias:"first broker login",config:{clientId:"acme-broker",clientSecret:$s,authorizationUrl:($u+"/realms/"+$pr+"/protocol/openid-connect/auth"),tokenUrl:($bi+"/realms/"+$pr+"/protocol/openid-connect/token"),logoutUrl:($u+"/realms/"+$pr+"/protocol/openid-connect/logout"),userInfoUrl:($bi+"/realms/"+$pr+"/protocol/openid-connect/userinfo"),jwksUrl:($bi+"/realms/"+$pr+"/protocol/openid-connect/certs"),issuer:($u+"/realms/"+$pr),useJwksUrl:"true",validateSignature:"true",syncMode:"IMPORT",showInAccountConsole:"ALWAYS"}}')
  printf '%s' "$payload" | kcadm_stdin create identity-provider/instances -r acme-demo -f - >/dev/null
  echo "Created identity provider: $alias"
}

flow_id() {
  local alias=$1
  kcadm get authentication/flows -r acme-demo | jq -r --arg a "$alias" '.[] | select(.alias==$a) | .id' | head -1
}

ensure_peoplesoft_stepup_flow() {
  local fid execution updated payload
  fid=$(flow_id "$PEOPLESOFT_FLOW_ALIAS")
  if [[ -z "$fid" ]]; then
    echo "Creating PeopleSoft passkey step-up flow"
    payload=$(jq -n --arg a "$PEOPLESOFT_FLOW_ALIAS" '{alias:$a,description:"PeopleSoft high-assurance client flow: always require WebAuthn passwordless/passkey authentication",providerId:"basic-flow",topLevel:true,builtIn:false}')
    printf '%s' "$payload" | kcadm_stdin create authentication/flows -r acme-demo -f - >/dev/null
    fid=$(flow_id "$PEOPLESOFT_FLOW_ALIAS")
  else
    echo "Authentication flow exists: $PEOPLESOFT_FLOW_ALIAS"
  fi

  [[ -n "$fid" ]] || { echo "ERROR: unable to create/find $PEOPLESOFT_FLOW_ALIAS authentication flow" >&2; exit 1; }

  execution=$(kcadm get "authentication/flows/$PEOPLESOFT_FLOW_ALIAS/executions" -r acme-demo | jq -c '.[] | select(.providerId=="webauthn-authenticator-passwordless")' | head -1)
  if [[ -z "$execution" ]]; then
    kcadm create "authentication/flows/$PEOPLESOFT_FLOW_ALIAS/executions/execution" -r acme-demo -s provider=webauthn-authenticator-passwordless >/dev/null
    execution=$(kcadm get "authentication/flows/$PEOPLESOFT_FLOW_ALIAS/executions" -r acme-demo | jq -c '.[] | select(.providerId=="webauthn-authenticator-passwordless")' | head -1)
    echo "Added WebAuthn Passwordless Authenticator to PeopleSoft flow"
  fi

  [[ -n "$execution" ]] || { echo "ERROR: PeopleSoft flow has no WebAuthn Passwordless Authenticator" >&2; exit 1; }

  if [[ "$(jq -r '.requirement' <<<"$execution")" != "REQUIRED" ]]; then
    updated=$(jq '.requirement="REQUIRED"' <<<"$execution")
    printf '%s' "$updated" | kcadm_stdin update "authentication/flows/$PEOPLESOFT_FLOW_ALIAS/executions" -r acme-demo -n -f - >/dev/null
  fi

  printf '%s' "$fid"
}

ensure_realm acme-demo "ACME Digital Identity"
ensure_realm legacy-idp "Legacy Identity"
ensure_realm partner-idp "Partner Identity"
ensure_realm corporate-idp "Corporate Identity"

# Same person represented in three sources; same generated password keeps the live demo simple.
ensure_user acme-demo alex alex@acme.example "$DEMO_PASS"
ensure_user legacy-idp alex alex@acme.example "$DEMO_PASS"
ensure_user partner-idp alex alex@acme.example "$DEMO_PASS"
ensure_user corporate-idp alex alex@acme.example "$DEMO_PASS"

# Reconcile the RHBK 26.6-compatible passwordless WebAuthn policy.
kcadm update realms/acme-demo \
  -s 'webAuthnPolicyPasswordlessRpEntityName=ACME Digital Identity' \
  -s 'webAuthnPolicyPasswordlessUserVerificationRequirement=required' \
  -s 'webAuthnPolicyPasswordlessRequireResidentKey=Yes' >/dev/null

# Enable integrated passkey UI where the 26.6 build exposes the field.
if ! kcadm update realms/acme-demo -s 'webAuthnPolicyPasswordlessPasskeysEnabled=true' >/dev/null 2>&1; then
  echo "Note: integrated passkeys field not accepted; WebAuthn passwordless remains configured"
fi

ensure_scope acme-demo personal-details "Read your basic ACME profile details"
ensure_scope acme-demo orders-history "Read your ACME order history"
ensure_scope acme-demo support-profile "Read information required for customer support"

if [[ -z "$(scope_uuid acme-demo orders-api-audience)" ]]; then
  cat <<'JSON' | kcadm_stdin create client-scopes -r acme-demo -f - >/dev/null
{
  "name":"orders-api-audience",
  "protocol":"openid-connect",
  "attributes":{"include.in.token.scope":"false"},
  "protocolMappers":[{
    "name":"orders-api-audience",
    "protocol":"openid-connect",
    "protocolMapper":"oidc-audience-mapper",
    "consentRequired":false,
    "config":{"included.client.audience":"orders-api","id.token.claim":"false","access.token.claim":"true","lightweight.claim":"false","introspection.token.claim":"true"}
  }]
}
JSON
  echo "Created client scope: acme-demo/orders-api-audience"
fi

ensure_client acme-demo acme-portal "$(jq -n --arg s "$PORTAL_SECRET" --arg r "$PORTAL_URL/callback" --arg o "$PORTAL_URL" '{clientId:"acme-portal",name:"ACME Portal",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,clientAuthenticatorType:"client-secret",consentRequired:false,standardFlowEnabled:true,directAccessGrantsEnabled:true,redirectUris:[$r],webOrigins:[$o],attributes:{"standard.token.exchange.enabled":"true"}}')"
ensure_client acme-demo acme-cli "$(jq -n --arg s "$CLI_SECRET" '{clientId:"acme-cli",name:"ACME CLI Demo Helper",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,clientAuthenticatorType:"client-secret",consentRequired:false,standardFlowEnabled:false,directAccessGrantsEnabled:true,attributes:{"standard.token.exchange.enabled":"true"}}')"
ensure_client acme-demo orders-api '{"clientId":"orders-api","name":"ACME Orders API","enabled":true,"protocol":"openid-connect","publicClient":false,"standardFlowEnabled":false,"directAccessGrantsEnabled":false}'
# The FAPI 2 Client Policy validates sensitive client metadata on every update.
# Once configure-fapi2.sh has applied that policy, generic client reconciliation
# can fail with "token_endpoint_auth_method [invalid_client_metadata]".
# This client is not used by the Portal browser flows: preserve its configuration.
# configure-fapi2.sh owns its policy and future changes.
if [[ -z "$(client_uuid acme-demo high-assurance-api)" ]]; then
  ensure_client acme-demo high-assurance-api "$(jq -n --arg r "$PORTAL_URL/fapi-callback" '{clientId:"high-assurance-api",name:"ACME High Assurance API",enabled:true,protocol:"openid-connect",publicClient:false,standardFlowEnabled:true,redirectUris:[$r]}')"
else
  echo "Preserving existing FAPI 2 policy-managed client: acme-demo/high-assurance-api"
fi
ensure_client acme-demo acme-automation '{"clientId":"acme-automation","name":"ACME Automation Workload","enabled":true,"protocol":"openid-connect","publicClient":false,"standardFlowEnabled":false,"directAccessGrantsEnabled":false,"serviceAccountsEnabled":true}'


# Separate fictional OIDC applications, both using this RHBK realm as the IdP.
# Public demo clients require PKCE S256 and do not share a secret.
for idp_app in acme-storefront acme-rewards; do
  ensure_client acme-demo "$idp_app" "$(jq -n \
    --arg cid "$idp_app" --arg r "$PORTAL_URL/idp-callback" --arg o "$PORTAL_URL" \
    '{clientId:$cid,name:$cid,description:"Fictional ACME IdP demonstration",enabled:true,protocol:"openid-connect",publicClient:true,standardFlowEnabled:true,directAccessGrantsEnabled:false,serviceAccountsEnabled:false,consentRequired:false,redirectUris:[$r],webOrigins:[$o],attributes:{"pkce.code.challenge.method":"S256"}}')"
done

for s in personal-details orders-history support-profile; do attach_optional_scope acme-demo acme-portal "$s"; done
attach_default_scope acme-demo acme-portal orders-api-audience
attach_default_scope acme-demo acme-cli orders-api-audience

# PeopleSoft is a separate application client. Its browser-flow override is the
# policy control: the client uses a loginless/passkey flow rather than the normal
# portal browser flow.
ensure_peoplesoft_stepup_flow >/dev/null
PEOPLESOFT_FLOW_ID=$(flow_id "$PEOPLESOFT_FLOW_ALIAS")
ensure_client acme-demo peoplesoft-app "$(jq -n \
  --arg s "$PEOPLESOFT_SECRET" \
  --arg r "$PORTAL_URL/peoplesoft-callback" \
  --arg o "$PORTAL_URL" \
  --arg f "$PEOPLESOFT_FLOW_ID" \
  '{clientId:"peoplesoft-app",name:"PeopleSoft HR - High Assurance",description:"Sensitive PI application requiring client-specific passkey step-up",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,clientAuthenticatorType:"client-secret",consentRequired:false,standardFlowEnabled:true,directAccessGrantsEnabled:false,redirectUris:[$r],webOrigins:[$o],authenticationFlowBindingOverrides:{browser:$f}}')"

# Broker demo comes after the core Portal client is known-good.
BROKER_REDIRECT_BASE="$KC_URL/realms/acme-demo/broker"
ensure_client legacy-idp acme-broker "$(jq -n --arg s "$LEGACY_SECRET" --arg r "$BROKER_REDIRECT_BASE/legacy-idp/endpoint" '{clientId:"acme-broker",name:"ACME Broker",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,standardFlowEnabled:true,redirectUris:[$r]}')"
ensure_client partner-idp acme-broker "$(jq -n --arg s "$PARTNER_SECRET" --arg r "$BROKER_REDIRECT_BASE/partner-idp/endpoint" '{clientId:"acme-broker",name:"ACME Broker",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,standardFlowEnabled:true,redirectUris:[$r]}')"
ensure_client corporate-idp acme-broker "$(jq -n --arg s "$CORPORATE_SECRET" --arg r "$BROKER_REDIRECT_BASE/corporate-idp/endpoint" '{clientId:"acme-broker",name:"ACME Broker",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,standardFlowEnabled:true,redirectUris:[$r]}')"

ensure_idp legacy-idp "Legacy Identity" legacy-idp "$LEGACY_SECRET"
ensure_idp partner-idp "Partner Identity" partner-idp "$PARTNER_SECRET"
ensure_idp corporate-idp "Corporate Identity" corporate-idp "$CORPORATE_SECRET"

# Ensure the passwordless WebAuthn registration required action is enabled.
kcadm update authentication/required-actions/webauthn-register-passwordless -r acme-demo -s enabled=true >/dev/null


# Check both IdP clients have correctly constrained redirect URIs and mandatory PKCE.
for idp_app in acme-storefront acme-rewards; do
  idp_uuid=$(client_uuid acme-demo "$idp_app")
  [[ -n "$idp_uuid" ]] || { echo "ERROR: missing IdP client $idp_app" >&2; exit 1; }
  idp_cfg=$(kcadm get "clients/$idp_uuid" -r acme-demo)
  if ! jq -e --arg expected "$PORTAL_URL/idp-callback" \
    '.publicClient == true and .standardFlowEnabled == true and
     .attributes["pkce.code.challenge.method"] == "S256" and
     (.redirectUris | index($expected) != null)' <<<"$idp_cfg" >/dev/null; then
    echo "ERROR: IdP client $idp_app must require PKCE S256 and have an exact callback." >&2
    exit 1
  fi
done

# Fail loudly if the browser clients are not actually present and correctly wired.
PORTAL_UUID=$(client_uuid acme-demo acme-portal)
PEOPLESOFT_UUID=$(client_uuid acme-demo peoplesoft-app)
[[ -n "$PORTAL_UUID" && -n "$PEOPLESOFT_UUID" ]] || {
  echo "ERROR: expected ACME Portal and PeopleSoft clients were not created." >&2
  exit 1
}

ACTUAL_REDIRECT=$(kcadm get "clients/$PORTAL_UUID" -r acme-demo | jq -r '.redirectUris[]? | select(endswith("/callback"))' | head -1)
if [[ "$ACTUAL_REDIRECT" != "$PORTAL_URL/callback" ]]; then
  echo "ERROR: acme-portal redirect URI is not reconciled to the current Portal Route." >&2
  echo "Expected: $PORTAL_URL/callback" >&2
  echo "Actual:   ${ACTUAL_REDIRECT:-<none>}" >&2
  exit 1
fi

PS_FLOW=$(kcadm get "clients/$PEOPLESOFT_UUID" -r acme-demo | jq -r '.authenticationFlowBindingOverrides.browser // empty')
if [[ "$PS_FLOW" != "$PEOPLESOFT_FLOW_ID" ]]; then
  echo "ERROR: PeopleSoft client is not bound to the passkey step-up flow." >&2
  exit 1
fi

PASSKEY_REQ=$(kcadm get "authentication/flows/$PEOPLESOFT_FLOW_ALIAS/executions" -r acme-demo | jq -r '.[] | select(.providerId=="webauthn-authenticator-passwordless") | .requirement' | head -1)
if [[ "$PASSKEY_REQ" != "REQUIRED" ]]; then
  echo "ERROR: PeopleSoft WebAuthn Passwordless execution is not REQUIRED." >&2
  exit 1
fi

echo
printf 'Bootstrap complete.\nRHBK:       %s\nPortal:     %s\nClient:     acme-demo/acme-portal OK\nPeopleSoft: acme-demo/peoplesoft-app -> %s (WebAuthn Passwordless REQUIRED) OK\n' "$KC_URL" "$PORTAL_URL" "$PEOPLESOFT_FLOW_ALIAS"
