-- Covia - ride read & discovery functions
-- ------------------------------------------------------------------
--   * search_rides          - browse/search with filters, sort + pagination
--   * get_ride              - ride detail with host public info
--   * get_ride_requests     - host: request queue with passenger info
--   * get_ride_participants - host/participants: who is on the ride
--   * get_ride_timeline     - host/participants: full event timeline
--
-- Distance sorting uses the haversine formula against the optional
-- origin coordinates; when the caller provides no coordinates it falls
-- back to departure time. The mobile client does not send coordinates
-- yet (geocoding is a later phase) — the architecture is ready.

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
  p_page_size integer default 20
)
returns table (
  id uuid,
  host_id uuid,
  origin text,
  destination text,
  pickup_point text,
  destination_point text,
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
  return query
    select
      r.id, r.host_id, r.origin, r.destination, r.pickup_point,
      r.destination_point, r.departure_time, r.estimated_arrival,
      r.total_seats, r.available_seats, r.fare_mode, r.fixed_fare,
      r.ride_status, r.is_student_only, r.is_women_only, r.notes,
      pp.username as host_username,
      pp.display_name as host_display_name,
      pp.profile_photo_url as host_avatar_url,
      pp.overall_rating as host_rating,
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
      and (p_origin is null or r.origin ilike '%' || btrim(p_origin) || '%')
      and (p_destination is null or r.destination ilike '%' || btrim(p_destination) || '%')
      and (p_date is null or r.departure_time::date = p_date)
      and (p_time_from is null or r.departure_time::time >= p_time_from)
      and (p_available_seats is null or r.available_seats >= p_available_seats)
      and (p_student_only is null or r.is_student_only = p_student_only)
      and (p_women_only is null or r.is_women_only = p_women_only)
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
create or replace function public.get_ride(p_ride_id uuid)
returns table (
  id uuid,
  host_id uuid,
  origin text,
  destination text,
  pickup_point text,
  destination_point text,
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

  return query
    select
      r.id, r.host_id, r.origin, r.destination, r.pickup_point,
      r.destination_point, r.departure_time, r.estimated_arrival,
      r.total_seats, r.available_seats, r.fare_mode, r.fixed_fare,
      r.ride_status, r.is_student_only, r.is_women_only, r.notes,
      pp.username, pp.display_name, pp.profile_photo_url, pp.overall_rating,
      r.created_at, r.updated_at
    from public.rides r
    left join public.public_profiles pp on pp.id = r.host_id
    where r.id = p_ride_id
      and (r.ride_status <> 'draft' or r.host_id = v_user);

  if not found then
    raise exception 'Ride not found';
  end if;
end;
$$;

-- ── Request queue (host) ───────────────────────────────────────────
create or replace function public.get_ride_requests(p_ride_id uuid)
returns table (
  id uuid,
  passenger_id uuid,
  status text,
  requested_at timestamptz,
  responded_at timestamptz,
  passenger_username text,
  passenger_display_name text,
  passenger_avatar_url text,
  passenger_rating numeric,
  passenger_reliability integer
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

  if not exists (
    select 1 from public.rides r
    where r.id = p_ride_id and r.host_id = v_user
  ) then
    raise exception 'Only the host can view the request queue' using errcode = '42501';
  end if;

  return query
    select
      rr.id, rr.passenger_id, rr.status, rr.requested_at, rr.responded_at,
      pp.username, pp.display_name, pp.profile_photo_url, pp.overall_rating,
      pp.reliability_score
    from public.ride_requests rr
    left join public.public_profiles pp on pp.id = rr.passenger_id
    where rr.ride_id = p_ride_id
    order by rr.requested_at desc;
end;
$$;

-- ── Participants (host & members) ──────────────────────────────────
create or replace function public.get_ride_participants(p_ride_id uuid)
returns table (
  user_id uuid,
  role text,
  joined_at timestamptz,
  left_at timestamptz,
  username text,
  display_name text,
  avatar_url text,
  rating numeric,
  reliability_score integer
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

  if not exists (
    select 1 from public.ride_participants rp
    where rp.ride_id = p_ride_id and rp.user_id = v_user
  ) then
    raise exception 'Only ride members can view participants' using errcode = '42501';
  end if;

  return query
    select
      rp.user_id, rp.role, rp.joined_at, rp.left_at,
      pp.username, pp.display_name, pp.profile_photo_url, pp.overall_rating,
      pp.reliability_score
    from public.ride_participants rp
    left join public.public_profiles pp on pp.id = rp.user_id
    where rp.ride_id = p_ride_id
    order by (rp.role = 'Host') desc, rp.joined_at asc;
end;
$$;

-- ── Timeline (host & members) ──────────────────────────────────────
create or replace function public.get_ride_timeline(p_ride_id uuid)
returns table (
  id uuid,
  event_type text,
  actor_id uuid,
  metadata jsonb,
  actor_username text,
  actor_display_name text,
  created_at timestamptz
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

  if not exists (
    select 1
    from public.rides r
    where r.id = p_ride_id and r.host_id = v_user
  ) and not exists (
    select 1 from public.ride_participants rp
    where rp.ride_id = p_ride_id and rp.user_id = v_user
  ) then
    raise exception 'Only ride members can view the timeline' using errcode = '42501';
  end if;

  return query
    select
      t.id, t.event_type, t.actor_id, t.metadata,
      pp.username, pp.display_name, t.created_at
    from public.ride_timeline t
    left join public.public_profiles pp on pp.id = t.actor_id
    where t.ride_id = p_ride_id
    order by t.created_at asc;
end;
$$;

-- ── Grants ─────────────────────────────────────────────────────────
revoke all on function public.search_rides(text, text, date, time, integer, boolean, boolean, text, numeric, numeric, integer, integer) from public;
revoke all on function public.get_ride(uuid) from public;
revoke all on function public.get_ride_requests(uuid) from public;
revoke all on function public.get_ride_participants(uuid) from public;
revoke all on function public.get_ride_timeline(uuid) from public;

grant execute on function public.search_rides(text, text, date, time, integer, boolean, boolean, text, numeric, numeric, integer, integer) to authenticated;
grant execute on function public.get_ride(uuid) to authenticated;
grant execute on function public.get_ride_requests(uuid) to authenticated;
grant execute on function public.get_ride_participants(uuid) to authenticated;
grant execute on function public.get_ride_timeline(uuid) to authenticated;
