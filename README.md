# ACME Digital Identity Demo — Red Hat build of Keycloak on OpenShift

This repository builds a compact, customer-facing **Red Hat build of Keycloak (RHBK) 26.6** demonstration on an existing OpenShift / ACM Hub cluster.

The lab is deliberately designed to show more than a basic Keycloak login. It demonstrates a modern identity architecture with:

- Identity brokering from multiple external OIDC identity providers
- Account linking to a single local identity
- Passkeys / WebAuthn passwordless authentication
- Scope-based user consent
- OAuth 2.0 Standard Token Exchange (RFC 8693)
- OpenShift workload identity using Kubernetes Service Account tokens instead of a static RHBK client secret
- FAPI 2.0 client policy positioning for high-assurance APIs
- API-driven / self-service client registration
- A small ACME Portal application so the demo is visible and interactive

> **Demo/lab only.** This package intentionally uses a single RHBK replica and a lightweight PostgreSQL database to fit on a constrained ACM Hub. It is not a production reference architecture.

---

## 1. Demo architecture

```text
                     +----------------------+
                     |  Legacy Identity     |
                     |  OIDC realm          |
                     +----------+-----------+
                                |
                                | OIDC broker
                                |
+----------------------+        v        +----------------------+
| Partner Identity     |   +--------------------+   | ACME Portal          |
| OIDC realm           +-->| RHBK / acme-demo   |<--+ Auth Code + Consent |
+----------------------+   |                    |   +----------------------+
                           | - Brokered login   |
                           | - Account linking  |
                           | - Passkeys         |
                           | - Consent scopes   |
                           | - Token exchange   |
                           | - FAPI policies    |
                           +---------+----------+
                                     |
                    +----------------+----------------+
                    |                                 |
                    v                                 v
             +-------------+                 +------------------+
             | Orders API  |                 | OpenShift        |
             | audience    |                 | workload         |
             +-------------+                 | ServiceAccount   |
                                             +--------+---------+
                                                      |
                                                      | short-lived JWT
                                                      v
                                             RHBK client auth
                                             (no static secret)
```

The entire demo is deployed into the namespace:

```text
rhbk
```

RHBK realms created by the bootstrap script:

```text
acme-demo       Main ACME identity realm
legacy-idp      Simulated legacy external identity provider
partner-idp     Simulated second external identity provider
```

---

## 2. What the demo proves

| Capability | What to show |
|---|---|
| Identity broker | Login to ACME through Legacy Identity or Partner Identity |
| Account linking | Both external identities resolve to one ACME local user |
| Passkeys | Register a platform passkey and sign in without typing a password |
| Consent | Portal requests separate `personal-details`, `orders-history`, and `support-profile` scopes |
| Token exchange | Portal exchanges the user's broad token for a token scoped to `orders-api` |
| Workload identity | OpenShift ServiceAccount JWT authenticates a confidential RHBK client without a client secret |
| FAPI 2.0 | Show built-in global FAPI 2 client profiles and apply one to a high-assurance client |
| Automation | Bootstrap is driven by Admin REST; optional Dynamic Client Registration demo creates a client using a short-lived Initial Access Token |

---

## 3. Prerequisites

You need:

- OpenShift 4.x cluster
- Cluster-admin access for the installation
- An ACM Hub is fine; this package does **not** require ACM itself
- A working default StorageClass
- Access to the Red Hat Operator catalog and Red Hat container registry
- Local tools:
  - `oc`
  - `curl`
  - `jq`
  - `openssl`
  - `python3`

Run the preflight check:

```bash
./scripts/preflight.sh
```

### Hub CPU warning

A single-node Hub often fails scheduling because CPU **requests** are nearly fully committed even when actual CPU use is low.

Check before installing:

```bash
oc describe node $(oc get nodes -o jsonpath='{.items[0].metadata.name}') | \
  sed -n '/Allocated resources:/,/Events:/p'

oc adm top node
```

This demo uses deliberately small requests:

| Component | CPU request | Memory request |
|---|---:|---:|
| RHBK | 250m | 1Gi |
| PostgreSQL | 100m | 256Mi |
| ACME Portal | 50m | 64Mi |

The RHBK Operator itself also consumes resources.

For a single-node ACM Hub, consider setting ACM and MCE to `availabilityConfig: Basic` rather than High availability before installing additional demo workloads.

---

## 4. Quick install

Extract the ZIP and run:

```bash
cd acme-rhbk-demo
./scripts/install.sh
```

The installer will:

