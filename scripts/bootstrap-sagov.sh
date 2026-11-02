#!/usr/bin/env bash
# Create a separate SA Government demo without altering the existing ACME realms.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib-kcadm.sh
for bin in oc jq openssl python3; do command -v "$bin" >/dev/null || { echo "$bin required" >&2; exit 1; }; done
acme_kcadm_login

KC_URL="https://$(oc -n "$ACME_NS" get route "$ACME_KC_NAME" -o jsonpath='{.spec.host}')"
PORTAL_URL="https://$(oc -n "$ACME_NS" get route sagov-portal -o jsonpath='{.spec.host}')"
MYSAGOV_SECRET=$(acme_secret_value sagov-demo-secrets mysagov-client-secret)
READER_SECRET=$(acme_secret_value sagov-demo-secrets reader-client-secret)
IDX_SECRET=$(acme_secret_value sagov-demo-secrets idx-broker-secret)
DIT_SECRET=$(acme_secret_value sagov-demo-secrets dit-broker-secret)
MYID_SECRET=$(acme_secret_value sagov-demo-secrets myid-broker-secret)
DEMO_PASSWORD=$(acme_secret_value sagov-demo-secrets dit-demo-password)

client_id() {
  acme_kcadm get clients -r "$1" -q clientId="$2" | jq -r '.[0].id // empty'
}

ensure_realm() {
  local name=$1 title=$2
  if ! acme_kcadm get "realms/$name" >/dev/null 2>&1; then
    jq -n --arg n "$name" --arg t "$title" '{realm:$n,displayName:$t,enabled:true,registrationAllowed:false}' |
      acme_kcadm_stdin create realms -f - >/dev/null
  fi
  echo "Realm ready: $name"
}

ensure_client() {
  local realm=$1 name=$2 json=$3 uuid current merged
  uuid=$(client_id "$realm" "$name")
  if [[ -z "$uuid" ]]; then
    printf '%s' "$json" | acme_kcadm_stdin create clients -r "$realm" -f - >/dev/null
  else
    current=$(acme_kcadm get "clients/$uuid" -r "$realm")
    merged=$(jq -s '.[0] * .[1]' <(printf '%s' "$current") <(printf '%s' "$json"))
    printf '%s' "$merged" | acme_kcadm_stdin update "clients/$uuid" -r "$realm" -n -f - >/dev/null
  fi
  echo "Client ready: $realm/$name"
}

ensure_idp() {
  local realm=$1 alias=$2 origin=$3 cid=$4 secret=$5 linkonly=$6
  local payload uuid
  # Public issuer and browser URLs, internal backchannel requests.
  payload=$(jq -n --arg alias "$alias" --arg origin "$origin" --arg cid "$cid" --arg secret "$secret"     --arg public "$KC_URL" --arg internal "http://$ACME_KC_NAME-service:8080" --argjson linkonly "$linkonly"     '{
      alias:$alias,displayName:$alias,providerId:"keycloak-oidc",
      enabled:true,trustEmail:false,storeToken:false,linkOnly:$linkonly,
      firstBrokerLoginFlowAlias:"first broker login",
      config:{
        clientId:$cid,clientSecret:$secret,
        issuer:($public+"/realms/"+$origin),
        authorizationUrl:($public+"/realms/"+$origin+"/protocol/openid-connect/auth"),
        tokenUrl:($internal+"/realms/"+$origin+"/protocol/openid-connect/token"),
        userInfoUrl:($internal+"/realms/"+$origin+"/protocol/openid-connect/userinfo"),
        jwksUrl:($internal+"/realms/"+$origin+"/protocol/openid-connect/certs"),
        logoutUrl:($public+"/realms/"+$origin+"/protocol/openid-connect/logout"),
        validateSignature:"true",useJwksUrl:"true",syncMode:"IMPORT"
      }
    }')
  if acme_kcadm get "identity-provider/instances/$alias" -r "$realm" >/dev/null 2>&1; then
    printf '%s' "$payload" | acme_kcadm_stdin update "identity-provider/instances/$alias" -r "$realm" -n -f - >/dev/null
  else
    printf '%s' "$payload" | acme_kcadm_stdin create identity-provider/instances -r "$realm" -f - >/dev/null
  fi
  echo "Broker ready: $realm -> $alias ($origin), linkOnly=$linkonly, trustEmail=false"
}

ensure_demo_user() {
  local realm=$1 user=$2 ident=$3 email=$4
  if [[ -z "$(acme_kcadm get users -r "$realm" -q username="$user" | jq -r '.[0].id // empty')" ]]; then
    jq -n --arg id "$ident" --arg user "$user" --arg email "$email" --arg pass "$DEMO_PASSWORD"       '{id:$id,username:$user,firstName:"Alex",lastName:"Demo",email:$email,
        enabled:true,emailVerified:true,credentials:[{type:"password",value:$pass,temporary:false}]}' |
      acme_kcadm_stdin create users -r "$realm" -f - >/dev/null
  fi
  local actual
  actual=$(acme_kcadm get users -r "$realm" -q username="$user" | jq -r '.[0].id // empty')
  [[ "$actual" == "$ident" ]] || { echo "Unsafe DIT sample subject mismatch for $user: $actual" >&2; exit 1; }
}

