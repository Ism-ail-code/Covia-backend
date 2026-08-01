-- Covia - Phase 9: reliability scoring + automatic moderation engine
--
-- Reliability: objective behaviour signals recorded from the ride
-- timeline feed into reliability_events with configurable weights
-- (reliability_config). Score = clamp(90 + sum(weights), 0, 100) and is
-- stored on profiles.reliability_score, independent of star ratings.
--
-- Moderation: moderation_rules defines thresholds per metric. After
-- every reliability event (and after confirmed reports in 0026) the
-- engine re-evaluates the user:
--   * severity 1 -> warning (notifies the user)
--   * severity 2 -> temporary restriction (ride creation + joining
--                   blocked for the configured duration)
--   * severity 4 -> suspension (permanent until a moderator lifts it)
-- Enforcement is GRADUATED: when a rule triggers at the same severity
-- the user already sits at, the engine escalates one level instead of
-- repeating the same action. Rides/requests/ratings are gated by
-- BEFORE INSERT triggers, so no Phase 5 function needed touching.

-- =============================================================
-- Scoring
-- =============================================================
create or replace function public.recalculate_reliability_score(p_user_id uuid)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_score numeric;
begin
  select round(least(greatest(
           90 + coalesce(sum(weight), 0), 0), 100)::numeric, 1)
    into v_score
    from public.reliability_events
   where user_id = p_user_id;

  update public.profiles
     set reliability_score = v_score::int
   where id = p_user_id;

  return v_score;
end;
$$;

