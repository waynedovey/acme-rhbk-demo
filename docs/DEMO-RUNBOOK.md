# ACME RHBK Customer Demo Runbook

## Before the session

- Confirm all `rhbk` pods are Running/Ready.
- Run `./scripts/demo-info.sh` and keep the output available privately.
- Open the ACME Portal and RHBK Admin Console in separate tabs.
- Use **Register / verify passkey** in the portal and confirm Touch ID / Windows Hello / security key works.
- Test the PeopleSoft step-up: ordinary ACME login first, then **Open PeopleSoft — require Touch ID / passkey**.
- Test `./scripts/token-exchange.sh`.
- Test `./scripts/workload-token-test.sh` after workload identity has been configured.
- Use a private/incognito window for broker and consent flows when you want to avoid an existing SSO session hiding screens.

## 0–5 minutes — customer architecture

Start on the portal dashboard. Use the customer-scenario diagram:

```text
PeopleSoft -> Oracle Access Manager -> RHBK -> Microsoft Entra ID
                                   |
                                   +-> policy / brokering / step-up
```

Explain that the lab represents OAM and Entra with lightweight demo components. The important architectural point is that applications trust RHBK while authentication can still be delegated upstream.

## 5–11 minutes — brokered login and account linking

1. In **Demo 1 — Identity brokering**, open the broker chooser.
2. Choose **Legacy Identity** or **Microsoft Entra ID (simulated)**.
3. Authenticate as `alex`.
4. Use Account Console -> Linked accounts to show that external identities can resolve to the same ACME identity.

Talking point: RHBK is the application-facing trust point; upstream identity systems can change independently of the application.

## 11–16 minutes — passkey registration

1. In **Demo 2 — Passkeys / WebAuthn**, click **Register / verify passkey**.
2. Use Touch ID, Windows Hello, a phone passkey or a hardware security key.
3. Sign in again using the passkey if you want to show the normal passwordless experience.

Talking point: phishing-resistant cryptographic authentication with less user friction than password + OTP.

## 16–24 minutes — PeopleSoft-specific step-up

This is the primary customer-specific demo.

1. Establish an ordinary ACME session first using normal brokered SSO.
2. Return to the portal dashboard.
3. In **Demo 3 — PeopleSoft**, click **Open PeopleSoft — require Touch ID / passkey**.
4. RHBK uses the `peoplesoft-app` client, whose browser-flow override is `peoplesoft-step-up`.
5. The flow contains a required `WebAuthn Passwordless Authenticator` execution.
6. Complete Touch ID/passkey authentication.
7. The simulated **PeopleSoft HR — Employee Profile** page opens.
8. Click **View token evidence** if you want to show the resulting OIDC client/session information.

Key point to say:

> The user already has normal SSO, but PeopleSoft contains sensitive personal information, so RHBK applies a stronger authentication control specifically to that application.

The demo intentionally uses a separate client-specific browser flow instead of globally making every application require the stronger factor.

## 24–29 minutes — granular OAuth consent

1. In **Demo 4 — Granular consent**, request `personal-details`.
2. Show the consent item.
3. Repeat with `orders-history` or multiple scopes.

Explain where OAuth scope consent ends and a richer business-consent ledger/application begins.

## 29–34 minutes — token exchange

1. Use **Demo 5 — OAuth 2.0 Token Exchange**.
2. Show the current ACME Portal token.
3. Exchange it for the Orders API.
4. Compare `aud`, `azp` and `scope` claims.

Alternative CLI:

```bash
./scripts/token-exchange.sh
```

## 34–39 minutes — OpenShift workload identity

Run:

```bash
./scripts/configure-workload-identity.sh
./scripts/workload-token-test.sh
```

Show:

- Kubernetes issuer and ServiceAccount subject.
- `openshift` Kubernetes identity provider in RHBK.
- Client `acme-automation` using federated JWT authentication.
- Projected ServiceAccount token is short lived.
- RHBK access token is obtained without a permanent RHBK client secret in the workload.

## 39–42 minutes — API-driven client onboarding

Run:

```bash
./scripts/dynamic-client-registration.sh
```

Show that the Initial Access Token is short-lived and count-limited.

Talking point: a developer portal or GitOps pipeline can onboard applications without giving every application team realm-admin privileges.

## 42–45 minutes — FAPI 2.0 and wrap-up

In **Demo 8 — FAPI 2.0**, open the RHBK Admin Console and show Client Policies / Profiles plus the `high-assurance-api` client.

Position FAPI as a high-assurance OAuth/OIDC policy set rather than something only relevant to banking.

## Closing architecture

```text
People:    External IdPs -> RHBK -> passkeys / step-up -> applications
Sensitive: Normal SSO -> PeopleSoft -> client-specific passkey challenge
Services:  User token -> token exchange -> API token
Workloads: OpenShift ServiceAccount -> federated client auth -> short-lived OAuth token
Delivery:  API / GitOps -> controlled client onboarding
```