1. Validate the OpenShift connection and required local tools.
2. Create namespace `rhbk`.
3. Install the RHBK Operator in `rhbk` if it is not already installed there.
4. Generate runtime-only demo secrets.
5. Deploy a lightweight persistent PostgreSQL 15 database.
6. Deploy the `acme-keycloak` Keycloak CR.
7. Expose RHBK with an OpenShift edge Route using the cluster router certificate.
8. Deploy the lightweight ACME Portal.
9. Create the three demo realms, clients, scopes, users and two OIDC brokers.
10. Create the OpenShift workload ServiceAccount used by the workload identity demo.
11. Print all demo URLs and the generated demo password.

The RHBK Subscription uses the channel containing `26.6` when available. Override it if required:

```bash
RHBK_CHANNEL=stable-v26.6 ./scripts/install.sh
```

For a lab, the script defaults the OLM install plan approval to `Automatic`. Override it with:

```bash
INSTALL_PLAN_APPROVAL=Manual ./scripts/install.sh
```

For production, review release notes and use controlled/manual upgrades.

---

### TLS note for the demo portal

The browser-facing OpenShift Routes use HTTPS. The tiny in-cluster ACME Portal defaults to not validating the router certificate for its own server-side OAuth calls so the kit also works on clusters using a private/default router certificate. Set `VERIFY_TLS=true` on the `acme-portal` deployment if your router certificate is trusted by the portal container and you want strict verification.

## 5. Get the demo information

At any time run:

```bash
./scripts/demo-info.sh
```

It prints:

- RHBK URL
- Admin Console URL
- ACME Portal URL
- Local ACME demo username/password
- Legacy IdP username/password
- Partner IdP username/password

No passwords are stored in this README or committed into manifests. They are generated when you install the demo and held in OpenShift Secrets.

The Operator-generated bootstrap admin credentials can be retrieved with:

```bash
oc -n rhbk get secret acme-keycloak-initial-admin \
  -o jsonpath='{.data.username}' | base64 --decode; echo

oc -n rhbk get secret acme-keycloak-initial-admin \
  -o jsonpath='{.data.password}' | base64 --decode; echo
```

---

# Customer demo runbook

The full presenter script is in:

```text
docs/DEMO-RUNBOOK.md
```

A strong 40–45 minute sequence is:

```text
00–05  Architecture and current broker model
05–12  Brokered login + account linking
12–20  Passkey registration and passwordless login
20–27  Granular OAuth consent
27–33  Standard Token Exchange
33–39  OpenShift workload identity without a client secret
39–43  API-driven self-service onboarding
43–45  FAPI 2.0 positioning and wrap-up
```

---

## 6. Demo #1 — identity brokering

Open the ACME Portal:

```bash
./scripts/demo-info.sh
```

Click **Sign in to ACME**.

The RHBK login screen will show broker choices for:

```text
Legacy Identity
Partner Identity
```

The bootstrap creates the same test person in all three realms so you can demonstrate that an external identity can be linked to one local ACME identity.

Use the password printed by `demo-info.sh`.

### Talking point

RHBK separates the application-facing identity from the upstream authentication system. Applications trust ACME RHBK, while RHBK brokers authentication to one or many external identity providers.

---

## 7. Demo #2 — passkeys

RHBK 26.6 supports passkey authentication using WebAuthn.

### Enable passkeys in the `acme-demo` realm

In the Admin Console:

```text
Realm: acme-demo

Authentication
  -> Required actions
  -> WebAuthn Register Passwordless
  -> Enabled
```

Then:

```text
Realm settings
  -> Login
  -> Login screen customization
  -> Enable Passkeys = ON
```

Recommended demo setting:

```text
Passkey Mediation = conditional
```

Then check:

```text
Authentication
  -> Policies
  -> WebAuthn Passwordless Policy
```

Suggested values for a demo:

```text
RP Entity Name               ACME Digital Identity
User Verification Requirement Required
Authenticator Attachment     Not specified
```

If demonstrating Windows Hello, ensure `RS256` is available in the passwordless WebAuthn signature algorithms.

### Register the passkey

Login to ACME as `alex`, open the Account Console, and go to:

```text
Account security
  -> Signing in
  -> Passkey / WebAuthn Passwordless
```

Register Touch ID, Windows Hello, a phone passkey, or a FIDO2 security key.

Log out and sign in again using **Sign in with Passkey** or the browser's passkey autofill.

### Talking point

Passkeys replace reusable passwords and OTP with phishing-resistant public-key authentication while retaining a simple user experience.

---

## 8. Demo #3 — granular consent

The bootstrap creates these optional OAuth scopes:

```text
personal-details
orders-history
support-profile
```

Each has user-facing consent text.

Open the ACME Portal and choose one of the consent examples.

The portal sends an Authorization Code request with the selected optional scopes. RHBK displays them separately on the consent screen.

