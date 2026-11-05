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

## 9 — RHBK as an Identity Provider (IdP)

From the Portal, select **IdP examples** (or open `/idp`).

1. Open **ACME Storefront** and sign in with the existing ACME demo user.
   The app uses its own OIDC client `acme-storefront`.
2. Open **ACME Rewards** in the same browser. Its separate OIDC client
   `acme-rewards` trusts the same RHBK issuer. The RHBK browser SSO
   session can be reused without entering credentials again.
3. Select **Compare client-specific OIDC evidence** to show identical realm
   issuer and user `sub`, but distinct client IDs and ID token audiences.
   No raw tokens are displayed.
4. Open **Live OIDC discovery metadata** to show the standard identity
   provider endpoints that both clients use.
5. Compare with **Identity brokering**, which redirects the user to a
   fictional external provider.
6. **Clear local example sessions** removes portal indicators only;
   it does not log the browser out of RHBK.

**Talking point:** RHBK can be a shared ACME Identity Provider trusted by
multiple ACME applications. Each application gets its own client registration,
policy configuration and OIDC tokens, while users benefit from SSO.

**Lab boundaries:** These are separate OIDC clients hosted as pages in one
Python portal. The users and provider configurations are fictional.
Both clients are public and require PKCE S256. No external integrations
are needed for this demonstration.

To deploy changes to the existing OpenShift lab:

```bash
./scripts/apply-demo-update.sh
```
