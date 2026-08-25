# ACME RHBK Demo Architecture

## Logical identity flow

```text
External identity providers
        |
        | OIDC
        v
+----------------------------+
| RHBK realm: acme-demo      |
|                            |
| Local identity: alex       |
| External identity links    |
| Passkeys / WebAuthn        |
| OAuth consent              |
| Standard Token Exchange    |
| FAPI Client Policies       |
+------+---------------------+
       |
       +--> ACME Portal
       +--> Orders API audience
       +--> OpenShift workload client
```

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

## Design intent

The lab is intentionally compact enough for a constrained single-node Hub. Production deployments should use an appropriately sized HA database, production TLS design, backup/restore, multiple RHBK instances where required, and production resource sizing.
