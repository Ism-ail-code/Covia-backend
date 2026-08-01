-- Covia - Phase 6: notifications schema
-- ------------------------------------------------------------------
-- In-app notification infrastructure + real-time communication.
--
-- Tables:
--   * notifications            - normalized per-user notification feed
--   * notification_preferences - per-user opt-in switches
--   * push_tokens              - Expo push tokens (registration only;
--                                delivery is a later phase)
--
-- Design: a CENTRAL notification service. Other modules emit events
-- (ride_timeline rows, verification actions, account lifecycle) and the
-- service decides whether to create an in-app notification (respecting
-- the recipient's preferences) and broadcast a real-time event.
-- Failures inside the service are swallowed so they never break the
-- primary action.
--
-- Event flow for one important action (e.g. ride approved):
--   1. the primary RPC updates the ride state
--   2. it records a ride_timeline event (unchanged behaviour)
--   3. the notify_from_ride_timeline() trigger maps the event to
--      notification rows via record_notification()
--   4. record_notification() checks the recipient's preferences
--   5. the trigger broadcasts a real-time event (supabase_realtime)
--   6. the client's postgres_changes subscription on `notifications`
--      receives the new row without a refresh
--
-- Push delivery is deliberately NOT implemented here: tokens are stored
-- so a later worker (NestJS or Edge Function) can send them.

-- ── Notifications ──────────────────────────────────────────────────
create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  recipient_user_id uuid not null references auth.users (id) on delete cascade,
  actor_user_id uuid references auth.users (id) on delete set null,
  type text not null check (type in (
    -- Ride events
    'ride_request_received', 'ride_request_approved', 'ride_request_rejected',
    'passenger_joined', 'passenger_left', 'passenger_removed',
    'ride_updated', 'ride_cancelled', 'ride_started', 'ride_completed',
    'ride_expired',
    -- Verification
    'verification_submitted', 'verification_approved', 'verification_rejected',
    'resubmission_requested',
    -- Account
    'welcome', 'password_changed', 'email_verified',
    -- Safety (prepared; emitters ship in a later phase)
    'safety_check', 'emergency_alert',
    -- Marketing (disabled by default in preferences)
    'marketing'
  )),
  title text not null,
  message text not null,
  data jsonb not null default '{}'::jsonb,
  is_read boolean not null default false,
  read_at timestamptz,
  expires_at timestamptz,
  deleted_at timestamptz,
  created_at timestamptz not null default now()
);

comment on table public.notifications is
  'Per-user notification feed. Clients read via RLS (own rows, non-deleted) and receive new rows over Supabase Realtime; all writes go through the security-definer notification service.';

-- Duplicate prevention: a request-scoped event (request received /
-- approved / rejected) is emitted exactly once per request. The unique
-- index fingerprints (recipient, type, request_id) so retries cannot
-- create duplicate notifications, while a re-request (new request_id)
-- still notifies normally.
create unique index if not exists notifications_request_once
  on public.notifications (recipient_user_id, type, (data ->> 'request_id'))
  where data ? 'request_id';

create index if not exists notifications_recipient_created_idx
  on public.notifications (recipient_user_id, created_at desc);

create index if not exists notifications_unread_idx
  on public.notifications (recipient_user_id)
  where is_read = false and deleted_at is null;

create index if not exists notifications_expires_idx
  on public.notifications (expires_at)
  where expires_at is not null;

-- ── Notification preferences ───────────────────────────────────────
create table if not exists public.notification_preferences (
  user_id uuid primary key references auth.users (id) on delete cascade,
  ride_enabled boolean not null default true,
  push_enabled boolean not null default true,
  email_enabled boolean not null default false,      -- future channel
  verification_enabled boolean not null default true,
  safety_enabled boolean not null default true,
  marketing_enabled boolean not null default false,  -- off by default
  updated_at timestamptz not null default now()
);

comment on table public.notification_preferences is
  'Per-user notification switches. ride_* notifications respect ride_enabled, verification_* respect verification_enabled, safety_* respect safety_enabled. push_enabled / email_enabled are reserved for the future delivery channels.';

