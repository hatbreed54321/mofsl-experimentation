# ADR-010: Internal SSO for Dashboard Authentication

**Status:** Accepted
**Date:** 2026-04-01
**Deciders:** Platform Team
**Category:** Security

---

## Context

The experimentation dashboard is an internal tool used exclusively by MOFSL employees (primarily Product Managers). We need an authentication mechanism that is secure, low-friction for users, and maintainable by the platform team.

MOFSL has an existing internal identity provider that supports SAML 2.0 and/or OIDC. All employees already have credentials in this system.

## Decision

**Dashboard authentication uses MOFSL's internal SSO via SAML 2.0 or OIDC (determined by what MOFSL's IdP supports).** The dashboard (Next.js) redirects unauthenticated users to the SSO login page. On successful authentication, the IdP issues a token that the dashboard exchanges for a session. The backend API validates JWT tokens issued by the IdP on every request.

**Phase 1 authorization model:** All authenticated users have full access. No role-based access control (RBAC). Every MOFSL employee who can authenticate can create experiments, upload targets, and view results.

**Phase 2 hook:** RBAC with roles (Viewer, Editor, Admin) is designed-for. The `users` table has a `role` column from day one, defaulting to `admin` for all users in Phase 1. Phase 2 adds middleware that checks role against endpoint permissions.

## Rationale

- **Zero password management:** Platform team does not manage user credentials — SSO handles everything
- **Consistent experience:** MOFSL employees use the same login as other internal tools
- **Security:** IdP handles MFA, password policies, account lockout — we inherit all of this
- **Offboarding:** When an employee leaves MOFSL, their SSO access is revoked centrally — no separate cleanup needed

## Consequences

**Positive:**
- No custom auth code (password hashing, reset flows, MFA) to build or maintain
- Automatic user lifecycle management through central IdP
- Users get a familiar login experience
- Inherits enterprise security policies (MFA, password rotation)

**Negative:**
- Dependency on MOFSL's IdP availability (if SSO is down, dashboard is inaccessible)
- Integration effort with MOFSL's specific IdP (configuration, redirect URIs, token validation)
- No RBAC in Phase 1 — any authenticated user has full access

**Mitigations:**
- SSO downtime is extremely rare for enterprise IdPs and affects all MOFSL internal tools (not specific to us)
- RBAC is designed-for in the schema — Phase 2 implementation is straightforward
- Sensitive operations (experiment deletion, bulk upload) have confirmation dialogs as a safety net

## API Authentication

| Interface | Method | Details |
|---|---|---|
| Dashboard → Control Plane API | JWT Bearer token | Token from SSO, validated on every request |
| SDK → Config Server | API key in `X-API-Key` header | Long-lived key per client app, rotatable |
| Riise App → Event Ingestion API | Same API key as config server | Identifies the calling application |

**API keys for SDK/events:** These are application-level keys, not user-level. Riise has one API key for all its users. The key authenticates the application; the `clientCode` in the request body identifies the end user. Keys are stored in an `api_keys` table in PostgreSQL, hashed with bcrypt.

## Alternatives Considered

1. **Custom email/password auth:** Full control, no external dependency. Rejected because it requires building password management, MFA, and user lifecycle — all already solved by MOFSL's IdP.

2. **API key for dashboard (no SSO):** Simplest to implement. Rejected because it doesn't provide per-user identity, audit trail attribution, or offboarding support.

3. **OAuth2 with Google Workspace:** If MOFSL uses Google. Possible, but SAML/OIDC with the existing IdP is more appropriate for an enterprise internal tool.
