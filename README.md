# ACME Digital Identity Demo — Red Hat build of Keycloak on OpenShift

A compact customer-facing **RHBK 26.6** demo for an existing OpenShift cluster. The repository uses only fictional **ACME** identities and applications and generates runtime secrets in OpenShift; no passwords are committed.

> Demo/lab only. The deployment is intentionally small and is not a production reference architecture.

## What it demonstrates

1. **Identity brokering** — Legacy, Partner and Corporate OIDC identity sources resolve to the ACME realm.
2. **Passkeys / WebAuthn** — discoverable passwordless credentials and fresh passkey sign-in.
3. **Client-specific step-up** — `peoplesoft-app` is bound to a dedicated WebAuthn passwordless browser flow.
4. **Granular OAuth scopes** — request `personal-details`, `orders-history` and `support-profile` independently and show token evidence.
5. **OAuth 2.0 Token Exchange** — RFC 8693 exchange from the ACME Portal token to an `orders-api` token.
6. **OpenShift workload identity** — a projected Kubernetes ServiceAccount JWT authenticates `acme-automation` with **Signed JWT - Federated**, with no permanent RHBK client secret.
7. **API-driven onboarding** — a 10-minute, one-use Initial Access Token registers a client and proves the same IAT cannot be reused.
8. **FAPI 2.0** — verifies the built-in RHBK FAPI 2 profiles and applies `fapi-2-security-profile` to `high-assurance-api` through a Client Policy.
9. **RHBK as an IdP** — ACME Storefront and ACME Rewards use separate OIDC clients against one RHBK issuer, demonstrating SSO and client-specific token evidence.

## Prerequisites

- OpenShift cluster and cluster-admin access
- Default StorageClass
- Access to the Red Hat Operator catalog and registry
- Local `oc`, `curl`, `jq`, `openssl`, `python3`

## Install

```bash
./scripts/preflight.sh
./scripts/install.sh
```

The installer creates namespace `rhbk`, PostgreSQL, RHBK, the ACME Portal, demo realms/clients/scopes/users and the workload ServiceAccount.

For an existing deployment, apply the current source without rebuilding the database:

```bash
./scripts/apply-demo-update.sh
```

## URLs and generated credentials

```bash
./scripts/demo-info.sh
```

Secrets are generated into OpenShift Secrets and are not stored in this repository.

## Recommended demo sequence

Open the Portal printed by `demo-info.sh`, then walk through sections 1–9 in order.

### 1. Identity brokering

Use the Portal buttons for:

- Legacy Identity
- Partner Identity
- Corporate Identity

The Portal status turns green after successful brokered authentication. The **Revoke** button resets only the Portal demo indicator; persistent federated identity links remain managed by RHBK.

### 2. Passkeys / WebAuthn

Register a credential from the Portal, then use **Test standard passkey sign-in** and select **Sign in with Passkey** in RHBK. The Portal status is a demo-flow indicator; credential management remains in the RHBK Account Console.

### 3. PeopleSoft client-specific step-up

`peoplesoft-app` uses the `peoplesoft-step-up` browser-flow override with `WebAuthn Passwordless Authenticator` set to `REQUIRED`.

### 4. Granular scopes

The Portal provides a clear review UX and then asks RHBK for optional scopes. A status turns green only when the returned token contains the requested scope(s).

The Portal intentionally keeps `consentRequired=false` on `acme-portal`; this demo shows granular OAuth scope issuance, not a complete business consent ledger.

### 5. RFC 8693 Token Exchange

View the current claims, then exchange the source token for `aud=orders-api`. The evidence page shows sanitized claims and token fingerprints rather than bearer tokens.

### 6. OpenShift workload identity

```bash
./scripts/configure-workload-identity.sh
./scripts/workload-token-test.sh
```

Expected flow:

