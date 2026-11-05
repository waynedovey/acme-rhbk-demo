# ACME RHBK Demo Runbook

## Preparation

```bash
./scripts/demo-info.sh
```

Open the ACME Portal and keep the RHBK Admin Console available in another tab.

## 1 — Identity brokering

Authenticate through Legacy, Partner and Corporate Identity. Show that the application continues to trust one ACME issuer while RHBK brokers upstream authentication.

## 2 — Passkeys

Register/verify a passkey, then use **Test standard passkey sign-in** and explicitly choose **Sign in with Passkey** in the RHBK UI.

## 3 — Client-specific step-up

Open PeopleSoft after ordinary SSO. Show that `peoplesoft-app` uses its own `peoplesoft-step-up` browser flow and requires WebAuthn Passwordless Authenticator.

## 4 — Granular scopes

Request Personal details, Orders history, then Multiple scopes. Use **Show consent token evidence** to prove which optional scopes RHBK issued.

## 5 — OAuth 2.0 Token Exchange

View the source claims, exchange for Orders API, then compare the sanitized source and target token evidence. Point out `aud=orders-api` and the different token fingerprints.

## 6 — OpenShift workload identity

```bash
./scripts/configure-workload-identity.sh
./scripts/workload-token-test.sh
```

Show the Portal evidence page after success. Emphasize: projected ServiceAccount JWT, Signed JWT - Federated, short-lived OAuth token, no permanent RHBK client secret.

## 7 — API-driven onboarding

```bash
./scripts/dynamic-client-registration.sh
```

Show the 600-second/one-use IAT, successful client registration, and the blocked second registration attempt.

## 8 — FAPI 2.0

```bash
./scripts/configure-fapi2.sh
```

Show the four built-in RHBK FAPI 2 profiles, then open **Realm Settings → Client Policies** in the Admin Console and show `acme-fapi2-high-assurance` using `fapi-2-security-profile` for `high-assurance-api`.

Do not describe the ACME demo application itself as independently FAPI certified; the demo proves RHBK policy configuration.

## 9 — RHBK as an Identity Provider

Open **IdP examples** on the Portal (or /idp).

1. Open **Citizen Services**, and sign in using the existing ACME demo
   user. This application uses an independent OIDC client.
2. Open **Agency Services** in the same browser. Its separate OIDC client
   trusts the same RHBK realm. RHBK can reuse the existing SSO session.
3. Select **Compare client-specific OIDC evidence** to see the same issuer
   and user subject with different clients, ID token audiences, and token
   fingerprints. No raw tokens are exposed.
4. Open **Live OIDC discovery metadata** to show the public standard
   IdP endpoint and its advertised capabilities.
5. Contrast this with **Identity brokering**, which redirects to a
   fictional upstream identity provider.
6. **Clear local example sessions** removes only portal evidence, not
   the RHBK SSO session.

**DTF talking point:** RHBK can be the shared identity issuer for agency
applications. IDX can remain the broker to DIT and myID. Establishing
ownership of a TRUMPS record is separate and requires DIT-backed proof,
secure linking rules, authorisation and audit.

**Limitations:** No SA ID registration, live IDX or government federation,
DIT verification or TRUMPS linking is configured. The apps are
two views of one Python Portal but distinct RHBK OIDC clients. Public
clients use PKCE S256.

To deploy updates to an existing cluster run ./scripts/apply-demo-update.sh.
