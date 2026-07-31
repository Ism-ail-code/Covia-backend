-- Covia - ride creation & editing functions
-- ------------------------------------------------------------------
--   * create_ride   - draft ride (validated, verified hosts only)
--   * publish_ride  - draft -> published, host joins as participant
--   * update_ride   - host edits before the ride starts (safe seat
--                     limits, recalculates available seats)
-- All security definer; every call is host/user-validated.

-- ── Create (draft) ─────────────────────────────────────────────────
create or replace function public.create_ride(
  p_origin text,
  p_destination text,
  p_pickup_point text,
  p_departure_time timestamptz,
  p_total_seats integer,
  p_fare_mode text,
  p_fixed_fare numeric default null,
  p_notes text default null,
  p_destination_point text default null,
  p_is_student_only boolean default false,
  p_is_women_only boolean default false,
  p_estimated_arrival timestamptz default null
)
returns public.rides
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

  -- Only verified users can create rides (any verification method).
  if not public.is_user_verified() then
    raise exception 'Only verified users can create rides — verify your ID or student status first';
  end if;

  if nullif(btrim(coalesce(p_origin, '')), '') is null then
    raise exception 'Origin is required';
  end if;
  if nullif(btrim(coalesce(p_destination, '')), '') is null then
    raise exception 'Destination is required';
  end if;
  if nullif(btrim(coalesce(p_pickup_point, '')), '') is null then
    raise exception 'Pickup point is required';
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

  insert into public.rides (
    host_id, origin, destination, pickup_point, destination_point,
    origin_lat, origin_lng, destination_lat, destination_lng,
    departure_time, estimated_arrival, total_seats, available_seats,
    fare_mode, fixed_fare, ride_status, is_student_only, is_women_only, notes
  )
  values (
    v_user, btrim(p_origin), btrim(p_destination), btrim(p_pickup_point),
    nullif(btrim(coalesce(p_destination_point, '')), ''),
    null, null, null, null,
    p_departure_time, p_estimated_arrival, p_total_seats, p_total_seats,
    p_fare_mode, case when p_fare_mode = 'fixed' then p_fixed_fare else null end,
    'draft', coalesce(p_is_student_only, false), coalesce(p_is_women_only, false),
    nullif(btrim(coalesce(p_notes, '')), '')
  )
  returning * into v_ride;

  perform public.record_ride_event(v_ride.id, 'created', v_user);

  return v_ride;
end;
$$;

-- ── Publish (draft -> published) ───────────────────────────────────
create or replace function public.publish_ride(p_ride_id uuid)
returns public.rides
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
    raise exception 'Only the host can publish this ride' using errcode = '42501';
  end if;
  if v_ride.ride_status <> 'draft' then
    raise exception 'Only draft rides can be published (current status: %)', v_ride.ride_status;
  end if;

  update public.rides set ride_status = 'published' where id = p_ride_id
  returning * into v_ride;

  insert into public.ride_participants (ride_id, user_id, role)
  values (p_ride_id, v_user, 'Host')
  on conflict (ride_id, user_id) do nothing;

  perform public.record_ride_event(p_ride_id, 'published', v_user);

  return v_ride;
end;
$$;

-- ── Edit (host, before start) ──────────────────────────────────────
create or replace function public.update_ride(
  p_ride_id uuid,
  p_departure_time timestamptz default null,
  p_pickup_point text default null,
  p_notes text default null,
  p_total_seats integer default null,
  p_fare_mode text default null,
  p_fixed_fare numeric default null
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
  if v_ride.ride_status in ('in_progress', 'completed', 'cancelled') then
    raise exception 'This ride can no longer be edited — it has already started';
  end if;

  -- Departure must stay in the future.
  if p_departure_time is not null then
    if p_departure_time <= now() then
      raise exception 'Departure must be in the future';
    end if;
    if p_departure_time <> v_ride.departure_time then
      v_changes := v_changes || jsonb_build_object('departure_time', p_departure_time);
    end if;
  end if;

  if p_pickup_point is not null and btrim(p_pickup_point) <> '' then
    if btrim(p_pickup_point) <> v_ride.pickup_point then
      v_changes := v_changes || jsonb_build_object('pickup_point', btrim(p_pickup_point));
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
      pickup_point = case when p_pickup_point is not null and btrim(p_pickup_point) <> '' then btrim(p_pickup_point) else pickup_point end,
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

-- ── Grants ─────────────────────────────────────────────────────────
revoke all on function public.create_ride(text, text, text, timestamptz, integer, text, numeric, text, text, boolean, boolean, timestamptz) from public;
revoke all on function public.publish_ride(uuid) from public;
revoke all on function public.update_ride(uuid, timestamptz, text, text, integer, text, numeric) from public;

grant execute on function public.create_ride(text, text, text, timestamptz, integer, text, numeric, text, text, boolean, boolean, timestamptz) to authenticated;
grant execute on function public.publish_ride(uuid) to authenticated;
grant execute on function public.update_ride(uuid, timestamptz, text, text, integer, text, numeric) to authenticated;
