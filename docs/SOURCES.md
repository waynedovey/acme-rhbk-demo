# Official product references

The demo was built around Red Hat build of Keycloak 26.6 behaviour current in August 2026.

- RHBK 26.6 Operator Guide
  - https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/operator_guide/index
  - Covers Operator installation, `rhbk-operator`, `Keycloak` CR, database prerequisite, OpenShift ingress/hostname behaviour, resource requests, bootstrap admin Secret and Realm Import behaviour.

- RHBK 26.6 Server Administration Guide
  - https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/server_administration_guide/index
  - Covers passkeys/WebAuthn, identity brokering, Kubernetes identity providers, Client Policies and FAPI positioning.

- RHBK 26.6 Securing Applications and Services Guide
  - https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/securing_applications_and_services_guide/index
  - Covers Standard Token Exchange V2 and FAPI 2.0 profiles.

- RHBK 26.6 Release Notes
  - https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/release_notes/index
  - RHBK 26.6 includes federated client authentication, Kubernetes ServiceAccount client authentication, JWT Authorization Grant and Workflows enhancements.

Key product details used by this demo:

- The Operator package name is `rhbk-operator`.
- The Keycloak API is `k8s.keycloak.org/v2beta1`.
- The RHBK Operator does not provision the database.
- The initial admin Secret is `<Keycloak CR name>-initial-admin`.
- Standard Token Exchange V2 is the supported token-exchange implementation.
- RHBK 26.6 supports Kubernetes ServiceAccount tokens for federated client authentication.
- FAPI 2.0 global profiles include `fapi-2-security-profile`, `fapi-2-dpop-security-profile`, `fapi-2-message-signing`, and `fapi-2-dpop-message-signing`.