ensure_reader() {
  local realm=$1 payload uuid sa_user rm_client role
  payload=$(jq -n --arg secret "$READER_SECRET" '{
    clientId:"sagov-link-reader",name:"SA Government demo link reader",
    enabled:true,publicClient:false,clientAuthenticatorType:"client-secret",
    secret:$secret,serviceAccountsEnabled:true,standardFlowEnabled:false,
    directAccessGrantsEnabled:false,fullScopeAllowed:true
  }')
  ensure_client "$realm" sagov-link-reader "$payload"
  uuid=$(client_id "$realm" sagov-link-reader)
  sa_user=$(acme_kcadm get "clients/$uuid/service-account-user" -r "$realm" | jq -r '.id')
  rm_client=$(client_id "$realm" realm-management)
  role=$(acme_kcadm get "clients/$rm_client/roles/view-users" -r "$realm")
  printf '[%s]' "$role" |
    acme_kcadm_stdin create "users/$sa_user/role-mappings/clients/$rm_client" -r "$realm" -f - >/dev/null
}

ensure_realm sa-id "South Australia ID (fictional)"
ensure_realm idx "Identity Exchange (fictional)"
ensure_realm dit-idp "DIT Identity (fictional)"
ensure_realm myid-idp "myID (fictional)"

# SA ID is independently self-registering. Email validation is via in-cluster
# Mailpit capture only; no real email leaves the lab.
CURRENT=$(acme_kcadm get realms/sa-id)
UPDATED=$(jq '.registrationAllowed=true | .resetPasswordAllowed=true | .verifyEmail=true |
  .eventsEnabled=true | .adminEventsEnabled=true |
  .webAuthnPolicyPasswordlessRpEntityName="SA ID demonstration" |
  .webAuthnPolicyPasswordlessUserVerificationRequirement="required" |
  .webAuthnPolicyPasswordlessRequireResidentKey="Yes" |
  .webAuthnPolicyPasswordlessPasskeysEnabled=true |
  .smtpServer={"host":"sagov-mailpit","port":"1025","from":"noreply@sagov.demo.invalid","fromDisplayName":"SA ID Demo","ssl":"false","starttls":"false"}' <<<"$CURRENT")
printf '%s' "$UPDATED" | acme_kcadm_stdin update realms/sa-id -n -f - >/dev/null

for name in idx dit-idp myid-idp; do
  acme_kcadm update "realms/$name" -s registrationAllowed=false -s eventsEnabled=true >/dev/null
done

ensure_demo_user dit-idp dit-alex "11111111-1111-4111-8111-111111111111" "alex.dit@demo.invalid"
ensure_demo_user dit-idp dit-jordan "22222222-2222-4222-8222-222222222222" "jordan.dit@demo.invalid"
ensure_demo_user myid-idp myid-alex "33333333-3333-4333-8333-333333333333" "alex.myid@demo.invalid"

ensure_client sa-id mysagov "$(jq -n --arg secret "$MYSAGOV_SECRET" --arg uri "$PORTAL_URL/callback" --arg origin "$PORTAL_URL" '{
 clientId:"mysagov",name:"mySAGOV citizen portal (fictional)",protocol:"openid-connect",
 enabled:true,publicClient:false,clientAuthenticatorType:"client-secret",secret:$secret,
 standardFlowEnabled:true,serviceAccountsEnabled:false,directAccessGrantsEnabled:false,
 redirectUris:[$uri],webOrigins:[$origin],
 attributes:{"post.logout.redirect.uris":($origin+"/")}
}')"

ensure_client idx idx-broker "$(jq -n --arg s "$IDX_SECRET" --arg u "$KC_URL/realms/sa-id/broker/idx/endpoint" '{
 clientId:"idx-broker",secret:$s,enabled:true,publicClient:false,protocol:"openid-connect",
 standardFlowEnabled:true,directAccessGrantsEnabled:false,redirectUris:[$u]
}')"
ensure_client dit-idp dit-broker "$(jq -n --arg s "$DIT_SECRET" --arg u "$KC_URL/realms/idx/broker/dit/endpoint" '{
 clientId:"dit-broker",secret:$s,enabled:true,publicClient:false,protocol:"openid-connect",
 standardFlowEnabled:true,directAccessGrantsEnabled:false,redirectUris:[$u]
}')"
ensure_client myid-idp myid-broker "$(jq -n --arg s "$MYID_SECRET" --arg u "$KC_URL/realms/idx/broker/myid/endpoint" '{
 clientId:"myid-broker",secret:$s,enabled:true,publicClient:false,protocol:"openid-connect",
 standardFlowEnabled:true,directAccessGrantsEnabled:false,redirectUris:[$u]
}')"

ensure_idp idx dit dit-idp dit-broker "$DIT_SECRET" false
ensure_idp idx myid myid-idp myid-broker "$MYID_SECRET" false
# Link-only: someone must already own an SA ID session before connecting IDX.
ensure_idp sa-id idx idx idx-broker "$IDX_SECRET" true
ensure_reader sa-id
ensure_reader idx

echo
echo "SA Government simulation configured (separate from the original ACME demo)."
echo "For credentials and routes: ./scripts/sagov-demo-info.sh"
echo "No email-based identity linking or TRUMPS claims are configured in RHBK."
