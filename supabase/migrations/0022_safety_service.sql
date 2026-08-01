-- ============================================================================
-- 0022 â€” Phase 8: Safety service â€” SOS, safety check-ins, live location
-- sharing, route monitoring, escalation and incident reporting.
--
-- Security model: every mutation is a security-definer RPC that asserts ride
-- membership; the client only ever reads (RLS) or calls RPCs. Notification
-- delivery is decoupled: in-app notifications go through the Phase 6
-- `record_notification` bus (safety_enabled-gated) and out-of-app delivery
-- lands in `outbound_notifications`, which a future SMS/email/push worker
-- drains â€” nothing here hardcodes a provider.
-- ============================================================================

-- â”€â”€ Internal helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
create or replace function public.assert_ride_member(p_ride_id uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.rides where id = p_ride_id) then
    raise exception 'Ride not found';
  end if;
  if not public.is_active_ride_member(p_ride_id, p_user) then
    raise exception 'You are not on this ride';
  end if;
end;
$$;

create or replace function public.is_valid_phone(p_phone text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select btrim(coalesce(p_phone, '')) <> ''
     and p_phone ~ '^\+?[0-9()\-\. ]{7,20}$';
$$;

-- Great-circle distance in meters (haversine).
create or replace function public.haversine_m(p_a jsonb, p_b jsonb)
returns numeric
language sql
immutable
set search_path = public
as $$
  with ab as (
    select
      radians((p_a ->> 'lat')::numeric) as alat,
      radians((p_a ->> 'lng')::numeric) as alng,
      radians((p_b ->> 'lat')::numeric) as blat,
      radians((p_b ->> 'lng')::numeric) as blng
  )
  select 6371000.0 * 2 * asin(
    least(1.0, sqrt(
      power(sin((blat - alat) / 2), 2)
      + cos(alat) * cos(blat) * power(sin((blng - alng) / 2), 2)
    ))
  )
  from ab;
$$;

-- Distance (meters) from a point to a segment, via an equirectangular
-- projection around the point (accurate enough for deviation checks).
create or replace function public.point_segment_distance_m(p_point jsonb, p_a jsonb, p_b jsonb)
returns numeric
language sql
immutable
set search_path = public
as $$
  with prj as (
    select
      ((p_point ->> 'lng')::numeric) * cos(radians((p_point ->> 'lat')::numeric)) as px,
      (p_point ->> 'lat')::numeric as py,
      ((p_a ->> 'lng')::numeric) * cos(radians((p_point ->> 'lat')::numeric)) as ax,
      (p_a ->> 'lat')::numeric as ay,
      ((p_b ->> 'lng')::numeric) * cos(radians((p_point ->> 'lat')::numeric)) as bx,
      (p_b ->> 'lat')::numeric as by
  ),
  dim as (
    select px, py, ax, ay, bx, by,
           bx - ax as dx, by - ay as dy
    from prj
  )
  select (
    case
      when dx * dx + dy * dy = 0 then sqrt(power(px - ax, 2) + power(py - ay, 2))
      else
        (with t as (
          select greatest(0.0, least(1.0,
            ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
          )) as t
          from dim
        )
        select sqrt(power(px - (ax + t.t * dx), 2) + power(py - (ay + t.t * dy), 2)) from t)
    end
  ) * 111320.0
  from dim;
$$;

-- Minimum distance (meters) from a point to a route polyline, or null when
-- the route has fewer than two points.
create or replace function public.distance_to_route_m(p_point jsonb, p_route jsonb)
returns numeric
language plpgsql
immutable
set search_path = public
as $$
declare
  v_n integer;
  v_i integer;
  v_min numeric := null;
  v_d numeric;
begin
  if p_route is null or jsonb_typeof(p_route) <> 'array' then
    return null;
  end if;
  v_n := jsonb_array_length(p_route);
  if v_n < 2 then
    return null;
  end if;
  for v_i in 0 .. v_n - 2 loop
    v_d := public.point_segment_distance_m(p_point, p_route -> v_i, p_route -> (v_i + 1));
    if v_min is null or v_d < v_min then
      v_min := v_d;
    end if;
  end loop;
  return v_min;
end;
$$;

-- â”€â”€ Safety configuration â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Thresholds are tunable post-launch without application changes.
-- Server-only writer (no grants below): the app reads, the backend tunes.
create or replace function public.get_safety_config()
returns public.safety_config
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_cfg public.safety_config;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  select * into v_cfg from public.safety_config where id = true;
  if v_cfg.id is null then
    insert into public.safety_config (id) values (true);
    select * into v_cfg from public.safety_config where id = true;
  end if;
  return v_cfg;
end;
$$;

create or replace function public.update_safety_config(
  p_route_deviation_meters numeric default null,
  p_stop_threshold_seconds integer default null,
  p_safety_check_timeout_seconds integer default null,
  p_never_started_minutes integer default null,
  p_exceeded_duration_minutes integer default null,
  p_notify_participants_on_sos boolean default null,
  p_sos_repeat_window_seconds integer default null,
  p_live_location_retention_hours integer default null
)
returns public.safety_config
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg public.safety_config;
begin
  update public.safety_config
  set route_deviation_meters = coalesce(p_route_deviation_meters, route_deviation_meters),
      stop_threshold_seconds = coalesce(p_stop_threshold_seconds, stop_threshold_seconds),
      safety_check_timeout_seconds = coalesce(p_safety_check_timeout_seconds, safety_check_timeout_seconds),
      never_started_minutes = coalesce(p_never_started_minutes, never_started_minutes),
      exceeded_duration_minutes = coalesce(p_exceeded_duration_minutes, exceeded_duration_minutes),
      notify_participants_on_sos = coalesce(p_notify_participants_on_sos, notify_participants_on_sos),
      sos_repeat_window_seconds = coalesce(p_sos_repeat_window_seconds, sos_repeat_window_seconds),
      live_location_retention_hours = coalesce(p_live_location_retention_hours, live_location_retention_hours),
      updated_at = now()
  where id = true
  returning * into v_cfg;
  return v_cfg;
end;
$$;

-- â”€â”€ Emergency contacts (owner-only CRUD) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
create or replace function public.get_emergency_contacts()
returns setof public.emergency_contacts
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
    select * from public.emergency_contacts
    where user_id = v_user
    order by is_primary desc, created_at;
end;
$$;

create or replace function public.add_emergency_contact(
  p_name text,
  p_phone text,
  p_relationship text,
  p_is_primary boolean default false
)
returns public.emergency_contacts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_contact public.emergency_contacts;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if nullif(btrim(coalesce(p_name, '')), '') is null then
    raise exception 'A contact name is required';
  end if;
  if not public.is_valid_phone(p_phone) then
    raise exception 'A valid phone number is required';
  end if;
  if nullif(btrim(coalesce(p_relationship, '')), '') is null then
    raise exception 'A relationship is required';
  end if;

  if p_is_primary then
    update public.emergency_contacts
    set is_primary = false, updated_at = now()
    where user_id = v_user and is_primary;
  end if;

  insert into public.emergency_contacts (user_id, name, phone, relationship, is_primary)
  values (v_user, btrim(p_name), btrim(p_phone), btrim(p_relationship), coalesce(p_is_primary, false))
  returning * into v_contact;
  return v_contact;
end;
$$;

create or replace function public.update_emergency_contact(
  p_contact_id uuid,
  p_name text default null,
  p_phone text default null,
  p_relationship text default null,
  p_is_primary boolean default null
)
returns public.emergency_contacts
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_contact public.emergency_contacts;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v_contact
  from public.emergency_contacts
  where id = p_contact_id and user_id = v_user;
  if v_contact.id is null then
    raise exception 'Contact not found';
  end if;

  if p_name is not null and nullif(btrim(p_name), '') is null then
    raise exception 'A contact name is required';
  end if;
  if p_phone is not null and not public.is_valid_phone(p_phone) then
    raise exception 'A valid phone number is required';
  end if;
  if p_relationship is not null and nullif(btrim(p_relationship), '') is null then
    raise exception 'A relationship is required';
  end if;

  if p_is_primary then
    update public.emergency_contacts
    set is_primary = false, updated_at = now()
    where user_id = v_user and is_primary and id <> p_contact_id;
  end if;

  update public.emergency_contacts
  set name = coalesce(btrim(p_name), name),
      phone = coalesce(btrim(p_phone), phone),
      relationship = coalesce(btrim(p_relationship), relationship),
      is_primary = coalesce(p_is_primary, is_primary),
      updated_at = now()
  where id = p_contact_id
  returning * into v_contact;
  return v_contact;
end;
$$;

create or replace function public.delete_emergency_contact(p_contact_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  delete from public.emergency_contacts
  where id = p_contact_id and user_id = v_user;
  if not found then
    raise exception 'Contact not found';
  end if;
end;
$$;

-- â”€â”€ Safety prompt (the "Are you safe?" flow) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Internal: raises a check on the ride (event + broadcast + in-app
-- notification + escalation timer). One open prompt per ride.
create or replace function public.perform_safety_check(
  p_ride_id uuid,
  p_user uuid,
  p_check_kind text,
  p_location jsonb,
  p_metadata jsonb
)
returns public.safety_events
language plpgsql
security definer
set search_path = public
as $$
declare
  v_evt public.safety_events;
  v_open uuid;
begin
  select check_event_id into v_open
  from public.ride_monitoring
  where ride_id = p_ride_id and check_required_at is not null;

  if v_open is not null then
    return null; -- already prompting this ride
  end if;

  insert into public.safety_events (ride_id, user_id, event_type, severity, location, metadata)
  values (p_ride_id, p_user, 'safety_check', 'warning', p_location,
          p_metadata || jsonb_build_object('check_kind', p_check_kind))
  returning * into v_evt;

  update public.ride_monitoring
  set check_required_at = now(), check_event_id = v_evt.id
  where ride_id = p_ride_id;

  perform public.broadcast_covia_event(
    'covia.safety.check_required',
    jsonb_build_object(
      'ride_id', p_ride_id,
      'event_id', v_evt.id,
      'user_id', p_user,
      'check_kind', p_check_kind
    )
  );

  perform public.record_notification(
    p_user, 'safety_check', 'Are you safe?',
    'Covia noticed unusual activity on your ride. Please confirm you are safe.',
    jsonb_build_object('ride_id', p_ride_id, 'event_id', v_evt.id, 'check_kind', p_check_kind),
    null, null
  );

  return v_evt;
end;
$$;

-- â”€â”€ SOS â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Internal: creates the critical event, broadcasts, notifies ride
-- participants (config-gated) and queues emergency-contact notifications.
-- Idempotent: an unresolved SOS for the same (ride, user) inside the repeat
-- window returns the existing event â€” the button never double-fires.
create or replace function public.perform_sos(
  p_ride_id uuid,
  p_user uuid,
  p_location jsonb,
  p_source text default 'sos_button'
)
returns public.safety_events
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cfg public.safety_config;
  v_evt public.safety_events;
  v_ride public.rides;
  v_mon public.ride_monitoring;
  v_contact record;
  v_recipient uuid;
  v_user_name text;
begin
  select * into v_cfg from public.safety_config where id = true;
  select * into v_mon from public.ride_monitoring where ride_id = p_ride_id;
  select * into v_ride from public.rides where id = p_ride_id;
  select display_name into v_user_name from public.profiles where id = p_user;

  -- Duplicate SOS â†’ return the existing event untouched.
  select * into v_evt
  from public.safety_events
  where ride_id = p_ride_id and user_id = p_user and event_type = 'sos'
    and resolved_at is null
    and created_at > now() - make_interval(secs => coalesce(v_cfg.sos_repeat_window_seconds, 120))
  order by created_at desc
  limit 1;

  if v_evt.id is not null then
    return v_evt;
  end if;

  if p_location is null and v_mon.last_location is not null then
    p_location := v_mon.last_location; -- emergency recovery: last known position
  end if;

  insert into public.safety_events (ride_id, user_id, event_type, severity, location, metadata)
  values (p_ride_id, p_user, 'sos', 'critical', p_location,
          jsonb_build_object('source', p_source, 'last_known_location', v_mon.last_location))
  returning * into v_evt;

  perform public.broadcast_covia_event(
    'covia.safety.sos',
    jsonb_build_object(
      'ride_id', p_ride_id,
      'event_id', v_evt.id,
      'user_id', p_user,
      'location', p_location
    )
  );

  if coalesce(v_cfg.notify_participants_on_sos, true) then
    if v_ride.host_id is distinct from p_user then
      perform public.record_notification(
        v_ride.host_id, 'emergency_alert', 'SOS from your ride',
        'A passenger pressed the emergency button. Check on them now.',
        jsonb_build_object('ride_id', p_ride_id, 'event_id', v_evt.id), p_user, null
      );
    end if;
    for v_recipient in
      select p.user_id
      from public.ride_participants p
      where p.ride_id = p_ride_id
        and p.role = 'Passenger'
        and p.left_at is null
        and p.user_id is distinct from p_user
    loop
      perform public.record_notification(
        v_recipient, 'emergency_alert', 'SOS from your ride',
        'A passenger pressed the emergency button. Check on them now.',
        jsonb_build_object('ride_id', p_ride_id, 'event_id', v_evt.id), p_user, null
      );
    end loop;
  end if;

  -- Out-of-app delivery queue (SMS/email/push worker drains this).
  for v_contact in
    select name, phone from public.emergency_contacts
    where user_id = p_user
  loop
    insert into public.outbound_notifications (channel, kind, recipient_name, recipient_phone, payload)
    values (
      'sms', 'sos_alert', v_contact.name, v_contact.phone,
      jsonb_build_object(
        'ride_id', p_ride_id,
        'event_id', v_evt.id,
        'user_id', p_user,
        'location', p_location,
        'message', 'Covia SOS: ' || coalesce(nullif(v_user_name, ''), 'Someone') || ' needs help.'
      )
    );
  end loop;

  return v_evt;
end;
$$;

-- Public one-tap entry point.
create or replace function public.trigger_sos(p_ride_id uuid, p_location jsonb default null)
returns public.safety_events
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
  perform public.assert_ride_member(p_ride_id, v_user);
  select * into v_ride from public.rides where id = p_ride_id;
  if v_ride.ride_status <> 'in_progress' then
    raise exception 'SOS is only available during an active ride';
  end if;
  return public.perform_sos(p_ride_id, v_user, p_location);
end;
$$;

-- â”€â”€ Safety check response ("I'm Safe" / "Need Help") â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- I'm Safe requires a successful device biometric/passcode unlock (the app
-- performs expo-local-authentication and passes p_biometric_confirmed);
-- a plain tap is rejected. "Need Help" escalates immediately to SOS.
create or replace function public.respond_safety_check(
  p_ride_id uuid,
  p_safe boolean,
  p_biometric_confirmed boolean default false
)
returns public.safety_events
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_mon public.ride_monitoring;
  v_check public.safety_events;
  v_evt public.safety_events;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  perform public.assert_ride_member(p_ride_id, v_user);

  select * into v_mon from public.ride_monitoring where ride_id = p_ride_id;
  if v_mon.check_event_id is null then
    raise exception 'No active safety prompt for this ride';
  end if;
  select * into v_check from public.safety_events where id = v_mon.check_event_id;
  if v_check.id is null then
    raise exception 'No active safety prompt for this ride';
  end if;
  if v_check.user_id is distinct from v_user then
    raise exception 'Only the rider can respond to this alert';
  end if;

  if p_safe then
    if not coalesce(p_biometric_confirmed, false) then
      raise exception 'Biometric confirmation is required to dismiss the alert';
    end if;

    update public.safety_events
    set resolved_at = now(), resolved_by = v_user
    where id = v_check.id;

    update public.ride_monitoring
    set check_required_at = null, check_event_id = null, stationary_since = null,
        escalated_at = null
    where ride_id = p_ride_id;

    insert into public.safety_events (ride_id, user_id, event_type, severity, location, metadata)
    values (p_ride_id, v_user, 'safety_confirmed', 'info', v_check.location,
            jsonb_build_object('check_event_id', v_check.id, 'confirmed_by_biometric', true))
    returning * into v_evt;

    perform public.broadcast_covia_event(
      'covia.safety.resolved',
      jsonb_build_object('ride_id', p_ride_id, 'event_id', v_evt.id, 'user_id', v_user,
                         'check_event_id', v_check.id)
    );
    return v_evt;
  end if;

  -- "Need Help": immediate SOS + escalation.
  v_evt := public.perform_sos(p_ride_id, v_user, v_check.location, 'safety_check_response');
  update public.ride_monitoring
  set check_required_at = null, check_event_id = null, escalated_at = now()
  where ride_id = p_ride_id;
  return v_evt;
end;
$$;

-- â”€â”€ Live location + monitoring feed â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- One upsert call does double duty: sharing (live_locations row, streamed
-- over Realtime to ride participants) and monitoring (movement, unexpected
-- stop and route-deviation detection). Sharing requires an active ride.
create or replace function public.update_live_location(p_ride_id uuid, p_location jsonb)
returns public.live_locations
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_ride public.rides;
  v_cfg public.safety_config;
  v_mon public.ride_monitoring;
  v_row public.live_locations;
  v_dist numeric;
  v_speed numeric;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  perform public.assert_ride_member(p_ride_id, v_user);

  if p_location is null
     or (p_location ->> 'lat')::numeric is null
     or (p_location ->> 'lng')::numeric is null then
    raise exception 'A valid location is required';
  end if;

  select * into v_ride from public.rides where id = p_ride_id;
  if v_ride.ride_status <> 'in_progress' then
    raise exception 'Live location is only shared during an active ride';
  end if;

  insert into public.live_locations (ride_id, user_id, location)
  values (p_ride_id, v_user, p_location)
  on conflict (ride_id, user_id)
  do update set location = excluded.location, is_active = true, updated_at = now()
  returning * into v_row;

  select * into v_cfg from public.safety_config where id = true;
  select * into v_mon from public.ride_monitoring where ride_id = p_ride_id;

  if v_mon.ride_id is null or v_mon.status = 'finished' then
    return v_row; -- nothing to monitor
  end if;

  -- Movement detection (uses the previous fix, before this one lands).
  v_speed := coalesce((p_location ->> 'speed')::numeric, -1);
  if v_speed < 0 and v_mon.last_location is not null then
    v_dist := public.haversine_m(p_location, v_mon.last_location);
    v_speed := case when v_dist >= 25 then 1 else 0 end;
  end if;

  if v_speed >= 1 then
    v_mon.stationary_since := null;
    v_mon.last_moved_at := now();
  elsif v_mon.stationary_since is null then
    v_mon.stationary_since := now();
  end if;

  update public.ride_monitoring
  set last_location = p_location,
      last_location_at = now(),
      stationary_since = v_mon.stationary_since,
      last_moved_at = v_mon.last_moved_at
  where ride_id = p_ride_id;

  if v_mon.status = 'suspended' then
    return v_row; -- detection paused (sharing continues)
  end if;

  -- Unexpected stop detection.
  if v_mon.stationary_since is not null
     and v_mon.stationary_since + make_interval(secs => coalesce(v_cfg.stop_threshold_seconds, 120)) <= now()
     and v_mon.check_required_at is null then
    perform public.perform_safety_check(
      p_ride_id, v_user, 'long_stop', p_location,
      jsonb_build_object('stationary_since', v_mon.stationary_since)
    );
  end if;

  -- Route deviation detection (minimum distance to the planned polyline).
  if v_mon.check_required_at is null
     and jsonb_array_length(coalesce(v_mon.planned_route, '[]'::jsonb)) >= 2 then
    v_dist := public.distance_to_route_m(p_location, v_mon.planned_route);
    if v_dist is not null
       and v_dist > coalesce(v_cfg.route_deviation_meters, 500) then
      perform public.perform_safety_check(
        p_ride_id, v_user, 'route_deviation', p_location,
        jsonb_build_object('distance_from_route_meters', v_dist)
      );
    end if;
  end if;

  return v_row;
end;
$$;

create or replace function public.stop_live_location(p_ride_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  perform public.assert_ride_member(p_ride_id, v_user);
  delete from public.live_locations where ride_id = p_ride_id and user_id = v_user;
end;
$$;

-- â”€â”€ Route + monitoring controls â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
create or replace function public.set_planned_route(p_ride_id uuid, p_points jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_i integer;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.rides where id = p_ride_id and host_id = v_user) then
    raise exception 'Only the host can set the planned route';
  end if;
  if p_points is null or jsonb_typeof(p_points) <> 'array' or jsonb_array_length(p_points) < 2 then
    raise exception 'A planned route needs at least two points';
  end if;
  for v_i in 0 .. jsonb_array_length(p_points) - 1 loop
    if (p_points -> v_i ->> 'lat')::numeric is null
       or (p_points -> v_i ->> 'lng')::numeric is null then
      raise exception 'Route points need lat/lng coordinates';
    end if;
  end loop;

  insert into public.ride_monitoring (ride_id, planned_route)
  values (p_ride_id, p_points)
  on conflict (ride_id)
  do update set planned_route = excluded.planned_route;
end;
$$;

create or replace function public.suspend_ride_monitoring(p_ride_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.rides where id = p_ride_id and host_id = v_user) then
    raise exception 'Only the host can control ride monitoring';
  end if;
  update public.ride_monitoring
  set status = 'suspended'
  where ride_id = p_ride_id and status = 'active';
  if not found then
    raise exception 'No active monitoring for this ride';
  end if;
end;
$$;

create or replace function public.resume_ride_monitoring(p_ride_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.rides where id = p_ride_id and host_id = v_user) then
    raise exception 'Only the host can control ride monitoring';
  end if;
  update public.ride_monitoring
  set status = 'active'
  where ride_id = p_ride_id and status = 'suspended';
  if not found then
    raise exception 'Monitoring is not suspended';
  end if;
end;
$$;

-- â”€â”€ Manual incident reporting â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
create or replace function public.report_safety_incident(p_ride_id uuid, p_note text)
returns public.safety_events
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_evt public.safety_events;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  perform public.assert_ride_member(p_ride_id, v_user);
  if nullif(btrim(coalesce(p_note, '')), '') is null then
    raise exception 'A note is required';
  end if;

  insert into public.safety_events (ride_id, user_id, event_type, severity, metadata)
  values (p_ride_id, v_user, 'manual_report', 'info',
          jsonb_build_object('note', btrim(p_note)))
  returning * into v_evt;

  perform public.broadcast_covia_event(
    'covia.safety.incident',
    jsonb_build_object('ride_id', p_ride_id, 'event_id', v_evt.id, 'user_id', v_user)
  );
  return v_evt;
end;
$$;

-- â”€â”€ Monitoring engine (escalation + never-started + duration + cleanup) â”€â”€â”€â”€
-- Runs every minute via pg_cron (guarded) and can be invoked on demand.
create or replace function public.run_safety_monitor()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actions integer := 0;
  v_cfg public.safety_config;
  v_mon record;
  v_evt public.safety_events;
  v_recipient uuid;
  v_contact record;
  v_cleaned integer;
begin
  select * into v_cfg from public.safety_config where id = true;

  -- 1. Escalate safety prompts that timed out without a response.
  for v_mon in
    select m.ride_id, m.check_event_id
    from public.ride_monitoring m
    join public.rides r on r.id = m.ride_id
    where m.status = 'active'
      and m.check_required_at is not null
      and m.check_required_at + make_interval(secs => coalesce(v_cfg.safety_check_timeout_seconds, 60)) <= now()
      and not exists (
        select 1 from public.safety_events e
        where e.ride_id = m.ride_id and e.event_type = 'emergency_escalation'
      )
  loop
    insert into public.safety_events (ride_id, user_id, event_type, severity, location, metadata)
    select m.ride_id,
           coalesce(c.user_id, r.host_id),
           'emergency_escalation', 'critical', c.location,
           jsonb_build_object('check_event_id', m.check_event_id,
                              'timeout_seconds', v_cfg.safety_check_timeout_seconds,
                              'last_known_location', m.last_location)
    from public.ride_monitoring m
    join public.rides r on r.id = m.ride_id
    left join public.safety_events c on c.id = m.check_event_id
    where m.ride_id = v_mon.ride_id
    returning * into v_evt;

    update public.ride_monitoring
    set escalated_at = now(), check_required_at = null, check_event_id = null
    where ride_id = v_mon.ride_id;

    perform public.broadcast_covia_event(
      'covia.safety.escalated',
      jsonb_build_object('ride_id', v_evt.ride_id, 'event_id', v_evt.id,
                         'user_id', v_evt.user_id, 'location', v_evt.location)
    );

    if coalesce(v_cfg.notify_participants_on_sos, true) then
      for v_recipient in
        select r.host_id as user_id
        from public.rides r where r.id = v_evt.ride_id
        union
        select p.user_id from public.ride_participants p
        where p.ride_id = v_evt.ride_id and p.role = 'Passenger' and p.left_at is null
      loop
        if v_recipient is distinct from v_evt.user_id then
          perform public.record_notification(
            v_recipient, 'emergency_alert', 'Safety escalation',
            'A rider did not respond to a safety check. Please check on them.',
            jsonb_build_object('ride_id', v_evt.ride_id, 'event_id', v_evt.id),
            v_evt.user_id, null
          );
        end if;
      end loop;
    end if;

    for v_contact in
      select name, phone from public.emergency_contacts
      where user_id = v_evt.user_id
    loop
      insert into public.outbound_notifications (channel, kind, recipient_name, recipient_phone, payload)
      values (
        'sms', 'escalation_alert', v_contact.name, v_contact.phone,
        jsonb_build_object(
          'ride_id', v_evt.ride_id,
          'event_id', v_evt.id,
          'user_id', v_evt.user_id,
          'location', v_evt.location,
          'message', 'Covia safety escalation: no response to a safety check.'
        )
      );
    end loop;

    v_actions := v_actions + 1;
  end loop;

  -- 2. Rides that never started on time.
  for v_mon in
    select r.id, r.host_id
    from public.rides r
    where r.ride_status = 'published'
      and r.departure_time + make_interval(mins => coalesce(v_cfg.never_started_minutes, 15)) <= now()
      and not exists (select 1 from public.ride_timeline t
                      where t.ride_id = r.id and t.event_type = 'started')
      and not exists (select 1 from public.safety_events e
                      where e.ride_id = r.id and e.event_type = 'ride_never_started')
  loop
    insert into public.safety_events (ride_id, user_id, event_type, severity, location, metadata)
    values (v_mon.id, v_mon.host_id, 'ride_never_started', 'warning', null, '{}'::jsonb)
    returning * into v_evt;

    perform public.broadcast_covia_event(
      'covia.safety.ride_never_started',
      jsonb_build_object('ride_id', v_mon.id, 'event_id', v_evt.id)
    );
    perform public.record_notification(
      v_mon.host_id, 'safety_check', 'Your ride never started',
      'Covia noticed your ride did not start on time.',
      jsonb_build_object('ride_id', v_mon.id, 'event_id', v_evt.id), null, null
    );
    v_actions := v_actions + 1;
  end loop;

  -- 3. Rides exceeding the expected duration.
  for v_mon in
    select m.ride_id, r.host_id, r.departure_time
    from public.ride_monitoring m
    join public.rides r on r.id = m.ride_id
    where m.status = 'active' and r.ride_status = 'in_progress'
      and r.departure_time + make_interval(mins => coalesce(v_cfg.exceeded_duration_minutes, 45)) <= now()
      and not exists (select 1 from public.safety_events e
                      where e.ride_id = m.ride_id and e.event_type = 'ride_duration_exceeded')
  loop
    insert into public.safety_events (ride_id, user_id, event_type, severity, location, metadata)
    values (v_mon.ride_id, v_mon.host_id, 'ride_duration_exceeded', 'warning',
            (select last_location from public.ride_monitoring where ride_id = v_mon.ride_id),
            jsonb_build_object('expected_end', v_mon.departure_time + make_interval(mins => coalesce(v_cfg.exceeded_duration_minutes, 45))))
    returning * into v_evt;

    perform public.broadcast_covia_event(
      'covia.safety.ride_duration_exceeded',
      jsonb_build_object('ride_id', v_mon.ride_id, 'event_id', v_evt.id)
    );
    perform public.record_notification(
      v_mon.host_id, 'safety_check', 'Your ride is taking longer than expected',
      'Covia noticed your ride exceeded its expected duration.',
      jsonb_build_object('ride_id', v_mon.ride_id, 'event_id', v_evt.id), null, null
    );
    v_actions := v_actions + 1;
  end loop;

  -- 4. Safety net: finish monitoring + stop live sharing for rides that are
  --    no longer active (covers cancelled/expired paths and pre-start rows).
  for v_mon in
    select m.ride_id
    from public.ride_monitoring m
    join public.rides r on r.id = m.ride_id
    where m.status <> 'finished' and r.ride_status not in ('in_progress')
  loop
    update public.ride_monitoring
    set status = 'finished', finished_at = now(), check_required_at = null, check_event_id = null
    where ride_id = v_mon.ride_id;
    delete from public.live_locations where ride_id = v_mon.ride_id;
    v_actions := v_actions + 1;
  end loop;

  -- 5. Retain finished-ride locations only within the configured window.
  delete from public.live_locations ll
  using public.ride_monitoring m
  where m.ride_id = ll.ride_id and m.status = 'finished'
    and ll.updated_at < now() - make_interval(hours => coalesce(v_cfg.live_location_retention_hours, 24));
  get diagnostics v_cleaned = row_count;
  v_actions := v_actions + v_cleaned;

  return v_actions;
end;
$$;

-- â”€â”€ Ride lifecycle hook â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Started â†’ monitoring begins. Completed / cancelled / expired â†’ monitoring
-- finishes and live sharing stops immediately (never retained beyond need).
create or replace function public.sync_safety_from_ride_timeline()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    case new.event_type
      when 'started' then
        insert into public.ride_monitoring (ride_id, status, started_at)
        values (new.ride_id, 'active', new.created_at)
        on conflict (ride_id)
        do update set status = 'active', started_at = new.created_at, finished_at = null;

      when 'completed', 'cancelled', 'expired' then
        update public.ride_monitoring
        set status = 'finished', finished_at = now(), check_required_at = null, check_event_id = null
        where ride_id = new.ride_id;
        delete from public.live_locations where ride_id = new.ride_id;

      else
        null;
    end case;
  exception when others then
    null; -- never fail the ride operation
  end;

  return new;
end;
$$;

drop trigger if exists sync_safety_from_ride_timeline on public.ride_timeline;
create trigger sync_safety_from_ride_timeline
  after insert on public.ride_timeline
  for each row execute function public.sync_safety_from_ride_timeline();

-- â”€â”€ Scheduled monitor (guarded: no-op on plain Postgres) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'covia-safety-monitor') then
      perform cron.schedule('covia-safety-monitor', '* * * * *', 'select public.run_safety_monitor()');
    end if;
  end if;
end $$;

-- â”€â”€ Grants â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
revoke all on function public.assert_ride_member(uuid, uuid) from public;
revoke all on function public.is_valid_phone(text) from public;
revoke all on function public.haversine_m(jsonb, jsonb) from public;
revoke all on function public.point_segment_distance_m(jsonb, jsonb, jsonb) from public;
revoke all on function public.distance_to_route_m(jsonb, jsonb) from public;
revoke all on function public.perform_safety_check(uuid, uuid, text, jsonb, jsonb) from public;
revoke all on function public.perform_sos(uuid, uuid, jsonb, text) from public;
revoke all on function public.run_safety_monitor() from public;
revoke all on function public.update_safety_config(numeric, integer, integer, integer, integer, boolean, integer, integer) from public;
revoke all on function public.sync_safety_from_ride_timeline() from public;

revoke all on function public.get_safety_config() from public;
revoke all on function public.get_emergency_contacts() from public;
revoke all on function public.add_emergency_contact(text, text, text, boolean) from public;
revoke all on function public.update_emergency_contact(uuid, text, text, text, boolean) from public;
revoke all on function public.delete_emergency_contact(uuid) from public;
revoke all on function public.trigger_sos(uuid, jsonb) from public;
revoke all on function public.respond_safety_check(uuid, boolean, boolean) from public;
revoke all on function public.update_live_location(uuid, jsonb) from public;
revoke all on function public.stop_live_location(uuid) from public;
revoke all on function public.set_planned_route(uuid, jsonb) from public;
revoke all on function public.suspend_ride_monitoring(uuid) from public;
revoke all on function public.resume_ride_monitoring(uuid) from public;
revoke all on function public.report_safety_incident(uuid, text) from public;

grant execute on function public.get_safety_config() to authenticated;
grant execute on function public.get_emergency_contacts() to authenticated;
grant execute on function public.add_emergency_contact(text, text, text, boolean) to authenticated;
grant execute on function public.update_emergency_contact(uuid, text, text, text, boolean) to authenticated;
grant execute on function public.delete_emergency_contact(uuid) to authenticated;
grant execute on function public.trigger_sos(uuid, jsonb) to authenticated;
grant execute on function public.respond_safety_check(uuid, boolean, boolean) to authenticated;
grant execute on function public.update_live_location(uuid, jsonb) to authenticated;
grant execute on function public.stop_live_location(uuid) to authenticated;
grant execute on function public.set_planned_route(uuid, jsonb) to authenticated;
grant execute on function public.suspend_ride_monitoring(uuid) to authenticated;
grant execute on function public.resume_ride_monitoring(uuid) to authenticated;
grant execute on function public.report_safety_incident(uuid, text) to authenticated;
