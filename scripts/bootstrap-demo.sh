#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
KC_NAME=acme-keycloak

b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
secret_value() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }

KC_HOST=$(oc -n "$NS" get route "$KC_NAME" -o jsonpath='{.spec.host}')
KC_URL="https://${KC_HOST}"
PORTAL_HOST=$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}')
PORTAL_URL="https://${PORTAL_HOST}"

# Always repair the portal issuer URL before touching realm configuration.
oc -n "$NS" set env deployment/acme-portal KEYCLOAK_URL="$KC_URL" >/dev/null
oc -n "$NS" rollout status deployment/acme-portal --timeout=180s >/dev/null

ADMIN_USER=$(secret_value "${KC_NAME}-initial-admin" username)
ADMIN_PASS=$(secret_value "${KC_NAME}-initial-admin" password)
DEMO_PASS=$(secret_value acme-demo-secrets demo-user-password)
PORTAL_SECRET=$(secret_value acme-demo-secrets portal-client-secret)
CLI_SECRET=$(secret_value acme-demo-secrets cli-client-secret)
LEGACY_SECRET=$(secret_value acme-demo-secrets legacy-broker-secret)
PARTNER_SECRET=$(secret_value acme-demo-secrets partner-broker-secret)

ADMIN_TOKEN=$(curl -skf \
  --data-urlencode client_id=admin-cli \
  --data-urlencode username="$ADMIN_USER" \
  --data-urlencode password="$ADMIN_PASS" \
  --data-urlencode grant_type=password \
  "$KC_URL/realms/master/protocol/openid-connect/token" | jq -r .access_token)

api() {
  local method=$1 path=$2; shift 2
  curl -skf -X "$method" \
    -H "Authorization: Bearer $ADMIN_TOKEN" \
    -H 'Content-Type: application/json' "$@" "$KC_URL$path"
}

exists() { api GET "$1" >/dev/null 2>&1; }

ensure_realm() {
  local realm=$1 display=$2
  if exists "/admin/realms/$realm"; then
    echo "Realm exists: $realm"
  else
    echo "Creating realm: $realm"
    api POST /admin/realms -d "$(jq -n --arg r "$realm" --arg d "$display" '{realm:$r,displayName:$d,enabled:true,registrationAllowed:false,resetPasswordAllowed:true,rememberMe:true}')" >/dev/null
  fi
}

client_uuid() {
  api GET "/admin/realms/$1/clients?clientId=$2" | jq -r '.[0].id // empty'
}

ensure_client() {
  local realm=$1 cid=$2 payload=$3
  local uuid current merged
  uuid=$(client_uuid "$realm" "$cid")
  if [[ -z "$uuid" ]]; then
    echo "Creating client: $realm/$cid"
    api POST "/admin/realms/$realm/clients" -d "$payload" >/dev/null
  else
    # Reconcile the demo client on every run. This is important when an OpenShift
    # Route, generated secret, or capability changes between installations.
    echo "Reconciling client: $realm/$cid"
    current=$(api GET "/admin/realms/$realm/clients/$uuid")
    merged=$(jq -s '.[0] * .[1]' <(printf '%s' "$current") <(printf '%s' "$payload"))
    api PUT "/admin/realms/$realm/clients/$uuid" -d "$merged" >/dev/null
  fi
}

ensure_user() {
  local realm=$1 username=$2 email=$3 pass=$4
  local id
  id=$(api GET "/admin/realms/$realm/users?username=$username&exact=true" | jq -r '.[0].id // empty')
  if [[ -n "$id" ]]; then
    echo "User exists: $realm/$username"
    return
  fi
  echo "Creating user: $realm/$username"
  api POST "/admin/realms/$realm/users" -d "$(jq -n --arg u "$username" --arg e "$email" --arg p "$pass" '{username:$u,email:$e,emailVerified:true,enabled:true,firstName:"Alex",lastName:"Demo",credentials:[{type:"password",value:$p,temporary:false}]}')" >/dev/null
}

scope_uuid() {
  api GET "/admin/realms/$1/client-scopes" | jq -r --arg n "$2" '.[] | select(.name==$n) | .id' | head -1
}

