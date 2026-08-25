# ACME RHBK Customer Demo Runbook

## Before the session

- Confirm all `rhbk` pods are Running/Ready.
- Run `./scripts/demo-info.sh` and keep the output available privately.
- Open the ACME Portal, Admin Console and Account Console in separate tabs.
- Register a passkey before the meeting if you want a guaranteed fast login demo; keep another demo user/browser profile available if you want to show registration live.
- Test `./scripts/token-exchange.sh`.
- Test `./scripts/workload-token-test.sh` after workload identity has been configured.
- Use a private/incognito window for broker and consent flows to avoid an existing SSO session skipping screens.

## 0–5 minutes — architecture

Explain that applications trust a single ACME RHBK issuer while authentication can be delegated to multiple upstream identity systems.

Show the three realms and two broker buttons.

## 5–12 minutes — brokered login and account linking

1. Open the ACME Portal.
2. Choose Sign in.
3. Select Legacy Identity.
4. Authenticate as `alex`.
5. If RHBK detects the existing ACME user, complete the account-linking verification.
6. Open Account Console -> Linked accounts.
7. Link Partner Identity.
8. Sign out and demonstrate that either external identity resolves to the same ACME user.

Talking point: account linking is an identity-brokering function. Administrative impersonation is a separate privileged function and should not be confused with identity linking.

## 12–20 minutes — passkeys

1. In Account Console, register a passwordless WebAuthn credential/passkey.
2. Use Touch ID, Windows Hello, a mobile passkey or a hardware security key.
3. Sign out.
4. Sign in with the passkey.

Talking point: cryptographic phishing-resistant authentication with a simpler user experience than password + OTP.

## 20–27 minutes — consent

1. Start a private browser session.
2. Open the ACME Portal.
3. Choose `Request personal details`.
4. Show the consent item.
5. Repeat with multiple scopes.

Explain where OAuth scope consent ends and a richer business consent ledger/application begins.

## 27–33 minutes — token exchange

1. Login to ACME Portal.
2. Show current token claims.
3. Click Exchange token for Orders API.
4. Compare the `aud` and scope claims.

Alternative CLI:

```bash
./scripts/token-exchange.sh
```

## 33–39 minutes — workload identity

Run:

```bash
./scripts/configure-workload-identity.sh
```

Show:

- Kubernetes issuer and ServiceAccount subject.
- `openshift` Kubernetes identity provider in RHBK.
- Client `acme-automation` -> Credentials -> Signed JWT - Federated.
- The projected token expires after ten minutes.
- The RHBK access token returned without a static RHBK client secret.

## 39–43 minutes — self-service onboarding

Run:

```bash
./scripts/dynamic-client-registration.sh
```

Show that the Initial Access Token is short-lived and count-limited.

Explain that a developer portal/GitOps pipeline can use this mechanism without granting realm-admin privileges to every application team.

## 43–45 minutes — FAPI 2.0

Open Realm settings -> Client policies -> Profiles.

Show the built-in FAPI 2 profiles and the `high-assurance-api` client.

Position FAPI as a high-assurance OAuth/OIDC profile rather than a feature exclusively relevant to financial institutions.

## Closing architecture

```text
People:    External IdPs -> RHBK -> Passkeys + consent -> applications
Services:  User token -> token exchange -> downscoped API token
Workloads: OpenShift ServiceAccount -> federated client auth -> short-lived OAuth token
Delivery:  Git/Ansible/API -> controlled client onboarding
```
