#!/usr/bin/env bash
set -euo pipefail
NS=${NAMESPACE:-rhbk}
b64d() { python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'; }
val() { oc -n "$NS" get secret "$1" -o jsonpath="{.data.$2}" | b64d; }

KC_HOST=$(oc -n "$NS" get route acme-keycloak -o jsonpath='{.spec.host}' 2>/dev/null || true)
PORTAL_HOST=$(oc -n "$NS" get route acme-portal -o jsonpath='{.spec.host}' 2>/dev/null || true)
DEMO_PASS=$(val acme-demo-secrets demo-user-password 2>/dev/null || true)
ADMIN_USER=$(val acme-keycloak-initial-admin username 2>/dev/null || true)
ADMIN_PASS=$(val acme-keycloak-initial-admin password 2>/dev/null || true)

cat <<EOF2

ACME RHBK Demo
==============
RHBK URL:          https://${KC_HOST}
Admin Console:     https://${KC_HOST}/admin/
ACME Portal:       https://${PORTAL_HOST}
PeopleSoft demo:   https://${PORTAL_HOST}/peoplesoft-home
Account Console:   https://${KC_HOST}/realms/acme-demo/account/

Demo identity (all demo realms)
-------------------------------
Username:          alex
Password:          ${DEMO_PASS}
Email:             alex@acme.example

Bootstrap admin
---------------
Username:          ${ADMIN_USER}
Password:          ${ADMIN_PASS}

Realms
------
acme-demo
legacy-idp
partner-idp        (represents Microsoft Entra ID in the customer demo)

PeopleSoft step-up
------------------
Client:            peoplesoft-app
Browser flow:      peoplesoft-step-up
Required factor:   WebAuthn Passwordless / passkey

Recommended live sequence
-------------------------
1. Open ACME Portal
2. Register / verify passkey
3. Sign in normally to establish SSO
4. Open PeopleSoft and complete Touch ID/passkey step-up
5. Continue through consent, token exchange and platform demos

Tip: use a private/incognito window between broker/consent demonstrations when you want to prevent an existing SSO session from hiding steps.
EOF2
