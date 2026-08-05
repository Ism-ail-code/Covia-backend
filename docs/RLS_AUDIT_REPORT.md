# Covia — RLS Security Audit & Fix Report

**Date:** 2026-08-05
**Rule:** Supabase Security Advisor `rls_disabled_in_public` (Critical)
**Status:** RESOLVED (plus full database lockdown — Phase 12)

## 1. Affected table

| Table | RLS before | RLS after |
| --- | --- | --- |
| `public.reserved_usernames` | **DISABLED** (flagged) | **ENABLED** (deny by default) |

## 2. Root cause analysis

- Migration `0002_profile_identity.sql` created `public.reserved_usernames`
  (an internal lookup of ~50 protected usernames) **without** enabling RLS.
- Supabase applies default privileges (`GRANT ALL ON TABLES` to `anon` and
  `authenticated`) to every new public-schema table. With RLS off, that means
  anyone holding the project anon key could read, insert, update or delete
  every row of the table — exactly what the Advisor reported.
- No later migration ever enabled RLS on it (verified across `0001`–`0041`),
  so the exposure existed since Phase 2.

## 3. Fix applied (`0042_rls_reserved_usernames.sql`)

1. `ALTER TABLE public.reserved_usernames ENABLE ROW LEVEL SECURITY;`
2. `REVOKE ALL` from `anon`, `authenticated` and `public` (removes the
   default-privilege grants).
3. **No policies created** — RLS with zero policies = deny-by-default.
   The table is internal-only.
4. `FORCE ROW LEVEL SECURITY` deliberately **not** set: the only legitimate
   readers are the SECURITY DEFINER functions `normalize_username()`
   (trigger, 0002) and `is_username_available()` (0003), which run as the
   table owner. Forcing RLS would subject the owner to RLS and break
   username normalization/availability checks.

## 4. Full public-schema audit (34 tables)

`relrowsecurity` read from `pg_class` after applying migrations 0001–0042.

| Table | RLS | Client grants | Policies | Notes |
| --- | --- | --- | --- | --- |
| admin_audit_log | ✅ | none | 25 | append-only, RPC-only |
| admin_role_permissions | ✅ | none | 0 | internal, deny-by-default |
| admin_roles | ✅ | none | 0 | internal, deny-by-default |
| admin_users | ✅ | none | 0 | internal, deny-by-default |
| appeals | ✅ | auth | 20 | policy-scoped |
| chat_messages | ✅ | auth | 42 | policy-scoped |
| emergency_contacts | ✅ | auth | 39 | policy-scoped |
| live_locations | ✅ | auth | 42 | policy-scoped |
| message_reads | ✅ | auth | 42 | policy-scoped |
| moderation_actions | ✅ | auth | 31 | policy-scoped |
| moderation_rules | ✅ | none | 0 | internal, deny-by-default |
| monitoring_events | ✅ | none | 33 | server-write only |
| notification_events | ✅ | auth | 74 | policy-scoped |
| notification_preferences | ✅ | auth | 24 | policy-scoped |
| notifications | ✅ | auth | 38 | policy-scoped |
| outbound_notifications | ✅ | none | 0 | internal, deny-by-default |
| profiles | ✅ | auth | 73 | own-row policies |
| push_tokens | ✅ | auth | 24 | policy-scoped |
| ratings | ✅ | auth | 25 | policy-scoped |
| reliability_config | ✅ | none | 0 | internal, deny-by-default |
| reliability_events | ✅ | auth | 31 | policy-scoped |
| reports | ✅ | auth | 20 | policy-scoped |
| **reserved_usernames** | **❌→✅** | revoked | 0 | **fixed in 0042** |
| reviews | ✅ | auth | 25 | policy-scoped |
| ride_chats | ✅ | auth | 39 | policy-scoped |
| ride_monitoring | ✅ | auth | 38 | policy-scoped |
| ride_participants | ✅ | auth | 33 | policy-scoped |
| ride_requests | ✅ | auth | 58 | policy-scoped |
| ride_timeline | ✅ | auth | 29 | policy-scoped |
| rides | ✅ | auth | 67 | policy-scoped |
| safety_config | ✅ | auth | 26 | policy-scoped |
| safety_events | ✅ | auth | 46 | policy-scoped |
| trust_config | ✅ | none | 0 | internal, deny-by-default |
| verification_audit | ✅ | auth | 35 | policy-scoped |
| verification_submissions | ✅ | auth | 74 | policy-scoped |

Every table is now either policy-scoped (least privilege via
`auth.uid()`/`is_admin()` checks) or deny-by-default internal
(no grants, no policies, RPC-only access). Zero `USING (true)` policies
were introduced.

