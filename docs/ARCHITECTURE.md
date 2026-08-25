# ACME Demo Architecture

```text
Legacy Identity -----\
Partner Identity -----+--> RHBK / acme-demo --> ACME Portal
Corporate Identity --/          |
                               +--> peoplesoft-app (passkey step-up)
                               +--> orders-api (token exchange audience)
                               +--> acme-automation (federated workload identity)
                               +--> high-assurance-api (FAPI 2 Client Policy)
```

The browser-facing authorization endpoints use the public OpenShift Route. Portal server-to-server token calls use `http://acme-keycloak-service:8080`.

## Realms

- `acme-demo`
- `legacy-idp`
- `partner-idp`
- `corporate-idp`

All identities and application names are fictional demo data.
