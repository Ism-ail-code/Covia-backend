-- Covia - ride write functions: structured locations, participant
-- management, draft deletion and ride expiry
-- ------------------------------------------------------------------
-- Phase 5b. Extends the Phase 5 write surface:
--
--   * create_ride (jsonb overload)  - canonical creation with structured
--                                     location objects + pickup kind +
--                                     visibility window + smart fare data
--   * update_ride (extended)        - the host can now edit destination,
--                                     pickup kind, structured locations
--                                     and the visibility window too
--   * delete_draft                  - drafts are deleted, everything else
--                                     is archived via cancel/expire
--   * remove_passenger              - host removes a passenger before
--                                     departure (frees the seat)
--   * expire_overdue_rides          - archives rides that departed
--                                     without starting (status 'expired')
--                                     + guarded pg_cron schedule
--
-- The original text-only create_ride (0010) is replaced by the
-- structured-location version below: this project has never been
-- deployed, so there are no callers to keep alive, and keeping both
-- overloads would make every text call ambiguous for PostgreSQL.

-- ── Create (draft) with structured locations ───────────────────────
drop function if exists public.create_ride(text, text, text, timestamptz, integer, text, numeric, text, text, boolean, boolean, timestamptz);

create or replace function public.create_ride(
  p_origin_loc jsonb,
  p_destination_loc jsonb,
  p_pickup_point_loc jsonb,
  p_departure_time timestamptz,
  p_total_seats integer,
  p_fare_mode text,
  p_fixed_fare numeric default null,
  p_notes text default null,
  p_destination_point_loc jsonb default null,
  p_is_student_only boolean default false,
  p_is_women_only boolean default false,
  p_pickup_type text default null,
  p_visible_at timestamptz default null,
  p_estimated_arrival timestamptz default null,
  p_smart_fare_details jsonb default null
)
returns public.rides
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_ride public.rides;
  v_origin text;
  v_destination text;
  v_pickup text;
  v_dest_point text;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  -- Only verified users can create rides (any verification method).
  if not public.is_user_verified() then
    raise exception 'Only verified users can create rides — verify your ID or student status first';
  end if;

  -- Structured locations (validated + display names extracted).
  v_origin := public.ride_location_text(p_origin_loc, 'Origin');
  v_destination := public.ride_location_text(p_destination_loc, 'Destination');
  v_pickup := public.ride_location_text(p_pickup_point_loc, 'Pickup point');
  if p_destination_point_loc is not null then
    v_dest_point := public.ride_location_text(p_destination_point_loc, 'Destination landmark');
  end if;

  -- Pickup rules: main-road points and public places only.
  if p_pickup_type is null or p_pickup_type not in (
    'main_road', 'landmark', 'university', 'bus_stop', 'metro_station', 'shopping_center'
  ) then
    raise exception 'Pickup must be a main-road point, landmark, university, bus stop, metro station or shopping centre';
  end if;

  if p_departure_time is null then
    raise exception 'Departure date and time are required';
  end if;
  if p_departure_time <= now() then
    raise exception 'Departure must be in the future';
  end if;
  if p_total_seats is null or p_total_seats < 1 or p_total_seats > 10 then
    raise exception 'Seats must be between 1 and 10';
  end if;
  if p_fare_mode not in ('fixed', 'smart') then
    raise exception 'Choose a fare mode (fixed or smart)';
  end if;
  if p_fare_mode = 'fixed' and (p_fixed_fare is null or p_fixed_fare <= 0) then
    raise exception 'Enter a per-seat fare for fixed fares';
  end if;
  if p_fare_mode = 'smart' and p_fixed_fare is not null then
    raise exception 'Smart fares do not use a fixed amount';
  end if;
  if p_is_student_only and not exists (
    select 1 from public.profiles where id = v_user and is_student_verified
  ) then
    raise exception 'Only verified students can create student-only rides';
  end if;

  -- Ride visibility window (optional): must be a future moment before
  -- the departure so the ride can never go live after it left.
  if p_visible_at is not null then
    if p_visible_at <= now() then
      raise exception 'Ride visibility date must be in the future';
    end if;
    if p_visible_at >= p_departure_time then
      raise exception 'Ride visibility must be before the departure time';
    end if;
  end if;

  -- Smart fare: only meaningful on smart-fare rides, must be an object.
  if p_smart_fare_details is not null then
    if p_fare_mode <> 'smart' then
      raise exception 'Smart fare details only apply to smart fares';
    end if;
    if jsonb_typeof(p_smart_fare_details) <> 'object' then
      raise exception 'Smart fare details must be a JSON object';
    end if;
  end if;

  insert into public.rides (
    host_id, origin, destination, pickup_point, destination_point,
    origin_lat, origin_lng, destination_lat, destination_lng,
    origin_loc, destination_loc, pickup_point_loc, destination_point_loc,
    pickup_type, visible_at, smart_fare_details,
    departure_time, estimated_arrival, total_seats, available_seats,
    fare_mode, fixed_fare, ride_status, is_student_only, is_women_only, notes
  )
  values (
    v_user, v_origin, v_destination, v_pickup, v_dest_point,
    nullif(p_origin_loc->>'latitude', '')::numeric,
    nullif(p_origin_loc->>'longitude', '')::numeric,
    nullif(p_destination_loc->>'latitude', '')::numeric,
    nullif(p_destination_loc->>'longitude', '')::numeric,
    p_origin_loc, p_destination_loc, p_pickup_point_loc, p_destination_point_loc,
    p_pickup_type, p_visible_at,
    case when p_fare_mode = 'smart' then p_smart_fare_details else null end,
    p_departure_time, p_estimated_arrival, p_total_seats, p_total_seats,
    p_fare_mode, case when p_fare_mode = 'fixed' then p_fixed_fare else null end,
    'draft', coalesce(p_is_student_only, false), coalesce(p_is_women_only, false),
    nullif(btrim(coalesce(p_notes, '')), '')
  )
  returning * into v_ride;

  perform public.record_ride_event(
    v_ride.id, 'created', v_user,
    jsonb_build_object('pickup_type', p_pickup_type)
  );

  return v_ride;
