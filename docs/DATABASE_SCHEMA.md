# Covia — Database Schema

Auth, profiles and the **ride coordination layer** live in **Supabase**
(managed PostgreSQL). The NestJS service owns business tables (chat,
ratings — future phases) in its own PostgreSQL database; the schema
below is applied to Supabase via the files in `supabase/migrations/`.

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
| `0009_rides_schema.sql` | `rides`, `ride_requests`, `ride_participants`, `ride_timeline` + RLS |
| `0010_rides_creation_functions.sql` | `create_ride`, `publish_ride`, `update_ride` |
| `0011_rides_request_functions.sql` | request/approval workflow: `request_to_join`, `cancel_ride_request`, `leave_ride`, `host_respond_to_request` |
| `0012_rides_lifecycle_functions.sql` | `start_ride`, `complete_ride`, `cancel_ride` |
| `0013_rides_read_functions.sql` | `search_rides`, `get_ride`, `get_ride_requests`, `get_ride_participants`, `get_ride_timeline` |
| `0014_rides_locations_schema.sql` | structured locations + pickup rules on `rides`, `ride_location_text()` helper, Realtime publication for `rides` / `ride_timeline` |
| `0015_rides_write_functions.sql` | jsonb `create_ride` (canonical), extended `update_ride`, `delete_draft`, `remove_passenger`, `expire_overdue_rides` + pg_cron job |
| `0016_rides_read_functions.sql` | extended `search_rides`/`get_ride` (expiry, `p_verified_host`), `is_user_verified(uuid)`, `ride_history` view + `get_ride_history` RPC |

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
| total_completed_rides | integer | default 0 — incremented by `complete_ride` (Phase 5) |
| total_cancelled_rides | integer | default 0 — incremented by `cancel_ride` (Phase 5) |
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

## Ride coordination (0009–0016)

Phase 5 feature: verified travellers coordinate seats on a shared
vehicle. Covia is **not** ride-hailing — it only manages bookings on
rides whose transport is booked elsewhere (Uber/inDrive/Yango). The
whole lifecycle below lives in Supabase RPCs; the NestJS service is not
involved.

### Lifecycle

```
draft → published → full → in_progress → completed
    \       \        \     \→ cancelled
     \      \→ cancelled
      \→ cancelled
published / full →(departure passed, never started)→ expired
```

| Status | Meaning | Entered via |
| --- | --- | --- |
| `draft` | created but invisible; host editing area | `create_ride` |
| `published` | visible in search, accepting requests | `publish_ride` |
| `full` | all seats taken; still accepting (→ rejected) requests | last approval / seat edit |
| `in_progress` | departed | `start_ride` (host) |
| `completed` | finished; reliability counters updated | `complete_ride` (host) |
| `cancelled` | host cancelled pre-start; open requests closed | `cancel_ride` (host) |
| `expired` | departure passed without starting; archived, never deleted | `expire_overdue_rides()` (pg_cron, every 15 min) |

Rules enforced in the functions (0010–0012, 0015):

- Only **verified users** create rides / request seats
  (`is_user_verified()` — any approved method); verified **students**
  only may create `student_only` rides.
- Departure must be in the future; seats 1–10; `fixed` fares need a
  per-seat amount, `smart` fares must not have one.
- **Structured locations** (0014): `create_ride` takes `origin_loc`,
  `destination_loc`, `pickup_point_loc` jsonb objects (display name ≤
  160 chars, optional lat/lng within ±90/±180); display names are
  copied into the legacy text columns for search. The **pickup point
  must be a public place** — `main_road | landmark | university |
  bus_stop | metro_station | shopping_center` (residential addresses
  are rejected).
- **Visibility scheduling** (0015): `visible_at` schedules when a ride
  appears in search; must be in the future and before departure.
- **Expiry** (0015): published/full rides whose departure passes
  without starting are archived `expired` — they leave search, stop
  accepting requests, open requests close, and they are never deleted.
  Runs via pg_cron (`covia-expire-rides`, every 15 min) and lazily
  inside `search_rides`/`get_ride`.
- Seat edits cannot drop below the approved passenger headcount.
- Requests: pending-only duplicates rejected (23505), hosts cannot
  request their own ride, no **overlapping rides** — an active seat or
  pending request on another ride departing within **6 hours** blocks
  the request (departed/cancelled/completed rides don't count, and a
  passenger who left frees the window).
