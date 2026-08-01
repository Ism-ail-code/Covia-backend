-- ============================================================================
-- 0021 â€” Phase 8: Safety â€” emergency contacts, safety events, live locations,
-- monitoring records and the outbound notification queue.
--
-- Design notes:
--   1. Every user owns their emergency contacts (owner-only RLS; mutations
--      go through the safety service in 0022 for validation).
--   2. `safety_events` is the immutable audit log: SOS presses, detections,
--      check-ins, manual reports and escalations all land here with a
--      severity, location and payload.
--   3. `live_locations` holds ONE row per (ride, user) â€” continuous upserts
--      while the ride is in progress. Rows are deleted when the ride ends
--      (trigger) or when they go stale (maintenance) â€” nothing is retained
--      longer than necessary.
--   4. `ride_monitoring` tracks per-ride monitoring state (active /
--      suspended / finished), the planned route, last known location and
--      the open safety check (escalation timer).
--   5. `safety_config` is a single-row configuration table so thresholds
--      (deviation distance, stop duration, escalation timeout, ...) can be
--      tuned after launch without touching application code.
--   6. `outbound_notifications` is a provider-agnostic queue (SMS/email/push)
--      drained by a future worker; SOS/escalation enqueue one row per
--      emergency contact. No client role can touch it.
-- ============================================================================

-- â”€â”€ Safety configuration (single row, server-managed) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
create table if not exists public.safety_config (
  id boolean primary key default true check (id),   -- single-row table
  route_deviation_meters numeric(10, 2) not null default 500,
  stop_threshold_seconds integer not null default 120,
  safety_check_timeout_seconds integer not null default 60,
  never_started_minutes integer not null default 15,
  exceeded_duration_minutes integer not null default 45,
  notify_participants_on_sos boolean not null default true,
  sos_repeat_window_seconds integer not null default 120,
  live_location_retention_hours integer not null default 24,
  updated_at timestamptz not null default now()
);

insert into public.safety_config (id) values (true)
on conflict (id) do nothing;

comment on table public.safety_config is
  'Global safety thresholds (single row). Mutations are server-only via update_safety_config in 0022.';

-- â”€â”€ Emergency contacts â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
create table if not exists public.emergency_contacts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  name text not null check (btrim(name) <> ''),
  phone text not null check (
    btrim(phone) <> '' and phone ~ '^\+?[0-9()\-\. ]{7,20}$'
  ),
  relationship text not null check (btrim(relationship) <> ''),
  is_primary boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.emergency_contacts is
  'A user''s emergency contacts. One primary contact per user (partial unique index).';

create unique index if not exists emergency_contacts_one_primary_idx
  on public.emergency_contacts (user_id) where is_primary;

