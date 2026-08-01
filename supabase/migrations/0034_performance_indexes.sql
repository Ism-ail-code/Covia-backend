-- Covia - Phase 10: performance optimization
-- ------------------------------------------------------------------
-- Targeted indexes for the Phase 10 admin surfaces and the hottest
-- reads: user search (name/email), ride search + status filters,
-- moderation/report/appeal queues, notification inbox, outbound
-- delivery, and the analytics aggregations.
--
-- Trigram GIN indexes (pg_trgm) accelerate ILIKE '%term%' searches on
-- the admin user/ride search. The extension is attempted first and
-- skipped silently where it is not available (e.g. the local test
-- harness), so the migration stays portable.

-- =============================================================
-- Trigram search (guarded)
-- =============================================================
do $$ begin
  create extension if not exists pg_trgm;
exception when others then
  null;
end $$;

do $indexes$ begin
  if exists (select 1 from pg_extension where extname = 'pg_trgm') then
    create index if not exists profiles_display_name_trgm_idx
      on public.profiles using gin (display_name gin_trgm_ops);
    create index if not exists rides_origin_trgm_idx
      on public.rides using gin (origin gin_trgm_ops);
    create index if not exists rides_destination_trgm_idx
      on public.rides using gin (destination gin_trgm_ops);
  end if;
exception when others then
  null;
end $indexes$;

-- =============================================================
-- Admin + queue indexes
-- =============================================================
create index if not exists profiles_email_idx on public.profiles (email);
create index if not exists profiles_verification_status_idx on public.profiles (verification_status);
create index if not exists profiles_created_at_idx on public.profiles (created_at desc);

create index if not exists rides_created_at_idx on public.rides (created_at desc);
create index if not exists rides_host_created_idx on public.rides (host_id, created_at desc);
create index if not exists ride_participants_ride_left_idx on public.ride_participants (ride_id, left_at);
create index if not exists ride_participants_user_created_idx on public.ride_participants (user_id, joined_at desc);

create index if not exists reports_created_at_idx on public.reports (created_at desc);
create index if not exists appeals_created_at_idx on public.appeals (created_at desc);
create index if not exists moderation_actions_created_at_idx on public.moderation_actions (created_at desc);
create index if not exists reliability_events_created_at_idx on public.reliability_events (created_at desc);
create index if not exists verification_submissions_created_at_idx on public.verification_submissions (created_at desc);
create index if not exists safety_events_created_at_idx on public.safety_events (created_at desc);
create index if not exists safety_events_open_sos_idx on public.safety_events (event_type, resolved_at)
  where event_type = 'sos';

create index if not exists notifications_created_at_idx on public.notifications (created_at desc);
create index if not exists outbound_notifications_recent_idx
  on public.outbound_notifications (created_at desc);

-- =============================================================
-- Fresh planner statistics after the DDL
-- =============================================================
analyze;