ensure_scope() {
  local realm=$1 name=$2 text=$3
  if [[ -n "$(scope_uuid "$realm" "$name")" ]]; then
    echo "Client scope exists: $realm/$name"
  else
    api POST "/admin/realms/$realm/client-scopes" -d "$(jq -n --arg n "$name" --arg t "$text" '{name:$n,protocol:"openid-connect",attributes:{"display.on.consent.screen":"true","consent.screen.text":$t,"include.in.token.scope":"true"}}')" >/dev/null
    echo "Created client scope: $realm/$name"
  fi
}

attach_optional_scope() {
  local realm=$1 cid=$2 scope=$3
  local cu su
  cu=$(client_uuid "$realm" "$cid"); su=$(scope_uuid "$realm" "$scope")
  api PUT "/admin/realms/$realm/clients/$cu/optional-client-scopes/$su" -d '{}' >/dev/null 2>&1 || true
}

attach_default_scope() {
  local realm=$1 cid=$2 scope=$3
  local cu su
  cu=$(client_uuid "$realm" "$cid"); su=$(scope_uuid "$realm" "$scope")
  api PUT "/admin/realms/$realm/clients/$cu/default-client-scopes/$su" -d '{}' >/dev/null 2>&1 || true
}

ensure_idp() {
  local alias=$1 display=$2 provider_realm=$3 secret=$4
  if exists "/admin/realms/acme-demo/identity-provider/instances/$alias"; then
    echo "Identity provider exists: $alias"
    return
  fi
  local payload
  payload=$(jq -n \
    --arg a "$alias" --arg d "$display" --arg s "$secret" --arg u "$KC_URL" --arg pr "$provider_realm" \
    '{alias:$a,displayName:$d,providerId:"keycloak-oidc",enabled:true,trustEmail:true,storeToken:true,firstBrokerLoginFlowAlias:"first broker login",config:{clientId:"acme-broker",clientSecret:$s,authorizationUrl:($u+"/realms/"+$pr+"/protocol/openid-connect/auth"),tokenUrl:($u+"/realms/"+$pr+"/protocol/openid-connect/token"),logoutUrl:($u+"/realms/"+$pr+"/protocol/openid-connect/logout"),userInfoUrl:($u+"/realms/"+$pr+"/protocol/openid-connect/userinfo"),jwksUrl:($u+"/realms/"+$pr+"/protocol/openid-connect/certs"),issuer:($u+"/realms/"+$pr),useJwksUrl:"true",validateSignature:"true",syncMode:"IMPORT"}}')
  api POST /admin/realms/acme-demo/identity-provider/instances -d "$payload" >/dev/null
  echo "Created identity provider: $alias"
}

ensure_realm acme-demo "ACME Digital Identity"
ensure_realm legacy-idp "Legacy Identity"
ensure_realm partner-idp "Partner Identity"

# Same person represented in three sources; same generated password keeps the live demo simple.
ensure_user acme-demo alex alex@acme.example "$DEMO_PASS"
ensure_user legacy-idp alex alex@acme.example "$DEMO_PASS"
ensure_user partner-idp alex alex@acme.example "$DEMO_PASS"

# Build the application-facing configuration first. The Portal should remain
# usable even if an optional broker demonstration later fails to configure.
ensure_scope acme-demo personal-details "Read your basic ACME profile details"
ensure_scope acme-demo orders-history "Read your ACME order history"
ensure_scope acme-demo support-profile "Read information required for customer support"

if [[ -z "$(scope_uuid acme-demo orders-api-audience)" ]]; then
  api POST /admin/realms/acme-demo/client-scopes -d '{
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
  }' >/dev/null
  echo "Created client scope: acme-demo/orders-api-audience"
fi