-- ── Push tokens (registration only, Phase 6) ───────────────────────
create table if not exists public.push_tokens (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  token text not null unique,
  device_id text,
  platform text check (platform in ('android', 'ios')),
  last_active_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

comment on table public.push_tokens is
  'Expo push tokens registered by the app. Private to their owner (RLS); push delivery is a later phase.';

create index if not exists push_tokens_user_idx on public.push_tokens (user_id);

-- ── Row Level Security ─────────────────────────────────────────────
alter table public.notifications enable row level security;
alter table public.notification_preferences enable row level security;
alter table public.push_tokens enable row level security;

-- Read-only for the client: SELECT is needed for the realtime
-- subscription; every write (mark read, delete, preferences, tokens)
-- goes through security-definer RPCs, so no insert/update/delete grants.
create policy "notifications read own non-deleted"
  on public.notifications for select
  to authenticated
  using (recipient_user_id = auth.uid() and deleted_at is null);

create policy "preferences read own"
  on public.notification_preferences for select
  to authenticated
  using (user_id = auth.uid());

create policy "push tokens read own"
  on public.push_tokens for select
  to authenticated
  using (user_id = auth.uid());

revoke all on public.notifications from public;
revoke all on public.notification_preferences from public;
revoke all on public.push_tokens from public;

grant select on public.notifications to authenticated;
grant select on public.notification_preferences to authenticated;
grant select on public.push_tokens to authenticated;

-- ── Supabase Realtime ──────────────────────────────────────────────
-- The notifications feed is published so clients receive new rows via
-- postgres_changes (filtered to their own recipient_user_id by RLS).
-- Guarded: no-op on plain Postgres (e.g. the local smoke-test DB).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- ── Notification service: internal helpers (not callable by clients) ─

-- record_notification(): the single entry point for creating in-app
-- notifications. Maps the type to a preference category and skips the
-- insert when the recipient has disabled that category. Silent failure
-- isolation is the CALLER's job (exception blocks in triggers/RPCs).
create or replace function public.record_notification(
  p_recipient_user_id uuid,
  p_type text,
  p_title text,
  p_message text,
  p_data jsonb default '{}'::jsonb,
  p_actor_user_id uuid default null,
  p_expires_at timestamptz default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_enabled boolean;
begin
  if p_recipient_user_id is null then
    raise exception 'A notification recipient is required';
  end if;

  if p_type not in (
    'ride_request_received', 'ride_request_approved', 'ride_request_rejected',
    'passenger_joined', 'passenger_left', 'passenger_removed',
    'ride_updated', 'ride_cancelled', 'ride_started', 'ride_completed',
    'ride_expired',
    'verification_submitted', 'verification_approved', 'verification_rejected',
    'resubmission_requested',
    'welcome', 'password_changed', 'email_verified',
    'safety_check', 'emergency_alert', 'marketing'
  ) then
    raise exception 'Unknown notification type: %', p_type;
  end if;

  -- Preference gate by category (account notifications always deliver).
  if p_type like 'ride_%' then
    select ride_enabled into v_enabled
      from public.notification_preferences where user_id = p_recipient_user_id;
    v_enabled := coalesce(v_enabled, true);
  elsif p_type in ('verification_submitted', 'verification_approved', 'verification_rejected', 'resubmission_requested') then
    select verification_enabled into v_enabled
      from public.notification_preferences where user_id = p_recipient_user_id;
    v_enabled := coalesce(v_enabled, true);
  elsif p_type in ('safety_check', 'emergency_alert') then
    select safety_enabled into v_enabled
      from public.notification_preferences where user_id = p_recipient_user_id;
    v_enabled := coalesce(v_enabled, true);
  elsif p_type = 'marketing' then
    select marketing_enabled into v_enabled
      from public.notification_preferences where user_id = p_recipient_user_id;
    v_enabled := coalesce(v_enabled, false);
  else
    v_enabled := true;
  end if;

  if not v_enabled then
    return;
  end if;

  insert into public.notifications (
    recipient_user_id, actor_user_id, type, title, message, data, expires_at
  )
  values (
    p_recipient_user_id, p_actor_user_id, p_type, p_title, p_message,
    p_data, p_expires_at
  );
end;
$$;

revoke all on function public.record_notification(uuid, text, text, text, jsonb, uuid, timestamptz) from public;

-- broadcast_covia_event(): real-time event bus. Always emits to the
-- `covia_events` NOTIFY channel (for server-side consumers: the future
-- NestJS push worker can LISTEN), and when Supabase Realtime is present
-- also emits a `broadcast` message on `supabase_realtime` so mobile
-- clients subscribed via channel().on('broadcast', ...) receive it.
-- Broadcast failures must never break the caller: wrap calls.
create or replace function public.broadcast_covia_event(
  p_event text,
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform pg_notify(
    'covia_events',
    jsonb_build_object('event', p_event, 'payload', p_payload)::text
  );

  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    perform pg_notify(
      'supabase_realtime',
      jsonb_build_object(
        'type', 'broadcast',
        'event', p_event,
        'payload', p_payload
      )::text
    );
  end if;
end;
$$;

revoke all on function public.broadcast_covia_event(text, jsonb) from public;

-- ── Account lifecycle emitters (welcome + email verified) ──────────
-- Fired from auth.users so signups and email confirmations produce
-- notifications without any client involvement. `password_changed`
-- has no reliable SQL hook, so it stays a reserved type.
create or replace function public.handle_account_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  begin
    if tg_op = 'INSERT' then
      perform public.record_notification(
        new.id, 'welcome',
        'Welcome to Covia',
        'Find verified travellers heading your way and share the ride.'
      );
    elsif tg_op = 'UPDATE'
      and new.email_confirmed_at is not null
      and old.email_confirmed_at is null
    then
      perform public.record_notification(
        new.id, 'email_verified',
        'Email verified',
        'Your email is confirmed. You can now create and join rides.'
      );
    end if;
  exception when others then null; -- never break signup/email updates
  end;
  return new;
end;
$$;

drop trigger if exists account_notifications on auth.users;

create trigger account_notifications
  after insert or update of email_confirmed_at on auth.users
  for each row execute function public.handle_account_notifications();
