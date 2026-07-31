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

## Mobile model mapping

- `src/types/profile.ts` — `UserProfile` (private) and `PublicProfile`
  (public); `DEFAULT_PROFILE` matches the DB defaults.
- `src/services/profiles.ts` — fetch/ensure/update, username ops,
  emergency contact ops, `getPublicProfile`, `searchProfiles`.
- `src/services/storage.ts` — avatar upload/replace/delete + validation.
