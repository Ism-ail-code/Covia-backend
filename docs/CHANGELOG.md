# Changelog

All notable changes to the Covia backend are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/) conventions.

## [Unreleased]

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
