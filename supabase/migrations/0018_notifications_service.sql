-- Covia - Phase 6: notification service functions
-- ------------------------------------------------------------------
-- Client-facing RPC surface for the notification feed, preferences and
-- push-token registration, plus the event-driven emitters that connect
-- existing modules (rides, verification) to the notification service.
--
-- Emitters:
--   * notify_from_ride_timeline() - AFTER INSERT trigger on ride_timeline
--     (rides already record a timeline event for every important action,
--     so this single central trigger covers the whole ride lifecycle)
--   * submit_verification / resubmit_verification / admin_review_verification
--     re-created to also notify (+ broadcast) on verification status changes
--
-- Isolation: every emitter wraps its notification + broadcast calls in
-- an exception block, so a notification failure can never roll back the
-- primary action.

-- ── Shared type validation helper ──────────────────────────────────
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
    'safety_check', 'emergency_alert', 'marketing'
  );
$$;

revoke all on function public.is_valid_notification_type(text) from public;
grant execute on function public.is_valid_notification_type(text) to authenticated;

-- ── Feed: get notifications (paginated) ────────────────────────────
create or replace function public.get_notifications(
  p_page integer default 1,
  p_page_size integer default 20,
  p_unread_only boolean default false,
  p_type text default null
)
returns table (
  id uuid,
  recipient_user_id uuid,
  actor_user_id uuid,
  type text,
  title text,
  message text,
  data jsonb,
  is_read boolean,
  read_at timestamptz,
  expires_at timestamptz,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_page_size integer := greatest(1, least(coalesce(p_page_size, 20), 50));
  v_offset integer := (greatest(coalesce(p_page, 1), 1) - 1) * v_page_size;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  if p_type is not null and not public.is_valid_notification_type(p_type) then
    raise exception 'Unknown notification type: %', p_type;
  end if;

  return query
    select n.id, n.recipient_user_id, n.actor_user_id, n.type, n.title,
           n.message, n.data, n.is_read, n.read_at, n.expires_at,
           n.created_at,
           count(*) over ()::bigint as total_count
    from public.notifications n
    where n.recipient_user_id = v_user
      and n.deleted_at is null
      and (p_unread_only is false or n.is_read = false)
      and (p_type is null or n.type = p_type)
    order by n.created_at desc
    limit v_page_size offset v_offset;
end;
$$;

-- ── Feed: unread count (for badges) ────────────────────────────────
create or replace function public.get_unread_notification_count()
returns bigint
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

  return (
    select count(*)::bigint
    from public.notifications
    where recipient_user_id = v_user
      and is_read = false
      and deleted_at is null
  );
end;
$$;

-- ── Feed: mark one notification as read ────────────────────────────
create or replace function public.mark_notification_read(p_notification_id uuid)
returns public.notifications
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_notif public.notifications;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  update public.notifications
  set is_read = true, read_at = coalesce(read_at, now())
  where id = p_notification_id
    and recipient_user_id = v_user
    and deleted_at is null
  returning * into v_notif;

  if not found then
    raise exception 'Notification not found';
  end if;

  return v_notif;
end;
$$;

-- ── Feed: batch mark all as read ───────────────────────────────────
create or replace function public.mark_all_notifications_read()
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_count bigint;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  update public.notifications
  set is_read = true, read_at = now()
  where recipient_user_id = v_user
    and is_read = false
    and deleted_at is null;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- ── Feed: delete (soft delete; the row disappears from the feed) ───
create or replace function public.delete_notification(p_notification_id uuid)
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

  update public.notifications
  set deleted_at = now()
  where id = p_notification_id
    and recipient_user_id = v_user
    and deleted_at is null;

  if not found then
    raise exception 'Notification not found';
  end if;
end;
$$;

-- ── Preferences: read (defaults when never configured) ─────────────
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
    v_pref := row(v_user, true, true, false, true, true, false, now())
      ::public.notification_preferences;
  end if;

  return v_pref;
end;
$$;

-- ── Preferences: update (null = leave unchanged) ───────────────────
create or replace function public.update_notification_preferences(
  p_ride_enabled boolean default null,
  p_push_enabled boolean default null,
  p_email_enabled boolean default null,
  p_verification_enabled boolean default null,
  p_safety_enabled boolean default null,
  p_marketing_enabled boolean default null
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
      updated_at = now()
  where user_id = v_user
  returning * into v_pref;

  if v_pref is null then
    insert into public.notification_preferences (
      user_id, ride_enabled, push_enabled, email_enabled,
      verification_enabled, safety_enabled, marketing_enabled
    )
    values (
      v_user,
      coalesce(p_ride_enabled, true),
      coalesce(p_push_enabled, true),
      coalesce(p_email_enabled, false),
      coalesce(p_verification_enabled, true),
      coalesce(p_safety_enabled, true),
      coalesce(p_marketing_enabled, false)
    )
    returning * into v_pref;
  end if;

  return v_pref;
end;
$$;

-- ── Push tokens: register (upsert per token; re-registration moves
--    the token to the current user — a device signed into a new
--    account overwrites the old owner) ──────────────────────────────
create or replace function public.register_push_token(
  p_token text,
  p_device_id text default null,
  p_platform text default null
)
returns public.push_tokens
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_token public.push_tokens;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  if nullif(btrim(coalesce(p_token, '')), '') is null then
    raise exception 'A push token is required';
  end if;

  if char_length(p_token) > 512 then
    raise exception 'Push token is too long';
  end if;

  if p_platform is not null and p_platform not in ('android', 'ios') then
    raise exception 'Platform must be android or ios';
  end if;

  insert into public.push_tokens (user_id, token, device_id, platform, last_active_at)
  values (v_user, p_token, nullif(p_device_id, ''), p_platform, now())
  on conflict (token) do update
    set user_id = excluded.user_id,
        device_id = coalesce(nullif(excluded.device_id, ''), push_tokens.device_id),
        platform = coalesce(excluded.platform, push_tokens.platform),
        last_active_at = now()
  returning * into v_token;

  return v_token;
end;
$$;

-- ── Push tokens: remove (idempotent) ───────────────────────────────
create or replace function public.remove_push_token(p_token text)
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

  delete from public.push_tokens
  where user_id = v_user and token = p_token;
end;
$$;

-- ── Ride emitter: ride_timeline → notifications + broadcasts ───────
-- Every ride lifecycle action records a timeline event; this trigger is
-- the centralized Notification Service for rides. It never fails the
-- primary action (everything is wrapped in an exception block).
create or replace function public.notify_from_ride_timeline()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_host_id uuid;
  v_origin text;
  v_destination text;
  v_actor_name text;
  v_passenger_id uuid;
  v_title text;
  v_message text;
  v_data jsonb;
  v_recipient uuid;
  v_reason text;
begin
  begin
    select r.host_id, r.origin, r.destination
      into v_host_id, v_origin, v_destination
      from public.rides r
      where r.id = new.ride_id;

    if v_host_id is null then
      return new; -- ride gone; nothing to notify
    end if;

    select display_name into v_actor_name
      from public.profiles where id = new.actor_id;
    v_actor_name := coalesce(nullif(v_actor_name, ''), 'Someone');

    case new.event_type
      when 'requested' then
        -- passenger asked to join → host
        v_passenger_id := nullif(new.metadata ->> 'passenger_id', '')::uuid;
        v_recipient := v_host_id;
        v_title := 'New ride request';
        v_message := v_actor_name || ' requested to join your ride to ' || v_destination;
        v_data := jsonb_build_object(
          'ride_id', new.ride_id,
          'request_id', new.metadata ->> 'request_id',
          'passenger_id', v_passenger_id,
          'actor_display_name', v_actor_name
        );

      when 'approved' then
        -- host accepted → passenger
        v_passenger_id := nullif(new.metadata ->> 'passenger_id', '')::uuid;
        v_recipient := v_passenger_id;
        v_title := 'Request approved';
        v_message := 'Your request to join the ride to ' || v_destination || ' was approved';
        v_data := jsonb_build_object(
          'ride_id', new.ride_id,
          'request_id', new.metadata ->> 'request_id',
          'actor_display_name', v_actor_name
        );

      when 'rejected' then
        -- host declined → passenger (with reason when present)
        v_passenger_id := nullif(new.metadata ->> 'passenger_id', '')::uuid;
        v_recipient := v_passenger_id;
        v_reason := new.metadata ->> 'reason';
        v_title := 'Request declined';
        v_message := 'Your request to join the ride to ' || v_destination || ' was declined';
        if nullif(v_reason, '') is not null then
          v_message := v_message || ' (' || v_reason || ')';
        end if;
        v_data := jsonb_build_object(
          'ride_id', new.ride_id,
          'request_id', new.metadata ->> 'request_id',
          'reason', v_reason,
          'actor_display_name', v_actor_name
        );

      when 'joined' then
        -- passenger confirmed on board → host
        v_recipient := v_host_id;
        v_title := 'Passenger joined';
        v_message := v_actor_name || ' joined your ride to ' || v_destination;
        v_data := jsonb_build_object('ride_id', new.ride_id, 'passenger_id', new.actor_id);

      when 'left' then
        -- passenger left → host
        v_recipient := v_host_id;
        v_title := 'Passenger left';
        v_message := v_actor_name || ' left your ride to ' || v_destination;
        v_data := jsonb_build_object('ride_id', new.ride_id, 'passenger_id', new.actor_id);

      when 'dropped' then
        -- host removed a passenger → the removed passenger
        v_passenger_id := nullif(new.metadata ->> 'passenger_id', '')::uuid;
        v_recipient := v_passenger_id;
        v_title := 'Removed from ride';
        v_message := 'You were removed from the ride to ' || v_destination;
        v_data := jsonb_build_object('ride_id', new.ride_id);

      when 'edited' then
        -- host edited the ride → every current member except the host
        v_title := 'Ride updated';
        v_message := 'The ride to ' || v_destination || ' was updated by ' || v_actor_name;
        v_data := jsonb_build_object('ride_id', new.ride_id, 'changes', new.metadata);
        for v_recipient in
          select p.user_id
          from public.ride_participants p
          where p.ride_id = new.ride_id
            and p.left_at is null
            and p.user_id is distinct from new.actor_id
        loop
          perform public.record_notification(
            v_recipient, 'ride_updated', v_title, v_message, v_data, new.actor_id
          );
        end loop;
        perform public.broadcast_covia_event(
          'covia.ride.updated',
          jsonb_build_object('ride_id', new.ride_id, 'changes', new.metadata)
        );
        return new;

      when 'started' then
        v_title := 'Ride started';
        v_message := 'Your ride to ' || v_destination || ' has started';
        v_data := jsonb_build_object('ride_id', new.ride_id);
        for v_recipient in
          select p.user_id
          from public.ride_participants p
          where p.ride_id = new.ride_id
            and p.left_at is null
            and p.user_id is distinct from new.actor_id
        loop
          perform public.record_notification(
            v_recipient, 'ride_started', v_title, v_message, v_data, new.actor_id
          );
        end loop;
        perform public.broadcast_covia_event(
          'covia.ride.started', jsonb_build_object('ride_id', new.ride_id)
        );
        return new;

      when 'completed' then
        v_title := 'Ride completed';
        v_message := 'Your ride to ' || v_destination || ' completed';
        v_data := jsonb_build_object('ride_id', new.ride_id);
        for v_recipient in
          select p.user_id
          from public.ride_participants p
          where p.ride_id = new.ride_id
            and p.left_at is null
            and p.user_id is distinct from new.actor_id
        loop
          perform public.record_notification(
            v_recipient, 'ride_completed', v_title, v_message, v_data, new.actor_id
          );
        end loop;
        perform public.broadcast_covia_event(
          'covia.ride.completed', jsonb_build_object('ride_id', new.ride_id)
        );
        return new;

      when 'cancelled' then
        v_title := 'Ride cancelled';
        v_message := 'The ride to ' || v_destination || ' was cancelled';
        v_data := jsonb_build_object('ride_id', new.ride_id);
        for v_recipient in
          select p.user_id
          from public.ride_participants p
          where p.ride_id = new.ride_id
            and p.left_at is null
            and p.user_id is distinct from new.actor_id
        loop
          perform public.record_notification(
            v_recipient, 'ride_cancelled', v_title, v_message, v_data, new.actor_id
          );
        end loop;
        perform public.broadcast_covia_event(
          'covia.ride.cancelled', jsonb_build_object('ride_id', new.ride_id)
        );
        return new;

      when 'expired' then
        -- departure passed without starting → host
        v_recipient := v_host_id;
        v_title := 'Ride expired';
        v_message := 'Your ride to ' || v_destination || ' expired without starting';
        v_data := jsonb_build_object('ride_id', new.ride_id);
        perform public.broadcast_covia_event(
          'covia.ride.expired', jsonb_build_object('ride_id', new.ride_id)
        );

      else
        -- created / published / request_cancelled / ride_full and any
        -- future event types: no notification
        return new;
    end case;

    if v_recipient is not null then
      perform public.record_notification(
        v_recipient, new.event_type, v_title, v_message, v_data, new.actor_id
      );
    end if;

  exception when others then
    null; -- notification failures never break the primary action
  end;

  return new;
end;
$$;

drop trigger if exists notify_from_ride_timeline on public.ride_timeline;

create trigger notify_from_ride_timeline
  after insert on public.ride_timeline
  for each row execute function public.notify_from_ride_timeline();

revoke all on function public.notify_from_ride_timeline() from public;

-- ── Verification emitters ──────────────────────────────────────────
-- Re-creates the Phase 4 functions with notification + broadcast calls.
-- Behaviour is unchanged; the notification calls are failure-isolated.

create or replace function public.submit_verification(
  p_verification_type text,
  p_front_document_url text default null,
  p_back_document_url text default null,
  p_selfie_url text default null,
  p_student_card_url text default null,
  p_university_email text default null,
  p_government_id_kind text default null
)
returns public.verification_submissions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_sub public.verification_submissions;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  if p_verification_type not in ('government_id', 'student') then
    raise exception 'Unknown verification type: %', p_verification_type;
  end if;

  if exists (
    select 1 from public.verification_submissions
    where user_id = v_user
      and verification_type = p_verification_type
      and status in ('pending', 'approved', 'resubmission_requested')
  ) then
    raise exception 'You already have an active % verification', p_verification_type
      using errcode = '23505', hint = 'resubmit';
  end if;

  if p_verification_type = 'government_id' then
    if p_front_document_url is null or p_front_document_url = '' then
      raise exception 'The front of your ID is required';
    end if;
    if p_government_id_kind not in ('national_id', 'drivers_license', 'passport') then
      raise exception 'Please choose the type of ID you are uploading';
    end if;
  else
    if (p_student_card_url is null or p_student_card_url = '')
       and nullif(btrim(coalesce(p_university_email, '')), '') is null then
      raise exception 'Upload your student card or provide your university email';
    end if;
  end if;

  insert into public.verification_submissions (
    user_id, verification_type, government_id_kind, status, submitted_at,
    front_document_url, back_document_url, selfie_url,
    student_card_url, university_email
  )
  values (
    v_user, p_verification_type, p_government_id_kind, 'pending', now(),
    nullif(p_front_document_url, ''), nullif(p_back_document_url, ''), nullif(p_selfie_url, ''),
    nullif(p_student_card_url, ''), nullif(btrim(coalesce(p_university_email, '')), '')
  )
  returning * into v_sub;

  insert into public.verification_audit (submission_id, action, performed_by)
  values (v_sub.id, 'submitted', v_user);

  insert into public.notification_events (user_id, event_type, payload)
  values (
    v_user, 'verification.submitted',
    jsonb_build_object('verification_type', p_verification_type, 'submission_id', v_sub.id)
  );

  begin
    perform public.record_notification(
      v_user, 'verification_submitted',
      'Verification submitted',
      'We received your ' || case p_verification_type
        when 'government_id' then 'Government ID'
        else 'Student'
      end || ' verification and will review it shortly.',
      jsonb_build_object('verification_type', p_verification_type, 'submission_id', v_sub.id)
    );
  exception when others then null;
  end;

  return v_sub;
end;
$$;

create or replace function public.resubmit_verification(
  p_submission_id uuid,
  p_front_document_url text default null,
  p_back_document_url text default null,
  p_selfie_url text default null,
  p_student_card_url text default null,
  p_university_email text default null,
  p_government_id_kind text default null
)
returns public.verification_submissions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_sub public.verification_submissions;
begin
  if v_user is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v_sub
  from public.verification_submissions
  where id = p_submission_id and user_id = v_user
  for update;

  if not found then
    raise exception 'Verification request not found';
  end if;

  if v_sub.status not in ('rejected', 'resubmission_requested') then
    raise exception 'Only rejected requests can be resubmitted';
  end if;

  if v_sub.verification_type = 'government_id' then
    if p_front_document_url is null or p_front_document_url = '' then
      raise exception 'The front of your ID is required';
    end if;
    if p_government_id_kind not in ('national_id', 'drivers_license', 'passport') then
      raise exception 'Please choose the type of ID you are uploading';
    end if;
  else
    if (p_student_card_url is null or p_student_card_url = '')
       and nullif(btrim(coalesce(p_university_email, '')), '') is null then
      raise exception 'Upload your student card or provide your university email';
    end if;
  end if;

  update public.verification_submissions
  set status = 'pending',
      submitted_at = now(),
      rejection_reason = null,
      government_id_kind = coalesce(p_government_id_kind, v_sub.government_id_kind),
      front_document_url = nullif(p_front_document_url, ''),
      back_document_url = nullif(p_back_document_url, ''),
      selfie_url = nullif(p_selfie_url, ''),
      student_card_url = nullif(p_student_card_url, ''),
      university_email = nullif(btrim(coalesce(p_university_email, '')), '')
  where id = p_submission_id
  returning * into v_sub;

  insert into public.verification_audit (submission_id, action, performed_by)
  values (v_sub.id, 'submitted', v_user);

  insert into public.notification_events (user_id, event_type, payload)
  values (
    v_user, 'verification.submitted',
    jsonb_build_object('verification_type', v_sub.verification_type, 'submission_id', v_sub.id)
  );

  begin
    perform public.record_notification(
      v_user, 'verification_submitted',
      'Verification submitted',
      'We received your updated documents and will review them shortly.',
      jsonb_build_object('verification_type', v_sub.verification_type, 'submission_id', v_sub.id)
    );
  exception when others then null;
  end;

  return v_sub;
end;
$$;

create or replace function public.admin_review_verification(
  p_submission_id uuid,
  p_action text,
  p_reason text default null
)
returns public.verification_submissions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin uuid := auth.uid();
  v_sub public.verification_submissions;
  v_event text;
  v_type_label text;
begin
  if not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;
  if v_admin is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;

  select * into v_sub
  from public.verification_submissions
  where id = p_submission_id
  for update;

  if not found then
    raise exception 'Verification request not found';
  end if;

  if v_sub.status <> 'pending' then
    raise exception 'Only pending requests can be reviewed (current status: %)', v_sub.status;
  end if;

  if p_action = 'approve' then
    update public.verification_submissions
    set status = 'approved', reviewed_at = now(), reviewed_by = v_admin, rejection_reason = null
    where id = p_submission_id
    returning * into v_sub;

    update public.profiles
    set verification_status = 'Verified',
        is_government_id_verified = case when v_sub.verification_type = 'government_id' then true else is_government_id_verified end,
        is_student_verified = case when v_sub.verification_type = 'student' then true else is_student_verified end,
        updated_at = now()
    where id = v_sub.user_id;

    v_event := 'verification.approved';

  elsif p_action = 'reject' then
    if nullif(btrim(coalesce(p_reason, '')), '') is null then
      raise exception 'A rejection reason is required';
    end if;

    update public.verification_submissions
    set status = 'rejected', reviewed_at = now(), reviewed_by = v_admin, rejection_reason = p_reason
    where id = p_submission_id
    returning * into v_sub;

    v_event := 'verification.rejected';

  elsif p_action = 'request_resubmission' then
    update public.verification_submissions
    set status = 'resubmission_requested', reviewed_at = now(), reviewed_by = v_admin,
        rejection_reason = coalesce(p_reason, 'Please upload clearer documents and try again')
    where id = p_submission_id
    returning * into v_sub;

    v_event := 'verification.resubmission_requested';

  else
    raise exception 'Unknown review action: % (expected approve | reject | request_resubmission)', p_action;
  end if;

  insert into public.verification_audit (submission_id, action, performed_by, reason)
  values (
    p_submission_id,
    case p_action
      when 'approve' then 'approved'
      when 'reject' then 'rejected'
      else 'resubmission_requested'
    end,
    v_admin,
    p_reason
  );

  insert into public.notification_events (user_id, event_type, payload)
  values (
    v_sub.user_id, v_event,
    jsonb_build_object(
      'verification_type', v_sub.verification_type,
      'submission_id', v_sub.id,
      'reason', p_reason
    )
  );

  v_type_label := case v_sub.verification_type
    when 'government_id' then 'Government ID'
    else 'Student'
  end;

  begin
    case p_action
      when 'approve' then
        perform public.record_notification(
          v_sub.user_id, 'verification_approved',
          'Verification approved',
          'Your ' || v_type_label || ' verification was approved. You can now create and join rides.',
          jsonb_build_object('verification_type', v_sub.verification_type, 'submission_id', v_sub.id)
        );
      when 'reject' then
        perform public.record_notification(
          v_sub.user_id, 'verification_rejected',
          'Verification rejected',
          'Your ' || v_type_label || ' verification was rejected: ' || p_reason,
          jsonb_build_object(
            'verification_type', v_sub.verification_type,
            'submission_id', v_sub.id,
            'reason', p_reason
          )
        );
      else
        perform public.record_notification(
          v_sub.user_id, 'resubmission_requested',
          'Documents needed',
          'Please upload clearer ' || v_type_label || ' documents: ' || v_sub.rejection_reason,
          jsonb_build_object(
            'verification_type', v_sub.verification_type,
            'submission_id', v_sub.id,
            'reason', v_sub.rejection_reason
          )
        );
    end case;

    perform public.broadcast_covia_event(
      'covia.verification.updated',
      jsonb_build_object(
        'user_id', v_sub.user_id,
        'verification_type', v_sub.verification_type,
        'status', v_sub.status
      )
    );
  exception when others then null;
  end;

  return v_sub;
end;
$$;

-- ── Grants for the Phase 6 surface ─────────────────────────────────
revoke all on function public.is_valid_notification_type(text) from public;
revoke all on function public.get_notifications(integer, integer, boolean, text) from public;
revoke all on function public.get_unread_notification_count() from public;
revoke all on function public.mark_notification_read(uuid) from public;
revoke all on function public.mark_all_notifications_read() from public;
revoke all on function public.delete_notification(uuid) from public;
revoke all on function public.get_notification_preferences() from public;
revoke all on function public.update_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean) from public;
revoke all on function public.register_push_token(text, text, text) from public;
revoke all on function public.remove_push_token(text) from public;
revoke all on function public.submit_verification(text, text, text, text, text, text, text) from public;
revoke all on function public.resubmit_verification(uuid, text, text, text, text, text, text) from public;
revoke all on function public.admin_review_verification(uuid, text, text) from public;

grant execute on function public.is_valid_notification_type(text) to authenticated;
grant execute on function public.get_notifications(integer, integer, boolean, text) to authenticated;
grant execute on function public.get_unread_notification_count() to authenticated;
grant execute on function public.mark_notification_read(uuid) to authenticated;
grant execute on function public.mark_all_notifications_read() to authenticated;
grant execute on function public.delete_notification(uuid) to authenticated;
grant execute on function public.get_notification_preferences() to authenticated;
grant execute on function public.update_notification_preferences(boolean, boolean, boolean, boolean, boolean, boolean) to authenticated;
grant execute on function public.register_push_token(text, text, text) to authenticated;
grant execute on function public.remove_push_token(text) to authenticated;
grant execute on function public.submit_verification(text, text, text, text, text, text, text) to authenticated;
grant execute on function public.resubmit_verification(uuid, text, text, text, text, text, text) to authenticated;
grant execute on function public.admin_review_verification(uuid, text, text) to authenticated;
