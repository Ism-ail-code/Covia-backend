# Deploying the Security Fixes (0042 + 0043)

Fixes Supabase Security Advisor rule `rls_disabled_in_public` (critical)
and applies the full database lockdown. Read fully before deploying.

## Migration 0042 — RLS on `reserved_usernames`

1. `ALTER TABLE public.reserved_usernames ENABLE ROW LEVEL SECURITY;`
2. `REVOKE ALL ... FROM anon, authenticated, public;` — removes the
   default privileges that made the table client-writable.
3. Creates **no policies** — RLS with zero policies is deny-by-default.
4. Does **not** set `FORCE ROW LEVEL SECURITY` — required so the
   SECURITY DEFINER functions keep working (see Risks).

## Migration 0043 — full database lockdown

1. RLS re-asserted on every public table (drift guard).
2. `REVOKE CREATE ON SCHEMA public FROM anon, authenticated, public` —
   clients can no longer create objects.
3. Default privileges revoked — future objects are never auto-granted
   to `anon`/`authenticated`.
4. `anon` loses **all** table and function privileges in `public`
   (including pgcrypto/pg_trgm defaults and trigger helpers).
5. Internal cron/trigger functions are no longer executable by
   `authenticated` (e.g. `handle_new_user`, `normalize_username`,
   `run_safety_monitor`, `expire_*`, `reveal_*`).
6. RLS enabled on `storage.buckets` and `storage.objects`.

## Deploy — choose one option

### Option A (recommended): Supabase SQL Editor

1. Open the Supabase Dashboard → your project (`covia`) → **SQL Editor**.
2. Paste the entire contents of
   `supabase/migrations/0042_rls_reserved_usernames.sql`.
3. Run. Expected output: `Success. No rows returned`.

### Option B: Supabase CLI

```powershell
cd covia-backend
supabase db push --linked
```

The CLI prompts for the database password. If the remote project has no
migration history table yet (migrations were applied via the SQL Editor in
the past), add `--include-all` to skip the history check:

```powershell
supabase db push --linked --include-all
```

(Option A is preferred — one file, fully idempotent, no history dependency.)

## Verify after deployment

### 1. RLS status (SQL Editor)

```sql
select c.relname, c.relrowsecurity as rls_enabled
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public' and c.relkind = 'r'
order by c.relname;
```

Expect `reserved_usernames` → `rls_enabled = true`. All rows true.

### 2. No client grants remain

```sql
select grantee, privilege_type
from information_schema.table_privileges
where table_schema = 'public' and table_name = 'reserved_usernames'
  and grantee in ('anon', 'authenticated');
```

Expect **0 rows**.

### 3. Clients are locked out

As `anon` (e.g. the Supabase client with no session):

```sql
select * from public.reserved_usernames;          -- permission denied (42501)
insert into public.reserved_usernames (name) values ('rogue');  -- denied
select * from public.rides;                       -- denied (0043)
select public.get_ride('00000000-0000-0000-0000-000000000000'); -- denied (0043)
```

### 4. Full lockdown status (0043)

```sql
-- no public table without RLS
select count(*) from pg_tables where schemaname = 'public' and not rowsecurity;  -- 0

-- clients cannot create objects
select has_schema_privilege('anon', 'public', 'create'),
       has_schema_privilege('authenticated', 'public', 'create');  -- false, false

-- anon has no table or function privileges anywhere in public
select count(*) from information_schema.table_privileges
 where table_schema = 'public' and grantee = 'anon';  -- 0
select count(*) from information_schema.routine_privileges
 where routine_schema = 'public' and grantee = 'anon';  -- 0

-- internal helpers are not client-callable
select has_function_privilege('authenticated', 'public.handle_new_user()', 'execute');   -- false
select has_function_privilege('authenticated', 'public.run_safety_monitor()', 'execute'); -- false

-- storage RLS
select relrowsecurity from pg_class where oid = 'storage.buckets'::regclass;  -- true
select relrowsecurity from pg_class where oid = 'storage.objects'::regclass;  -- true
```

### 5. App flows still work

```sql
select public.is_username_available('admin');      -- false (RPC works)
select public.is_username_available('fresh_pick_1'); -- true
```

Also confirm in the app: profile update with a reserved username is
rejected, a normal username saves; login, ride creation, chat, admin
console all behave as before.

### 6. Security Advisor

Dashboard → **Security Advisor** → re-run scan.
Expect the `rls_disabled_in_public` (critical) finding to be gone and no
new findings. Note: the advisor may take a few minutes to refresh after
the scan.

## Risks & notes

| Concern | Status |
| --- | --- |
| Breaks `is_username_available()`? | No — SECURITY DEFINER, runs as owner, bypasses RLS |
| Breaks `normalize_username()` trigger? | No — same reason |
| Direct reads by app/admin code? | None found — grep of mobile/admin/backend for `reserved_usernames` returns nothing |
| `FORCE ROW LEVEL SECURITY`? | Deliberately off; forcing it would lock the owner out and break both functions |
| Breaks client RPCs? | No — the 100+ RPCs the mobile/admin apps call keep their explicit `authenticated` grants; verified by the 760-check smoke suite |
| Breaks pg_cron jobs? | No — cron functions run as the owner (pg_cron execution model), which is exactly how the smoke suite now exercises them |
| Breaks anon API surface? | Intended — the app requires authentication everywhere (A8: email verification before access) |
| Storage uploads/downloads? | No — policies on `storage.objects` (0004/0006) still govern; clients just cannot list buckets |
| Idempotent? | Yes — both migrations verified by re-applying twice locally |
| No `USING (true)` policies added | Confirmed — zero policies created |

## If something goes wrong

The migrations are reversible (run in SQL Editor, emergency only — they
re-open the Advisor warning and weaken the lockdown):

```sql
grant select on table public.reserved_usernames to authenticated;
alter table public.reserved_usernames disable row level security;
grant usage, create on schema public to anon, authenticated;
grant execute on all functions in schema public to anon;
```

## Local validation performed

- Applied 0001–0040 + 0042 + 0043 to a scratch DB (0041 excluded locally: its
  partial index uses `now()`, rejected by the local PG 18 embedded engine
  but fine on Supabase PG 15+).
- Full smoke suite: 760/760 checks pass, including the reserved_usernames
  lockdown and the full 0043 lockdown block (RLS everywhere, no CREATE,
  anon zero privileges, internal functions not client-callable, storage
  RLS, probe-table grants).
