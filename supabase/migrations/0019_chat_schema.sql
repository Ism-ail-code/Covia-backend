-- ============================================================================
-- Phase 7 — Ride Chat & Communication System
--
-- Schema layer: chat rooms, messages, read receipts + security + storage.
--
-- Design notes
-- ------------
--   1. Every ride owns at most one chat room (`ride_chats.ride_id` unique).
--      The room is created lazily by the service layer when the first
--      passenger is approved and never exposed through client RPCs.
--   2. Only the ride host and approved passengers (left_at is null) can
--      read a chat; pending/rejected users and outsiders see nothing
--      (RLS) and cannot subscribe to the realtime feed.
--   3. All writes go through security-definer RPCs in 0020; the client
--      has SELECT-only grants here (plus the storage policies below).
--   4. Message retention: chat_messages live for 90 days and are purged
--      by `purge_expired_chat_messages()` (cron-guarded in 0020). Chats
--      flagged for a safety investigation carry `preserve_until` and are
--      exempt from purging until the case is resolved.
--   5. Media lives in the `chat-media` Storage bucket under
--      `chat/{chat_id}/{file}`; object-level RLS ties access back to
--      chat membership, so phone numbers never leave Covia.
-- ============================================================================

-- ── ride_chats ──────────────────────────────────────────────────────────────
create table if not exists public.ride_chats (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null unique references public.rides (id) on delete cascade,
  created_at timestamptz not null default now(),
  archived_at timestamptz,          -- set when the ride completes
  locked_at timestamptz,            -- set at completion + 2h (or on cancel)
  preserve_until timestamptz        -- safety hold: exempt from the 90-day purge
);

comment on table public.ride_chats is
  'One chat room per ride. Lifecycle (create/archive/lock) is managed by triggers in 0020; clients only ever read.';

create index if not exists ride_chats_created_idx on public.ride_chats (created_at desc);

-- ── chat_messages ───────────────────────────────────────────────────────────
create table if not exists public.chat_messages (
  id uuid primary key default gen_random_uuid(),
  chat_id uuid not null references public.ride_chats (id) on delete cascade,
  sender_id uuid references public.profiles (id) on delete set null,
  message_type text not null check (message_type in ('text', 'image', 'system')),
  message text,
  media_url text,
  sent_at timestamptz not null default now(),
  edited_at timestamptz,
  deleted_at timestamptz,           -- soft delete: row stays, body hidden
  constraint chat_messages_text_requires_body
    check (message_type <> 'text' or message is not null),
  constraint chat_messages_image_requires_media
    check (message_type <> 'image' or media_url is not null),
  constraint chat_messages_system_has_no_sender
    check (message_type <> 'system' or sender_id is null),
  constraint chat_messages_system_has_body
    check (message_type <> 'system' or message is not null),
  constraint chat_messages_media_only_for_images
    check (message_type = 'image' or media_url is null)
);

comment on table public.chat_messages is
  'Chat messages (text / image / system). System messages are ride-lifecycle announcements with no sender.';

create index if not exists chat_messages_feed_idx
  on public.chat_messages (chat_id, sent_at desc);

create index if not exists chat_messages_feed_alive_idx
  on public.chat_messages (chat_id, sent_at desc)
  where deleted_at is null;

create index if not exists chat_messages_search_idx
  on public.chat_messages (chat_id, lower(message))
  where message_type = 'text' and deleted_at is null;

create index if not exists chat_messages_retention_idx
  on public.chat_messages (sent_at)
  where deleted_at is null;

-- ── message_reads (read receipts) ──────────────────────────────────────────
create table if not exists public.message_reads (
  message_id uuid not null references public.chat_messages (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

comment on table public.message_reads is
  'Read receipts: one row per reader per message. Senders count them to show delivered/read status.';

create index if not exists message_reads_user_idx on public.message_reads (user_id);

-- ── Membership helper (used by RLS policies and RPCs) ──────────────────────
create or replace function public.is_chat_participant(p_chat_id uuid, p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.ride_chats rc
    join public.rides r on r.id = rc.ride_id
    where rc.id = p_chat_id
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

revoke all on function public.is_chat_participant(uuid, uuid) from public;
grant execute on function public.is_chat_participant(uuid, uuid) to authenticated;

-- ── Row Level Security ─────────────────────────────────────────────────────
-- SELECT-only for the client (realtime subscriptions read rows under RLS);
-- every mutation goes through the security-definer chat service in 0020.
alter table public.ride_chats enable row level security;
alter table public.chat_messages enable row level security;
alter table public.message_reads enable row level security;

drop policy if exists "chat rooms readable by participants" on public.ride_chats;
create policy "chat rooms readable by participants"
  on public.ride_chats for select
  to authenticated
  using (public.is_chat_participant(id, auth.uid()));

drop policy if exists "chat messages readable by participants" on public.chat_messages;
create policy "chat messages readable by participants"
  on public.chat_messages for select
  to authenticated
  using (public.is_chat_participant(chat_id, auth.uid()));

drop policy if exists "read receipts readable by participants" on public.message_reads;
create policy "read receipts readable by participants"
  on public.message_reads for select
  to authenticated
  using (exists (
    select 1
    from public.chat_messages m
    where m.id = message_id
      and public.is_chat_participant(m.chat_id, auth.uid())
  ));

revoke all on public.ride_chats from public;
revoke all on public.chat_messages from public;
revoke all on public.message_reads from public;

grant select on public.ride_chats to authenticated;
grant select on public.chat_messages to authenticated;
grant select on public.message_reads to authenticated;

-- ── Media storage: chat-media bucket + object policies ────────────────────
-- Objects live at chat/{chat_id}/{filename}. Access is granted only to
-- chat participants; inserts require the object owner to be the caller.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'chat-media',
  'chat-media',
  false,
  5242880,                                            -- 5 MB per image
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic']
)
on conflict (id) do nothing;

drop policy if exists "chat media readable by participants" on storage.objects;
create policy "chat media readable by participants"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'chat-media'
    and (storage.foldername(name))[1] = 'chat'
    and public.is_chat_participant((storage.foldername(name))[2]::uuid, auth.uid())
  );

drop policy if exists "chat media uploaded by participants" on storage.objects;
create policy "chat media uploaded by participants"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'chat-media'
    and owner = auth.uid()
    and (storage.foldername(name))[1] = 'chat'
    and public.is_chat_participant((storage.foldername(name))[2]::uuid, auth.uid())
  );

