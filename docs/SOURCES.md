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

## PeopleSoft high-assurance / step-up demo references

- RHBK 26.6 Server Administration Guide — authentication flows, WebAuthn passwordless and step-up authentication
  - https://docs.redhat.com/en/documentation/red_hat_build_of_keycloak/26.6/html-single/server_administration_guide/index
- Keycloak Admin REST API — authentication flow creation, execution creation and client configuration
  - https://www.keycloak.org/docs-api/latest/rest-api/index.html

The PeopleSoft demo deliberately uses a **client-specific browser-flow override** containing the WebAuthn Passwordless Authenticator. The portal starts that client authorization with `prompt=login` and `max_age=0`, making the sensitive application obtain a fresh passkey authentication even when a normal ACME browser SSO session already exists.

For a production design where applications consume and verify explicit assurance levels in the token, use Keycloak/RHBK step-up authentication with ACR-to-LoA mappings and have the application validate the resulting `acr` claim. The client-specific flow in this lab is intentionally easier to see in a live demo.
