-- Covia - Phase 12: full database lockdown
-- ------------------------------------------------------------------
-- Comprehensive hardening pass for the production database holding
-- confidential user data. Complements 0035 (admin surface) and 0042
-- (reserved_usernames RLS). Every statement is idempotent and safe to
-- re-run.
--
-- What this migration does:
--   1. Re-asserts RLS on every public table (guards against drift).
--   2. Revokes CREATE on schema public from client roles + PUBLIC.
--   3. Revokes default privileges so future objects are never
--      auto-granted to anon/authenticated.
--   4. Zero table privileges for anon across the public schema.
--   5. Zero EXECUTE for anon across the public schema (kills the
--      pgcrypto/pg_trgm defaults and trigger-helper exposure).
--   6. Revokes EXECUTE on internal-only helper/cron/trigger functions
--      from authenticated (clients never call these; the mobile and
--      admin apps only call the RPC surface granted in 0001-0041).
--   7. Storage RLS (see note below — cannot be altered from migrations).
--
-- Deliberately NOT done (documented in SECURITY.md):
--   * service_role grants untouched - reserved for the NestJS backend.
--   * auth schema untouched - GoTrue manages it; clients have no grants
--     there by default.
--   * FORCE ROW LEVEL SECURITY not set - would break the SECURITY
--     DEFINER functions that legitimately bypass RLS as the owner.

-- =============================================================
-- 1. RLS on every public table (idempotent re-assert)
-- =============================================================
do $$
declare
  v_table text;
begin
  for v_table in
    select t.tablename
    from pg_tables t
    where t.schemaname = 'public'
      and not exists (
        select 1 from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relname = t.tablename
          and c.relrowsecurity
      )
  loop
    execute format('alter table public.%I enable row level security', v_table);
    raise notice 'RLS enabled on public.%', v_table;
  end loop;
end $$;

-- =============================================================
-- 2. No CREATE on schema public for clients
-- =============================================================
revoke create on schema public from anon, authenticated;
revoke create on schema public from public;
grant usage on schema public to anon, authenticated;

-- =============================================================
-- 3. Default privileges: future objects stay locked
-- =============================================================
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from anon, authenticated;

-- =============================================================
-- 4. anon: zero table access in public (PUBLIC-level grants +
--    any direct anon grants; direct authenticated grants from the
--    migrations are untouched and keep working)
-- =============================================================
revoke all on all tables in schema public from public;
revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from public, anon, authenticated;

-- =============================================================
-- 5. Zero EXECUTE for anon and for PUBLIC inheritance in public
--    (kills the pgcrypto/pg_trgm defaults and trigger-helper
--    exposure; client RPCs keep their explicit authenticated grants)
-- =============================================================
revoke execute on all functions in schema public from public;
revoke execute on all functions in schema public from anon;

-- =============================================================
-- 6. authenticated: revoke internal-only helper functions
--    (clients reach this logic only through the granted RPC surface)
-- =============================================================
revoke execute on function
  public.handle_new_user(),
  public.set_updated_at(),
  public.normalize_username(),
  public.handle_account_notifications(),
  public.notify_from_ride_timeline(),
  public.broadcast_covia_event(text, jsonb),
  public.sync_chat_from_ride_timeline(),
  public.broadcast_chat_message(),
  public.sync_safety_from_ride_timeline(),
  public.is_valid_notification_type(text),
  public.expire_overdue_rides(),
  public.expire_moderation_actions()
  from authenticated;

-- =============================================================
-- 7. Storage: RLS on buckets and objects
-- =============================================================
-- Hosted Supabase owns the storage schema (supabase_storage_admin);
-- `alter table storage.*` fails with 42501 (must be owner) from any
-- migration. RLS is already enabled on storage.buckets AND
-- storage.objects by the platform (verified: relrowsecurity = true
-- for both), and object access is governed by the bucket policies
-- from 0004/0006. Nothing to do here.
