-- Covia - Phase 10: role-based access control (RBAC)
-- ------------------------------------------------------------------
-- Four admin roles with an explicit permission matrix:
--
--   super_admin   - everything, including managing other admins
--   admin         - every operational capability except admin management
--   moderator     - verification queue, reports, appeals, manual actions
--   support_agent - read-only queue access + user lookup
--
-- Permissions are stored as (role, permission) rows so the matrix is
-- queryable and auditable; has_permission() bypasses the table for
-- super_admin so that role can never be locked out of the platform.
--
-- Admin membership stays in public.admin_users (Phase 4) with a new
-- role_name column. is_admin() is redefined as "member of any admin
-- role" so every pre-Phase-10 admin function keeps its exact semantics.
--
-- The tables are RLS-locked: nothing is readable or writable by
-- clients directly. All access happens through security definer
-- helpers and admin functions.

-- =============================================================
-- Roles
-- =============================================================
create table if not exists public.admin_roles (
  role_name text primary key
    check (role_name in ('super_admin', 'admin', 'moderator', 'support_agent')),
  level smallint not null unique
    check (level between 1 and 4),
  description text not null default ''
);

insert into public.admin_roles (role_name, level, description) values
  ('super_admin', 1, 'Full platform control including admin account management'),
  ('admin', 2, 'Every operational capability except admin account management'),
  ('moderator', 3, 'Verification queue, reports, appeals and manual moderation actions'),
  ('support_agent', 4, 'Read-only queues and user lookup')
on conflict (role_name) do nothing;

-- =============================================================
-- Permission matrix
-- =============================================================
create table if not exists public.admin_role_permissions (
  role_name text not null references public.admin_roles (role_name) on delete cascade,
  permission text not null,
  primary key (role_name, permission)
);

insert into public.admin_role_permissions (role_name, permission) values
  -- admin: everything except admin.manage (super_admin only)
  ('admin', 'user.view'), ('admin', 'user.manage'),
  ('admin', 'ride.view'), ('admin', 'ride.cancel'),
  ('admin', 'verification.view'), ('admin', 'verification.review'),
  ('admin', 'report.view'), ('admin', 'report.review'),
  ('admin', 'appeal.view'), ('admin', 'appeal.decide'),
  ('admin', 'moderation.apply'), ('admin', 'moderation.configure'),
  ('admin', 'analytics.view'), ('admin', 'audit.view'),
  ('admin', 'monitor.view'), ('admin', 'config.view'), ('admin', 'config.manage'),
  -- moderator: queue work + case handling, no account/ride enforcement
  ('moderator', 'user.view'), ('moderator', 'ride.view'),
  ('moderator', 'verification.view'), ('moderator', 'verification.review'),
  ('moderator', 'report.view'), ('moderator', 'report.review'),
  ('moderator', 'appeal.view'), ('moderator', 'moderation.apply'),
  ('moderator', 'config.view'), ('moderator', 'audit.view'),
  -- support_agent: triage visibility only
  ('support_agent', 'user.view'), ('support_agent', 'ride.view'),
  ('support_agent', 'verification.view'), ('support_agent', 'report.view'),
  ('support_agent', 'appeal.view'), ('support_agent', 'config.view')
on conflict (role_name, permission) do nothing;

-- =============================================================
-- admin_users gains a role
-- =============================================================
-- Existing rows (e.g. the Phase 4 bootstrap admin) default to the
-- least-privileged role; promote them explicitly.
alter table public.admin_users
  add column if not exists role_name text not null default 'support_agent'
    references public.admin_roles (role_name);

-- =============================================================
-- Helpers
-- =============================================================
-- The role of the signed-in admin (null for non-admins).
create or replace function public.current_admin_role()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select role_name
    from public.admin_users
   where user_id = auth.uid();
$$;

-- Membership check, backwards compatible with every pre-Phase-10 gate.
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select public.current_admin_role() is not null;
$$;

-- Permission check. super_admin bypasses the matrix.
create or replace function public.has_permission(p_permission text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.admin_users a
     where a.user_id = auth.uid()
       and (
         a.role_name = 'super_admin'
         or exists (
           select 1
             from public.admin_role_permissions rp
            where rp.role_name = a.role_name
              and rp.permission = p_permission
         )
       )
  );
$$;

-- Raise a 42501 when the permission is missing.
create or replace function public.require_permission(p_permission text)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.has_permission(p_permission) then
    raise exception 'Permission denied: % role cannot %', coalesce(public.current_admin_role(), 'anonymous'), p_permission
      using errcode = '42501';
  end if;
end;
$$;

-- =============================================================
-- Admin account management (super_admin only)
-- =============================================================
create or replace function public.admin_list_admin_users()
returns table (
  user_id uuid,
  email text,
  display_name text,
  role_name text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

  return query
    select a.user_id, p.email, p.display_name, a.role_name, a.created_at
      from public.admin_users a
      left join public.profiles p on p.id = a.user_id
     order by a.role_name, a.created_at;
end;
$$;

create or replace function public.admin_set_admin_role(
  p_user_id uuid,
  p_role_name text
)
returns public.admin_users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.admin_users;
  v_actor uuid := auth.uid();
begin
  perform public.require_permission('admin.manage');
  if v_actor is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.admin_roles where role_name = p_role_name) then
    raise exception 'Unknown admin role: %', p_role_name;
  end if;
  if p_user_id = v_actor then
    raise exception 'You cannot change your own role';
  end if;

  insert into public.admin_users (user_id, role_name)
  values (p_user_id, p_role_name)
  on conflict (user_id) do update
    set role_name = excluded.role_name
  returning * into v_row;

  return v_row;
end;
$$;

create or replace function public.admin_remove_admin(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.admin_users;
  v_actor uuid := auth.uid();
  v_super_remaining bigint;
begin
  perform public.require_permission('admin.manage');
  if v_actor is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if p_user_id = v_actor then
    raise exception 'You cannot remove yourself from the admin team';
  end if;

  select * into v_row from public.admin_users where user_id = p_user_id;
  if not found then
    raise exception 'That user is not an admin';
  end if;

  if v_row.role_name = 'super_admin' then
    select count(*) into v_super_remaining
      from public.admin_users
     where role_name = 'super_admin';
    if v_super_remaining <= 1 then
      raise exception 'Covia must keep at least one super admin';
    end if;
  end if;

  delete from public.admin_users where user_id = p_user_id;
end;
$$;

-- =============================================================
-- Lockdown + grants
-- =============================================================
alter table public.admin_roles enable row level security;
alter table public.admin_role_permissions enable row level security;

revoke all on public.admin_roles from public;
revoke all on public.admin_role_permissions from public;
revoke all on table public.admin_roles from anon, authenticated;
revoke all on table public.admin_role_permissions from anon, authenticated;
revoke all on table public.admin_users from anon, authenticated;

revoke all on function
  public.current_admin_role, public.is_admin, public.has_permission,
  public.require_permission, public.admin_list_admin_users,
  public.admin_set_admin_role, public.admin_remove_admin
  from public;

grant execute on function
  public.current_admin_role(), public.is_admin(), public.has_permission(text),
  public.require_permission(text), public.admin_list_admin_users(),
  public.admin_set_admin_role(uuid, text), public.admin_remove_admin(uuid)
  to authenticated;
