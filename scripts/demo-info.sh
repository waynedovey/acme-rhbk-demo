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

cat <<EOF

ACME RHBK Demo
==============
RHBK URL:          https://${KC_HOST}
Admin Console:     https://${KC_HOST}/admin/
ACME Portal:       https://${PORTAL_HOST}
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
partner-idp

Tip: use a private/incognito window between broker/consent demonstrations to avoid an existing SSO session hiding steps.
EOF
