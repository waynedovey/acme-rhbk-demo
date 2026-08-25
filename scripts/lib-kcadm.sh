#!/usr/bin/env bash
# Shared RHBK Admin CLI helper for the ACME demo.
# Source this file, then call acme_kcadm_login once before acme_kcadm commands.

ACME_NS=${NAMESPACE:-rhbk}
ACME_KC_NAME=${KEYCLOAK_NAME:-acme-keycloak}
ACME_KC_POD=${KEYCLOAK_POD:-${ACME_KC_NAME}-0}
ACME_KCADM=/opt/keycloak/bin/kcadm.sh
ACME_KCADM_CFG=${ACME_KCADM_CFG:-/tmp/acme-demo-helper-kcadm.config}

acme_b64d() {
  python3 -c 'import base64,sys; print(base64.b64decode(sys.stdin.read()).decode(), end="")'
}

acme_secret_value() {
  oc -n "$ACME_NS" get secret "$1" -o jsonpath="{.data.$2}" | acme_b64d
}

acme_kcadm_login() {
  local user pass
  command -v oc >/dev/null || { echo "oc is required" >&2; return 1; }
  command -v jq >/dev/null || { echo "jq is required" >&2; return 1; }
  command -v python3 >/dev/null || { echo "python3 is required" >&2; return 1; }
  oc whoami >/dev/null 2>&1 || { echo "Not logged in to OpenShift" >&2; return 1; }
  oc -n "$ACME_NS" get pod "$ACME_KC_POD" >/dev/null 2>&1 || { echo "Keycloak pod $ACME_NS/$ACME_KC_POD not found" >&2; return 1; }

  user=$(acme_secret_value "${ACME_KC_NAME}-initial-admin" username)
  pass=$(acme_secret_value "${ACME_KC_NAME}-initial-admin" password)

  oc -n "$ACME_NS" exec "$ACME_KC_POD" -- \
    "$ACME_KCADM" config credentials \
    --config "$ACME_KCADM_CFG" \
    --server http://localhost:8080 \
    --realm master \
    --user "$user" \
    --password "$pass" >/dev/null
}

acme_kcadm() {
  oc -n "$ACME_NS" exec "$ACME_KC_POD" -- "$ACME_KCADM" "$@" --config "$ACME_KCADM_CFG"
}

acme_kcadm_stdin() {
  oc -n "$ACME_NS" exec -i "$ACME_KC_POD" -- "$ACME_KCADM" "$@" --config "$ACME_KCADM_CFG"
}
