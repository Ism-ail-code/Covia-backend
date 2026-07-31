# Covia — Database Schema

Auth and profiles live in **Supabase** (managed PostgreSQL). The NestJS
service owns business tables (rides, chat, ratings — future phases) in its
own PostgreSQL database; the schema below is applied to Supabase via the
files in `supabase/migrations/`.

Migrations (apply in order, in the Supabase SQL Editor):

| File | Contents |
| --- | --- |
| `0001_profiles.sql` | `profiles` table, signup trigger, `updated_at` trigger, RLS |
| `0002_profile_identity.sql` | identity fields, username rules, emergency contacts, reserved usernames |
| `0003_public_profiles.sql` | `public_profiles` view + lookup/search/availability functions |
| `0004_avatars_storage.sql` | `avatars` Storage bucket + object policies |
| `0005_verification_schema.sql` | `verification_submissions` + audit trail, `admin_users`, `notification_events`, RLS |
| `0006_verification_storage.sql` | private `verification-documents` Storage bucket + owner/admin policies |
| `0007_verification_user_functions.sql` | user RPCs: submit/resubmit/get my submission/is verified |
| `0008_verification_admin_functions.sql` | admin RPCs: review queue + approve/reject/resubmission review |

## `public.profiles`

One row per user. The primary key **is** the `auth.users` id (uuid,
`on delete cascade`), so no separate `user_id` column is needed.

| Column | Type | Notes |
| --- | --- | --- |
| id | uuid PK | = `auth.users.id`, FK cascade |
| email | text | set by the signup trigger |
| display_name | text | ≤ 60 chars |
| full_name | text | from signup metadata |
| username | text | optional; unique, lowercase, `[a-z0-9_]{3,20}` |
| avatar_url | text | public Storage URL of the profile photo |
| phone | text | **private** (never in `public_profiles`) |
| date_of_birth | date | **private**; not in the future |
| gender | text | `Female` / `Male` / `Non-binary` / `Prefer not to say` |
| home_city | text | ≤ 80 chars (app-level "city") |
| country | text | ≤ 80 chars |
| bio | text | ≤ 500 chars |
| verification_status | text | `Pending` / `In Review` / `Verified` / `Rejected` (default `Pending`) |
| rating | numeric(2,1) | default 5.0; 0–5 |
| reliability_score | integer | default 90; 0–100 |
| total_completed_rides | integer | default 0 — placeholder for Phase 4 |
| total_cancelled_rides | integer | default 0 — placeholder for Phase 4 |
| is_government_id_verified | boolean | default false |
| is_student_verified | boolean | default false |
| emergency_contact_name | text | all-or-nothing with the two below |
| emergency_contact_phone | text | 7–20 chars, **private** |
| emergency_contact_relationship | text | ≤ 40 chars, **private** |
| created_at | timestamptz | default now() |
| updated_at | timestamptz | kept fresh by `set_updated_at()` trigger |

Key constraints & indexes:

- `profiles_username_unique` — unique index on `username` where not null.
- `profiles_username_format` — `username ~ '^[a-z0-9_]{3,20}$'`.
- `profiles_emergency_contact_all_or_nothing` — all three contact columns
  null, or all three set.
- Length/range checks for display_name, bio, city, country, gender, DOB,
  rating, reliability, ride counters.

### Username rules (enforced in `0002`)

- Normalized by the `normalize_username()` trigger: trimmed, lowercased,
  empty → NULL. Runs `before insert or update of username`.
- Reserved names live in `public.reserved_usernames` (seeded with ~46
  service words); the trigger raises if a username matches.
- Availability for the UI: `is_username_available(text)` RPC.

### Row creation

`handle_new_user()` (security definer) fires on `auth.users` insert and
creates the profile row with defaults, carrying `full_name` and `phone`
from signup metadata. The client's `ensureProfile` is an idempotent
fallback for races.

### Row Level Security

- `profiles` — users can `select` and `update` only their own row.
- Table grants: `select, update` for `authenticated` (rows gated by RLS).
- **No** insert/delete policies on `profiles` — creation is trigger-only,
  deletion follows the auth user (cascade).

## `public.public_profiles` (view)

The **public model** — the only read surface for other users. Security
barrier view exposing only: `id, username, display_name, profile_photo_url
(avatar_url), bio, city (home_city), country, overall_rating (rating),
reliability_score, total_completed_rides, total_cancelled_rides,
verification_status, is_government_id_verified, is_student_verified,
created_at`.

Never exposed: email, phone, date_of_birth, gender, emergency contact,
updated_at. The base table's RLS is bypassed for this view by design (view
owner = table owner); the view itself is the guard.

### Functions

| Function | Returns | Purpose |
| --- | --- | --- |
| `get_public_profile(p_user_id uuid)` | `public_profiles` row | view one user's public profile |
| `search_profiles(p_query text, p_limit int default 20)` | setof `public_profiles` | username-prefix search (limit 1–50) |
| `is_username_available(p_username text)` | boolean | format + reserved + uniqueness check |

All three are `security definer`, `search_path = public`, with execute
granted only to `authenticated`.

## Storage (`avatars` bucket)

- Public bucket, `file_size_limit` 5 MB, `allowed_mime_types` jpeg/png/webp.
- Object paths: `avatars/<user-id>/avatar.<ext>` — the user id is the first
  path segment, which the RLS policies key on.
- Policies: insert/update/delete only into one's own folder
  (`(storage.foldername(name))[1] = auth.uid()::text`); public read for
  anon + authenticated.
