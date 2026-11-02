# SA Government Identity Journey (optional demo)

This add-on uses only fictional persons and records. **No real SA Government,
DIT, myID or TRUMPS system is connected.** The original eight ACME demos remain
unchanged.

## Logical architecture

    Citizen -> mySAGOV Portal (OIDC)
                     |
                SA ID realm
                  | explicit, link-only federation
                IDX realm ------> myID simulated realm
                  |
             DIT simulated realm
                  |
         Verified DIT subject from RHBK identity link
                  |
       mySAGOV backend -> mock TRUMPS API (ClusterIP only)
                  |
              SQLite record-link and audit ledger

SA ID manages independent citizen registration, passkeys, email verification,
password reset and the primary OIDC subject. IDX is a separate broker realm.
DIT and myID are simulated RHBK provider realms. Mock TRUMPS compares a
trusted, authenticated DIT subject with a *fictional* record owner; it never
uses an email match.

## Two distinct links

1. Identity link: SA ID sub -> IDX federated subject -> DIT federated subject.
   These are actual RHBK federated-identity records, queried server-side using
   separate realm-scoped view-users service accounts.
2. Record entitlement: SA ID sub -> simulated TRUMPS record ID, added only
   after successful DIT subject/record ownership verification.

An unrelated user with an identical email never acquires the record.
A second SA ID claiming an already linked record is rejected, not merged.

## Install

Install the original ACME RHBK demo first. Then:

    bash scripts/install-sagov-demo.sh
    bash scripts/sagov-demo-info.sh

Uses existing namespace rhbk; deploys mySAGOV Portal, mock TRUMPS, Mailpit,
new independent RHBK realms and PVC-backed claim ledger. Installer is additive
and idempotent. No existing ACME realm is updated.

## Customer walkthrough

1. Open the new mySAGOV Route. Select Sign in / Register; click Register
   on the Keycloak login page. Use alex.sa@demo.invalid. SA ID creation
   does not require a DIT or TRUMPS record.
2. Open the Mailpit Route to retrieve the *fictional* email verification
   link. Optionally register a passkey through the SA ID Account Console.
3. Signed-in dashboard starts with no licence. Click Connect DIT identity
   through IDX. This invokes the link-only IDX broker action while the
   citizen holds an authenticated SA ID session.
4. At IDX choose DIT (not myID) and authenticate as dit-alex using the
   password displayed by sagov-demo-info.sh.
5. Back at the dashboard, enter DEMO-LIC-001. The backend reads both actual
   RHBK federated-identity links and calls the mock TRUMPS API with the
   authenticated DIT subject. The matching fictional record is linked and
   the decision is audited.
6. Sign out, sign back in and show the persistent licence entitlement.
7. Attempt DEMO-LIC-002 as dit-alex: deny. Show a second independent
   simulated user dit-jordan owns DEMO-LIC-002.
8. In the RHBK Admin Console show SA ID -> Users -> Federated identities,
   IDX -> Users -> Federated identities and RHBK user events. In the Portal
   show the per-user record-claim audit log.

The SA ID email is intentionally **different** from the mock DIT email.

## Recovery and what is not delivered yet

RHBK self-service password-reset email can be tested using lab Mailpit; no
real email leaves the cluster. Passkey credentials are managed in the RHBK
Account Console. Assisted recovery requiring independent identity proofing
and human approval is **not implemented**. Mailpit inbox and reset links
are reachable via a lab Route; use synthetic users only.

The mock TRUMPS lookup is **not government-grade identity proofing**. It
shows how an approved DIT/TRUMPS proofing or verification API might be
integrated. DIT/IDX SSO may also be reused and therefore the demo cannot
assert fresh high-assurance DIT authentication at the time of linking.
Production would require freshness, proofing evidence, audit, re-authentication
requirements, replay controls and independent record owner verification.

This implementation deliberately restricts one record to one SA ID.
Multiple permitted people accessing one record requires a **separate,
revocable authorisation/delegation model**, not merging identity accounts.

The existing ACME API-driven registration demo is developer self-service,
not citizen account creation. The ACME granular OAuth scope demo does not
constitute a consent ledger.

The SA ID / IDX realms are logical boundaries inside the same RHBK
deployment, NOT separate high-availability or sovereign installations.
Application sessions are single-process and transient, SQLite runs with
one pod/PVC. No production HA, disaster recovery, KMS, security assessment
or legal authorisation is implied.

## Testing

Offline:

    python3 -m unittest discover -s sagov/tests -v
    python3 -m py_compile sagov/mysagov/app.py sagov/trumps/app.py
    bash -n scripts/install-sagov-demo.sh scripts/bootstrap-sagov.sh

Live OpenShift/Keycloak integration requires manual validation of
registration, email verification, passwordless sign-in, IDX linking and
both allowed/denied claims. No live cluster access was used to build this PR.

## Beyond MVP backlog

- Assisted recovery with case workflow and independent proof.
- Mandatory fresh, high-assurance DIT authentication/proofing transaction.
- Reversible delegated access for multiple SA IDs, record consent/expiry.
- Operational separation of SA ID and IDX, scalable sessions and audit export.
- Risk signals, consent management, adaptive authentication and fraud checks.
