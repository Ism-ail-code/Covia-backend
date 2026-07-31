-- Covia - public profile model & lookup functions
-- ------------------------------------------------------------------
-- A read-only view over profiles that exposes ONLY public information.
-- Private columns (email, phone, date of birth, gender, emergency
-- contact) never leave this view. Access is through the view and the
-- security-definer functions below; the base table stays locked to
-- own-row access by RLS (see 0001).
--
-- NOTE: the view must be owned by the table owner (postgres - the
-- default when run in the Supabase SQL Editor) so the base table's RLS
-- does not constrain cross-user reads; the view itself exposes only
-- public columns.

create or replace view public.public_profiles
with (security_barrier = true) as
select
  id,
  username,
  display_name,
  avatar_url as profile_photo_url,
  bio,
  home_city as city,
  country,
  rating as overall_rating,
  reliability_score,
  total_completed_rides,
  total_cancelled_rides,
  verification_status,
  is_government_id_verified,
  is_student_verified,
  created_at
from public.profiles;

revoke all on public.public_profiles from public;
grant select on public.public_profiles to authenticated;

-- Table-level grants for the authenticated role (RLS still gates the rows;
-- Supabase default privileges usually cover this, explicit grants make the
-- migration deterministic anywhere it runs).
grant select, update on public.profiles to authenticated;

-- Get one user's public profile. Works for any authenticated user.
create or replace function public.get_public_profile(p_user_id uuid)
returns public.public_profiles
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.public_profiles
  where id = p_user_id;
$$;

revoke all on function public.get_public_profile(uuid) from public;
grant execute on function public.get_public_profile(uuid) to authenticated;

-- Search users by username prefix (for future ride/community features).
create or replace function public.search_profiles(
  p_query text,
  p_limit integer default 20
)
returns setof public.public_profiles
language sql
stable
security definer
set search_path = public
as $$
  select *
  from public.public_profiles
  where username is not null
    and username like lower(btrim(p_query)) || '%'
  order by username
  limit greatest(1, least(p_limit, 50));
$$;

revoke all on function public.search_profiles(text, integer) from public;
grant execute on function public.search_profiles(text, integer) to authenticated;

-- Username availability check (format + reserved + uniqueness).
create or replace function public.is_username_available(p_username text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_name text := lower(btrim(p_username));
begin
  if v_name !~ '^[a-z0-9_]{3,20}$' then
    return false;
  end if;
  if exists (select 1 from public.reserved_usernames where name = v_name) then
    return false;
  end if;
  return not exists (select 1 from public.profiles where username = v_name);
end;
$$;

revoke all on function public.is_username_available(text) from public;
grant execute on function public.is_username_available(text) to authenticated;
