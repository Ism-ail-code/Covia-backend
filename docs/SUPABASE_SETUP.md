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

2. Verify with:

   ```sql
   select * from public.profiles;
   ```

3. (Optional) Apply via the Supabase CLI instead:

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

## Notes & security

- The anon key is safe to ship in the client (`EXPO_PUBLIC_*` is inlined at
  build time) — Supabase RLS is what protects the data, not the key.
- Never store the service-role key in the mobile app.
- The NestJS API (Phase 3+) will use the Supabase service-role key
  server-side, alongside JWT verification for user-bound requests.
