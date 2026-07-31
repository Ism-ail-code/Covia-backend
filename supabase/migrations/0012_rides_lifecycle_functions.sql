-- Covia - ride lifecycle functions
-- ------------------------------------------------------------------
--   * start_ride    - published/full -> in_progress (host)
--   * complete_ride - in_progress -> completed (host), updates the
--                     reliability counters on profiles
--   * cancel_ride   - draft/published/full -> cancelled (host), closes
--                     open requests, updates counters
-- The full lifecycle is validated in every transition:
--
--   draft --> published --> full --> in_progress --> completed
--       \       \        \     \---> cancelled
--        \      \--------\--> cancelled
--         \--> cancelled

-- ── Start ──────────────────────────────────────────────────────────
create or replace function public.start_ride(p_ride_id uuid)
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
    raise exception 'Only the host can start this ride' using errcode = '42501';
  end if;
  if v_ride.ride_status not in ('published', 'full') then
    raise exception 'Only published rides can be started (current status: %)', v_ride.ride_status;
  end if;

  update public.rides set ride_status = 'in_progress' where id = p_ride_id
  returning * into v_ride;

  perform public.record_ride_event(p_ride_id, 'started', v_user);

  return v_ride;
end;
$$;

-- ── Complete ───────────────────────────────────────────────────────
create or replace function public.complete_ride(p_ride_id uuid)
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
    raise exception 'Only the host can complete this ride' using errcode = '42501';
  end if;
  if v_ride.ride_status <> 'in_progress' then
    raise exception 'Only in-progress rides can be completed (current status: %)', v_ride.ride_status;
  end if;

  update public.rides set ride_status = 'completed' where id = p_ride_id
  returning * into v_ride;

  -- Reliability counters: the host and everyone who actually rode it.
  update public.profiles
  set total_completed_rides = total_completed_rides + 1, updated_at = now()
  where id = v_ride.host_id
     or id in (
       select user_id from public.ride_participants
       where ride_id = p_ride_id and role = 'Passenger' and left_at is null
     );

  perform public.record_ride_event(p_ride_id, 'completed', v_user);

  return v_ride;
end;
$$;

-- ── Cancel (host, before start) ────────────────────────────────────
create or replace function public.cancel_ride(p_ride_id uuid)
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
    raise exception 'Only the host can cancel this ride' using errcode = '42501';
  end if;
  if v_ride.ride_status = 'cancelled' then
    raise exception 'This ride was already cancelled';
  end if;
  if v_ride.ride_status in ('in_progress', 'completed') then
    raise exception 'This ride has already started and cannot be cancelled';
  end if;

  update public.rides set ride_status = 'cancelled' where id = p_ride_id
  returning * into v_ride;

  -- Close any open requests.
  update public.ride_requests
  set status = 'cancelled', responded_at = now()
  where ride_id = p_ride_id and status = 'pending';

  -- Cancellation statistics for the future reliability scoring.
  update public.profiles
  set total_cancelled_rides = total_cancelled_rides + 1, updated_at = now()
  where id = v_ride.host_id;

  perform public.record_ride_event(p_ride_id, 'cancelled', v_user);

  return v_ride;
end;
$$;

-- ── Grants ─────────────────────────────────────────────────────────
revoke all on function public.start_ride(uuid) from public;
revoke all on function public.complete_ride(uuid) from public;
revoke all on function public.cancel_ride(uuid) from public;

grant execute on function public.start_ride(uuid) to authenticated;
grant execute on function public.complete_ride(uuid) to authenticated;
grant execute on function public.cancel_ride(uuid) to authenticated;
