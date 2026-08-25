# Troubleshooting

## 1. Pod Pending: `Insufficient cpu`

This usually means CPU requests are fully allocated, not that the node is actually busy.

```bash
oc describe node $(oc get nodes -o jsonpath='{.items[0].metadata.name}') | \
  sed -n '/Allocated resources:/,/Events:/p'

oc adm top node
```

The demo Keycloak CR requests `250m` CPU. PostgreSQL requests `100m` and the portal `50m`.

On a single-node ACM Hub, `availabilityConfig: Basic` for ACM/MCE can significantly reduce redundant HA replica reservations. Also consider disabling optional heavy components that are not needed for the current demo rather than modifying core OpenShift control-plane workloads.

## 2. Keycloak: `secret "keycloak-db-secret" not found`

Run:

```bash
./scripts/generate-secrets.sh
```

Check:

```bash
oc get secret keycloak-db-secret -n rhbk
```

## 3. Keycloak: `UnknownHostException: postgres-db`

Check the PostgreSQL service and pod:

```bash
oc get svc postgres-db -n rhbk
oc get pods -l app=postgres-db -n rhbk
oc logs -n rhbk deployment/postgres-db
```

## 4. PostgreSQL PVC Pending

```bash
oc get pvc -n rhbk
oc get storageclass
oc describe pvc postgres-data -n rhbk
```

Use a valid default StorageClass or modify `manifests/10-postgres.yaml` to set `storageClassName` explicitly.

## 5. Keycloak never becomes Ready

```bash
oc get keycloak acme-keycloak -n rhbk -o yaml
oc get pods -n rhbk
oc logs -n rhbk statefulset/acme-keycloak --tail=200
```

Inspect conditions:

```bash
oc get keycloak acme-keycloak -n rhbk \
  -o go-template='{{range .status.conditions}}CONDITION: {{.type}}{{"\n"}}STATUS: {{.status}}{{"\n"}}MESSAGE: {{.message}}{{"\n\n"}}{{end}}'
```

## 6. Broker buttons do not appear

```bash
./scripts/bootstrap-demo.sh
```

Then check in Admin Console:

```text
acme-demo -> Identity providers
```

You should see `legacy-idp` and `partner-idp` enabled.

## 7. Token exchange fails

Confirm:

- Client `acme-portal` has Standard Token Exchange enabled.
- It is confidential.
- The original access token includes `orders-api` in its audience.
- `orders-api-audience` is a default client scope of `acme-portal`.

Run:

```bash
./scripts/token-exchange.sh
```

## 8. Workload identity fails

First reconfigure:

```bash
./scripts/configure-workload-identity.sh
```

Check the current ServiceAccount token issuer:

```bash
TOKEN=$(oc -n rhbk create token acme-automation --duration=10m)
python3 - "$TOKEN" <<'PY'
import base64,json,sys
p=sys.argv[1].split('.')[1]; p += '='*(-len(p)%4)
print(json.dumps(json.loads(base64.urlsafe_b64decode(p)),indent=2))
PY
```

In RHBK check:

```text
acme-demo -> Identity providers -> openshift
acme-demo -> Clients -> acme-automation -> Credentials
```

The client authenticator should be `Signed JWT - Federated` and the federated subject should be:

```text
system:serviceaccount:rhbk:acme-automation
```

## 9. Passkey option not visible

Check:

```text
Authentication -> Required actions -> WebAuthn Register Passwordless = Enabled
Realm settings -> Login -> Enable Passkeys = ON
Authentication -> Policies -> WebAuthn Passwordless Policy
```

Passkeys require a secure browser context; use the HTTPS OpenShift Route.

## 10. Portal errors after bootstrap

```bash
oc get pods -n rhbk -l app=acme-portal
oc logs -n rhbk deployment/acme-portal
oc get route acme-portal -n rhbk
oc -n rhbk get deployment acme-portal -o jsonpath='{.spec.template.spec.containers[0].env}' | jq
```

## PostgreSQL crash loop: `tuple already updated by self`

The demo database is configured with a `Recreate` deployment strategy to prevent overlapping PostgreSQL pods on the same PVC. If a prior/abrupt restart left the disposable lab database damaged, reset it with:

```bash
./scripts/reset-postgres.sh --yes
./scripts/bootstrap-demo.sh
```

The reset deletes the PostgreSQL PVC. Do not use it for data you need to preserve.

## Portal redirects to `https://keycloak.invalid`

The portal must use the external OpenShift Route for browser-facing OIDC authorization requests.
Repair it with:

```bash
./scripts/repair-portal.sh
```

Or manually:

```bash
KC_URL="https://$(oc -n rhbk get route acme-keycloak -o jsonpath='{.spec.host}')"
oc -n rhbk set env deployment/acme-portal KEYCLOAK_URL="$KC_URL"
oc -n rhbk rollout status deployment/acme-portal
```

Verify:

```bash
oc -n rhbk set env deployment/acme-portal --list | grep KEYCLOAK_URL
```

## 11. PeopleSoft does not ask for a passkey

Run the verifier first:

```bash
./scripts/verify-peoplesoft-stepup.sh
```

The result should show:

```text
status: READY
client: peoplesoft-app
expectedFlow.alias: peoplesoft-step-up
expectedFlow.passkeyExecutionRequirement: REQUIRED
```

The PeopleSoft client must have its browser authentication-flow override bound to `peoplesoft-step-up`. Reconcile it with:

```bash
./scripts/apply-demo-update.sh
```

The portal's PeopleSoft authorization request also sends `prompt=login` and `max_age=0` so a normal RHBK SSO cookie cannot silently satisfy the sensitive-app login.

## 12. PeopleSoft says no passkey / no credential is available

The dedicated PeopleSoft flow intentionally contains only the passwordless WebAuthn authenticator. Register a passwordless credential for `alex` first:

1. Open the ACME Portal.
2. Click **Register / verify passkey**.
3. Complete Touch ID, Windows Hello, Face ID or another supported passkey authenticator.
4. Run:

```bash
./scripts/verify-peoplesoft-stepup.sh
```

`alexCredentialTypes` should contain:

```text
webauthn-passwordless
```

If it does not, check the realm policy in **Authentication → Policies → WebAuthn Passwordless Policy** and confirm the site is being accessed over the HTTPS OpenShift Route.

## 13. PeopleSoft callback reports an invalid redirect URI

Check the current portal route and client redirect URI:

```bash
PORTAL="https://$(oc -n rhbk get route acme-portal -o jsonpath='{.spec.host}')"
echo "$PORTAL/peoplesoft-callback"
./scripts/apply-demo-update.sh
```

The update script reconciles `peoplesoft-app` to the current route each time it runs.

## `verify-peoplesoft-stepup.sh` exits while obtaining an admin token

Older v6 bundles attempted to authenticate the temporary bootstrap administrator by posting a password grant to the public `admin-cli` token endpoint. Some RHBK deployments do not permit that path for the temporary administrator, even though Admin CLI login works.

v7 no longer depends on that token grant. Both bootstrap and verification run `kcadm.sh` inside the RHBK pod against `http://localhost:8080`.

Check the admin path with:

```bash
./scripts/verify-admin-cli.sh
```

Then reconcile and verify the demo:

```bash
./scripts/apply-demo-update.sh
./scripts/verify-peoplesoft-stepup.sh
```