-- ── Supabase Realtime ──────────────────────────────────────────────────────
-- Messages + read receipts are published so clients receive new rows
-- instantly (postgres_changes); RLS keeps each subscription scoped to
-- chats the user belongs to. Guarded: no-op on plain Postgres.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
      where pubname = 'supabase_realtime'
        and schemaname = 'public'
        and tablename = 'chat_messages'
    ) then
      alter publication supabase_realtime
        add table public.chat_messages, public.message_reads;
    end if;
  end if;
end $$;

-- ── Notification service extension (Phase 6 + chat) ───────────────────────
-- Chat messages produce in-app notifications gated by a new
-- `chat_enabled` preference. `record_notification`, the preferences
-- reader and the preferences writer are re-created with the chat
-- category; behaviour is otherwise unchanged.
alter table public.notification_preferences
  add column if not exists chat_enabled boolean not null default true;

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
    'chat_message', 'chat_image',
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
  elsif p_type in ('chat_message', 'chat_image') then
    select chat_enabled into v_enabled
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

create or replace function public.get_notification_preferences()
returns public.notification_preferences
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_pref public.notification_preferences;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v_pref
  from public.notification_preferences
  where user_id = v_user;

  if not found then
    -- Column order matches the physical table layout (chat_enabled was
    -- added after updated_at by ALTER TABLE).
    v_pref := row(v_user, true, true, false, true, true, false, now(), true)
      ::public.notification_preferences;
  end if;

  return v_pref;
end;
$$;

create or replace function public.update_notification_preferences(
  p_ride_enabled boolean default null,
  p_push_enabled boolean default null,
  p_email_enabled boolean default null,
  p_verification_enabled boolean default null,
  p_safety_enabled boolean default null,
  p_marketing_enabled boolean default null,
  p_chat_enabled boolean default null
)
returns public.notification_preferences
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_pref public.notification_preferences;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  update public.notification_preferences
  set ride_enabled = coalesce(p_ride_enabled, ride_enabled),
      push_enabled = coalesce(p_push_enabled, push_enabled),
      email_enabled = coalesce(p_email_enabled, email_enabled),
      verification_enabled = coalesce(p_verification_enabled, verification_enabled),
      safety_enabled = coalesce(p_safety_enabled, safety_enabled),
      marketing_enabled = coalesce(p_marketing_enabled, marketing_enabled),
      chat_enabled = coalesce(p_chat_enabled, chat_enabled),
      updated_at = now()
  where user_id = v_user
  returning * into v_pref;

  if v_pref is null then
    insert into public.notification_preferences (
      user_id, ride_enabled, push_enabled, email_enabled,
      verification_enabled, safety_enabled, marketing_enabled, chat_enabled
    )
    values (
      v_user,
      coalesce(p_ride_enabled, true),
      coalesce(p_push_enabled, true),
      coalesce(p_email_enabled, false),
      coalesce(p_verification_enabled, true),
      coalesce(p_safety_enabled, true),
      coalesce(p_marketing_enabled, false),
      coalesce(p_chat_enabled, true)
    )
    returning * into v_pref;
  end if;

  return v_pref;
end;
$$;

-- The Phase 6 writer is superseded (chat_enabled param added); drop the
-- old overload so partial named-argument calls stay unambiguous.
drop function if exists public.update_notification_preferences(
  boolean, boolean, boolean, boolean, boolean, boolean
);

revoke all on function public.get_notification_preferences() from public;
revoke all on function public.update_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean, boolean) from public;
grant execute on function public.get_notification_preferences() to authenticated;
grant execute on function public.update_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean, boolean) to authenticated;
