# Changelog

All notable changes to the Covia backend are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/) conventions.

## [Unreleased]

### Phase 5 — Ride management & matching

- `supabase/migrations/0009_rides_schema.sql` — `rides` (statuses
  draft/published/full/in_progress/completed/cancelled, fare modes
  fixed/smart, seat + point + time checks, search indexes), `ride_requests`
  (manual approval workflow, one-pending partial unique index),
  `ride_participants` (Host/Passenger, `left_at`), `ride_timeline` (13
  event types, metadata) + security definer `record_ride_event` helper;
  RLS — select-only grants, `is_ride_member()` helper so policies don't
  recurse.
- `supabase/migrations/0010_rides_creation_functions.sql` — `create_ride`
  (verified hosts only, full validation), `publish_ride` (draft →
  published, host joins as participant), `update_ride` (host, pre-start,
  seat floor, auto full/published restatus, `edited` events only on
  change).
- `supabase/migrations/0011_rides_request_functions.sql` — `request_to_join`
  (verified only, no own ride, duplicates 23505, no overlapping rides
  within 6h — active seats + pending requests), `cancel_ride_request`,
  `leave_ride` (pre-start, frees the seat), `host_respond_to_request`
  (capacity-checked approval, last seat → `full` + `ride_full` event,
  rejection reason).
- `supabase/migrations/0012_rides_lifecycle_functions.sql` — `start_ride`,
  `complete_ride` (increments `total_completed_rides` for host + staying
  passengers), `cancel_ride` (pre-start, no double cancel, closes pending
  requests, increments `total_cancelled_rides`).
- `supabase/migrations/0013_rides_read_functions.sql` — `search_rides`
  (published/full only, ILIKE filters, date/time/seats/student/women
  filters, departure/recent/distance sort with haversine + nulls-last
  fallback, pagination ≤ 50, `total_count` window, host profile joins),
  `get_ride` (drafts host-only), `get_ride_requests` (host queue),
  `get_ride_participants` (members), `get_ride_timeline` (members).
- `supabase/migrations/0014_rides_locations_schema.sql` — structured
  locations on `rides`: `pickup_type` (main-road/landmark/university/
  bus-stop/metro-station/shopping-centre — residential rejected),
  jsonb `origin_loc` / `destination_loc` / `pickup_point_loc` /
  `destination_point_loc` (`display_name`, `latitude`, `longitude`,
  `place_id`, `full_address`), `smart_fare_details`, `visible_at`
  (scheduled search visibility); `ride_location_text()` validator
  helper (revoked from `public`); guarded Supabase Realtime publication
  for `rides` + `ride_timeline`.
- `supabase/migrations/0015_rides_write_functions.sql` — jsonb
  `create_ride` (canonical; legacy text overload dropped — never
  deployed, would be ambiguous), extended `update_ride` (locations,
  pickup type, visibility, smart-fare details), `delete_draft`
  (drafts only — everything else is cancelled/expired), `remove_passenger`
  (pre-start, seat freed, `dropped` event), `expire_overdue_rides()`
  (published/full rides past departure → `expired`; guarded pg_cron job
  `covia-expire-rides` every 15 min, skipped if pg_cron is missing).
- `supabase/migrations/0016_rides_read_functions.sql` — extended
  `search_rides` (`p_verified_host` filter; lazy expiry purge) and
  `get_ride` (expired rides stay visible to host + members);
  `is_user_verified(uuid)`; security-barrier `ride_history` view
  (scoped to `auth.uid()`) + `get_ride_history(p_relation, p_status,
  p_page, p_page_size)`; "rides published read" RLS policy recreated to
  include `expired` status.
- `scripts/sql-smoke.mjs` — Phase 5 assertions: schema/grants, verified
  gates, creation validations, publish/republish, request/approve/reject/
  withdraw, overlap + duplicate + capacity rules, seat floor, lifecycle
  transitions incl. invalid ones, counter updates, timeline event sets,
  search filters/sort/pagination, RPC member gating, direct-write
  blocking. **303/303 pass** (Phases 1–4 + 5), including the Phase 5b
  suite: structured locations (validation, lat/lng bounds, display-name
  extraction), pickup-type rules, visibility scheduling, expiry
  (cron + lazy paths), delete_draft, remove_passenger, verified-host
  filter, ride history view + RPC.
- `docs/DATABASE_SCHEMA.md` — ride tables, lifecycle matrix, RLS and
  functions documented; `docs/API_DOCUMENTATION.md` — RPC reference with
  permissions, statuses and error conventions.

### Phase 1 — Infrastructure (in progress)

- NestJS 11 application scaffolded with pnpm, strict TypeScript.
- Global request-id middleware (`X-Request-Id` / generated UUID, echoed on
  responses, logs, and envelopes).
- Global exception filter → standardized error envelope with friendly
  messages for common Prisma error codes (P2002, P2003, P2025).
- Global transform interceptor → standardized success envelope; pass-through
  for `success`-bearing payloads (enriched with traceability).
- Structured logging with pino (request correlation, redaction, pretty-print
  in development).
