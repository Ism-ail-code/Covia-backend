-- Covia - Phase 10: platform analytics
-- ------------------------------------------------------------------
-- admin_get_analytics() returns the four dashboard sections in one
-- call so a dashboard renders with a single round trip:
--
--   users    - totals, verification split, new/active users, daily
--              registrations, weekly cohort retention
--   rides    - totals by status, average occupancy, popular routes
--   safety   - SOS, escalations, deviations, incidents, reports
--   platform - notification delivery, database health, storage usage,
--              function (RPC) latency stats when the stats collector
--              is enabled
--
-- Gate: analytics.view.

create or replace function public.admin_get_analytics()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_users jsonb;
  v_rides jsonb;
  v_safety jsonb;
  v_platform jsonb;
  v_registrations jsonb;
  v_retention jsonb;
  v_active7 bigint;
  v_active30 bigint;
  v_status jsonb;
  v_occupancy numeric;
  v_routes jsonb;
  v_events jsonb;
  v_outbound jsonb;
  v_storage jsonb;
  v_functions jsonb;
  v_db jsonb;
  v_tables jsonb;
begin
  perform public.require_permission('analytics.view');

  -- ---------------- users ----------------
  select jsonb_build_object(
           'total_users', (select count(*) from public.profiles),
           'verified_users', (select count(*) from public.profiles where verification_status = 'Verified'),
           'government_id_verified', (select count(*) from public.profiles where is_government_id_verified),
           'student_verified', (select count(*) from public.profiles where is_student_verified),
           'banned_users', (select count(*) from public.profiles where is_banned),
           'suspended_users', (select count(*) from (
               select ma.user_id from public.moderation_actions ma
                where ma.status = 'active' and ma.action_type = 'suspension'
                group by ma.user_id
             ) s),
           'new_users_7d', (select count(*) from public.profiles where created_at >= now() - interval '7 days'),
           'active_users_7d', (select count(*) from (
               select user_id from (
                 select host_id as user_id from public.rides where created_at >= now() - interval '7 days'
                 union all select user_id from public.ride_participants where joined_at >= now() - interval '7 days'
                 union all select rater_user_id from public.ratings where created_at >= now() - interval '7 days'
                 union all select reporter_user_id from public.reports where created_at >= now() - interval '7 days'
                 union all select user_id from public.safety_events where created_at >= now() - interval '7 days'
                 union all select recipient_user_id as user_id from public.notifications where read_at >= now() - interval '7 days'
               ) act where act.user_id is not null group by act.user_id
             ) a),
           'active_users_30d', (select count(*) from (
               select user_id from (
                 select host_id as user_id from public.rides where created_at >= now() - interval '30 days'
                 union all select user_id from public.ride_participants where joined_at >= now() - interval '30 days'
                 union all select rater_user_id from public.ratings where created_at >= now() - interval '30 days'
                 union all select reporter_user_id from public.reports where created_at >= now() - interval '30 days'
                 union all select user_id from public.safety_events where created_at >= now() - interval '30 days'
                 union all select recipient_user_id as user_id from public.notifications where read_at >= now() - interval '30 days'
               ) act where act.user_id is not null group by act.user_id
             ) a)
         )
    into v_users;

  select coalesce(jsonb_agg(jsonb_build_object(
           'day', d::date,
           'registrations', coalesce(c.cnt, 0)
         ) order by d), '[]'::jsonb)
    into v_registrations
    from generate_series(now()::date - 13, now()::date, interval '1 day') d
    left join (
      select created_at::date as day, count(*) as cnt
        from public.profiles
       where created_at >= now()::date - 13
       group by created_at::date
    ) c on c.day = d::date;

  -- Weekly cohorts (last 6 signup weeks) and how many were active the
  -- following week (activity = the same signal set used above).
  select coalesce(jsonb_agg(row order by row ->> 'cohort'), '[]'::jsonb)
    into v_retention
    from (
      with weeks as (
        select generate_series(0, 5) as i
      ),
      cohorts as (
        select w.i,
               date_trunc('week', now())::date - (w.i * 7) as week_start,
               count(p.id) as size
          from weeks w
          left join public.profiles p
            on p.created_at >= (date_trunc('week', now())::date - (w.i * 7) - interval '6 days')
           and p.created_at <  (date_trunc('week', now())::date - (w.i * 7) + interval '1 day')
         group by w.i
      ),
      retained as (
        select c.i,
               count(distinct act.user_id) as active_next_week
          from cohorts c
          left join (
            select host_id as user_id, created_at as ts from public.rides
            union all select user_id, joined_at from public.ride_participants
            union all select rater_user_id, created_at from public.ratings
            union all select reporter_user_id, created_at from public.reports
            union all select user_id, created_at from public.safety_events
            union all select recipient_user_id as user_id, read_at from public.notifications where read_at is not null
          ) act
            on act.user_id in (select p2.id from public.profiles p2
                                where p2.created_at >= (date_trunc('week', now())::date - (c.i * 7) - interval '6 days')
                                  and p2.created_at <  (date_trunc('week', now())::date - (c.i * 7) + interval '1 day'))
           and act.ts >= (date_trunc('week', now())::date - (c.i * 7) + interval '1 day')
           and act.ts <  (date_trunc('week', now())::date - (c.i * 7) + interval '8 days')
         group by c.i
      )
      select jsonb_build_object(
               'cohort', to_char(cohorts.week_start, 'YYYY-MM-DD'),
               'signups', cohorts.size,
               'active_next_week', coalesce(retained.active_next_week, 0),
               'retention', case when cohorts.size = 0 then 0
                                 else round((coalesce(retained.active_next_week, 0)::numeric / cohorts.size) * 100, 1)
                            end
             ) as row
        from cohorts
        left join retained on retained.i = cohorts.i
    ) sub;

  -- ---------------- rides ----------------
  select jsonb_build_object(
           'total_rides', (select count(*) from public.rides),
           'published_rides', (select count(*) from public.rides where ride_status in ('published', 'full')),
           'in_progress_rides', (select count(*) from public.rides where ride_status = 'in_progress'),
           'completed_rides', (select count(*) from public.rides where ride_status = 'completed'),
           'cancelled_rides', (select count(*) from public.rides where ride_status = 'cancelled'),
           'expired_rides', (select count(*) from public.rides where ride_status = 'expired'),
           'average_occupancy', (select round(
               avg(
                 (select count(*) from public.ride_participants rp
                   where rp.ride_id = r.id and rp.left_at is null)::numeric - 1
               ) / nullif(avg(r.total_seats), 0), 3)
             from public.rides r where r.ride_status = 'completed'),
           'rides_7d', (select count(*) from public.rides where created_at >= now() - interval '7 days')
         )
    into v_rides;

  select coalesce(jsonb_agg(jsonb_build_object(
           'origin', origin, 'destination', destination,
           'rides', cnt
         )), '[]'::jsonb)
    into v_routes
    from (
      select origin, destination, count(*) as cnt
        from public.rides
       where ride_status = 'completed'
       group by origin, destination
       order by cnt desc
       limit 5
    ) r;

  select coalesce(jsonb_agg(jsonb_build_object(
           'event_type', event_type,
           'count', cnt
         )), '[]'::jsonb)
    into v_events
    from (
      select event_type, count(*) as cnt
        from public.safety_events
       group by event_type
    ) e;

  select jsonb_build_object(
           'safety_events', (select count(*) from public.safety_events),
           'reports_submitted', (select count(*) from public.reports),
           'reports_pending', (select count(*) from public.reports where status = 'pending'),
           'reports_resolved', (select count(*) from public.reports where status = 'resolved'),
           'by_event_type', v_events
         )
    into v_safety;

  -- ---------------- platform ----------------
  -- Database health.
  select jsonb_build_object(
           'database_size_mb', round(pg_database_size(current_database())::numeric / 1048576, 1),
           'active_connections', (select count(*) from pg_stat_activity where datname = current_database()),
           'cache_hit_ratio', round(
             (select sum(blks_hit)::numeric / nullif(sum(blks_hit) + sum(blks_read), 0) * 100
                from pg_stat_database where datname = current_database()), 1),
           'transaction_commit_rate', round(
             (select sum(xact_commit)::numeric / nullif(sum(xact_commit) + sum(xact_rollback), 0) * 100
                from pg_stat_database where datname = current_database()), 1)
         )
    into v_db;

  -- Storage usage per bucket. The size column exists on Supabase; the
  -- test harness stubs a minimal objects table, so probe for it. The
  -- branch must be chosen BEFORE planning, so two queries (one per
  -- shape) run via dynamic SQL.
  if exists (
    select 1 from information_schema.columns
     where table_schema = 'storage' and table_name = 'objects'
       and column_name = 'size'
  ) then
    execute '
      select coalesce(jsonb_agg(jsonb_build_object(
               ''bucket'', s.bucket_id,
               ''objects'', obj_cnt,
               ''bytes'', bytes
             )), ''[]''::jsonb)
        from (
          select s.bucket_id,
                 count(*) as obj_cnt,
                 coalesce(sum(s.size), 0) as bytes
            from storage.objects s
           group by s.bucket_id
        ) s'
      into v_storage;
  else
    execute '
      select coalesce(jsonb_agg(jsonb_build_object(
               ''bucket'', s.bucket_id,
               ''objects'', obj_cnt,
               ''bytes'', null
             )), ''[]''::jsonb)
        from (
          select s.bucket_id,
                 count(*) as obj_cnt
            from storage.objects s
           group by s.bucket_id
        ) s'
      into v_storage;
  end if;

  -- RPC latency from pg_stat_user_functions (pg_stat_statements).
  -- Absent in the test harness -> null without failing the call.
  begin
    execute '
      select coalesce(jsonb_agg(jsonb_build_object(
               ''name'', f.funcname,
               ''calls'', f.calls,
               ''avg_ms'', round(f.total_time / f.calls, 3)
             ) order by f.total_time desc limit 20), ''[]''::jsonb)
        from pg_stat_user_functions f'
      into v_functions;
  exception when others then
    v_functions := null;
  end;

  -- Largest tables (rows + disk) for capacity planning.
  begin
    execute '
      select coalesce(jsonb_agg(jsonb_build_object(
               ''table'', tbl,
               ''rows'', n_live_tup,
               ''size_mb'', round(pg_total_relation_size(tbl)::numeric / 1048576, 1)
             ) order by pg_total_relation_size(tbl) desc limit 10), ''[]''::jsonb)
        from (
          select schemaname || ''.'' || relname as tbl, n_live_tup
            from pg_stat_user_tables
        ) t'
      into v_tables;
  exception when others then
    v_tables := null;
  end;

  select jsonb_build_object(
           'notifications_sent', (select count(*) from public.notifications),
           'notifications_unread', (select count(*) from public.notifications where read_at is null),
           'push_tokens', (select count(*) from public.push_tokens),
           'outbound_by_status', (select coalesce(jsonb_object_agg(st, cnt), '{}'::jsonb)
             from (select case when sent_at is null then 'queued' else 'sent' end as st, count(*) as cnt
                     from public.outbound_notifications group by 1) o),
           'pending_outbound', (select count(*) from public.outbound_notifications where sent_at is null),
           'database', v_db,
           'storage', v_storage,
           'rpc_latency', v_functions,
           'largest_tables', v_tables
         )
    into v_platform;

  return jsonb_build_object(
    'users', jsonb_build_object(
      'overview', v_users,
      'daily_registrations', v_registrations,
      'weekly_retention', v_retention
    ),
    'rides', jsonb_build_object(
      'overview', v_rides,
      'popular_routes', v_routes
    ),
    'safety', v_safety,
    'platform', v_platform
  );
end;
$$;

revoke all on function public.admin_get_analytics() from public;
grant execute on function public.admin_get_analytics() to authenticated;
