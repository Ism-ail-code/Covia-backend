# Covia — Security Model

How the Covia Supabase schema protects data and what operators must do
to keep it that way. This covers Phases 1–10, with the Phase 10 admin
layer (RBAC, audit, lockdown) as the current security surface.

## 1. Layers of defense

1. **Row Level Security** — every client-facing table is RLS-locked;
   the admin tables (`admin_roles`, `admin_role_permissions`,
   `admin_users`, `admin_audit_log`, `monitoring_events`) have RLS
   enabled (`relrowsecurity = true`) as the last line of defense.
2. **Grant discipline** — clients (`anon`, `authenticated`) get the
   minimal grants: `select`/`update` on their own data where needed,
   **no direct write** on anything governed by RPCs. Phase 10 tables
   grant nothing to clients at all (direct access raises 42501).
3. **Security-definer functions** — every mutation is an RPC that
   re-validates the actor server-side; the client JWT is only the
   *actor id* (`auth.uid()` = `request.jwt.claim.sub`).
4. **Function lockdown** — 0035 revokes `anon` EXECUTE from the entire
   admin + internal surface (`admin_*`, `record_audit`,
   `record_monitoring_event`, `get_platform_health`,
   `has_permission`, …).
5. **Append-only audit** — `admin_audit_log` has no client grants; its
   only writer is security-definer `record_audit()`; rows cannot be
   updated or deleted by any client role (asserted in the smoke suite).
6. **Internal tables are deny-by-default** — `reserved_usernames` (0042)
   plus the admin/config/monitoring tables have RLS enabled with zero
   client grants and zero policies; clients can only reach them through
   SECURITY DEFINER functions (e.g. `is_username_available()`,
   `normalize_username()`), never directly.

## 2. Admin permission matrix (0027)

| Permission | super_admin | admin | moderator | support_agent |
| --- | --- | --- | --- | --- |
| `admin.manage`, `role.manage`, `user.ban`, `ride.cancel` | ✅ | ✅ | — | — |
| `audit.view`, `analytics.view`, `config.view`, `config.manage`, `monitor.view` | ✅ | ✅ | — | — |
| `user.view`, `user.manage`, `user.suspend`, `ride.view`, `report.review`, `verification.review` | ✅ | ✅ | ✅ | — |
| `report.triage` | ✅ | ✅ | ✅ | ✅ |

- `is_admin()` = member of any admin role — **never** a bare boolean
  column on profiles; promotion happens only through the audited
  `admin_set_admin_role`.
- `require_permission(...)` raises `42501` with the caller's role;
  `super_admin` bypasses every check.
- Guardrails: you cannot change/remove your own role; at least one
  super admin must always exist; support agents can never grant roles.

## 3. Enforcement of account status

- **Ban** (`profiles.is_banned`): blocks ride creation/joining, rating
  and reporting (`account_operational_gate` + the
  `rides`/`ride_requests` BEFORE INSERT triggers).
- **Suspension** (active `moderation_actions` row, `ends_at` honored):
  same participation blocks while active; lifted by
  `admin_reactivate_user` or expiry — `ends_at` semantics, so a lifted
  user is immediately unlocked.
- **Admin cancellation** uses the `cancelled_by_admin` timeline event,
  which the reliability engine ignores — punitive actions never corrupt
  a host's score.

## 4. Privacy by design

- Verification documents live in a **private** storage bucket
  (owner + admin only; signed URLs).
- Ratings are double-blind: unrevealed ratings are invisible to the
  counterpart; reports and appeals are confidential.
- `public_profiles` view exposes only public columns; `phone`, DOB,
  emergency contacts and report counts never appear in it.

## 5. Operator checklist

- [ ] Only the **anon key** ships in the mobile client; the service
      key stays server-side
- [ ] Admin seats are minimal and role-scoped (matrix above)
- [ ] `admin_audit_log` is exported/retained for compliance and is
      never granted to clients
- [ ] `get_platform_health()` is monitored; `monitoring_events` feeds
      alerting
- [ ] pg_cron schedules (expiry/reveal/moderation/safety) are enabled
- [ ] RLS is never disabled for public tables; re-run
      `scripts/sql-smoke.mjs` (739 checks incl. anon lockdown +
      table revokes + reserved_usernames lockdown) after any schema change
