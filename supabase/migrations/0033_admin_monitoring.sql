-- Covia - Phase 10: monitoring, health checks + operational config
-- ------------------------------------------------------------------
-- monitoring_events is the structured log for backend subsystems
-- (safety monitor, outbound delivery, scheduled jobs). It is
-- append-only and invisible to clients; the delivery/scheduler side
-- (edge functions or pg_cron) writes through record_monitoring_event().
--
-- get_platform_health() is the ops dashboard probe: connectivity,
-- outbound queue health, open emergencies, error counts, storage and
-- database basics. admin_update_safety_config() gives admins the
-- server-side config knobs with a permission gate and audit trail.

-- =============================================================
-- Structured log
-- =============================================================
create table if not exists public.monitoring_events (
  id uuid primary key default gen_random_uuid(),
  source text not null check (char_length(source) between 1 and 60),
  level text not null check (level in ('info', 'warn', 'error', 'critical')),
  message text not null check (char_length(message) between 1 and 500),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists monitoring_events_level_idx
  on public.monitoring_events (level, created_at desc);
create index if not exists monitoring_events_source_idx
  on public.monitoring_events (source, created_at desc);

alter table public.monitoring_events enable row level security;

drop policy if exists "admins read monitoring events" on public.monitoring_events;
create policy "admins read monitoring events"
  on public.monitoring_events
  for select
  to authenticated
  using (public.has_permission('monitor.view'));

revoke all on public.monitoring_events from public;
revoke all on table public.monitoring_events from anon, authenticated;

-- Server-only writer (edge functions / pg_cron / internal jobs).
create or replace function public.record_monitoring_event(
  p_source text,
  p_level text,
  p_message text,
  p_details jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if p_level not in ('info', 'warn', 'error', 'critical') then
    raise exception 'Unknown log level: %', p_level;
  end if;
  if p_source is null or char_length(p_source) = 0 then
    raise exception 'A log source is required';
  end if;
  if p_message is null or char_length(p_message) = 0 then
    raise exception 'A log message is required';
  end if;
  insert into public.monitoring_events (source, level, message, details)
  values (p_source, p_level, p_message, coalesce(p_details, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.admin_list_monitoring_events(
  p_level text default null,
  p_source text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns table (
  id uuid,
  source text,
  level text,
  message text,
  details jsonb,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 200);
  v_page integer := greatest(p_page, 1);
begin
  perform public.require_permission('monitor.view');
  if p_level is not null and p_level not in ('info', 'warn', 'error', 'critical') then
    raise exception 'Unknown log level: %', p_level;
  end if;

  return query
    select e.id, e.source, e.level, e.message, e.details, e.created_at,
           count(*) over ()::bigint
      from public.monitoring_events e
     where (p_level is null or e.level = p_level)
       and (p_source is null or e.source = p_source)
     order by e.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

-- =============================================================
-- Health probe
-- =============================================================
create or replace function public.get_platform_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_checks jsonb;
  v_status text;
  v_pending bigint;
  v_errors bigint;
  v_open_sos bigint;
begin
  perform public.require_permission('monitor.view');

  select count(*) into v_pending
    from public.outbound_notifications where sent_at is null;

  select count(*) into v_errors
    from public.monitoring_events
   where level in ('error', 'critical') and created_at >= now() - interval '24 hours';

  select count(*) into v_open_sos
    from public.safety_events
   where event_type = 'sos' and resolved_at is null;

  v_status := 'ok';
  if v_pending > 50 or v_open_sos > 0 or v_errors > 0 then
    v_status := 'degraded';
  end if;

  select jsonb_agg(jsonb_build_object(
           'name', name, 'ok', ok, 'detail', detail
         ) order by name)
    into v_checks
    from (
      select 'database_connectivity' as name,
             pg_is_in_recovery() = false as ok,
             case when pg_is_in_recovery() then 'database is in recovery' else 'writable' end as detail
      union all select 'database_connections', conns.ok, conns.detail from (
        select (select count(*) from pg_stat_activity where datname = current_database())
                 < (select current_setting('max_connections')::int) as ok,
               (select count(*) from pg_stat_activity where datname = current_database())
                 || ' / ' || current_setting('max_connections') as detail
      ) conns
      union all select 'outbound_delivery_queue', (v_pending <= 50), v_pending || ' pending'
      union all select 'monitoring_errors_24h', (v_errors = 0), v_errors || ' errors in 24h'
      union all select 'open_emergencies', (v_open_sos = 0), v_open_sos || ' unresolved SOS'
      union all select 'storage_buckets',
             (select count(*) from storage.buckets) > 0,
             (select count(*) from storage.buckets) || ' buckets'
    ) checks;

  return jsonb_build_object(
    'status', v_status,
    'checked_at', now(),
    'checks', v_checks,
    'database_size_mb', round(pg_database_size(current_database())::numeric / 1048576, 1)
  );
end;
$$;

-- =============================================================
-- Operational config (admin wrapper over safety_config)
-- =============================================================
create or replace function public.admin_update_safety_config(
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
  v_old public.safety_config;
  v_cfg public.safety_config;
begin
  perform public.require_permission('config.manage');

  select * into v_old from public.safety_config where id = true;

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

  perform public.record_audit(
    'config.safety_update', 'safety_config', null,
    jsonb_build_object(
      'route_deviation_meters', v_old.route_deviation_meters,
      'stop_threshold_seconds', v_old.stop_threshold_seconds,
      'safety_check_timeout_seconds', v_old.safety_check_timeout_seconds,
      'never_started_minutes', v_old.never_started_minutes,
      'exceeded_duration_minutes', v_old.exceeded_duration_minutes,
      'notify_participants_on_sos', v_old.notify_participants_on_sos,
      'sos_repeat_window_seconds', v_old.sos_repeat_window_seconds,
      'live_location_retention_hours', v_old.live_location_retention_hours
    ),
    jsonb_build_object(
      'route_deviation_meters', v_cfg.route_deviation_meters,
      'stop_threshold_seconds', v_cfg.stop_threshold_seconds,
      'safety_check_timeout_seconds', v_cfg.safety_check_timeout_seconds,
      'never_started_minutes', v_cfg.never_started_minutes,
      'exceeded_duration_minutes', v_cfg.exceeded_duration_minutes,
      'notify_participants_on_sos', v_cfg.notify_participants_on_sos,
      'sos_repeat_window_seconds', v_cfg.sos_repeat_window_seconds,
      'live_location_retention_hours', v_cfg.live_location_retention_hours
    )
  );

  return v_cfg;
end;
$$;

-- =============================================================
-- Grants
-- =============================================================
revoke all on function
  public.record_monitoring_event, public.admin_list_monitoring_events,
  public.get_platform_health, public.admin_update_safety_config
  from public;

-- record_monitoring_event is server-only; the health surface is admin-only.
grant execute on function
  public.admin_list_monitoring_events(text, text, integer, integer),
  public.get_platform_health(),
  public.admin_update_safety_config(numeric, integer, integer, integer, integer, boolean, integer, integer)
  to authenticated;
