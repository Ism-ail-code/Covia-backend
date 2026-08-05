# Deploying the RLS Fix (`0042_rls_reserved_usernames.sql`)

Fixes Supabase Security Advisor rule `rls_disabled_in_public` — critical.
Read fully before deploying. ~2 minutes.

## What the migration does

1. `ALTER TABLE public.reserved_usernames ENABLE ROW LEVEL SECURITY;`
2. `REVOKE ALL ... FROM anon, authenticated, public;` — removes the
   default privileges that made the table client-writable.
3. Creates **no policies** — RLS with zero policies is deny-by-default.
4. Does **not** set `FORCE ROW LEVEL SECURITY` — required so the
   SECURITY DEFINER functions keep working (see Risks).

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

Expect `reserved_usernames` → `rls_enabled = true`. All 34 rows true.

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
```

### 4. App flows still work

```sql
select public.is_username_available('admin');      -- false (RPC works)
select public.is_username_available('fresh_pick_1'); -- true
```

Also confirm in the app: profile update with a reserved username is
rejected, a normal username saves.

### 5. Security Advisor

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
| Idempotent? | Yes — verified by re-applying twice locally |
| No `USING (true)` policies added | Confirmed — zero policies created |

## If something goes wrong

The migration is fully reversible with three statements (run in SQL Editor):

```sql
grant select on table public.reserved_usernames to authenticated;
alter table public.reserved_usernames disable row level security;
```

(Only do this for emergency rollback — it re-opens the Advisor warning.)

## Local validation performed

- Applied 0001–0040 + 0042 to a scratch DB (0041 excluded locally: its
  partial index uses `now()`, rejected by the local PG 18 embedded engine
  but fine on Supabase PG 15).
- Full smoke suite: 739/739 checks pass, including 14 new assertions for
  the reserved_usernames lockdown.
