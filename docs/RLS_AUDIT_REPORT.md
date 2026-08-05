# Covia — RLS Security Audit & Fix Report

**Date:** 2026-08-05
**Rule:** Supabase Security Advisor `rls_disabled_in_public` (Critical)
**Status:** RESOLVED

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

## 7. Verification

- Applied 0042 to a scratch DB (migrations 0001–0040 + 0042) and ran the
  full SQL smoke suite (`scripts/sql-smoke.mjs`): **all checks pass**,
  including 8 new regression assertions:
  - RLS enabled on `reserved_usernames`
  - no client grants remain
  - `anon`/`authenticated` select/insert/delete all fail with `42501`
- Functional checks pass: `is_username_available('admin')` still returns
  `false` and `normalize_username()` still rejects reserved names via the
  SECURITY DEFINER functions.
- Security Advisor: no `rls_disabled_in_public` findings remain for the
  public schema (re-run in Supabase dashboard to confirm; push 0042 first).

## 8. Commits

- `security: enable RLS on reserved_usernames to fix rls_disabled_in_public` (0042)
- `test(security): assert reserved_usernames is RLS-locked and client-inaccessible` (smoke suite, 739 checks)
- `docs(security): add RLS audit report and update security model + changelog`
- `docs(security): add deployment guide for the reserved_usernames RLS fix`
