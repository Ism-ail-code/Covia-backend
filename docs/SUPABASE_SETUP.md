# Supabase Setup — Authentication & Profiles

The Companion mobile app authenticates directly against **Supabase Auth**
(email + password) using the `@supabase/supabase-js` client. This document
covers everything needed to go from "placeholder keys" to a working auth
flow in the app.

## 1. Create the project

1. Go to <https://supabase.com/dashboard> → **New project** (name e.g.
   `companion`, region closest to users, strong database password).
2. Copy the two public values from **Project Settings → API**:
   - **Project URL** → `EXPO_PUBLIC_SUPABASE_URL`
   - **anon / public key** → `EXPO_PUBLIC_SUPABASE_ANON_KEY`
3. In `covia-mobile/.env`, replace the placeholders:

   ```env
   EXPO_PUBLIC_SUPABASE_URL=https://YOUR_PROJECT_REF.supabase.co
   EXPO_PUBLIC_SUPABASE_ANON_KEY=YOUR_SUPABASE_ANON_KEY
   ```

4. Restart the Expo dev server. The app will now warn instead of error when
   Supabase is not configured, and all auth screens go live.

## 2. Auth settings (Authentication → Sign In / Providers)

- **Email → Enable "Email signups"** — required for registration.
- **Email → Confirm email** — **ON** (the app's registration flow is built
  around email confirmation: signup without a session routes to the
  "verify your email" screen).
- **Password policy** (optional, app already validates client-side):
  8+ chars with upper/lower/digit/symbol.

## 3. Redirect URLs (Authentication → URL Configuration)

The app uses the `companion` URL scheme (see `covia-mobile/app.json`).

Add the following **Redirect URLs** so confirmation/reset links come back
into the app (PKCE flow):

```
companion://verify
companion://reset
```

- The email-confirmation link routes to `companion://verify?code=…` — the
  app exchanges the code for a session via
  `supabase.auth.exchangeCodeForSession`.
- The password-reset link routes to `companion://reset?code=…`; the same
  exchange applies, and the reset screen (future Phase) lets the user pick
  a new password.

> The confirmation path is wired to `Linking.createURL("verify")`, so if
> the scheme ever changes, both `app.json` and these URLs must change.

## 4. Database

1. Open **SQL Editor** and run `supabase/migrations/0001_profiles.sql`.
   This creates:

   - `public.profiles` — one row per auth user, with `verification_status`
     default `'Pending'`, `rating` default `5.0`, `reliability_score`
     default `90`, and `is_government_id_verified` /
     `is_student_verified` default `false`.
   - A trigger that auto-creates the profile row on `auth.users` insert
     (carrying `full_name` / `phone` from signup metadata).
   - Row Level Security: users can select/update **only their own** row.

2. Run the Phase 3–5 migrations in order:

   - `supabase/migrations/0002_profile_identity.sql` — identity fields
     (username, DOB, gender, country), ride-metric placeholders, emergency
     contacts, username uniqueness/reserved-names rules.
   - `supabase/migrations/0003_public_profiles.sql` — the
     `public_profiles` view (public info only) and the
     `get_public_profile` / `search_profiles` / `is_username_available`
     functions.
   - `supabase/migrations/0004_avatars_storage.sql` — the public `avatars`
     Storage bucket with folder-scoped RLS policies.
   - `supabase/migrations/0005_verification_schema.sql` — verification
     submissions, audit trail, `admin_users`, notification placeholders.
   - `supabase/migrations/0006_verification_storage.sql` — the **private**
     `verification-documents` bucket (owner uploads, admin reads).
   - `supabase/migrations/0007_verification_user_functions.sql` — user
     RPCs: submit / resubmit / get my submission / `is_user_verified`.
   - `supabase/migrations/0008_verification_admin_functions.sql` — admin
     RPCs: review queue + approve/reject/request-resubmission.
   - `supabase/migrations/0009_rides_schema.sql` — `rides`,
     `ride_requests`, `ride_participants`, `ride_timeline` + RLS
     (`is_ride_member()` helper).
   - `supabase/migrations/0010_rides_creation_functions.sql` —
     `create_ride` / `publish_ride` / `update_ride`.
   - `supabase/migrations/0011_rides_request_functions.sql` — request
     workflow: `request_to_join` / `cancel_ride_request` / `leave_ride` /
     `host_respond_to_request`.
   - `supabase/migrations/0012_rides_lifecycle_functions.sql` —
     `start_ride` / `complete_ride` / `cancel_ride`.
   - `supabase/migrations/0013_rides_read_functions.sql` — `search_rides`
     / `get_ride` / `get_ride_requests` / `get_ride_participants` /
     `get_ride_timeline`.

   Local SQL can be smoke-tested against the embedded PostgreSQL before
   applying anywhere: `node scripts/sql-smoke.mjs` (database must be
   running — `pnpm db:dev:start`). **246 checks cover Phases 1–5.**

3. Verify with:

   ```sql
   select * from public.profiles;
   select * from public.public_profiles;
   ```

4. (Optional) Apply via the Supabase CLI instead:

   ```sh
   supabase db push
   ```

## 5. Test checklist (manual, on device or emulator)

- [ ] **Register** with a real email → confirmation email arrives; profile
      row exists in `public.profiles` with defaults.
- [ ] **Confirm email** via the deep link → app opens, session created,
      user lands in the app (home).
