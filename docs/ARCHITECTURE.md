# ACME RHBK Demo Architecture

## Customer scenario represented by the lab

```text
PeopleSoft
    |
    v
Oracle Access Manager
    |
    v
+--------------------------------+
| Red Hat build of Keycloak      |
| realm: acme-demo               |
|                                |
| - identity brokering           |
| - account linking              |
| - passkeys / WebAuthn          |
| - PeopleSoft-specific step-up  |
| - consent scopes               |
| - token exchange               |
| - workload identity            |
| - FAPI client policies         |
+---------------+----------------+
                |
                v
       Microsoft Entra ID
```

The demo does not deploy real PeopleSoft, OAM or Entra. The portal and demo identity realms represent those integration points so the authentication behaviour can be shown without those external systems.

## Browser clients

```text
acme-portal
  browser flow: realm default
  use: normal SSO, brokering, passkeys, consent, token exchange

peoplesoft-app
  browser flow override: peoplesoft-step-up
  required execution: WebAuthn Passwordless Authenticator
  use: sensitive PI application requiring stronger authentication
```

The PeopleSoft client is intentionally isolated from the standard portal authentication path. A user can hold an ordinary RHBK SSO session and still be challenged again when entering PeopleSoft.

## OpenShift resources

```text
Namespace rhbk

rhbk-operator
    |
    +--> Keycloak CR: acme-keycloak
           |
           +--> StatefulSet acme-keycloak
           +--> Service acme-keycloak-service

PostgreSQL Deployment + PVC
ACME Portal Deployment + edge Route
ACME Keycloak edge Route
ServiceAccount acme-automation
```

## Demo capability map

1. Identity brokering and account linking
2. Passkeys / WebAuthn
3. PeopleSoft-specific step-up authentication
4. Granular OAuth consent
5. OAuth 2.0 Standard Token Exchange
6. OpenShift workload identity
7. API-driven client onboarding
8. FAPI 2.0 client policy positioning

## Production note

The lab is intentionally compact enough for a constrained single-node Hub. Production deployments should use an appropriately sized HA database, production TLS design, backup/restore, multiple RHBK instances where required, production resource sizing, and a reviewed integration design for the real OAM / Entra / PeopleSoft protocol boundaries.