```text
OpenShift ServiceAccount
  -> projected 600-second JWT
  -> RHBK Kubernetes identity provider
  -> Signed JWT - Federated
  -> client_credentials
  -> short-lived OAuth access token
```

The test Pod contains no RHBK client secret and satisfies restricted PodSecurity settings.

### 7. API-driven onboarding

```bash
./scripts/dynamic-client-registration.sh
```

The script creates a **600-second / one-use** Initial Access Token, uses only that token for the developer registration call, verifies the registered client where a Registration Access Token is returned, then deliberately reuses the same IAT and expects rejection.

The sandbox Route may not expose the Client Registration path, so the script uses a temporary `oc port-forward` as transport. The registration request is still authenticated only by the IAT.

### 8. FAPI 2.0

```bash
./scripts/configure-fapi2.sh
```

The script verifies these built-in profiles from the running RHBK instance:

```text
fapi-2-security-profile
fapi-2-message-signing
fapi-2-dpop-security-profile
fapi-2-dpop-message-signing
```

It then applies `fapi-2-security-profile` to `high-assurance-api` using the `acme-fapi2-high-assurance` Client Policy and verifies the configuration before the Portal turns green.

This proves **RHBK FAPI policy configuration**; it does not claim independent certification of the ACME demo application.

## Important implementation details

The browser uses the public RHBK Route:

```text
KEYCLOAK_URL=https://<route>
```

Server-to-server token calls from the Portal use the internal service:

```text
KEYCLOAK_BACKCHANNEL_URL=http://acme-keycloak-service:8080
```

This avoids routing OAuth backchannel requests through the external OpenShift Route.

## Main files

```text
portal/app.py                         ACME Portal and demo status/evidence UI
scripts/bootstrap-demo.sh             Realm/client/broker/passkey bootstrap
scripts/configure-workload-identity.sh Federated workload client configuration
scripts/workload-token-test.sh         Projected-SA-token live test
scripts/dynamic-client-registration.sh Controlled client-registration live test
scripts/configure-fapi2.sh             FAPI 2 Client Policy configuration/test
scripts/apply-demo-update.sh            Update an existing demo
```

## Cleanup

```bash
./scripts/cleanup.sh
```

For detailed presenter notes see `docs/DEMO-RUNBOOK.md`; for troubleshooting see `docs/TROUBLESHOOTING.md`.

## 9. RHBK as an Identity Provider service

Open **IdP examples** on the portal homepage, or visit `/idp`.
This is a real OIDC authentication demonstration using **fictional ACME applications**:

- **ACME Storefront** — client `acme-storefront`
- **ACME Rewards** — client `acme-rewards`

Each client uses the RHBK `acme-demo` realm as an **Identity Provider**.
Both use OAuth 2.0 Authorization Code with mandatory PKCE S256.
Sign into ACME Storefront and then open ACME Rewards **in the same browser**.
RHBK can reuse the existing SSO session. Select
**Compare client-specific OIDC evidence** to inspect:

- The same trusted realm issuer and user `sub` across both applications
- Separate client IDs and ID token audiences for each application
- Sanitized token claims and short token fingerprints (never bearer tokens)

**IdP versus broker:** As an IdP, RHBK authenticates ACME users and issues
tokens for registered applications. The existing **Identity brokering**
scenario demonstrates how RHBK can delegate authentication to fictional
upstream providers instead.

**Lab scope:** The applications are two separate OIDC clients hosted as
views in the same ACME Portal, not independent deployments. The accounts
are pre-created ACME demo users; self-registration is not enabled.
All names and data are fictional.

**Security:** This demo uses public clients with mandatory PKCE S256;
production server-side applications should evaluate appropriate confidential
client authentication and full token validation. Clearing local IdP demo
sessions does **not** terminate the RHBK browser SSO session.

Deploy updates:

```bash
./scripts/apply-demo-update.sh
```

See the [demo runbook](docs/DEMO-RUNBOOK.md) for a short walkthrough.