end;
$$;

-- ── Edit (host, before start) — extended ───────────────────────────
-- The old 7-argument signature is replaced by this one; every legacy
-- positional call still resolves here because the new parameters all
-- have defaults.
drop function if exists public.update_ride(uuid, timestamptz, text, text, integer, text, numeric);

create or replace function public.update_ride(
  p_ride_id uuid,
  p_departure_time timestamptz default null,
  p_pickup_point text default null,
  p_notes text default null,
  p_total_seats integer default null,
  p_fare_mode text default null,
  p_fixed_fare numeric default null,
  p_destination text default null,
  p_destination_point text default null,
  p_pickup_type text default null,
  p_visible_at timestamptz default null,
  p_origin_loc jsonb default null,
  p_destination_loc jsonb default null,
  p_pickup_point_loc jsonb default null,
  p_destination_point_loc jsonb default null,
  p_smart_fare_details jsonb default null
)
returns public.rides
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_ride public.rides;
  v_approved integer;
  v_new_total integer;
  v_available integer;
  v_new_departure timestamptz;
  v_new_origin text;
  v_new_destination text;
  v_new_pickup text;
  v_new_dest_point text;
  v_changes jsonb := '{}'::jsonb;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v_ride
  from public.rides
  where id = p_ride_id
  for update;

  if not found then
    raise exception 'Ride not found';
  end if;
  if v_ride.host_id <> v_user then
    raise exception 'Only the host can edit this ride' using errcode = '42501';
  end if;
  if v_ride.ride_status in ('in_progress', 'completed', 'cancelled', 'expired') then
    raise exception 'This ride can no longer be edited — it has already finished';
  end if;

  -- Departure must stay in the future.
  v_new_departure := coalesce(p_departure_time, v_ride.departure_time);
  if p_departure_time is not null then
    if p_departure_time <= now() then
      raise exception 'Departure must be in the future';
    end if;
    if p_departure_time <> v_ride.departure_time then
      v_changes := v_changes || jsonb_build_object('departure_time', p_departure_time);
    end if;
  end if;

  -- Structured locations (validated, display names extracted).
  if p_origin_loc is not null then
    v_new_origin := public.ride_location_text(p_origin_loc, 'Origin');
    if v_new_origin <> v_ride.origin then
      v_changes := v_changes || jsonb_build_object('origin', v_new_origin);
    end if;
  end if;
  if p_destination_loc is not null then
    v_new_destination := public.ride_location_text(p_destination_loc, 'Destination');
    if v_new_destination <> v_ride.destination then
      v_changes := v_changes || jsonb_build_object('destination', v_new_destination);
    end if;
  end if;
  if p_pickup_point_loc is not null then
    v_new_pickup := public.ride_location_text(p_pickup_point_loc, 'Pickup point');
    if v_new_pickup <> v_ride.pickup_point then
      v_changes := v_changes || jsonb_build_object('pickup_point', v_new_pickup);
    end if;
  end if;
  if p_destination_point_loc is not null then
    v_new_dest_point := public.ride_location_text(p_destination_point_loc, 'Destination landmark');
    if coalesce(v_new_dest_point, '') <> coalesce(v_ride.destination_point, '') then
      v_changes := v_changes || jsonb_build_object('destination_point', v_new_dest_point);
    end if;
  end if;

  -- Legacy plain-text overrides (kept for compatibility).
  if p_destination is not null and btrim(p_destination) <> '' then
    if btrim(p_destination) <> v_ride.destination then
      v_changes := v_changes || jsonb_build_object('destination', btrim(p_destination));
    end if;
  end if;
  if p_destination_point is not null then
    if nullif(btrim(p_destination_point), '') is distinct from v_ride.destination_point then
      v_changes := v_changes || jsonb_build_object('destination_point', nullif(btrim(p_destination_point), ''));
    end if;
  end if;

  if p_pickup_point is not null and btrim(p_pickup_point) <> '' then
    if btrim(p_pickup_point) <> v_ride.pickup_point then
      v_changes := v_changes || jsonb_build_object('pickup_point', btrim(p_pickup_point));
    end if;
  end if;

  -- Pickup kind rules.
  if p_pickup_type is not null then
    if p_pickup_type not in (
      'main_road', 'landmark', 'university', 'bus_stop', 'metro_station', 'shopping_center'
    ) then
      raise exception 'Pickup must be a main-road point, landmark, university, bus stop, metro station or shopping centre';
    end if;
    if p_pickup_type <> v_ride.pickup_type then
      v_changes := v_changes || jsonb_build_object('pickup_type', p_pickup_type);
    end if;
  end if;

  -- Visibility window: future and before departure.
  if p_visible_at is not null then
    if p_visible_at <= now() then
      raise exception 'Ride visibility date must be in the future';
    end if;
    if p_visible_at >= v_new_departure then
      raise exception 'Ride visibility must be before the departure time';
    end if;
    if p_visible_at <> v_ride.visible_at then
      v_changes := v_changes || jsonb_build_object('visible_at', p_visible_at);
    end if;
  end if;

  -- Smart fare details payload.
  if p_smart_fare_details is not null then
    if coalesce(p_fare_mode, v_ride.fare_mode) <> 'smart' then
      raise exception 'Smart fare details only apply to smart fares';
    end if;
    if jsonb_typeof(p_smart_fare_details) <> 'object' then
      raise exception 'Smart fare details must be a JSON object';
    end if;
    if p_smart_fare_details is distinct from v_ride.smart_fare_details then
      v_changes := v_changes || jsonb_build_object('smart_fare_details', p_smart_fare_details);
    end if;
  end if;

  if p_notes is not null then
    if coalesce(btrim(p_notes), null) is distinct from v_ride.notes then
      v_changes := v_changes || jsonb_build_object('notes', btrim(p_notes));
    end if;
  end if;

  if p_fare_mode is not null then
    if p_fare_mode not in ('fixed', 'smart') then
      raise exception 'Choose a fare mode (fixed or smart)';
    end if;
    if p_fare_mode = 'fixed' and (p_fixed_fare is null or p_fixed_fare <= 0) then
      raise exception 'Enter a per-seat fare for fixed fares';
    end if;
    if p_fare_mode = 'smart' and p_fixed_fare is not null then
      raise exception 'Smart fares do not use a fixed amount';
    end if;
    if (p_fare_mode, p_fixed_fare) is distinct from (v_ride.fare_mode, v_ride.fixed_fare) then
      v_changes := v_changes || jsonb_build_object('fare_mode', p_fare_mode, 'fixed_fare', p_fixed_fare);
    end if;
  end if;

  -- Seat edits: cannot drop below the number of approved passengers.
  select count(*) into v_approved
  from public.ride_participants
  where ride_id = p_ride_id and role = 'Passenger' and left_at is null;

  v_new_total := coalesce(p_total_seats, v_ride.total_seats);
  if v_new_total < 1 or v_new_total > 10 then
    raise exception 'Seats must be between 1 and 10';
  end if;
  if v_new_total < v_approved then
    raise exception 'Cannot reduce seats below the % approved passengers', v_approved;
  end if;
  v_available := v_new_total - v_approved;
  if p_total_seats is not null and p_total_seats <> v_ride.total_seats then
    v_changes := v_changes || jsonb_build_object('total_seats', p_total_seats, 'available_seats', v_available);
  end if;

  update public.rides
  set departure_time = coalesce(p_departure_time, departure_time),
      origin = coalesce(v_new_origin, origin),
      origin_lat = case when p_origin_loc is not null then nullif(p_origin_loc->>'latitude', '')::numeric else origin_lat end,
      origin_lng = case when p_origin_loc is not null then nullif(p_origin_loc->>'longitude', '')::numeric else origin_lng end,
      origin_loc = coalesce(p_origin_loc, origin_loc),
      destination = case
        when p_destination_loc is not null then v_new_destination
        when p_destination is not null and btrim(p_destination) <> '' then btrim(p_destination)
        else destination
      end,
      destination_lat = case when p_destination_loc is not null then nullif(p_destination_loc->>'latitude', '')::numeric else destination_lat end,
      destination_lng = case when p_destination_loc is not null then nullif(p_destination_loc->>'longitude', '')::numeric else destination_lng end,
      destination_loc = coalesce(p_destination_loc, destination_loc),
      pickup_point = case
        when p_pickup_point_loc is not null then v_new_pickup
        when p_pickup_point is not null and btrim(p_pickup_point) <> '' then btrim(p_pickup_point)
        else pickup_point
      end,
      pickup_point_loc = coalesce(p_pickup_point_loc, pickup_point_loc),
      destination_point = case
        when p_destination_point_loc is not null then v_new_dest_point
        when p_destination_point is not null then nullif(btrim(p_destination_point), '')
        else destination_point
      end,
      destination_point_loc = coalesce(p_destination_point_loc, destination_point_loc),
      pickup_type = coalesce(p_pickup_type, pickup_type),
      visible_at = coalesce(p_visible_at, visible_at),
      smart_fare_details = case
        when p_smart_fare_details is not null then p_smart_fare_details
        when p_fare_mode = 'smart' then smart_fare_details
        when p_fare_mode = 'fixed' then null
        else smart_fare_details
      end,
      notes = case when p_notes is not null then nullif(btrim(p_notes), '') else notes end,
      total_seats = v_new_total,
      available_seats = v_available,
      fare_mode = coalesce(p_fare_mode, fare_mode),
      fixed_fare = case
        when p_fare_mode = 'fixed' then p_fixed_fare
        when p_fare_mode = 'smart' then null
        else fixed_fare
      end,
      ride_status = case
        when ride_status = 'draft' then 'draft'
        when v_available = 0 then 'full'
        else 'published'
      end
  where id = p_ride_id
  returning * into v_ride;

  if v_changes <> '{}'::jsonb then
    perform public.record_ride_event(p_ride_id, 'edited', v_user, v_changes);
  end if;

  return v_ride;