-- Single entry point for reliability signals (internal; no client grant).
create or replace function public.record_reliability_event(
  p_user_id uuid,
  p_event_type text,
  p_ride_id uuid default null,
  p_reason text default 'recorded'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_weight numeric;
begin
  if p_user_id is null then
    return;
  end if;

  select weight into v_weight
    from public.reliability_config
   where event_type = p_event_type and enabled = true;
  if not found then
    return; -- disabled or unknown signal: ignore
  end if;

  insert into public.reliability_events (user_id, event_type, weight, reason, ride_id)
  values (p_user_id, p_event_type, v_weight, p_reason, p_ride_id);

  perform public.recalculate_reliability_score(p_user_id);
  perform public.run_moderation_engine(p_user_id);
end;
$$;

-- =============================================================
-- Timeline integration
-- =============================================================
-- Objective signals derived from ride_timeline:
--   * completed -> every rider who stayed on the ride (host + active
--                  passengers) earns ride_completed
--   * cancelled -> the host earns ride_cancelled_by_host
--   * left      -> the leaver earns ride_cancelled_by_passenger
-- dropped (removed by host) and expired are neutral by design.
-- no_show / late_arrival have no automatic source yet; they are ready
-- for a future presence flow.
create or replace function public.reliability_from_ride_timeline()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_id uuid;
  v_rider uuid;
begin
  if new.event_type = 'completed' then
    -- Everyone still on the ride earns a completed-ride signal.
    for v_rider in
      select rp.user_id
        from public.ride_participants rp
       where rp.ride_id = new.ride_id
         and rp.left_at is null
    loop
      perform public.record_reliability_event(
        v_rider, 'ride_completed', new.ride_id, 'completed ride');
    end loop;
  elsif new.event_type = 'cancelled' then
    select host_id into v_host_id from public.rides where id = new.ride_id;
    perform public.record_reliability_event(
      v_host_id, 'ride_cancelled_by_host', new.ride_id, 'cancelled ride');
  elsif new.event_type = 'left' and new.actor_id is not null then
    perform public.record_reliability_event(
      new.actor_id, 'ride_cancelled_by_passenger', new.ride_id, 'left the ride');
  end if;
  return new;
end;
$$;

create trigger reliability_from_ride_timeline_trigger
  after insert on public.ride_timeline
  for each row execute function public.reliability_from_ride_timeline();

-- =============================================================
-- Moderation engine (graduated enforcement)
-- =============================================================
create or replace function public.user_active_moderation_severity(p_user_id uuid)
returns integer
language sql
security definer
set search_path = public
as $$
  select coalesce(max(severity), 0)::int
    from public.moderation_actions
   where user_id = p_user_id
     and status = 'active'
     and (ends_at is null or ends_at > now());
$$;

create or replace function public.metric_value(p_user_id uuid, p_metric text)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_value numeric;
begin
  case p_metric
    when 'reliability' then
      select reliability_score into v_value from public.profiles where id = p_user_id;
    when 'no_show' then
      select count(*) into v_value from public.reliability_events
       where user_id = p_user_id and event_type = 'no_show';
    when 'cancellations' then
      select count(*) into v_value from public.reliability_events
       where user_id = p_user_id
         and event_type in ('ride_cancelled_by_passenger', 'ride_cancelled_by_host');
    when 'confirmed_reports' then
      select count(*) into v_value from public.reports
       where target_user_id = p_user_id and is_confirmed = true;
    else
      return null;
  end case;
  return v_value;
end;
$$;

create or replace function public.rule_metric(p_rule_name text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when p_rule_name like 'reliability_%' then 'reliability'
    when p_rule_name like 'no_show_%' then 'no_show'
    when p_rule_name like 'cancellations_%' then 'cancellations'
    when p_rule_name like 'confirmed_reports_%' then 'confirmed_reports'
    else 'reliability'
  end;
$$;

-- Evaluate the rules and apply the strictest justified action, escalating
-- one level above the user's current state when a rule re-fires at the
-- same level (warning -> temporary restriction -> suspension).
create or replace function public.run_moderation_engine(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.moderation_rules;
  v_value numeric;
  v_active_severity integer;
  v_target_severity integer;
  v_action_type text;
  v_duration integer;
begin
  if p_user_id is null then
    return;
  end if;

  v_active_severity := public.user_active_moderation_severity(p_user_id);
  v_target_severity := 0;

  for v_rule in
    select * from public.moderation_rules
     where enabled = true
     order by severity
  loop
    v_value := public.metric_value(p_user_id, public.rule_metric(v_rule.rule_name));
    if v_value is not null and v_value >= v_rule.threshold then
      v_target_severity := greatest(v_target_severity, v_rule.severity);
    end if;
  end loop;

  if v_target_severity = 0 then
    return; -- nothing triggered
  end if;

  -- Graduated: escalate past the current level, never repeat it.
  if v_target_severity <= v_active_severity then
    v_target_severity := least(v_active_severity + 1, 4);
  end if;

  select action_type, duration_hours into v_action_type, v_duration
    from public.moderation_rules
   where severity = v_target_severity
     and enabled = true
   order by case action_type when 'suspension' then 0 else 1 end, threshold desc
   limit 1;

  if v_action_type is null then
    return;
  end if;

  insert into public.moderation_actions (
    user_id, action_type, status, reason, details, source,
    starts_at, ends_at
  ) values (
    p_user_id, v_action_type, 'active',
    'Automatic enforcement (severity ' || v_target_severity || ')',
    jsonb_build_object('triggered_severity', v_target_severity),
    'automatic', now(),
    case when v_duration is not null then now() + make_interval(hours => v_duration) else null end
  );

  -- Notify the user: warnings tell them what happened; restrictions too.
  begin
    if v_action_type = 'warning' then
      perform public.record_notification(
        p_user_id, 'warning_issued',
        'Account warning',
        'Your account has been issued a warning for behaviour that breaches our community guidelines.',
        jsonb_build_object('action_type', v_action_type)
      );
    else
      perform public.record_notification(
        p_user_id, 'account_restricted',
        'Account restriction',
        'Your account has been restricted from creating and joining rides. You can appeal this decision.',
        jsonb_build_object('action_type', v_action_type)
      );
    end if;
  exception when others then
    null; -- notifications must never break enforcement
  end;
end;
$$;

-- =============================================================
-- Ride gates (BEFORE INSERT triggers — Phase 5 functions untouched)
-- =============================================================
create or replace function public.assert_ride_creation_allowed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action text;
  v_ends timestamptz;
begin
  select action_type, ends_at into v_action, v_ends
    from public.moderation_actions
   where user_id = auth.uid()
     and status = 'active'
     and (ends_at is null or ends_at > now())
     and action_type in ('temporary_restriction', 'ride_creation_disabled', 'suspension')
   order by severity desc
   limit 1;
  if found then
    raise exception 'Your account is restricted from creating rides%', 
      case when v_ends is not null then ' until ' || to_char(v_ends, 'YYYY-MM-DD HH24:MI') else '' end;
  end if;
  return new;
end;
$$;

create trigger rides_block_restricted_creation
  before insert on public.rides
  for each row execute function public.assert_ride_creation_allowed();

create or replace function public.assert_ride_joining_allowed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action text;
  v_ends timestamptz;
begin
  select action_type, ends_at into v_action, v_ends
    from public.moderation_actions
   where user_id = auth.uid()
     and status = 'active'
     and (ends_at is null or ends_at > now())
     and action_type in ('temporary_restriction', 'ride_joining_disabled', 'suspension')
   order by severity desc
   limit 1;
  if found then
    raise exception 'Your account is restricted from joining rides%',
      case when v_ends is not null then ' until ' || to_char(v_ends, 'YYYY-MM-DD HH24:MI') else '' end;
  end if;
  return new;
end;
$$;

create trigger ride_requests_block_restricted_joining
  before insert on public.ride_requests
  for each row execute function public.assert_ride_joining_allowed();

-- Suspended users cannot submit new ratings (reporting + appeals stay
-- open — they are safety valves, not privileges).
create or replace function public.assert_not_suspended_on_ratings()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.moderation_actions
     where user_id = auth.uid()
       and status = 'active'
       and action_type = 'suspension'
  ) then
    raise exception 'Your account is suspended; you cannot rate rides right now';
  end if;
  return new;
end;
$$;

create trigger ratings_block_suspended
  before insert on public.ratings
  for each row execute function public.assert_not_suspended_on_ratings();

-- =============================================================
-- Expiry
-- =============================================================
create or replace function public.expire_moderation_actions()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer := 0;
begin
  update public.moderation_actions
     set status = 'expired'
   where status = 'active'
     and ends_at is not null
     and ends_at <= now();
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- =============================================================
-- Notification vocabulary extension (Phase 9 types)
-- =============================================================
create or replace function public.is_valid_notification_type(p_type text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_type in (
    'ride_request_received', 'ride_request_approved', 'ride_request_rejected',
    'passenger_joined', 'passenger_left', 'passenger_removed',
    'ride_updated', 'ride_cancelled', 'ride_started', 'ride_completed',
    'ride_expired',
    'verification_submitted', 'verification_approved', 'verification_rejected',
    'resubmission_requested',
    'welcome', 'password_changed', 'email_verified',
    'safety_check', 'emergency_alert', 'marketing',
    'warning_issued', 'account_restricted', 'appeal_decided', 'report_resolved'
  );
$$;

-- =============================================================
-- Grants
-- =============================================================
revoke all on function
  public.recalculate_reliability_score, public.record_reliability_event,
  public.reliability_from_ride_timeline, public.run_moderation_engine,
  public.user_active_moderation_severity, public.metric_value,
  public.rule_metric, public.assert_ride_creation_allowed,
  public.assert_ride_joining_allowed, public.assert_not_suspended_on_ratings,
  public.expire_moderation_actions, public.is_valid_notification_type
  from public;

grant execute on function public.is_valid_notification_type(text) to authenticated;
grant execute on function public.expire_moderation_actions() to authenticated;

-- =============================================================
-- Scheduler (guarded: only on databases with pg_cron, e.g. Supabase)
-- =============================================================
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'covia-expire-moderation-actions',
      '0 * * * *',
      $job$ select public.expire_moderation_actions(); $job$
    );
  end if;
end;
$$;
