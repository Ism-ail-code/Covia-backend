-- Covia - ride read & discovery functions: locations, verified-host
-- filter, visibility gating and ride history
-- ------------------------------------------------------------------
-- Phase 5b. Extends the Phase 5 read surface:
--
--   * search_rides (extended) - new structured-location columns, a
--     verified-host filter and an automatic lazy ride expiry pass;
--     rides with a future visibility window stay hidden until visible
--   * get_ride (extended)     - same new columns + visibility gate
--   * ride_history view       - per-user history (hosted / joined /
--                               requested), scoped to auth.uid() so a
--                               user only ever sees their own history
--   * get_ride_history        - paginated history RPC (the basis for
--                               the future reliability/rating/analytics)
--
-- The legacy positional signatures are replaced; new parameters are
-- appended so old call patterns keep working.

-- ── Verified-host helper (scoped to any user) ──────────────────────
-- Variant of is_user_verified() that checks a specific user, used by
-- discovery filters (a host's verification status is public inside the
-- app: it is already shown on the public profile).
create or replace function public.is_user_verified(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.verification_submissions
    where user_id = p_user_id and status = 'approved'
  );
$$;

revoke all on function public.is_user_verified(uuid) from public;
grant execute on function public.is_user_verified(uuid) to authenticated;

-- ── Search / browse ────────────────────────────────────────────────
drop function if exists public.search_rides(text, text, date, time, integer, boolean, boolean, text, numeric, numeric, integer, integer);