- The app stores only the public URL in `profiles.avatar_url`.

## Identity verification (0005–0008)

Phase 4 feature: users prove identity with a **government ID** (national ID,
driver's licence or passport — front, optional back, optional selfie) or
**student status** (student card photo OR university email). Review is done
by admins via SQL/RPC; there is no admin UI yet.

### `public.verification_submissions`

One row per verification attempt (an account can have a history — only one
active row per type thanks to a partial unique index).

| Column | Type | Notes |
| --- | --- | --- |
| id | uuid PK | default `gen_random_uuid()` |
| user_id | uuid FK → auth.users | `on delete cascade` |
| verification_type | text | `government_id` / `student` |
| government_id_kind | text | `national_id` / `drivers_license` / `passport` (required for government ID) |
| status | text | `pending` / `approved` / `rejected` / `expired` / `resubmission_requested` |
| submitted_at | timestamptz | set when (re)submitted |
| reviewed_at / reviewed_by | timestamptz / uuid | set by the reviewing admin |
| rejection_reason | text | admin's reason (shown to the user) |
| front_document_url | text | **object path** in `verification-documents`, required for government ID |
| back_document_url / selfie_url | text | optional paths |
| student_card_url / university_email | text | student evidence — at least one required |
| created_at / updated_at | timestamptz | `updated_at` kept fresh by trigger |

Constraints: per-type evidence checks, path length ≤ 500, email format,
partial unique index `(user_id, verification_type)` where status in
(`pending`, `approved`, `resubmission_requested`) — blocks duplicate
submissions while one is live.

### Other tables

- `public.verification_audit` — immutable trail: `submission_id`, `action`
  (`submitted`/`approved`/`rejected`/`resubmission_requested`/`expired`),
  `performed_by`, `reason`, `created_at`. Written only by the security
  definer functions.
- `public.admin_users` — `user_id` PK → auth.users. Adding a row makes that
  user an admin. **There is no UI for this — an owner runs
  `insert into public.admin_users (user_id) values ('<uuid>');` in the SQL
  Editor.**
- `public.notification_events` — placeholder inbox: `user_id`, `event_type`
  (`verification.submitted` / `.approved` / `.rejected` /
  `.resubmission_requested`), `payload` jsonb, `read_at`. The real
  notifications module will consume/replace this.

### Row Level Security

- No direct client writes to any of the four tables — all writes go through
  security definer functions (grants revoked from `public`, `select` granted
  to `authenticated` for submissions, audit and notifications).
- Users read only their own submissions and notification events; admins
  (via `public.is_admin()`) additionally read all submissions, the audit
  trail and all notifications.

### Functions

User side (security definer, `authenticated` only):

| Function | Purpose |
| --- | --- |
| `submit_verification(p_verification_type, p_front_document_url, p_back_document_url, p_selfie_url, p_student_card_url, p_university_email, p_government_id_kind)` | start a check; validates evidence, rejects duplicates (23505), writes audit + notification, returns the row |
| `resubmit_verification(p_submission_id, …same evidence args…)` | re-upload after `rejected`/`resubmission_requested`; only the owner may call it |
| `get_my_verification(p_verification_type)` | caller's latest submission for one type (or null) |
| `is_user_verified()` | boolean — true once **any** type is approved; the gate for ride creation/joining |

Admin side (security definer, guarded by `is_admin()`, `authenticated` only):

| Function | Purpose |
| --- | --- |
| `is_admin()` | membership check against `admin_users` (used by RLS policies too) |
| `admin_list_verifications(p_status text default 'pending')` | review queue with `user_email` / `user_display_name` joined in; `'all'` returns everything |
| `admin_review_verification(p_submission_id, p_action, p_reason)` | `approve` / `reject` / `request_resubmission`; only `pending` rows; approve flips `profiles.verification_status` → `Verified` + the matching `is_government_id_verified` / `is_student_verified` flag; writes audit + notification. Reject requires a reason |

### Storage (`verification-documents` bucket)

- **Private** bucket (`public = false`), `file_size_limit` 10 MB,
  `allowed_mime_types` jpeg/png/webp.
- Object paths: `verification/<user-id>/<slot>-<timestamp>.<ext>` — policies
  key on the first two path segments.
- Policies: insert/update/delete only into one's own folder; **read** by the
  owner **and admins** (everyone else — nothing).
- The app stores only the object **path** on the submission. Owners and
  admins render documents with **signed URLs** generated on demand:
  - owners: `supabase.storage.from(...).createSignedUrl(path, 3600)` client-side
  - admins: must use a service-role client (NestJS admin API, future phase)
    — the anon key cannot sign URLs for other users' documents.

## Mobile model mapping

- `src/types/profile.ts` — `UserProfile` (private) and `PublicProfile`
  (public); `DEFAULT_PROFILE` matches the DB defaults.
- `src/services/profiles.ts` — fetch/ensure/update, username ops,
  emergency contact ops, `getPublicProfile`, `searchProfiles`.
- `src/services/storage.ts` — avatar upload/replace/delete + validation.
- `src/types/verification.ts` — `VerificationSubmission`, status lifecycle,
  ID kinds, `VerificationDraft`.
- `src/services/verification.ts` — document upload to the private bucket,
  submit/resubmit/get-my-verification RPC calls, `isUserVerified()` gate,
  friendly error mapping.
- `app/(app)/verification.tsx` — Government ID / Student ID flows: upload
  tiles per document, kind + method selectors, live status cards
  (pending / approved / rejected with reason / expired), resubmission.
