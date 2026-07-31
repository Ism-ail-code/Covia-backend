-- Covia - ride request & approval functions
-- ------------------------------------------------------------------
-- The manual approval workflow:
--
--   passenger request_to_join -> host_respond_to_request (approve /
--   reject) -> approved passengers become participants
--
-- Guards: only verified users participate, hosts never request their
-- own ride, duplicate requests are blocked, capacity is enforced at
-- approval time, and passengers cannot sit on two overlapping rides.

-- ── Request to join ────────────────────────────────────────────────
create or replace function public.request_to_join(p_ride_id uuid)
returns public.ride_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_ride public.rides;
  v_req public.ride_requests;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  if not public.is_user_verified() then
    raise exception 'Only verified users can join rides — verify your ID or student status first';
  end if;

  select * into v_ride
  from public.rides
  where id = p_ride_id
  for update;

  if not found then
    raise exception 'Ride not found';
  end if;
  if v_ride.host_id = v_user then
    raise exception 'You cannot request to join your own ride';
  end if;
  if v_ride.ride_status = 'draft' then
    raise exception 'This ride has not been published yet';
  end if;
  if v_ride.ride_status = 'full' then
    raise exception 'This ride is full';
  end if;
  if v_ride.ride_status in ('in_progress', 'completed') then
    raise exception 'This ride has already started';
  end if;
  if v_ride.ride_status = 'cancelled' then
    raise exception 'This ride was cancelled';
  end if;

  if exists (
    select 1 from public.ride_requests
    where ride_id = p_ride_id and passenger_id = v_user and status = 'pending'
  ) then
    raise exception 'You already requested to join this ride' using errcode = '23505';
  end if;

  -- An approved passenger cannot double-book the same ride.
  if exists (
    select 1 from public.ride_participants
    where ride_id = p_ride_id and user_id = v_user
      and role = 'Passenger' and left_at is null
  ) then
    raise exception 'You are already on this ride';
  end if;

  -- No overlapping rides: the user cannot have an active participation or
  -- an open (pending) request on another ride departing within 6 hours
  -- of this one. Approved requests already created a participant row, so
  -- only pending requests matter here (and participants who left are not
  -- counted — their seat was freed).
  if exists (
    select 1
    from public.ride_participants rp
    join public.rides r on r.id = rp.ride_id
    where rp.user_id = v_user and rp.role = 'Passenger' and rp.left_at is null
      and r.ride_status in ('published', 'full', 'in_progress')
      and abs(extract(epoch from (r.departure_time - v_ride.departure_time))) < 6 * 3600
  ) then
    raise exception 'You already have a seat on a ride departing around the same time';
  end if;

  if exists (
    select 1
    from public.ride_requests rr
    join public.rides r on r.id = rr.ride_id
    where rr.passenger_id = v_user and rr.status = 'pending'
      and r.ride_status in ('published', 'full', 'in_progress')
      and abs(extract(epoch from (r.departure_time - v_ride.departure_time))) < 6 * 3600
  ) then
    raise exception 'You already have a request or seat on a ride departing around the same time';
  end if;

  insert into public.ride_requests (ride_id, passenger_id)
  values (p_ride_id, v_user)
  returning * into v_req;

  perform public.record_ride_event(
    p_ride_id, 'requested', v_user,
    jsonb_build_object('request_id', v_req.id, 'passenger_id', v_user)
  );

  return v_req;
end;
$$;

-- ── Withdraw a pending request ─────────────────────────────────────
create or replace function public.cancel_ride_request(p_request_id uuid)
returns public.ride_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_req public.ride_requests;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v_req
  from public.ride_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Ride request not found';
  end if;
  if v_req.passenger_id <> v_user then
    raise exception 'Only the passenger can withdraw this request' using errcode = '42501';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'Only pending requests can be withdrawn (current status: %)', v_req.status;
  end if;

  update public.ride_requests
  set status = 'cancelled', responded_at = now()
  where id = p_request_id
  returning * into v_req;

  perform public.record_ride_event(
    v_req.ride_id, 'request_cancelled', v_user,
    jsonb_build_object('request_id', v_req.id)
  );

  return v_req;
end;
$$;