To repeat the consent demonstration after the user has already granted it, run:

```bash
./scripts/reset-consent.sh
```

### Important boundary

RHBK provides OAuth scopes, consent screens and authorization foundations. A full business consent ledger with concepts such as data source, purpose, effective date, expiry, extension, historical revocation and business audit is normally implemented as an application/service integrated with RHBK rather than treated as a turnkey Keycloak feature.

---

## 9. Demo #4 — Standard Token Exchange

RHBK 26.6 enables the supported **Standard Token Exchange V2** server capability by default. The requesting confidential client must also have its Standard Token Exchange capability enabled.

The bootstrap creates:

```text
acme-portal     browser-facing confidential client
acme-cli        consent-free CLI helper used by token-exchange.sh
orders-api      downstream target audience
```

and a default audience scope that adds `orders-api` to the original access token.

### Browser demo

1. Login to the ACME Portal.
2. Open **View token claims**.
3. Select **Exchange token for Orders API**.
4. Compare the original and exchanged JWT claims.

### CLI demo

```bash
./scripts/token-exchange.sh
```

The script uses the dedicated `acme-cli` helper client to obtain a demo user token, then exchanges it using RFC 8693 for an access token filtered to the `orders-api` audience. The browser demonstration continues to use `acme-portal`.

### Talking point

Do not forward a broad user token to every downstream service. Exchange it for a shorter-lived token with only the audience/scopes needed by the next service.

---

## 10. Demo #5 — OpenShift workload identity

This is the machine-identity part of the demo.

Traditional model:

```text
Pod -> client_id + long-lived client_secret -> RHBK
```

Demo model:

```text
Pod -> projected short-lived Kubernetes ServiceAccount JWT -> RHBK -> OAuth token
```

Run:

```bash
./scripts/configure-workload-identity.sh
```

The script:

- Creates/uses ServiceAccount `acme-automation`.
- Detects the OpenShift service-account issuer.
- Configures a Kubernetes Identity Provider in `acme-demo`.
- Configures client `acme-automation` with the **Signed JWT - Federated** authenticator.
- Creates a temporary test Pod with a projected token whose audience is the ACME realm issuer.
- Exchanges that short-lived ServiceAccount JWT for an RHBK OAuth access token.

Re-run the test without recreating the configuration:

```bash
./scripts/workload-token-test.sh
```

### Talking point

The workload no longer needs a long-lived Keycloak client secret stored in a namespace, Ansible variable or CI/CD platform. OpenShift supplies the workload identity and RHBK validates it.

---

## 11. Demo #6 — FAPI 2.0

The bootstrap creates client:

```text
high-assurance-api
```

In the Admin Console:

```text
Realm settings
  -> Client policies
  -> Profiles
```

Show the built-in global profiles:

```text
fapi-2-security-profile
fapi-2-dpop-security-profile
fapi-2-message-signing
fapi-2-dpop-message-signing
```

Then create a client policy that applies the appropriate global FAPI 2 profile to `high-assurance-api`.

### Talking point

FAPI is useful beyond banking. It is a hardened OAuth/OIDC profile for APIs where stronger assurance, sender constraints, request integrity and stricter client behaviour are valuable.

---

## 12. Demo #7 — developer self-service / automation

The entire lab bootstrap is itself performed with the RHBK Admin REST API.

For a more visible self-service example run:

```bash
./scripts/dynamic-client-registration.sh
```

The script:

1. Creates a short-lived Initial Access Token.
2. Calls the OIDC Dynamic Client Registration endpoint.
3. Registers a new application without giving the application team realm-admin credentials.
4. Prints the resulting client metadata.

This can be incorporated into GitOps, Ansible or an application onboarding pipeline.

### Operator positioning

The RHBK Operator manages the RHBK deployment lifecycle and supports one-time `KeycloakRealmImport` operations. Realm Import is not a continuous realm/client reconciliation engine: an existing realm is not overwritten and edits made later are not automatically synchronized back to the Realm Import CR.

For ongoing identity configuration automation use mechanisms such as:

- Admin REST API
- `kcadm.sh`
- OIDC Dynamic Client Registration
- Client Policies / Client Registration Policies
- Ansible or GitOps pipelines that call the APIs

---

## 13. Troubleshooting

See:

```text
docs/TROUBLESHOOTING.md
```

Common checks:

```bash
oc get pods -n rhbk
oc get keycloak acme-keycloak -n rhbk
oc get route -n rhbk
oc logs -n rhbk statefulset/acme-keycloak
oc logs -n rhbk deployment/postgres-db
```

### `Insufficient cpu`

Check reservations rather than only real CPU use:

