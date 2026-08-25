#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib-kcadm.sh
source "$SCRIPT_DIR/lib-kcadm.sh"
acme_kcadm_login

USER_ID=$(acme_kcadm get users -r acme-demo -q username=alex | jq -r '.[0].id // empty')
CLIENT_UUID=$(acme_kcadm get clients -r acme-demo -q clientId=acme-portal | jq -r '.[0].id // empty')
[[ -n "$USER_ID" ]] || { echo "ERROR: user alex not found" >&2; exit 1; }
[[ -n "$CLIENT_UUID" ]] || { echo "ERROR: client acme-portal not found" >&2; exit 1; }

acme_kcadm delete "users/$USER_ID/consents/$CLIENT_UUID" -r acme-demo >/dev/null 2>&1 || true
echo "Cleared saved acme-portal consent for user alex. The next authorization request can show consent again."
