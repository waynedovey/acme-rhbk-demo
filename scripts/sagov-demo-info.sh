#!/usr/bin/env bash
set -euo pipefail
NS=rhbk
echo "== Fictional SA Government demo =="
for name in sagov-portal sagov-mailpit acme-keycloak; do
  host=$(oc -n "$NS" get route "$name" -o jsonpath='{.spec.host}')
  echo "$name: https://$host"
done
echo "DIT IdP test users: dit-alex / dit-jordan"
echo "Fake DIT licence values: DEMO-LIC-001 / DEMO-LIC-002"
echo "Both DIT test users use the generated demo password:"
oc -n "$NS" get secret sagov-demo-secrets -o jsonpath='{.data.dit-demo-password}' | base64 --decode
printf '\n'
echo "Open Mailpit to read synthetic verification/reset emails."
echo "The original ACME demo remains available and unchanged."