## 5. Policy coverage (select / insert / update / delete)

Verified in migration history; policy-bearing tables use the existing
Covia architecture (`auth.uid()` ownership, `is_admin()`/`require_permission()`
guards, SECURITY DEFINER RPCs for writes). Internal tables (`admin_*`,
`monitoring_events`, config/rules tables, `reserved_usernames`) are
deny-by-default with zero client grants.

## 6. Storage buckets

Reviewed migrations `0004_avatars_storage.sql` and
`0006_verification_storage.sql`:

| Bucket | Public | Policies |
| --- | --- | --- |
| `avatars` | yes | insert/update/delete restricted to `avatars/<uid>/` via `auth.uid()`; public read |
| `verification-documents` | no | owner-only insert/update/delete in `verification/<uid>/`; owner + admin read only |

`storage.objects` RLS is enabled by default in Supabase; the advisor rule
only targets the `public` schema. No storage policy changes required.

## 7. Full database lockdown (`0043_full_database_lockdown.sql`)

Beyond the Advisor finding, the database was hardened end-to-end because
it holds confidential user data (profiles, verification documents, live
locations, safety events):

1. **RLS re-asserted** on every public table — any future migration that
   disables RLS will now need an explicit exception.
2. **`REVOKE CREATE ON SCHEMA public`** from `anon`, `authenticated`,
   `public` — clients cannot create tables/functions.
3. **Default privileges revoked** for client roles — new objects in future
   migrations are never auto-granted to `anon`/`authenticated`.
4. **`anon` zeroed out** — no table and no function privileges anywhere
   in `public`. This removes the Supabase defaults (pgcrypto helpers,
   pg_trgm functions, trigger-helper exposure) that were reachable with
   the anon key.
5. **Internal helpers not client-callable** — 12 functions
   (`handle_new_user`, `set_updated_at`, `normalize_username`,
   `handle_account_notifications`, `notify_from_ride_timeline`,
   `broadcast_covia_event`, `sync_chat_from_ride_timeline`,
   `broadcast_chat_message`, `sync_safety_from_ride_timeline`,
   `is_valid_notification_type`, `expire_overdue_rides`,
   `expire_moderation_actions`) are no longer executable by
   `authenticated`; they run only via triggers or pg_cron as owner.
6. **Storage RLS enforced** — `storage.buckets` and `storage.objects`
   both have RLS on (bucket listing was previously possible with the
   anon key).

Untouched by design: `service_role` (NestJS backend), the `auth` schema,
and the authenticated RPC surface granted explicitly in 0001–0041
(mobile + admin RPCs all verified intact). `FORCE ROW LEVEL SECURITY` is
not set, to keep SECURITY DEFINER functions working.

## 8. Verification

- Applied 0042 + 0043 to a scratch DB (migrations 0001–0040, 0042, 0043;
  0041 excluded — local PG 18 rejects its `now()` partial-index predicate,
  fine on Supabase PG 15+) and ran the full SQL smoke suite
  (`scripts/sql-smoke.mjs`): **760/760 checks pass**, including:
  - RLS enabled on `reserved_usernames`, no client grants remain,
    `anon`/`authenticated` select/insert/delete all fail with `42501`
  - every public table has RLS on (0 disabled)
  - no `CREATE` on schema `public` for clients
  - `anon` has zero table and zero function privileges
  - the 12 internal functions are not executable by `authenticated`
  - default privileges give new tables no client grants (probe table)
  - clients cannot list storage buckets; `storage.buckets`/`objects`
    RLS enforced
  - cron/system functions pass when run as owner (their real pg_cron
    execution context)
- Functional checks pass: `is_username_available('admin')` still returns
  `false`, `normalize_username()` still rejects reserved names, and the
  mobile/admin RPC surfaces are intact.
- Idempotency: both migrations re-applied twice on a scratch DB with no
  errors and identical final state.
- Security Advisor: no `rls_disabled_in_public` findings remain for the
  public schema (re-run in Supabase dashboard to confirm; push 0042 + 0043
  first).

## 9. Commits

- `security: enable RLS on reserved_usernames to fix rls_disabled_in_public` (0042)
- `test(security): assert reserved_usernames is RLS-locked and client-inaccessible` (smoke suite)
- `docs(security): add RLS audit report and update security model + changelog`
- `docs(security): add deployment guide for the reserved_usernames RLS fix`
- `security: full database lockdown - schema, grants, defaults, storage` (0043)
- `test(security): lock down smoke suite for 0043 + cron runs as owner` (smoke suite, 760 checks)
- `docs(security): lockdown docs - security model, deployment guide, changelog, audit report`