- Approvals enforce capacity: the last seat flips the ride to `full`;
  further approvals are refused. Leaving a ride frees the seat and
  re-opens a full ride.
- Editing is host-only and stops once the ride starts; cancellations
  are host-only, pre-start only, recorded forever (reliability
  scoring), and close pending requests.
- `complete_ride` increments `total_completed_rides` for the host and
  every passenger who stayed; `cancel_ride` increments
  `total_cancelled_rides` for the host.
- The host can **remove a passenger** before the ride starts
  (`remove_passenger`); drafts are the only rides that can be deleted
  (`delete_draft`) — everything else is cancelled or expired instead.

### `public.rides`

| Column | Type | Notes |
| --- | --- | --- |
| id | uuid PK | `gen_random_uuid()` |
| host_id | uuid FK → auth.users | owner; `on delete cascade` |
| origin / destination | text | 1–120 chars, trimmed; display-name copies of the location objects |
| pickup_point / destination_point | text | 1–160 chars (destination optional) |
| pickup_type | text | `main_road` / `landmark` / `university` / `bus_stop` / `metro_station` / `shopping_center` |
| origin_loc / destination_loc / pickup_point_loc / destination_point_loc | jsonb | structured locations (0014): `display_name`, `latitude`, `longitude`, `place_id`, `full_address` |
| smart_fare_details | jsonb | smart-fare pricing model (0015); only on `smart` fares |
| visible_at | timestamptz | scheduled search visibility (0015); future + pre-departure |
| origin_lat / lng, destination_lat / lng | numeric(9,6) | copied from the location objects for distance sort |
| departure_time | timestamptz | must be in the future when created/edited |
| estimated_arrival | timestamptz | > departure_time |
| total_seats | integer | 1–10 |
| available_seats | integer | 0–total |
| fare_mode | text | `fixed` / `smart` |
| fixed_fare | numeric(10,2) | required when `fixed`, forbidden when `smart` |
| ride_status | text | lifecycle above; default `draft` |
| is_student_only / is_women_only | boolean | filters, not hard gates (women-only is a preference, not enforcement) |
| notes | text | ≤ 1000 chars |
| created_at / updated_at | timestamptz | `updated_at` via `set_updated_at()` trigger |

Indexes: `(ride_status, departure_time)`, origin, destination, host_id,
student/women flags.

### `public.ride_requests`

| Column | Type | Notes |
| --- | --- | --- |
| id | uuid PK | |
| ride_id | uuid FK → rides | `on delete cascade` |
| passenger_id | uuid FK → auth.users | `on delete cascade` |
| status | text | `pending` / `approved` / `rejected` / `cancelled` |
| requested_at / responded_at | timestamptz | response time set on any non-pending outcome |

Partial unique index `(ride_id, passenger_id) where status = 'pending'`
— one open request per (ride, passenger).

### `public.ride_participants`

| Column | Type | Notes |
| --- | --- | --- |
| ride_id + user_id | PK (both FK, cascade) | |
| role | text | `Host` (added on publish) / `Passenger` (added on approval) |
| joined_at / left_at | timestamptz | `left_at` marks pre-start departures |

### `public.ride_timeline`

Every event, timestamped — powers the activity feed and notifications
in later phases. Columns: `id`, `ride_id` (FK, cascade), `event_type`
(one of 15 values), `actor_id` (FK → auth.users, set null on delete),
`metadata` jsonb, `created_at`.

Event types: `created`, `published`, `requested`, `request_cancelled`,
`approved`, `rejected`, `joined`, `left`, `ride_full`, `edited`,
`started`, `completed`, `cancelled`, `dropped`, `expired`. Written only
by the security definer `record_ride_event(ride_id, event, actor,
metadata)` helper (revoked from `public`).

### Row Level Security

- Tables are readable only via the `authenticated` role (no client
  writes anywhere — grants are `select`-only, everything else runs
  through security definer functions).
- `rides` — host sees own; participants (via `is_ride_member()`)
  see their ride; everyone sees non-draft rides.
- `ride_requests` — passenger sees own, host sees requests on their
  rides.
- `ride_participants` — only ride members (via `is_ride_member()`).
- `ride_timeline` — host or members.
- `is_ride_member(ride_id, user_id)` is a security definer helper so
  policies don't recurse into `ride_participants`.