```bash
oc describe node $(oc get nodes -o jsonpath='{.items[0].metadata.name}') | \
  sed -n '/Allocated resources:/,/Events:/p'
```

The Keycloak CR in this kit requests only `250m` CPU.


### PostgreSQL: `tuple already updated by self` / `another server might be running`

If the demo PostgreSQL pod enters a crash loop with messages such as:

```text
pg_ctl: another server might be running
ERROR: tuple already updated by self
```

stop using the PVC immediately. The demo PostgreSQL manifest uses `strategy: Recreate` so a rollout cannot intentionally run two PostgreSQL pods against the same `PGDATA`.

For a disposable demo database, the fastest recovery is:

```bash
./scripts/reset-postgres.sh --yes
```

This **deletes `postgres-data` and all RHBK database contents**, recreates PostgreSQL, restarts Keycloak, and then tells you to re-run:

```bash
./scripts/bootstrap-demo.sh
```

If the database contains data you need to preserve, do **not** use the reset script. Back up the PVC/database and follow a PostgreSQL recovery process instead.

### `UnknownHostException: postgres-db`

Check:

```bash
oc get svc postgres-db -n rhbk
oc get pods -l app=postgres-db -n rhbk
```

The database Service must exist before RHBK can initialize its JDBC datasource.

---

## 14. Cleanup

Delete the entire demo:

```bash
./scripts/cleanup.sh
```

By default this deletes the `rhbk` namespace and everything in it, including PostgreSQL data.

The cluster-scoped RHBK CRDs may remain after cleanup. Do not delete them if another RHBK installation depends on them.

---

## 15. Production differences

For a production RHBK architecture do not copy the lab database/topology unchanged. Review at least:

- Multiple RHBK instances
- Externally managed, supported HA database
- Database backup and restore
- Proper TLS and certificate lifecycle
- Restricted administrative access
- MFA/passkeys for administrators
- NetworkPolicies
- Resource sizing and autoscaling
- Observability and audit event retention
- Upgrade strategy with manual approvals/change control
- Disaster recovery / multi-site requirements
- Vault/external secret integration where appropriate

---

## 16. Directory layout

```text
acme-rhbk-demo/
├── README.md
├── docs/
│   ├── ARCHITECTURE.md
│   ├── DEMO-RUNBOOK.md
│   ├── SOURCES.md
│   └── TROUBLESHOOTING.md
├── manifests/
│   ├── 00-namespace.yaml
│   ├── 10-postgres.yaml
│   ├── 20-keycloak-template.yaml
│   ├── 30-portal.yaml
│   └── 40-workload-identity.yaml
├── portal/
│   └── app.py
└── scripts/
    ├── install.sh
    ├── preflight.sh
    ├── install-operator.sh
    ├── generate-secrets.sh
    ├── deploy-keycloak.sh
    ├── bootstrap-demo.sh
    ├── configure-workload-identity.sh
    ├── workload-token-test.sh
    ├── token-exchange.sh
    ├── reset-consent.sh
    ├── dynamic-client-registration.sh
    ├── demo-info.sh
    └── cleanup.sh
```

---

## 17. Official references

Links and product behaviour used by this demo are recorded in `docs/SOURCES.md`.

### Portal redirects to `keycloak.invalid`

If a previous install was interrupted before bootstrap, repair the portal's browser-facing RHBK URL:

```bash
./scripts/repair-portal.sh
```

The portal must point to the external `acme-keycloak` OpenShift Route, not a placeholder or the internal service URL.

## Repair: `Client not found` from the ACME Portal

If the RHBK page displays `Client not found`, the browser has successfully reached RHBK and the `acme-demo` realm, but the `acme-portal` OIDC client is missing or incomplete. Repair it without reinstalling the stack:

```bash
./scripts/repair-portal-client.sh
```

The repair script creates the client if missing, or reconciles the client secret, current OpenShift Portal Route, redirect URI, web origin, consent setting and Standard Token Exchange flag if it already exists.

Then verify:

```bash
./scripts/bootstrap-demo.sh
./scripts/demo-info.sh
```

The expected redirect URI is the current Portal Route plus `/callback`.

## Force-repairing `Client not found`

If the browser reaches the `acme-demo` realm but displays **Client not found**, do not reinstall the stack. Run:

```bash
./scripts/force-repair-portal-client.sh
```

This is deliberately more verbose than the normal bootstrap. It authenticates to the Admin REST API, creates or reconciles `acme-demo/acme-portal`, attaches the consent scopes, updates the running Portal environment, and sends the exact OIDC authorization request used by the demo. It exits non-zero and prints the HTTP response if RHBK still rejects the client.
