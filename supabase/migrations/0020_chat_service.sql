-- ============================================================================
-- Phase 7 — Ride Chat & Communication System (service layer)
--
-- Client surface (all security definer, participant-only):
--   get_chat, get_chat_messages, send_chat_message, edit_chat_message,
--   delete_chat_message, mark_messages_read, search_chat_messages
--
-- Internal (revoked from the client):
--   ensure_ride_chat, add_chat_system_message, purge_expired_chat_messages,
--   sync_chat_from_ride_timeline (trigger), broadcast_chat_message (trigger)
--
-- Lifecycle (all driven by the ride_timeline trigger so chat state can
-- never drift from ride state):
--   first approval (joined) ─▶ chat room created
--   completed               ─▶ archived + locked_at = now() + 2h
--   cancelled / expired     ─▶ archived + locked immediately
--   messaging is blocked while archived_at is set or locked_at is past
-- ============================================================================

-- ── Internal: ensure the ride has a chat room ─────────────────────────────
create or replace function public.ensure_ride_chat(p_ride_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  insert into public.ride_chats (ride_id)
  values (p_ride_id)
  on conflict (ride_id) do nothing;

  select id into v_id from public.ride_chats where ride_id = p_ride_id;
  return v_id;
end;
$$;

-- ── Internal: system announcement (no client access) ──────────────────────
-- No-ops when the chat does not exist yet (e.g. events on rides nobody
-- joined). The timeline trigger calls this before archiving/locking, so
-- lifecycle announcements are always recorded.
create or replace function public.add_chat_system_message(p_chat_id uuid, p_message text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_chat_id is null or nullif(btrim(coalesce(p_message, '')), '') is null then
    return;
  end if;

  insert into public.chat_messages (chat_id, sender_id, message_type, message)
  values (p_chat_id, null, 'system', p_message);
end;
$$;

-- ── Internal: access check used by every client RPC ───────────────────────
-- Raises the same friendly error for "no chat" and "not a participant" so
-- outsiders cannot probe chat existence.
create or replace function public.assert_chat_access(p_chat_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_user_id is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  if not public.is_chat_participant(p_chat_id, p_user_id) then
    raise exception 'Chat not found';
  end if;
end;
$$;

-- ── Client: chat header with pinned ride information ──────────────────────
-- The mobile screen pins this at the top and re-fetches it when the ride
-- changes (edits arrive as covia.ride.updated broadcasts), so it always
-- shows the latest pickup, destination, departure, host and headcount.
create or replace function public.get_chat(p_chat_id uuid)
returns table (
  id uuid,
  ride_id uuid,
  created_at timestamptz,
  archived_at timestamptz,
  locked_at timestamptz,
  ride_status text,
  origin text,
  pickup_point text,
  destination text,
  departure_time timestamptz,
  host_id uuid,
  host_name text,
  participant_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
begin
  perform public.assert_chat_access(p_chat_id, v_user);

  return query
    select rc.id, rc.ride_id, rc.created_at, rc.archived_at, rc.locked_at,
           r.ride_status, r.origin, r.pickup_point, r.destination,
           r.departure_time, r.host_id,
           coalesce(nullif(pr.display_name, ''), 'Host'),
           (
             select count(*)::bigint
             from public.ride_participants p
             where p.ride_id = r.id
               and p.role = 'Passenger'
               and p.left_at is null
           ) + 1::bigint as participant_count
    from public.ride_chats rc
    join public.rides r on r.id = rc.ride_id
    left join public.profiles pr on pr.id = r.host_id
    where rc.id = p_chat_id;
end;
$$;

-- ── Client: message feed (cursor pagination for lazy loading) ─────────────
-- Newest page first; pass the oldest sent_at you already have as
-- p_before to load older messages. `total_count` is the full alive
-- history so the client knows how far back it can scroll.
create or replace function public.get_chat_messages(
  p_chat_id uuid,
  p_before timestamptz default null,
  p_page_size integer default 30
)
returns table (
  id uuid,
  chat_id uuid,
  sender_id uuid,
  sender_name text,
  message_type text,
  message text,
  media_url text,
  sent_at timestamptz,
  edited_at timestamptz,
  read_count bigint,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_size integer := greatest(1, least(coalesce(p_page_size, 30), 100));
begin
  perform public.assert_chat_access(p_chat_id, v_user);

  return query
    select m.id, m.chat_id, m.sender_id, pr.display_name as sender_name,
           m.message_type, m.message, m.media_url, m.sent_at, m.edited_at,
             (
               select count(*)::bigint
               from public.message_reads mr
               where mr.message_id = m.id
             ) as read_count,
           (
             select count(*)::bigint
             from public.chat_messages allm
             where allm.chat_id = p_chat_id
               and allm.deleted_at is null
           ) as total_count
    from public.chat_messages m
    left join public.profiles pr on pr.id = m.sender_id
    where m.chat_id = p_chat_id
      and m.deleted_at is null
      and (p_before is null or m.sent_at < p_before)
    order by m.sent_at desc
    limit v_size;
end;
$$;

-- ── Client: send a message ─────────────────────────────────────────────────
-- text:  message required, <= 2000 chars
-- image: media_url = storage object path `chat/{chat_id}/{file}` that the
--        sender actually uploaded (existence + ownership are verified)
-- Blocks: non-participants, archived chats (ride completed), locked chats
-- (2h after completion / cancelled / expired).
create or replace function public.send_chat_message(
  p_chat_id uuid,
  p_message text default null,
  p_message_type text default 'text',
  p_media_url text default null
)
returns public.chat_messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_chat public.ride_chats;
  v_msg public.chat_messages;
begin
  perform public.assert_chat_access(p_chat_id, v_user);

  if p_message_type not in ('text', 'image') then
    raise exception 'Message type must be text or image';
  end if;

  select * into v_chat from public.ride_chats where id = p_chat_id;
  if v_chat.archived_at is not null then
    raise exception 'This chat is archived — the ride has ended';
  end if;
  if v_chat.locked_at is not null and v_chat.locked_at <= now() then
    raise exception 'This chat is locked';
  end if;

  if p_message_type = 'text' then
    if nullif(btrim(coalesce(p_message, '')), '') is null then
      raise exception 'A message is required';
    end if;
    if char_length(p_message) > 2000 then
      raise exception 'Messages are limited to 2000 characters';
    end if;
  else
    if nullif(btrim(coalesce(p_media_url, '')), '') is null then
      raise exception 'An image is required';
    end if;
    if not exists (
      select 1
      from storage.objects o
      where o.bucket_id = 'chat-media'
        and o.owner = v_user
        and o.name = p_media_url
        and (storage.foldername(o.name))[1] = 'chat'
        and (storage.foldername(o.name))[2]::uuid = p_chat_id
    ) then
      raise exception 'Image not found in this chat folder';
    end if;
  end if;

  insert into public.chat_messages (
    chat_id, sender_id, message_type, message, media_url
  )
  values (
    p_chat_id, v_user, p_message_type,
    case when p_message_type = 'text' then btrim(p_message) else null end,
    case when p_message_type = 'image' then btrim(p_media_url) else null end
  )
  returning * into v_msg;

  return v_msg;
end;
$$;

-- ── Client: edit own message (text only, while the chat is open) ──────────
create or replace function public.edit_chat_message(p_message_id uuid, p_message text)
returns public.chat_messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_msg public.chat_messages;
  v_chat public.ride_chats;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  if nullif(btrim(coalesce(p_message, '')), '') is null then
    raise exception 'A message is required';
  end if;
  if char_length(p_message) > 2000 then
    raise exception 'Messages are limited to 2000 characters';
  end if;

  select * into v_msg
  from public.chat_messages
  where id = p_message_id and sender_id = v_user
  for update;

  if not found then
    raise exception 'Message not found';
  end if;

  if v_msg.message_type <> 'text' then
    raise exception 'Only text messages can be edited';
  end if;

  select * into v_chat from public.ride_chats where id = v_msg.chat_id;
  if v_chat.archived_at is not null or (v_chat.locked_at is not null and v_chat.locked_at <= now()) then
    raise exception 'This chat is locked';
  end if;

  update public.chat_messages
  set message = btrim(p_message), edited_at = now()
  where id = p_message_id
  returning * into v_msg;

  return v_msg;
end;
$$;

-- ── Client: soft-delete own message (row stays for audit/realtime) ────────
create or replace function public.delete_chat_message(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_chat public.ride_chats;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select c.* into v_chat
  from public.chat_messages m
  join public.ride_chats c on c.id = m.chat_id
  where m.id = p_message_id and m.sender_id = v_user;

  if v_chat is null then
    raise exception 'Message not found';
  end if;

  update public.chat_messages
  set deleted_at = now(), message = null, media_url = null
  where id = p_message_id;
end;
$$;

-- ── Client: read receipts (batch mark through a point in time) ────────────
create or replace function public.mark_messages_read(
  p_chat_id uuid,
  p_through timestamptz default null
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_count bigint;
begin
  perform public.assert_chat_access(p_chat_id, v_user);

  insert into public.message_reads (message_id, user_id)
  select m.id, v_user
  from public.chat_messages m
  where m.chat_id = p_chat_id
    and m.deleted_at is null
      and (p_through is null or m.sent_at <= p_through + interval '1 millisecond')
    and not exists (
      select 1 from public.message_reads r
      where r.message_id = m.id and r.user_id = v_user
    );

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ── Client: search messages inside a ride (scoped; the architecture
--    generalises to a global search index later) ───────────────────────────
create or replace function public.search_chat_messages(
  p_chat_id uuid,
  p_query text,
  p_page integer default 1,
  p_page_size integer default 20
)
returns table (
  id uuid,
  sender_id uuid,
  sender_name text,
  message text,
  sent_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_q text := btrim(coalesce(p_query, ''));
  v_size integer := greatest(1, least(coalesce(p_page_size, 20), 50));
  v_offset integer := (greatest(coalesce(p_page, 1), 1) - 1) * v_size;
begin
  perform public.assert_chat_access(p_chat_id, v_user);

  if v_q = '' then
    raise exception 'A search query is required';
  end if;
  if char_length(v_q) > 100 then
    raise exception 'Search queries are limited to 100 characters';
  end if;

  return query
    select m.id, m.sender_id, pr.display_name as sender_name,
           m.message, m.sent_at,
           count(*) over ()::bigint as total_count
    from public.chat_messages m
    left join public.profiles pr on pr.id = m.sender_id
    where m.chat_id = p_chat_id
      and m.deleted_at is null
      and m.message_type = 'text'
      and m.message ilike '%' || v_q || '%'
    order by m.sent_at desc
    limit v_size offset v_offset;
end;
$$;

-- ── Retention: purge messages older than 90 days ──────────────────────────
-- Chats flagged for a safety investigation (preserve_until set and still
-- in the future) are exempt. Runs daily at 03:00 via pg_cron when the
-- extension is available; also callable by ops.
create or replace function public.purge_expired_chat_messages()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count bigint;
begin
  delete from public.chat_messages m
  where m.sent_at < now() - interval '90 days'
    and not exists (
      select 1 from public.ride_chats rc
      where rc.id = m.chat_id
        and rc.preserve_until is not null
        and rc.preserve_until > now()
    );

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (select 1 from cron.job where jobname = 'covia-chat-retention') then
      perform cron.schedule(
        'covia-chat-retention',
        '0 3 * * *',
        'select public.purge_expired_chat_messages()'
      );
    end if;
  end if;
end $$;

-- ── Lifecycle sync: ride_timeline → chat ─────────────────────────────────
-- Drives room creation (first approval), system announcements and the
-- archive/lock rules. Failure-isolated: chat problems never break the
-- ride operation that produced the timeline event.
create or replace function public.sync_chat_from_ride_timeline()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_chat_id uuid;
  v_name text;
  v_passenger_id uuid;
begin
  begin
    case new.event_type
      when 'joined' then
        -- first approval creates the room; every approval announces it
        v_chat_id := public.ensure_ride_chat(new.ride_id);
        v_passenger_id := nullif(new.metadata ->> 'passenger_id', '')::uuid;
        v_passenger_id := coalesce(v_passenger_id, new.actor_id);
        select display_name into v_name from public.profiles where id = v_passenger_id;
        perform public.add_chat_system_message(
          v_chat_id, coalesce(nullif(v_name, ''), 'Someone') || ' joined the ride'
        );

      when 'left' then
        select id into v_chat_id from public.ride_chats where ride_id = new.ride_id;
        select display_name into v_name from public.profiles where id = new.actor_id;
        perform public.add_chat_system_message(
          v_chat_id, coalesce(nullif(v_name, ''), 'Someone') || ' left the ride'
        );

      when 'dropped' then
        select id into v_chat_id from public.ride_chats where ride_id = new.ride_id;
        v_passenger_id := nullif(new.metadata ->> 'passenger_id', '')::uuid;
        select display_name into v_name from public.profiles where id = v_passenger_id;
        perform public.add_chat_system_message(
          v_chat_id, coalesce(nullif(v_name, ''), 'Someone') || ' was removed from the ride'
        );

      when 'started' then
        select id into v_chat_id from public.ride_chats where ride_id = new.ride_id;
        perform public.add_chat_system_message(v_chat_id, 'The ride has started');

      when 'completed' then
        select id into v_chat_id from public.ride_chats where ride_id = new.ride_id;
        perform public.add_chat_system_message(v_chat_id, 'The ride has completed');
        update public.ride_chats
        set archived_at = now(), locked_at = now() + interval '2 hours'
        where ride_id = new.ride_id;

      when 'cancelled' then
        select id into v_chat_id from public.ride_chats where ride_id = new.ride_id;
        perform public.add_chat_system_message(v_chat_id, 'The ride has been cancelled');
        update public.ride_chats
        set archived_at = now(), locked_at = now()
        where ride_id = new.ride_id;

      when 'expired' then
        select id into v_chat_id from public.ride_chats where ride_id = new.ride_id;
        perform public.add_chat_system_message(v_chat_id, 'The ride expired');
        update public.ride_chats
        set archived_at = now(), locked_at = now()
        where ride_id = new.ride_id;

      else
        null; -- created / published / requested / approved / request_cancelled
      end case;

  exception when others then
    null; -- never fail the ride operation
  end;

  return new;
end;
$$;

drop trigger if exists sync_chat_from_ride_timeline on public.ride_timeline;
create trigger sync_chat_from_ride_timeline
  after insert on public.ride_timeline
  for each row execute function public.sync_chat_from_ride_timeline();

-- ── Realtime + notifications for new messages ─────────────────────────────
-- Every user message is broadcast (covia.chat.new_message) for instant
-- delivery and produces a chat_message / chat_image in-app notification
-- for the other members, gated by their chat_enabled preference.
-- System messages are not broadcast/notified (ride lifecycle events
-- already notify via Phase 6).
create or replace function public.broadcast_chat_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_recipient uuid;
  v_title text;
  v_message text;
  v_type text;
  v_chat public.ride_chats;
begin
  if new.sender_id is null then
    return new; -- system messages are announced in-chat only
  end if;

  begin
    select * into v_chat from public.ride_chats where id = new.chat_id;

    v_type := case when new.message_type = 'image' then 'chat_image' else 'chat_message' end;
    v_title := case when new.message_type = 'image' then 'Image in your ride chat' else 'New message in your ride chat' end;
    v_message := case
      when new.message_type = 'image' then 'An image was shared in the ride chat'
      else left(coalesce(new.message, ''), 200)
    end;

    perform public.broadcast_covia_event(
      'covia.chat.new_message',
      jsonb_build_object(
        'chat_id', new.chat_id,
        'ride_id', v_chat.ride_id,
        'message_id', new.id,
        'sender_id', new.sender_id,
        'message_type', new.message_type
      )
    );

    -- Notify every member except the sender (host first, then passengers).
    select r.host_id into v_recipient
    from public.ride_chats rc
    join public.rides r on r.id = rc.ride_id
    where rc.id = new.chat_id;
    if v_recipient is distinct from new.sender_id then
      perform public.record_notification(
        v_recipient, v_type, v_title, v_message,
        jsonb_build_object(
          'chat_id', new.chat_id,
          'ride_id', v_chat.ride_id,
          'message_id', new.id,
          'media_type', new.message_type
        ),
        new.sender_id
      );
    end if;

    for v_recipient in
      select p.user_id
      from public.ride_participants p
      where p.ride_id = v_chat.ride_id
        and p.role = 'Passenger'
        and p.left_at is null
        and p.user_id is distinct from new.sender_id
    loop
      perform public.record_notification(
        v_recipient, v_type, v_title, v_message,
        jsonb_build_object(
          'chat_id', new.chat_id,
          'ride_id', v_chat.ride_id,
          'message_id', new.id,
          'media_type', new.message_type
        ),
        new.sender_id
      );
    end loop;

  exception when others then
    null; -- notification/broadcast failures never break message delivery
  end;

  return new;
end;
$$;

drop trigger if exists broadcast_chat_message on public.chat_messages;
create trigger broadcast_chat_message
  after insert on public.chat_messages
  for each row execute function public.broadcast_chat_message();

-- ── Grants ────────────────────────────────────────────────────────────────
revoke all on function public.ensure_ride_chat(uuid) from public;
revoke all on function public.add_chat_system_message(uuid, text) from public;
revoke all on function public.assert_chat_access(uuid, uuid) from public;
revoke all on function public.get_chat(uuid) from public;
revoke all on function public.get_chat_messages(uuid, timestamptz, integer) from public;
revoke all on function public.send_chat_message(uuid, text, text, text) from public;
revoke all on function public.edit_chat_message(uuid, text) from public;
revoke all on function public.delete_chat_message(uuid) from public;
revoke all on function public.mark_messages_read(uuid, timestamptz) from public;
revoke all on function public.search_chat_messages(uuid, text, integer, integer) from public;
revoke all on function public.purge_expired_chat_messages() from public;

grant execute on function public.get_chat(uuid) to authenticated;
grant execute on function public.get_chat_messages(uuid, timestamptz, integer) to authenticated;
grant execute on function public.send_chat_message(uuid, text, text, text) to authenticated;
grant execute on function public.edit_chat_message(uuid, text) to authenticated;
grant execute on function public.delete_chat_message(uuid) to authenticated;
grant execute on function public.mark_messages_read(uuid, timestamptz) to authenticated;
grant execute on function public.search_chat_messages(uuid, text, integer, integer) to authenticated;