-- ── Passenger leaves before the ride starts ────────────────────────
create or replace function public.leave_ride(p_ride_id uuid)
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

  if not exists (
    select 1 from public.ride_participants
    where ride_id = p_ride_id and user_id = v_user and role = 'Passenger' and left_at is null
  ) then
    raise exception 'You are not on this ride';
  end if;

  select * into v_ride
  from public.rides
  where id = p_ride_id
  for update;

  if v_ride.ride_status in ('in_progress', 'completed') then
    raise exception 'You can only leave before the ride starts';
  end if;
  if v_ride.ride_status = 'cancelled' then
    raise exception 'This ride was cancelled';
  end if;

  update public.ride_participants
  set left_at = now()
  where ride_id = p_ride_id and user_id = v_user and role = 'Passenger' and left_at is null;

  update public.rides
  set available_seats = least(total_seats, available_seats + 1),
      ride_status = case when ride_status = 'full' then 'published' else ride_status end
  where id = p_ride_id
  returning * into v_ride;

  perform public.record_ride_event(p_ride_id, 'left', v_user);

  return v_ride;
end;
$$;

-- ── Host approves / rejects a request ──────────────────────────────
create or replace function public.host_respond_to_request(
  p_request_id uuid,
  p_approve boolean,
  p_reason text default null
)
returns public.ride_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host uuid := auth.uid();
  v_req public.ride_requests;
  v_ride public.rides;
begin
  if v_host is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v_req
  from public.ride_requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Ride request not found';
  end if;

  select * into v_ride
  from public.rides
  where id = v_req.ride_id
  for update;

  if v_ride.host_id <> v_host then
    raise exception 'Only the host can respond to this request' using errcode = '42501';
  end if;
  if v_req.status <> 'pending' then
    raise exception 'This request was already handled (status: %)', v_req.status;
  end if;
  if v_ride.ride_status not in ('published', 'full') then
    raise exception 'This ride is not accepting requests right now (status: %)', v_ride.ride_status;
  end if;

  if p_approve then
    if v_ride.available_seats < 1 then
      raise exception 'This ride is full';
    end if;
    if exists (
      select 1 from public.ride_participants
      where ride_id = v_req.ride_id and user_id = v_req.passenger_id
        and role = 'Passenger' and left_at is null
    ) then
      raise exception 'This passenger is already on the ride';
    end if;

    update public.ride_requests
    set status = 'approved', responded_at = now()
    where id = p_request_id
    returning * into v_req;

    insert into public.ride_participants (ride_id, user_id, role)
    values (v_req.ride_id, v_req.passenger_id, 'Passenger')
    on conflict (ride_id, user_id) do nothing;

    if v_ride.available_seats = 1 then
      update public.rides
      set available_seats = 0, ride_status = 'full'
      where id = v_req.ride_id
      returning * into v_ride;

      perform public.record_ride_event(v_req.ride_id, 'ride_full', v_host);
    else
      update public.rides
      set available_seats = available_seats - 1
      where id = v_req.ride_id
      returning * into v_ride;
    end if;

    perform public.record_ride_event(
      v_req.ride_id, 'approved', v_host,
      jsonb_build_object('request_id', v_req.id, 'passenger_id', v_req.passenger_id)
    );
    perform public.record_ride_event(
      v_req.ride_id, 'joined', v_host,
      jsonb_build_object('request_id', v_req.id, 'passenger_id', v_req.passenger_id)
    );
  else
    update public.ride_requests
    set status = 'rejected', responded_at = now()
    where id = p_request_id
    returning * into v_req;

    perform public.record_ride_event(
      v_req.ride_id, 'rejected', v_host,
      jsonb_build_object('request_id', v_req.id, 'passenger_id', v_req.passenger_id, 'reason', p_reason)
    );
  end if;

  return v_req;
end;
$$;

-- ── Grants ─────────────────────────────────────────────────────────
revoke all on function public.request_to_join(uuid) from public;
revoke all on function public.cancel_ride_request(uuid) from public;
revoke all on function public.leave_ride(uuid) from public;
revoke all on function public.host_respond_to_request(uuid, boolean, text) from public;

grant execute on function public.request_to_join(uuid) to authenticated;
grant execute on function public.cancel_ride_request(uuid) to authenticated;
grant execute on function public.leave_ride(uuid) to authenticated;
grant execute on function public.host_respond_to_request(uuid, boolean, text) to authenticated;
