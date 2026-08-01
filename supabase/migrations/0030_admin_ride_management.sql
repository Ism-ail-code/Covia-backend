-- Covia - Phase 10: admin ride management
-- ------------------------------------------------------------------
-- Search rides, inspect full ride details (host, passengers,
-- requests, reports), review the ride timeline, and cancel fraudulent
-- rides with a distinct timeline event that never penalizes the host's
-- reliability score (the platform made the call, not the host).
--
-- Permissions: ride.view for reads, ride.cancel for enforcement.

-- =============================================================
-- New timeline event type for admin cancellations
-- =============================================================
alter table public.ride_timeline drop constraint if exists ride_timeline_event_type_check;
alter table public.ride_timeline add constraint ride_timeline_event_type_check
  check (event_type in (
    'created', 'published', 'requested', 'request_cancelled', 'approved',
    'rejected', 'joined', 'left', 'ride_full', 'edited', 'started',
    'completed', 'cancelled', 'dropped', 'expired', 'cancelled_by_admin'
  ));

-- =============================================================
-- Reads (ride.view)
-- =============================================================
create or replace function public.admin_search_rides(
  p_query text default null,
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns table (
  id uuid,
  host_id uuid,
  host_name text,
  origin text,
  destination text,
  pickup_point text,
  departure_time timestamptz,
  ride_status text,
  fare_mode text,
  fixed_fare numeric,
  total_seats integer,
  available_seats integer,
  passenger_count bigint,
  is_student_only boolean,
  is_women_only boolean,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 100);
  v_page integer := greatest(p_page, 1);
  v_query text := nullif(btrim(coalesce(p_query, '')), '');
begin
  perform public.require_permission('ride.view');
  if p_status is not null and p_status not in (
    'draft', 'published', 'full', 'in_progress', 'completed', 'cancelled', 'expired'
  ) then
    raise exception 'Unknown ride status filter: %', p_status;
  end if;

  return query
    select r.id, r.host_id, pr.display_name,
           r.origin, r.destination, r.pickup_point,
           r.departure_time, r.ride_status, r.fare_mode, r.fixed_fare,
           r.total_seats, r.available_seats,
           (select count(*) from public.ride_participants rp
             where rp.ride_id = r.id and rp.left_at is null),
           r.is_student_only, r.is_women_only, r.created_at,
           count(*) over ()::bigint
      from public.rides r
      left join public.profiles pr on pr.id = r.host_id
     where (v_query is null
            or r.origin ilike '%' || v_query || '%'
            or r.destination ilike '%' || v_query || '%'
            or r.pickup_point ilike '%' || v_query || '%'
            or r.notes ilike '%' || v_query || '%'
            or pr.display_name ilike '%' || v_query || '%')
       and (p_status is null or r.ride_status = p_status)
     order by r.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

create or replace function public.admin_get_ride_details(p_ride_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ride public.rides;
  v_host jsonb;
  v_participants jsonb;
  v_requests bigint;
  v_reports jsonb;
begin
  perform public.require_permission('ride.view');

  select * into v_ride from public.rides where id = p_ride_id;
  if not found then
    raise exception 'Ride not found';
  end if;

  select jsonb_build_object(
           'user_id', pr.id, 'display_name', pr.display_name,
           'username', pr.username, 'email', pr.email, 'phone', pr.phone,
           'rating', pr.rating, 'reliability_score', pr.reliability_score,
           'verification_status', pr.verification_status
         )
    into v_host
    from public.profiles pr
   where pr.id = v_ride.host_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'user_id', rp.user_id, 'role', rp.role,
           'display_name', pr.display_name,
           'username', pr.username,
           'rating', pr.rating,
           'reliability_score', pr.reliability_score,
           'joined_at', rp.joined_at,
           'left_at', rp.left_at
         ) order by rp.joined_at), '[]'::jsonb)
    into v_participants
    from public.ride_participants rp
    left join public.profiles pr on pr.id = rp.user_id
   where rp.ride_id = p_ride_id;

  select count(*) into v_requests
    from public.ride_requests
   where ride_id = p_ride_id and status = 'pending';

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', re.id, 'reporter_user_id', re.reporter_user_id,
           'reporter_name', pr.display_name,
           'reason', re.reason, 'details', re.details,
           'evidence_refs', re.evidence_refs,
           'status', re.status, 'is_confirmed', re.is_confirmed,
           'created_at', re.created_at
         ) order by re.created_at desc), '[]'::jsonb)
    into v_reports
    from public.reports re
    left join public.profiles pr on pr.id = re.reporter_user_id
   where re.target_type = 'ride' and re.target_ride_id = p_ride_id;

  return jsonb_build_object(
    'ride_id', p_ride_id,
    'host', v_host,
    'origin', v_ride.origin,
    'destination', v_ride.destination,
    'pickup_point', v_ride.pickup_point,
    'destination_point', v_ride.destination_point,
    'departure_time', v_ride.departure_time,
    'estimated_arrival', v_ride.estimated_arrival,
    'ride_status', v_ride.ride_status,
    'fare_mode', v_ride.fare_mode,
    'fixed_fare', v_ride.fixed_fare,
    'total_seats', v_ride.total_seats,
    'available_seats', v_ride.available_seats,
    'is_student_only', v_ride.is_student_only,
    'is_women_only', v_ride.is_women_only,
    'notes', v_ride.notes,
    'created_at', v_ride.created_at,
    'pending_requests', v_requests,
    'participants', v_participants,
    'reports', v_reports
  );