-- â”€â”€ Safety events (audit log) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
create table if not exists public.safety_events (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid references public.rides (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  event_type text not null check (event_type in (
    'sos',
    'route_deviation',
    'long_stop',
    'safety_check',
    'safety_confirmed',
    'manual_report',
    'emergency_escalation',
    'ride_never_started',
    'ride_duration_exceeded'
  )),
  severity text not null default 'info' check (severity in ('info', 'warning', 'critical')),
  location jsonb,                         -- {lat, lng, accuracy, ...} at the time of the event
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolved_by uuid references auth.users (id) on delete set null
);

comment on table public.safety_events is
  'Immutable safety audit log. Created only by the security-definer safety service (0022).';

create index if not exists safety_events_ride_idx
  on public.safety_events (ride_id, created_at desc);

create index if not exists safety_events_user_idx
  on public.safety_events (user_id, created_at desc);

create index if not exists safety_events_open_check_idx
  on public.safety_events (ride_id) where event_type = 'safety_check' and resolved_at is null;

-- â”€â”€ Live locations (sharing during an active ride) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
create table if not exists public.live_locations (
  ride_id uuid not null references public.rides (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  location jsonb not null,                -- {lat, lng, accuracy, speed, heading, recorded_at}
  is_active boolean not null default true,
  shared_since timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (ride_id, user_id)
);

comment on table public.live_locations is
  'One row per sharing participant per ride. Upserted while the ride is in progress; removed when the ride ends or sharing stops.';

create index if not exists live_locations_active_idx
  on public.live_locations (ride_id) where is_active;

-- â”€â”€ Ride monitoring (safety state machine) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
create table if not exists public.ride_monitoring (
  ride_id uuid primary key references public.rides (id) on delete cascade,
  status text not null default 'active' check (status in ('active', 'suspended', 'finished')),
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  planned_route jsonb,                    -- [{lat, lng}, ...] expected route polyline
  last_location jsonb,                    -- last known location (emergency recovery)
  last_location_at timestamptz,
  last_moved_at timestamptz,
  stationary_since timestamptz,           -- when the ride last stopped moving
  check_required_at timestamptz,          -- open "Are you safe?" prompt
  check_event_id uuid references public.safety_events (id) on delete set null,
  escalated_at timestamptz
);

comment on table public.ride_monitoring is
  'Per-ride safety monitoring state machine (active / suspended / finished) plus route + last known location.';

-- â”€â”€ Outbound notification queue (SMS/email/push provider placeholder) â”€â”€â”€â”€â”€â”€
create table if not exists public.outbound_notifications (
  id uuid primary key default gen_random_uuid(),
  channel text not null default 'sms' check (channel in ('sms', 'email', 'push')),
  kind text not null check (kind in ('sos_alert', 'escalation_alert')),
  recipient_name text not null,
  recipient_phone text not null,
  payload jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  sent_at timestamptz                     -- set by the future delivery worker
);

comment on table public.outbound_notifications is
  'Provider-agnostic outbound notification queue (SMS/email/push). No client role may read or write it; a future worker drains unsent rows.';

create index if not exists outbound_notifications_pending_idx
  on public.outbound_notifications (created_at) where sent_at is null;

-- â”€â”€ Membership helper (used by RLS policies and RPCs) â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
create or replace function public.is_active_ride_member(p_ride_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.rides r
    where r.id = p_ride_id
      and (
        r.host_id = p_user_id
        or exists (
          select 1
          from public.ride_participants p
          where p.ride_id = r.id
            and p.user_id = p_user_id
            and p.role = 'Passenger'
            and p.left_at is null
        )
      )
  );
$$;

revoke all on function public.is_active_ride_member(uuid, uuid) from public;
grant execute on function public.is_active_ride_member(uuid, uuid) to authenticated;

-- â”€â”€ Row Level Security â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- SELECT-only for safety data (realtime subscriptions + reads run under
-- RLS); every mutation goes through the security-definer service in 0022.
alter table public.emergency_contacts enable row level security;
alter table public.safety_events enable row level security;
alter table public.live_locations enable row level security;
alter table public.ride_monitoring enable row level security;
alter table public.safety_config enable row level security;
alter table public.outbound_notifications enable row level security;

drop policy if exists "emergency contacts visible to owner" on public.emergency_contacts;
create policy "emergency contacts visible to owner"
  on public.emergency_contacts for select
  to authenticated
  using (user_id = auth.uid());

drop policy if exists "safety events visible to members and owner" on public.safety_events;
create policy "safety events visible to members and owner"
  on public.safety_events for select
  to authenticated
  using (
    user_id = auth.uid()
    or (ride_id is not null and public.is_active_ride_member(ride_id, auth.uid()))
  );

drop policy if exists "live locations visible to ride members" on public.live_locations;
create policy "live locations visible to ride members"
  on public.live_locations for select
  to authenticated
  using (public.is_active_ride_member(ride_id, auth.uid()));

drop policy if exists "monitoring visible to ride members" on public.ride_monitoring;
create policy "monitoring visible to ride members"
  on public.ride_monitoring for select
  to authenticated
  using (public.is_active_ride_member(ride_id, auth.uid()));

drop policy if exists "safety config readable" on public.safety_config;
create policy "safety config readable"
  on public.safety_config for select
  to authenticated
  using (true);

revoke all on public.emergency_contacts from public;
revoke all on public.safety_events from public;
revoke all on public.live_locations from public;
revoke all on public.ride_monitoring from public;
revoke all on public.safety_config from public;
revoke all on public.outbound_notifications from public;

grant select on public.emergency_contacts to authenticated;
grant select on public.safety_events to authenticated;
grant select on public.live_locations to authenticated;
grant select on public.ride_monitoring to authenticated;
grant select on public.safety_config to authenticated;

-- â”€â”€ Supabase Realtime â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
-- Live locations stream to ride participants (postgres_changes under RLS);
-- safety events stream so the app can react instantly to SOS / prompts.
-- Guarded: no-op on plain Postgres.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'live_locations'
    ) then
      alter publication supabase_realtime
        add table public.live_locations, public.safety_events;
    end if;
  end if;
end $$;