- Global validation pipe (whitelist + transform), Helmet, CORS from config,
  gzip compression, URI versioning (`/api/v1`), rate limiting.
- Boot-time environment validation (fails fast on missing/invalid config).
- Prisma 7 integration: `prisma-client` generator (commonjs module format),
  `@prisma/adapter-pg` driver adapter, config via `prisma.config.ts`,
  client regenerated on install.
- Global `PrismaService` with connection lifecycle hooks (global module).
- Embedded PostgreSQL development database (`scripts/dev-db.mjs`, port 5433,
  zero Docker/system install) + pnpm scripts for start/stop/migrate/studio.
- Health check endpoint `GET /api/v1/health` (server + database probe).
- Swagger/OpenAPI documentation at `/api/docs` (development only).
- Unit tests (Jest) and end-to-end tests (supertest against the real DB).
- Documentation: README, PROJECT_ARCHITECTURE, BACKEND_SETUP, src/ layout notes.

### Phase 2 — Supabase Auth support (mobile)

- Added `supabase/migrations/0001_profiles.sql`: `public.profiles` table
  (defaults: verification `Pending`, rating 5.0, reliability 90,
  `is_government_id_verified` / `is_student_verified` false), trigger-based
  profile creation on `auth.users` insert (carries `full_name` / `phone`
  from signup metadata), `updated_at` trigger, RLS restricted to own row.
- Added `docs/SUPABASE_SETUP.md`: project creation, auth settings
  (email signups + confirmation, password policy), redirect URLs for the
  `companion` scheme, SQL application, and manual test checklist.
- Note: authentication itself lives in the mobile client (Supabase Auth);
  the NestJS API remains the Phase 3+ server for business endpoints.

### Phase 4 — Identity verification (mobile)

- `supabase/migrations/0005_verification_schema.sql` — `verification_submissions`
  (type, ID kind, status lifecycle incl. `expired` + `resubmission_requested`,
  review fields, per-type evidence checks, active-row partial unique index),
  `verification_audit`, `admin_users`, `notification_events` (placeholder
  inbox); `is_admin()` security definer helper; RLS — no client writes,
  users read own submissions/notifications only, admins read everything.
- `supabase/migrations/0006_verification_storage.sql` — **private**
  `verification-documents` Storage bucket (10 MB, jpeg/png/webp) with RLS:
  owners insert/update/delete/read only `verification/<uid>/…`, admins may
  read all; documents are referenced by path and rendered via signed URLs.
- `supabase/migrations/0007_verification_user_functions.sql` —
  `submit_verification` (validates evidence, rejects duplicates with 23505),
  `resubmit_verification` (owner-only, for rejected/re-upload requests),
  `get_my_verification`, `is_user_verified` (ride-creation gate).
- `supabase/migrations/0008_verification_admin_functions.sql` —
  `admin_list_verifications(status)` queue (joins user email/name) and
  `admin_review_verification(id, approve|reject|request_resubmission, reason)`
  — approve flips `verification_status` → `Verified` + the matching
  verified flag on `profiles`; every action writes audit + notification.
- `scripts/sql-smoke.mjs` — Phase 4 assertions added: schema/constraints,
  submit/duplicate/evidence rules, admin gating (42501 for non-admins),
  approve/reject/resubmit flows, profile badge updates, notifications,
  audit RLS, storage folder policies + private bucket config. **84/84 pass.**
- `docs/DATABASE_SCHEMA.md` — verification tables, functions, storage, RLS
  and signed-URL guidance documented.

### Phase 3 — User profiles & identity (mobile)

- `supabase/migrations/0002_profile_identity.sql` — identity fields
  (username, date of birth, gender, country), ride-metric placeholders
  (`total_completed_rides`, `total_cancelled_rides`), emergency contact
  columns (all-or-nothing), username rules (unique index, format check
  `[a-z0-9_]{3,20}`, lowercase-normalizing trigger, `reserved_usernames`
  table + rejection trigger), value-hygiene checks (lengths, DOB future,
  gender whitelist).
- `supabase/migrations/0003_public_profiles.sql` — `public_profiles`
  security-barrier view (public columns only — email/phone/DOB/gender/
  emergency contact never exposed) + `get_public_profile(uuid)`,
  `search_profiles(text, int)` and `is_username_available(text)` RPCs
  (security definer, authenticated-only execute) + explicit table grants.
- `supabase/migrations/0004_avatars_storage.sql` — public `avatars`
  Storage bucket (5 MB, jpeg/png/webp) + RLS policies scoped to each
  user's own folder (`avatars/<user-id>/…`), public read.
- `scripts/sql-smoke.mjs` — applies all migrations to a scratch database
  (stubbed `auth`/`storage` schemas) and asserts auto-creation, username
  rules, emergency contacts, public/private split, RLS and bucket config
  (39 checks; `pg` added as a dev dependency).
- `docs/DATABASE_SCHEMA.md` — full schema reference (tables, view,
  functions, storage, RLS, mobile model mapping).
- Note: profile logic lives in the mobile client + Supabase RPCs; the
  NestJS API remains for business endpoints (rides, chat, ratings).
