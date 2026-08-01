# Covia — Deployment Guide

Production rollout for the Covia Supabase backend (Phases 1–10). The
mobile app talks only to Supabase (Auth + Postgres + Storage); there is
no HTTP API to deploy — the NestJS repo hosts the schema, the smoke
suite and the docs.

## 1. Create the Supabase project

1. Create a project at https://supabase.com (region closest to users).
2. Copy the **Project URL** and **anon key** into `covia-mobile/.env`
   (`EXPO_PUBLIC_SUPABASE_URL`, `EXPO_PUBLIC_SUPABASE_ANON_KEY`).

## 2. Apply the migrations

Run every file in `supabase/migrations/` **in order** (0001 → 0035) in
the Supabase SQL Editor:

```bash
# local verification before touching production:
pnpm db:dev:start
node scripts/sql-smoke.mjs   # applies all migrations + asserts (725/725)
```

Manual checklist (SQL Editor):

- `0001_profiles.sql` first (creates `profiles` + signup trigger).
- Run the rest sequentially; each file is idempotent (`create if not
  exists`, `create or replace`).
- Migrations 0027–0035 (admin dashboard) depend on every earlier file
  and on each other — apply them in one pass, in order.

### Post-migration setup

| Item | Where | Notes |
| --- | --- | --- |
| Auth providers | Dashboard → Authentication | Email + password; confirmation + recovery URLs use the `companion://verify` / `companion://reset` deep links |
| Storage buckets | created by 0004 / 0006 | `avatars` public (5 MB), `verification-documents` **private** (10 MB) |
| Reviewer / admin accounts | SQL Editor | `insert into public.admin_users (user_id, role_name) values ('<uuid>', 'super_admin');` — one super admin is mandatory (0035 keeps at least one) |
| Realtime | Database → Replication | Published tables: `rides`, `ride_timeline`, `notifications`, `chat_messages`, `message_reads`, `live_locations`, `safety_events`, `ratings`, `reviews` |
| pg_cron | Database → Extensions | `pg_cron` (ride expiry, review reveal, moderation expiry, safety monitor); `pg_trgm` (0034 search indexes — the migration skips it when absent) |

## 3. Verify health & monitoring

- `get_platform_health()` (run in the SQL Editor or from an admin
  client) reports `ok`/`degraded` with per-check detail:
  database connectivity/connections, outbound delivery queue,
  monitoring errors in 24h, open emergencies, storage buckets.
- `admin_get_analytics()` gives the daily dashboard numbers
  (users/rides/safety/platform).
- Server-written events land in `monitoring_events`
  (`record_monitoring_event`); wire an external alert on
  `get_platform_health()` → `status = 'degraded'`.

## 4. Backups & recovery

- Supabase manages physical backups (continuous, point-in-time).
- Application-level: `admin_audit_log` is the compliance trail —
  never grant clients write access; export it periodically
  (`select * from public.admin_audit_log` via the service role).
- Migration rollback: migrations are append-only by policy — revert by
  applying the *next* migration that fixes the behaviour, never by
  editing an applied file.

## 5. Performance notes

- Search indexes (0034): trigram GIN on `profiles.display_name`,
  `rides.origin`, `rides.destination` are created only when `pg_trgm`
  is enabled; on Supabase it is available — enable the extension for
  fuzzy search to take effect.
- `admin_*` search RPCs page at ≤ 100 rows and always return
  `total_count`; keep the dashboard on the analytics RPC instead of
  ad-hoc queries.
- `outbound_notifications` is a worker queue: a future delivery
  worker drains `sent_at is null` rows; the partial index
  `outbound_notifications_pending_idx` keeps that sweep fast.

## 6. Production checklist

- [ ] Migrations 0001–0035 applied in order; smoke suite passes
      (725/725) against the local scratch DB
- [ ] `.env` in `covia-mobile` points at the real project; anon key
      only (never the service key in the client)
- [ ] At least one super_admin promoted in `admin_users`
- [ ] Realtime + pg_cron extensions configured
- [ ] `get_platform_health()` reports `ok`
- [ ] Storage buckets public/private settings match 0004/0006
- [ ] Admin access is role-scoped (see SECURITY.md matrix)