end;
$$;

-- ── Delete a draft ─────────────────────────────────────────────────
-- Only drafts are ever deleted (nothing has been published yet);
-- published/full rides are archived through cancel_ride, and finished
-- rides through complete_ride / expire_overdue_rides.
create or replace function public.delete_draft(p_ride_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_ride public.rides;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v_ride
  from public.rides
  where id = p_ride_id
  for update;

  if not found then
    raise exception 'Ride not found';
  end if;
  if v_ride.host_id <> v_user then
    raise exception 'Only the host can delete this ride' using errcode = '42501';
  end if;
  if v_ride.ride_status <> 'draft' then
    raise exception 'Only draft rides can be deleted — % rides are cancelled or completed instead', v_ride.ride_status;
  end if;

  delete from public.rides where id = p_ride_id;

  return true;
end;
$$;

-- ── Host removes a passenger (before departure) ────────────────────
-- The seat is freed immediately and the ride re-opens if it was full.
-- An approved request row stays 'approved' for the request history;
-- the 'dropped' timeline event records the removal.
create or replace function public.remove_passenger(p_ride_id uuid, p_passenger_id uuid)
returns public.rides
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host uuid := auth.uid();
  v_ride public.rides;
begin
  if v_host is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v_ride
  from public.rides
  where id = p_ride_id
  for update;

  if not found then
    raise exception 'Ride not found';
  end if;
  if v_ride.host_id <> v_host then
    raise exception 'Only the host can remove passengers' using errcode = '42501';
  end if;
  if v_ride.ride_status in ('in_progress', 'completed') then
    raise exception 'Passengers can only be removed before the ride starts';
  end if;
  if v_ride.ride_status in ('cancelled', 'expired') then
    raise exception 'This ride is no longer active';
  end if;

  if not exists (
    select 1 from public.ride_participants
    where ride_id = p_ride_id and user_id = p_passenger_id
      and role = 'Passenger' and left_at is null
  ) then
    raise exception 'That passenger is not on this ride';
  end if;

  update public.ride_participants
  set left_at = now()
  where ride_id = p_ride_id and user_id = p_passenger_id
    and role = 'Passenger' and left_at is null;

  update public.rides
  set available_seats = least(total_seats, available_seats + 1),
      ride_status = case when ride_status = 'full' then 'published' else ride_status end
  where id = p_ride_id
  returning * into v_ride;

  perform public.record_ride_event(
    p_ride_id, 'dropped', v_host,
    jsonb_build_object('passenger_id', p_passenger_id)
  );

  return v_ride;
end;
$$;

-- ── Ride expiry (auto-archive after departure) ─────────────────────
-- published/full rides whose departure time has passed are archived to
-- 'expired' (never deleted — history stays). Pending requests on them
-- are closed and an 'expired' timeline event is recorded for each ride.
-- Idempotent; safe to call from a scheduler or on read.
create or replace function public.expire_overdue_rides()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  insert into public.ride_timeline (ride_id, event_type, actor_id, metadata)
  select r.id, 'expired', null, jsonb_build_object('departure_time', r.departure_time)
  from public.rides r
  where r.ride_status in ('published', 'full')
    and r.departure_time <= now();

  update public.ride_requests rr
  set status = 'cancelled', responded_at = now()
  from public.rides r
  where rr.ride_id = r.id and rr.status = 'pending'
    and r.ride_status in ('published', 'full')
    and r.departure_time <= now();

  update public.rides
  set ride_status = 'expired', updated_at = now()
  where ride_status in ('published', 'full')
    and departure_time <= now();

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ── Scheduler (guarded: only on databases with pg_cron, e.g. Supabase)
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'covia-expire-rides',
      '*/15 * * * *',
      $job$ select public.expire_overdue_rides(); $job$
    );
  end if;
end $$;

-- ── Grants ─────────────────────────────────────────────────────────
revoke all on function public.create_ride(jsonb, jsonb, jsonb, timestamptz, integer, text, numeric, text, jsonb, boolean, boolean, text, timestamptz, timestamptz, jsonb) from public;
revoke all on function public.update_ride(uuid, timestamptz, text, text, integer, text, numeric, text, text, text, timestamptz, jsonb, jsonb, jsonb, jsonb, jsonb) from public;
revoke all on function public.delete_draft(uuid) from public;
revoke all on function public.remove_passenger(uuid, uuid) from public;
revoke all on function public.expire_overdue_rides() from public;

grant execute on function public.create_ride(jsonb, jsonb, jsonb, timestamptz, integer, text, numeric, text, jsonb, boolean, boolean, text, timestamptz, timestamptz, jsonb) to authenticated;
grant execute on function public.update_ride(uuid, timestamptz, text, text, integer, text, numeric, text, text, text, timestamptz, jsonb, jsonb, jsonb, jsonb, jsonb) to authenticated;
grant execute on function public.delete_draft(uuid) to authenticated;
grant execute on function public.remove_passenger(uuid, uuid) to authenticated;
grant execute on function public.expire_overdue_rides() to authenticated;