- [ ] **Login** with confirmed credentials → home screen.
- [ ] **Restart** the app → session restored automatically (AsyncStorage).
- [ ] **Logout** (Settings → Log out) → returns to welcome screen; Home and
      other protected screens are no longer reachable.
- [ ] **Forgot password** → reset email → set a new password → login with
      the new password.
- [ ] **Wrong password** → friendly "Incorrect email or password" message.
- [ ] **Duplicate email** → friendly "An account with this email already
      exists" message.
- [ ] **Unverified login attempt** → friendly "Please verify your email"
      message with the verify screen.

### Phase 3 — profile checks

- [ ] Profile row exists immediately after signup (trigger).
- [ ] Create-profile screen saves display name, username, city, country,
      bio → reflected in the profile tab.
- [ ] Username: lowercase-normalized; duplicates and reserved names
      (`admin`, `support`, …) rejected with friendly messages; 3–20 chars,
      `[a-z0-9_]` enforced.
- [ ] Avatar upload (create-profile): photo appears in the profile tab;
      invalid types/sizes rejected; re-upload replaces the old file.
- [ ] Emergency contact (Safety centre): add → edit → remove works; partial
      contacts rejected.
- [ ] Profile tab shows `@username` and `city, country`.
- [ ] `get_public_profile(<other-user-id>)` returns only public fields
      (no email/phone/DOB/emergency contact).
- [ ] `search_profiles('ali')` finds `alice_example`.
- [ ] Direct table access as another user returns only your own row
      (RLS) — verified by `scripts/sql-smoke.mjs`.

### Phase 4 — verification checks

- [ ] Verification screen: submit a government ID (kind selector + front
      photo required, back/selfie optional) → pending card appears.
- [ ] Student flow: submit via student card photo OR university email.
- [ ] Duplicate submissions blocked with a friendly message while one is
      pending.
- [ ] Promotion of a reviewer: in the SQL Editor,
      `insert into public.admin_users (user_id) values ('<user-uuid>');`
      (no admin UI in this phase).
- [ ] As admin: `select * from admin_list_verifications('pending')` returns
      the queue with user email/name.
- [ ] `select * from admin_review_verification('<id>', 'approve')` →
      profile shows `verification_status = 'Verified'` and the matching
      `is_government_id_verified` / `is_student_verified = true`.
- [ ] `admin_review_verification('<id>', 'reject', 'reason')` → user sees
      the reason on the verification screen and can "Submit again"
      (resubmission).
- [ ] `is_user_verified()` returns true once any method is approved (used
      to gate ride creation/joining once rides ship).
- [ ] Rejected/expired submissions can be resubmitted; an approved one
      cannot.
- [ ] A non-admin calling `admin_list_verifications` / `admin_review_verification`
      gets `Admin access required` (SQLSTATE 42501).
- [ ] Documents are invisible to everyone except the owner and admins
      (private bucket); render via `createSignedUrl` client-side, or the
      service-role key server-side for admins.

### Phase 5 — ride checks

Requires two users: one **verified** host and one **verified**
passenger (approve their verification first), plus one unverified user.

- [ ] Unverified users cannot create rides or request seats (friendly
      "verify first" message).
- [ ] Verified host creates a ride → `ride_status = 'draft'` with
      `available_seats = total_seats`; past departures, empty fields, seat
      counts outside 1–10, and missing/invalid fares are rejected.
- [ ] Student-only rides: rejected for non-students, allowed for verified
      students.
- [ ] `publish_ride` → status `published`; the host appears in
      `get_ride_participants` as `Host`; republishing is rejected.
- [ ] Passenger requests → `pending`; a second request is rejected
      (duplicate); requesting your own ride / a draft / a full / a started /
      a cancelled ride is rejected.
- [ ] Overlap guard: a passenger already on a ride (or with a pending
      request) cannot request another ride departing within **6 hours**.
- [ ] Host approves → request `approved`, passenger added, seats
      decremented; last seat → `full` and further approvals refused.
- [ ] Host rejects with a reason → `rejected`; passenger sees the reason.
- [ ] Passenger withdraws a pending request; a passenger on the ride can
      `leave_ride` before departure (seat freed, ride re-opens from `full`).
- [ ] Host edits: past departure / seats below approved passengers are
      rejected; seat changes restatus `full`/`published` correctly.
- [ ] `start_ride` → `in_progress` (host only); `complete_ride` →
      `completed` and `total_completed_rides` increments for host +
      passengers; `cancel_ride` (pre-start) → `cancelled`, pending requests
      closed, `total_cancelled_rides` incremented; no double cancels or
      cancels after start.
- [ ] `search_rides` returns only published/full rides and honours origin/
      destination/date/time/seat/student/women filters, sorts
      (departure/recent/distance) and pagination (`total_count` matches).
- [ ] `get_ride` hides drafts from non-hosts; `get_ride_requests` is
      host-only; participants/timeline are member-only.
- [ ] Direct `insert`/`update` on ride tables fails (select-only grants).
- [ ] Timeline shows the full event sequence for a ride
      (created → published → requested → approved → joined → ride_full →
      … started → completed / cancelled).

## Notes & security

- The anon key is safe to ship in the client (`EXPO_PUBLIC_*` is inlined at
  build time) — Supabase RLS is what protects the data, not the key.
- Never store the service-role key in the mobile app.
- The NestJS API (Phase 3+) will use the Supabase service-role key
  server-side, alongside JWT verification for user-bound requests.