end;
$$;

create or replace function public.admin_get_ride_timeline(p_ride_id uuid)
returns setof public.ride_timeline
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_permission('ride.view');
  if not exists (select 1 from public.rides where id = p_ride_id) then
    raise exception 'Ride not found';
  end if;

  return query
    select * from public.ride_timeline
     where ride_id = p_ride_id
     order by created_at, id;
end;
$$;

-- =============================================================
-- Enforcement (ride.cancel)
-- =============================================================
create or replace function public.admin_cancel_ride(
  p_ride_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ride public.rides;
  v_old_status text;
  v_recipient uuid;
begin
  perform public.require_permission('ride.cancel');
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A reason is required';
  end if;

  select * into v_ride from public.rides where id = p_ride_id;
  if not found then
    raise exception 'Ride not found';
  end if;
  if v_ride.ride_status in ('completed', 'cancelled') then
    raise exception 'Only active rides can be cancelled (current status: %)', v_ride.ride_status;
  end if;
  v_old_status := v_ride.ride_status;

  update public.rides
     set ride_status = 'cancelled', available_seats = 0, updated_at = now()
   where id = p_ride_id;

  insert into public.ride_timeline (ride_id, event_type, actor_id, metadata)
  values (p_ride_id, 'cancelled_by_admin', auth.uid(),
          jsonb_build_object('reason', p_reason));

  perform public.record_audit(
    'ride.cancel', 'ride', p_ride_id,
    jsonb_build_object('ride_status', v_old_status),
    jsonb_build_object('ride_status', 'cancelled'),
    jsonb_build_object('reason', p_reason, 'host_id', v_ride.host_id)
  );

  -- Notify the host and everyone still on the ride.
  for v_recipient in
    select rp.user_id
      from public.ride_participants rp
     where rp.ride_id = p_ride_id
       and rp.left_at is null
    union
    select v_ride.host_id
  loop
    begin
      perform public.record_notification(
        v_recipient, 'ride_cancelled', 'Ride cancelled by Covia',
        'Your ride to ' || v_ride.destination || ' was cancelled: ' || p_reason,
        jsonb_build_object('ride_id', p_ride_id, 'reason', p_reason, 'by_admin', true)
      );
    exception when others then
      null;
    end;
  end loop;
end;
$$;

-- =============================================================
-- Grants
-- =============================================================
revoke all on function
  public.admin_search_rides, public.admin_get_ride_details,
  public.admin_get_ride_timeline, public.admin_cancel_ride
  from public;

grant execute on function
  public.admin_search_rides(text, text, integer, integer),
  public.admin_get_ride_details(uuid),
  public.admin_get_ride_timeline(uuid),
  public.admin_cancel_ride(uuid, text)
  to authenticated;