### Functions

Write side (security definer, `authenticated` only; every mutation
writes timeline events):

| Function | Purpose |
| --- | --- |
| `create_ride(p_origin_loc, p_destination_loc, p_pickup_point_loc, p_departure_time, p_total_seats, p_fare_mode, p_fixed_fare, p_notes, p_destination_point_loc, p_is_student_only, p_is_women_only, p_pickup_type, p_visible_at, p_estimated_arrival, p_smart_fare_details)` | validated draft ride from **structured locations** (verified host only); pickup must be a public place (0014/0015) |
| `publish_ride(p_ride_id)` | draft → published; host joins as participant |
| `update_ride(p_ride_id, p_departure_time, p_pickup_point, p_notes, p_total_seats, p_fare_mode, p_fixed_fare, p_destination, p_destination_point, p_pickup_type, p_visible_at, p_origin_loc, p_destination_loc, p_pickup_point_loc, p_destination_point_loc, p_smart_fare_details)` | host edits pre-start; seat floor + auto `full`/`published` restatus; locations re-validated |
| `delete_draft(p_ride_id)` | host-only; **drafts** are deleted, every other status must be cancelled/expired instead |
| `request_to_join(p_ride_id)` | verified passenger request; duplicates 23505, overlap checks |
| `cancel_ride_request(p_request_id)` | passenger withdraws a pending request |
| `leave_ride(p_ride_id)` | passenger leaves pre-start; seat freed, `full` → `published` |
| `host_respond_to_request(p_request_id, p_approve, p_reason)` | approve (capacity-checked, adds participant, last seat → `full` + `ride_full` event) or reject with reason |
| `remove_passenger(p_ride_id, p_passenger_id)` | host removes a passenger pre-start; seat freed (`dropped` event) |
| `start_ride(p_ride_id)` | published/full → in_progress (host) |
| `complete_ride(p_ride_id)` | in_progress → completed; increments reliability counters |
| `cancel_ride(p_ride_id)` | pre-start cancel (host); closes pending requests, records counter |
| `expire_overdue_rides()` | archives published/full rides past departure as `expired` (pg_cron `covia-expire-rides` every 15 min; also called lazily by `search_rides`/`get_ride`) |

Read side (security definer, `authenticated` only):

| Function | Purpose |
| --- | --- |
| `search_rides(p_origin, p_destination, p_date, p_time_from, p_available_seats, p_student_only, p_women_only, p_sort, p_origin_lat, p_origin_lng, p_verified_host, p_page, p_page_size)` | published/full rides only (expired excluded); ILIKE filters; sort departure/recent/distance (haversine, nulls last when no coordinates); `p_verified_host` filters to verified hosts only; `total_count` via window; pagination (page size ≤ 50) |
| `get_ride(p_ride_id)` | detail + host public profile; drafts visible only to the host; otherwise "Ride not found" |
| `get_ride_requests(p_ride_id)` | host-only request queue with passenger public profiles |
| `get_ride_participants(p_ride_id)` | members-only roster (Host first) |
| `get_ride_timeline(p_ride_id)` | members-only chronological events with actor names |
| `get_ride_history(p_relation, p_status, p_page, p_page_size)` | the caller's own history via the `ride_history` security-barrier view — `hosted` / `joined` / `requested` (null = all), optional ride-status filter, paginated with `total_count` |
| `is_user_verified(p_user_id)` | same gate as `is_user_verified()` but for an arbitrary user (used by `search_rides`' `p_verified_host` filter) |

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
- `src/types/ride.ts` — `Ride`, `RideRequest`, `RideParticipant`,
  `RideTimelineEvent`, `RideLocation` (structured locations),
  `PickupType` + labels, `RideHistoryEntry`/`RideHistoryRelation`,
  status/event/fare label maps, search filters.
- `src/services/rides.ts` — every write RPC (create/publish/update/
  delete-draft/request/cancel-request/leave/respond/remove-passenger/
  start/complete/cancel) + the read functions (search/get/requests/
  participants/timeline/history), client-side `validateRideInput`
  (structured locations + pickup rules + visibility window), friendly
  `RideError` mapping. Numeric columns (numeric/bigint) are cast from
  strings.