create or replace function public.search_rides(
  p_origin text default null,
  p_destination text default null,
  p_date date default null,
  p_time_from time default null,
  p_available_seats integer default 1,
  p_student_only boolean default null,
  p_women_only boolean default null,
  p_sort text default 'departure',
  p_origin_lat numeric default null,
  p_origin_lng numeric default null,
  p_page integer default 1,
  p_page_size integer default 20,
  p_verified_host boolean default null
)
returns table (
  id uuid,
  host_id uuid,
  origin text,
  destination text,
  pickup_point text,
  destination_point text,
  pickup_type text,
  origin_loc jsonb,
  destination_loc jsonb,
  pickup_point_loc jsonb,
  destination_point_loc jsonb,
  smart_fare_details jsonb,
  visible_at timestamptz,
  departure_time timestamptz,
  estimated_arrival timestamptz,
  total_seats integer,
  available_seats integer,
  fare_mode text,
  fixed_fare numeric,
  ride_status text,
  is_student_only boolean,
  is_women_only boolean,
  notes text,
  host_username text,
  host_display_name text,
  host_avatar_url text,
  host_rating numeric,
  host_verified boolean,
  distance_km numeric,
  total_count bigint,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_page_size integer := greatest(1, least(coalesce(p_page_size, 20), 50));
  v_offset integer := (greatest(coalesce(p_page, 1), 1) - 1) * v_page_size;
begin
  -- Lazy expiry: rides that departed without ever starting disappear
  -- from discovery even if the scheduler has not run yet. Idempotent.
  perform public.expire_overdue_rides();

  return query
    select
      r.id, r.host_id, r.origin, r.destination, r.pickup_point,
      r.destination_point, r.pickup_type,
      r.origin_loc, r.destination_loc, r.pickup_point_loc,
      r.destination_point_loc, r.smart_fare_details, r.visible_at,
      r.departure_time, r.estimated_arrival,
      r.total_seats, r.available_seats, r.fare_mode, r.fixed_fare,
      r.ride_status, r.is_student_only, r.is_women_only, r.notes,
      pp.username as host_username,
      pp.display_name as host_display_name,
      pp.profile_photo_url as host_avatar_url,
      pp.overall_rating as host_rating,
      public.is_user_verified(r.host_id) as host_verified,
      case
        when p_origin_lat is not null and p_origin_lng is not null
             and r.origin_lat is not null and r.origin_lng is not null
        then round((
          6371 * 2 * asin(sqrt(
            power(sin(radians((r.origin_lat - p_origin_lat) / 2)), 2)
            + cos(radians(p_origin_lat)) * cos(radians(r.origin_lat))
              * power(sin(radians((r.origin_lng - p_origin_lng) / 2)), 2)
          ))
        )::numeric, 1)
        else null
      end as distance_km,
      count(*) over () as total_count,
      r.created_at, r.updated_at
    from public.rides r
    left join public.public_profiles pp on pp.id = r.host_id
    where r.ride_status in ('published', 'full')
      -- Visibility window: hidden until released.
      and (r.visible_at is null or r.visible_at <= now())
      and (p_origin is null or r.origin ilike '%' || btrim(p_origin) || '%')
      and (p_destination is null or r.destination ilike '%' || btrim(p_destination) || '%')
      and (p_date is null or r.departure_time::date = p_date)
      and (p_time_from is null or r.departure_time::time >= p_time_from)
      and (p_available_seats is null or r.available_seats >= p_available_seats)
      and (p_student_only is null or r.is_student_only = p_student_only)
      and (p_women_only is null or r.is_women_only = p_women_only)
      -- Verified-host filter.
      and (p_verified_host is null or p_verified_host = public.is_user_verified(r.host_id))
    order by
      case when p_sort = 'distance' and p_origin_lat is not null and p_origin_lng is not null
              and r.origin_lat is not null and r.origin_lng is not null
        then 6371 * 2 * asin(sqrt(
          power(sin(radians((r.origin_lat - p_origin_lat) / 2)), 2)
          + cos(radians(p_origin_lat)) * cos(radians(r.origin_lat))
            * power(sin(radians((r.origin_lng - p_origin_lng) / 2)), 2)
        ))
        else null
      end asc nulls last,
      case when p_sort = 'recent' then r.created_at else null end desc nulls last,
      case when p_sort is null or p_sort in ('departure', 'distance')
        then r.departure_time else null
      end asc nulls last
    limit v_page_size
    offset v_offset;
end;
$$;

-- ── Ride detail ────────────────────────────────────────────────────
drop function if exists public.get_ride(uuid);

create or replace function public.get_ride(p_ride_id uuid)
returns table (
  id uuid,
  host_id uuid,
  origin text,
  destination text,
  pickup_point text,
  destination_point text,
  pickup_type text,
  origin_loc jsonb,
  destination_loc jsonb,
  pickup_point_loc jsonb,
  destination_point_loc jsonb,
  smart_fare_details jsonb,
  visible_at timestamptz,
  departure_time timestamptz,
  estimated_arrival timestamptz,
  total_seats integer,
  available_seats integer,
  fare_mode text,
  fixed_fare numeric,
  ride_status text,
  is_student_only boolean,
  is_women_only boolean,
  notes text,
  host_username text,
  host_display_name text,
  host_avatar_url text,
  host_rating numeric,
  host_verified boolean,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  -- Lazy expiry so stale rides read as 'expired' immediately.
  perform public.expire_overdue_rides();

  return query
    select
      r.id, r.host_id, r.origin, r.destination, r.pickup_point,
      r.destination_point, r.pickup_type,
      r.origin_loc, r.destination_loc, r.pickup_point_loc,
      r.destination_point_loc, r.smart_fare_details, r.visible_at,
      r.departure_time, r.estimated_arrival,
      r.total_seats, r.available_seats, r.fare_mode, r.fixed_fare,
      r.ride_status, r.is_student_only, r.is_women_only, r.notes,
      pp.username, pp.display_name, pp.profile_photo_url, pp.overall_rating,
      public.is_user_verified(r.host_id),
      r.created_at, r.updated_at
    from public.rides r
    left join public.public_profiles pp on pp.id = r.host_id
    where r.id = p_ride_id
      and (
        r.ride_status <> 'draft'
        or r.host_id = v_user
      )
      and (
        r.visible_at is null
        or r.visible_at <= now()
        or r.host_id = v_user
        or public.is_ride_member(r.id, v_user)
      );

  if not found then
    raise exception 'Ride not found';
  end if;
end;
$$;

-- ── Ride history (per-user, security-scoped view) ──────────────────
-- The history model: every ride the user hosted, every ride they
-- joined (or left) and every request they submitted, with the host's
-- public profile attached. Scoped to auth.uid() inside the view so a
-- caller can never see another user's history — this is the data that
-- will power reliability scores, ratings and analytics in later phases.
-- Rides are archived, never deleted, so history is complete.
create or replace view public.ride_history
with (security_barrier = true) as
  select
    r.id as ride_id,
    'hosted'::text as relation,
    r.host_id as user_id,
    r.origin,
    r.destination,
    r.departure_time,
    r.ride_status,
    null::text as request_status,
    r.fare_mode,
    r.fixed_fare,
    r.total_seats,
    r.available_seats,
    r.is_student_only,
    r.is_women_only,
    r.pickup_type,
    r.created_at,
    r.updated_at,
    null::timestamptz as joined_at,
    null::timestamptz as left_at,
    pp.username as host_username,
    pp.display_name as host_display_name,
    pp.profile_photo_url as host_avatar_url
  from public.rides r
  left join public.public_profiles pp on pp.id = r.host_id
  where r.host_id = (select auth.uid())
union all
  select
    r.id as ride_id,
    'joined'::text as relation,
    rp.user_id as user_id,
    r.origin,
    r.destination,
    r.departure_time,
    r.ride_status,
    null::text as request_status,
    r.fare_mode,
    r.fixed_fare,
    r.total_seats,
    r.available_seats,
    r.is_student_only,
    r.is_women_only,
    r.pickup_type,
    r.created_at,
    r.updated_at,
    rp.joined_at,
    rp.left_at,
    pp.username as host_username,
    pp.display_name as host_display_name,
    pp.profile_photo_url as host_avatar_url
  from public.ride_participants rp
  join public.rides r on r.id = rp.ride_id
  left join public.public_profiles pp on pp.id = r.host_id
  where rp.user_id = (select auth.uid())
    and rp.role = 'Passenger'
union all
  select
    r.id as ride_id,
    'requested'::text as relation,
    rr.passenger_id as user_id,
    r.origin,
    r.destination,
    r.departure_time,
    r.ride_status,
    rr.status as request_status,
    r.fare_mode,
    r.fixed_fare,
    r.total_seats,
    r.available_seats,
    r.is_student_only,
    r.is_women_only,
    r.pickup_type,
    r.created_at,
    r.updated_at,
    null::timestamptz as joined_at,
    null::timestamptz as left_at,
    pp.username as host_username,
    pp.display_name as host_display_name,
    pp.profile_photo_url as host_avatar_url
  from public.ride_requests rr
  join public.rides r on r.id = rr.ride_id
  left join public.public_profiles pp on pp.id = r.host_id
  where rr.passenger_id = (select auth.uid());

revoke all on public.ride_history from public;
grant select on public.ride_history to authenticated;

-- ── History RPC (paginated) ────────────────────────────────────────
create or replace function public.get_ride_history(
  p_relation text default null,
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 20
)
returns table (
  ride_id uuid,
  relation text,
  user_id uuid,
  origin text,
  destination text,
  departure_time timestamptz,
  ride_status text,
  request_status text,
  fare_mode text,
  fixed_fare numeric,
  total_seats integer,
  available_seats integer,
  is_student_only boolean,
  is_women_only boolean,
  pickup_type text,
  joined_at timestamptz,
  left_at timestamptz,
  host_username text,
  host_display_name text,
  host_avatar_url text,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_page_size integer := greatest(1, least(coalesce(p_page_size, 20), 50));
  v_offset integer := (greatest(coalesce(p_page, 1), 1) - 1) * v_page_size;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  if p_relation is not null and p_relation not in ('hosted', 'joined', 'requested') then
    raise exception 'History relation must be hosted, joined or requested';
  end if;

  return query
    select
      h.ride_id, h.relation, h.user_id, h.origin, h.destination,
      h.departure_time, h.ride_status, h.request_status,
      h.fare_mode, h.fixed_fare, h.total_seats, h.available_seats,
      h.is_student_only, h.is_women_only, h.pickup_type,
      h.joined_at, h.left_at, h.host_username, h.host_display_name,
      h.host_avatar_url, h.created_at,
      count(*) over () as total_count
    from public.ride_history h
    where (p_relation is null or h.relation = p_relation)
      and (p_status is null or
           (h.relation = 'requested' and h.request_status = p_status)
           or (h.relation <> 'requested' and h.ride_status = p_status))
    order by h.departure_time desc, h.created_at desc
    limit v_page_size
    offset v_offset;
end;
$$;

-- ── Grants ─────────────────────────────────────────────────────────
-- Archived ('expired') rides remain readable like cancelled/completed
-- ones: history is never hidden, discovery excludes them by status.
drop policy if exists "rides published read" on public.rides;
create policy "rides published read"
  on public.rides
  for select
  to authenticated
  using (ride_status in ('published', 'full', 'in_progress', 'completed', 'cancelled', 'expired'));

revoke all on function public.search_rides(text, text, date, time, integer, boolean, boolean, text, numeric, numeric, integer, integer, boolean) from public;
revoke all on function public.get_ride(uuid) from public;
revoke all on function public.get_ride_history(text, text, integer, integer) from public;

grant execute on function public.search_rides(text, text, date, time, integer, boolean, boolean, text, numeric, numeric, integer, integer, boolean) to authenticated;
grant execute on function public.get_ride(uuid) to authenticated;
grant execute on function public.get_ride_history(text, text, integer, integer) to authenticated;
