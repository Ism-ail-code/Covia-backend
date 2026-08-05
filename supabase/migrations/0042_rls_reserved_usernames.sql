-- Covia - Critical security fix: enable RLS on reserved_usernames
-- ------------------------------------------------------------------
-- Supabase Security Advisor rule `rls_disabled_in_public` flagged
-- `public.reserved_usernames` as publicly accessible.
--
-- Root cause: migration 0002 created the table without enabling RLS.
-- On Supabase, default privileges grant ALL on new public tables to
-- `anon` and `authenticated`, so with RLS off anyone holding the
-- project anon key could read/edit/delete every row.
--
-- Fix (least privilege, per Covia security architecture):
--   1. Enable RLS (deny by default - no policies are created).
--   2. Revoke the default client grants (anon/authenticated).
--   3. Keep FORCE ROW LEVEL SECURITY off: the only legitimate readers
--      are the SECURITY DEFINER functions `normalize_username()`
--      (0002) and `is_username_available()` (0003), which run as the
--      table owner and must not be subject to RLS. Clients are
--      already served through those RPCs instead of direct reads.

alter table public.reserved_usernames enable row level security;

-- Supabase default privileges give anon/authenticated ALL on new
-- public tables; revoke so clients can never touch it directly.
revoke all on table public.reserved_usernames from anon, authenticated;
revoke all on table public.reserved_usernames from public;

-- No policies are created: this is an internal lookup table whose
-- only access path is the SECURITY DEFINER functions above. RLS with
-- zero policies equals deny-by-default for every client role.