ensure_client acme-demo acme-portal "$(jq -n --arg s "$PORTAL_SECRET" --arg r "$PORTAL_URL/callback" --arg o "$PORTAL_URL" '{clientId:"acme-portal",name:"ACME Portal",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,clientAuthenticatorType:"client-secret",consentRequired:true,standardFlowEnabled:true,directAccessGrantsEnabled:true,redirectUris:[$r],webOrigins:[$o],attributes:{"standard.token.exchange.enabled":"true"}}')"
ensure_client acme-demo acme-cli "$(jq -n --arg s "$CLI_SECRET" '{clientId:"acme-cli",name:"ACME CLI Demo Helper",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,clientAuthenticatorType:"client-secret",consentRequired:false,standardFlowEnabled:false,directAccessGrantsEnabled:true,attributes:{"standard.token.exchange.enabled":"true"}}')"
ensure_client acme-demo orders-api '{"clientId":"orders-api","name":"ACME Orders API","enabled":true,"protocol":"openid-connect","publicClient":false,"standardFlowEnabled":false,"directAccessGrantsEnabled":false}'
ensure_client acme-demo high-assurance-api "$(jq -n --arg r "$PORTAL_URL/fapi-callback" '{clientId:"high-assurance-api",name:"ACME High Assurance API",enabled:true,protocol:"openid-connect",publicClient:false,standardFlowEnabled:true,redirectUris:[$r]}')"
ensure_client acme-demo acme-automation '{"clientId":"acme-automation","name":"ACME Automation Workload","enabled":true,"protocol":"openid-connect","publicClient":false,"standardFlowEnabled":false,"directAccessGrantsEnabled":false,"serviceAccountsEnabled":true}'

for s in personal-details orders-history support-profile; do attach_optional_scope acme-demo acme-portal "$s"; done
attach_default_scope acme-demo acme-portal orders-api-audience
attach_default_scope acme-demo acme-cli orders-api-audience

# Broker demo comes after the core Portal client is known-good.
BROKER_REDIRECT_BASE="$KC_URL/realms/acme-demo/broker"
ensure_client legacy-idp acme-broker "$(jq -n --arg s "$LEGACY_SECRET" --arg r "$BROKER_REDIRECT_BASE/legacy-idp/endpoint" '{clientId:"acme-broker",name:"ACME Broker",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,standardFlowEnabled:true,redirectUris:[$r]}')"
ensure_client partner-idp acme-broker "$(jq -n --arg s "$PARTNER_SECRET" --arg r "$BROKER_REDIRECT_BASE/partner-idp/endpoint" '{clientId:"acme-broker",name:"ACME Broker",enabled:true,protocol:"openid-connect",publicClient:false,secret:$s,standardFlowEnabled:true,redirectUris:[$r]}')"

ensure_idp legacy-idp "Legacy Identity" legacy-idp "$LEGACY_SECRET"
ensure_idp partner-idp "Partner Identity" partner-idp "$PARTNER_SECRET"

# Ensure the passwordless WebAuthn registration required action is enabled.
RA=$(api GET /admin/realms/acme-demo/authentication/required-actions | jq '.[] | select(.alias=="webauthn-register-passwordless")' || true)
if [[ -n "$RA" && "$RA" != "null" ]]; then
  api PUT /admin/realms/acme-demo/authentication/required-actions/webauthn-register-passwordless -d "$(jq '.enabled=true' <<<"$RA")" >/dev/null
fi

# Fail loudly if the Portal client is not actually present. A missing client makes
# every browser button return "Client not found" even though RHBK itself is healthy.
PORTAL_UUID=$(client_uuid acme-demo acme-portal)
if [[ -z "$PORTAL_UUID" ]]; then
  echo "ERROR: acme-demo/acme-portal was not created." >&2
  exit 1
fi

ACTUAL_REDIRECT=$(api GET "/admin/realms/acme-demo/clients/$PORTAL_UUID" | jq -r '.redirectUris[]? | select(endswith("/callback"))' | head -1)
if [[ "$ACTUAL_REDIRECT" != "$PORTAL_URL/callback" ]]; then
  echo "ERROR: acme-portal redirect URI is not reconciled to the current Portal Route." >&2
  echo "Expected: $PORTAL_URL/callback" >&2
  echo "Actual:   ${ACTUAL_REDIRECT:-<none>}" >&2
  exit 1
fi

echo
printf 'Bootstrap complete.\nRHBK:   %s\nPortal: %s\nClient:  acme-demo/acme-portal OK\n' "$KC_URL" "$PORTAL_URL"
