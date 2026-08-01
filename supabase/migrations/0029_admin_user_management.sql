-- Covia - Phase 10: admin user management
-- ------------------------------------------------------------------
-- Search users, view full profiles, ride history, and apply account
-- enforcement (suspend / reactivate / permanent ban).
--
-- Enforcement model:
--   * suspension -> active moderation_action of type suspension; blocks
--     ride creation, joining and rating via existing gates + new
--     BEFORE INSERT triggers on rides / ride_requests.
--   * permanent ban -> profiles.is_banned = true + an indefinite
--     suspension action; also blocks filing new reports.
--   * reactivate  -> lifts active suspension actions and clears the
--     ban flag; warnings and restrictions stay on record.
--
-- Everything is permission-gated (user.view / user.manage) and
-- audited.

-- =============================================================
-- Ban flag
-- =============================================================
alter table public.profiles
  add column if not exists is_banned boolean not null default false;

comment on column public.profiles.is_banned is
  'Permanent ban flag (Phase 10). Admin-set via admin_ban_user, cleared by admin_reactivate_user.';

-- =============================================================
-- Operational gates
-- =============================================================
-- Suspended or banned users cannot create rides, request to join,
-- rate, or file new reports. Banned users also lose reporting.
create or replace function public.account_operational_gate(p_context text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    return;
  end if;
  if exists (
    select 1 from public.profiles where id = v_actor and is_banned = true
  ) then
    raise exception 'Your account has been permanently banned; contact support';
  end if;
  if exists (
    select 1 from public.moderation_actions
     where user_id = v_actor
       and status = 'active'
       and action_type = 'suspension'
       and (ends_at is null or ends_at > now())
  ) then
    raise exception 'Your account is suspended; you cannot % right now', p_context;
  end if;
end;
$$;

-- Ride-facing gate: replaces the Phase 9 creation/joining triggers so a
-- single trigger distinguishes ban, suspension and temporary restriction
-- (per-table verb) and respects lifted restrictions via ends_at.
drop trigger if exists rides_block_restricted_creation on public.rides;
drop trigger if exists ride_requests_block_restricted_joining on public.ride_requests;
drop trigger if exists rides_restriction_gate on public.rides;
drop trigger if exists ride_requests_restriction_gate on public.ride_requests;
drop function if exists public.assert_ride_creation_allowed();
drop function if exists public.assert_ride_joining_allowed();

create or replace function public.block_restricted_on_rides()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_action text;
  v_ends timestamptz;
  v_verb text;
begin
  if v_actor is null then
    return new;
  end if;
  if exists (
    select 1 from public.profiles where id = v_actor and is_banned = true
  ) then
    raise exception 'Your account has been permanently banned; contact support';
  end if;
  v_verb := case when tg_table_name = 'rides' then 'creating' else 'joining' end;
  select action_type, ends_at into v_action, v_ends
    from public.moderation_actions
   where user_id = v_actor
     and status = 'active'
     and (ends_at is null or ends_at > now())
     and action_type in (
       case when tg_table_name = 'rides' then 'temporary_restriction'
       else 'ride_joining_disabled' end,
       'suspension',
       case when tg_table_name = 'rides' then 'ride_creation_disabled'
       else 'temporary_restriction' end
     )
   order by severity desc
   limit 1;
  if v_action is not null and v_action = 'suspension' then
    raise exception 'Your account is suspended; you cannot % right now', v_verb;
  end if;
  if v_action is not null then
    raise exception 'Your account is restricted from % rides%', v_verb,
      case when v_ends is not null then ' until ' || to_char(v_ends, 'YYYY-MM-DD HH24:MI') else '' end;
  end if;
  return new;
end;
$$;

create trigger rides_restriction_gate
  before insert on public.rides
  for each row execute function public.block_restricted_on_rides();

create trigger ride_requests_restriction_gate
  before insert on public.ride_requests
  for each row execute function public.block_restricted_on_rides();

-- Reporting is a participation privilege too.
create or replace function public.report_user(
  p_user_id uuid,
  p_reason text,
  p_details text default null,
  p_evidence_refs jsonb default '[]'::jsonb
)
returns public.reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_report public.reports;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to report someone';
  end if;
  perform public.account_operational_gate('report users');
  if p_user_id is null or p_user_id = auth.uid() then
    raise exception 'You cannot report yourself';
  end if;
  if not public.is_valid_report_reason(p_reason) then
    raise exception 'That report reason is not recognised';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'That user does not exist';
  end if;
  perform public.validate_evidence_refs(p_evidence_refs);

  insert into public.reports (
    reporter_user_id, target_type, target_user_id, reason, details, evidence_refs
  ) values (
    auth.uid(), 'user', p_user_id, p_reason, p_details, p_evidence_refs
  ) returning * into v_report;

  return v_report;
exception when unique_violation then
  raise exception 'You have already reported this user for this reason';
end;
$$;

create or replace function public.report_ride(
  p_ride_id uuid,
  p_reason text,
  p_details text default null,
  p_evidence_refs jsonb default '[]'::jsonb
)
returns public.reports
language plpgsql
security definer
set search_path = public
as $$
declare
  v_report public.reports;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to report a ride';
  end if;
  perform public.account_operational_gate('report rides');
  if not public.is_valid_report_reason(p_reason) then
    raise exception 'That report reason is not recognised';
  end if;
  if not exists (select 1 from public.rides where id = p_ride_id) then
    raise exception 'That ride does not exist';
  end if;
  perform public.validate_evidence_refs(p_evidence_refs);

  insert into public.reports (
    reporter_user_id, target_type, target_ride_id, reason, details, evidence_refs
  ) values (
    auth.uid(), 'ride', p_ride_id, p_reason, p_details, p_evidence_refs
  ) returning * into v_report;

  return v_report;
exception when unique_violation then
  raise exception 'You have already reported this ride for this reason';
end;
$$;

-- Banned state is public knowledge (profile block).
create or replace function public.get_public_trust_summary(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_avg numeric;
  v_count bigint;
  v_age_days integer;
begin
  select * into v_profile from public.profiles where id = p_user_id;
  if not found then
    raise exception 'User not found';
  end if;

  select round(avg(overall_rating)::numeric, 2), count(*)
    into v_avg, v_count
    from public.ratings
   where ratee_user_id = p_user_id and is_revealed = true;

  v_age_days := greatest(extract(epoch from (now() - v_profile.created_at)) / 86400, 0)::int;

  return jsonb_build_object(
    'user_id', p_user_id,
    'average_rating', coalesce(v_avg, 5.0),
    'rating_count', v_count,
    'reliability_score', v_profile.reliability_score,
    'completed_rides', v_profile.total_completed_rides,
    'cancelled_rides', v_profile.total_cancelled_rides,
    'verification_status', v_profile.verification_status,
    'is_government_id_verified', v_profile.is_government_id_verified,
    'is_student_verified', v_profile.is_student_verified,
    'is_banned', v_profile.is_banned,
    'account_age_days', v_age_days
  );
end;
$$;

-- =============================================================
-- Search + profile + history (user.view)
-- =============================================================
create or replace function public.admin_search_users(
  p_query text default null,
  p_verification_status text default null,
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns table (
  id uuid,
  username text,
  display_name text,
  email text,
  phone text,
  verification_status text,
  reliability_score integer,
  rating numeric,
  total_completed_rides integer,
  total_cancelled_rides integer,
  is_banned boolean,
  is_suspended boolean,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 100);
  v_page integer := greatest(p_page, 1);
  v_query text := nullif(btrim(coalesce(p_query, '')), '');
begin
  perform public.require_permission('user.view');
  if p_verification_status is not null
     and p_verification_status not in ('Pending', 'In Review', 'Verified', 'Rejected') then
    raise exception 'Unknown verification status filter: %', p_verification_status;
  end if;
  if p_status is not null and p_status not in ('active', 'suspended', 'banned') then
    raise exception 'Unknown account status filter: %', p_status;
  end if;

  return query
    select pr.id, pr.username, pr.display_name, pr.email, pr.phone,
           pr.verification_status, pr.reliability_score, pr.rating,
           pr.total_completed_rides, pr.total_cancelled_rides,
           pr.is_banned,
           exists (
             select 1 from public.moderation_actions ma
              where ma.user_id = pr.id
                and ma.status = 'active'
                and ma.action_type = 'suspension'
           ) as is_suspended,
           pr.created_at,
           count(*) over ()::bigint
      from public.profiles pr
     where (v_query is null
            or pr.display_name ilike '%' || v_query || '%'
            or pr.username ilike '%' || v_query || '%'
            or pr.email ilike '%' || v_query || '%')
       and (p_verification_status is null
            or pr.verification_status = p_verification_status)
       and (p_status is null or (
         case p_status
           when 'banned' then pr.is_banned
           when 'suspended' then exists (
             select 1 from public.moderation_actions ma
              where ma.user_id = pr.id
                and ma.status = 'active'
                and ma.action_type = 'suspension'
           )
           else not pr.is_banned
         end
       ))
     order by pr.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

create or replace function public.admin_get_user_profile(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_summary jsonb;
  v_verification jsonb;
  v_active_restrictions bigint;
  v_reports_received bigint;
begin
  perform public.require_permission('user.view');

  select * into v_profile from public.profiles where id = p_user_id;
  if not found then
    raise exception 'User not found';
  end if;

  v_summary := public.build_trust_summary(p_user_id);

  select jsonb_build_object(
           'status', s.status,
           'verification_type', s.verification_type,
           'submitted_at', s.submitted_at,
           'reviewed_at', s.reviewed_at,
           'rejection_reason', s.rejection_reason
         )
    into v_verification
    from public.verification_submissions s
   where s.user_id = p_user_id
   order by s.submitted_at desc
   limit 1;

  select count(*) into v_active_restrictions
    from public.moderation_actions
   where user_id = p_user_id and status = 'active';

  select count(*) into v_reports_received
    from public.reports
   where target_user_id = p_user_id;

  return jsonb_build_object(
    'user_id', p_user_id,
    'username', v_profile.username,
    'display_name', v_profile.display_name,
    'email', v_profile.email,
    'phone', v_profile.phone,
    'home_city', v_profile.home_city,
    'bio', v_profile.bio,
    'verification_status', v_profile.verification_status,
    'is_government_id_verified', v_profile.is_government_id_verified,
    'is_student_verified', v_profile.is_student_verified,
    'is_banned', v_profile.is_banned,
    'rating', v_profile.rating,
    'reliability_score', v_profile.reliability_score,
    'total_completed_rides', v_profile.total_completed_rides,
    'total_cancelled_rides', v_profile.total_cancelled_rides,
    'created_at', v_profile.created_at,
    'latest_verification', v_verification,
    'active_restrictions', v_active_restrictions,
    'reports_received_total', v_reports_received,
    'trust', v_summary
  );
end;
$$;

create or replace function public.admin_get_user_ride_history(
  p_user_id uuid,
  p_page integer default 1,
  p_page_size integer default 20
)
returns table (
  ride_id uuid,
  role text,
  origin text,
  destination text,
  ride_status text,
  departure_time timestamptz,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 100);
  v_page integer := greatest(p_page, 1);
begin
  perform public.require_permission('user.view');

  return query
    select r.id, rp.role, r.origin, r.destination, r.ride_status,
           r.departure_time, r.created_at,
           count(*) over ()::bigint
      from public.rides r
      join public.ride_participants rp on rp.ride_id = r.id
     where rp.user_id = p_user_id
     order by r.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

-- =============================================================
-- Enforcement (user.manage)
-- =============================================================
create or replace function public.admin_suspend_user(
  p_user_id uuid,
  p_reason text,
  p_duration_hours integer default null
)
returns public.moderation_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.moderation_actions;
begin
  perform public.require_permission('user.manage');
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'User not found';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A reason is required';
  end if;
  if exists (
    select 1 from public.moderation_actions
     where user_id = p_user_id and status = 'active' and action_type = 'suspension'
  ) then
    raise exception 'That user already has an active suspension';
  end if;

  insert into public.moderation_actions (
    user_id, action_type, reason, source, created_by, ends_at
  ) values (
    p_user_id, 'suspension', p_reason, 'manual', auth.uid(),
    case when p_duration_hours is not null
         then now() + make_interval(hours => p_duration_hours) else null end
  ) returning * into v_action;

  perform public.record_audit(
    'user.suspend', 'user', p_user_id,
    null,
    jsonb_build_object('moderation_action_id', v_action.id,
                       'reason', p_reason,
                       'duration_hours', p_duration_hours)
  );

  begin
    perform public.record_notification(
      p_user_id, 'account_restricted', 'Account suspended',
      'Your account has been suspended: ' || p_reason,
      jsonb_build_object('action_type', 'suspension')
    );
  exception when others then
    null;
  end;

  return v_action;
end;
$$;

create or replace function public.admin_ban_user(
  p_user_id uuid,
  p_reason text
)
returns public.moderation_actions
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.moderation_actions;
begin
  perform public.require_permission('user.manage');
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'User not found';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A reason is required';
  end if;

  update public.profiles set is_banned = true, updated_at = now()
   where id = p_user_id;

  insert into public.moderation_actions (
    user_id, action_type, reason, source, created_by, ends_at
  ) values (
    p_user_id, 'suspension', 'PERMANENT BAN: ' || p_reason, 'manual', auth.uid(), null
  ) returning * into v_action;

  perform public.record_audit(
    'user.ban', 'user', p_user_id,
    null,
    jsonb_build_object('moderation_action_id', v_action.id, 'reason', p_reason)
  );

  begin
    perform public.record_notification(
      p_user_id, 'account_restricted', 'Account permanently banned',
      'Your account has been permanently banned: ' || p_reason,
      jsonb_build_object('action_type', 'suspension', 'permanent', true)
    );
  exception when others then
    null;
  end;

  return v_action;
end;
$$;

create or replace function public.admin_reactivate_user(
  p_user_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lifted integer;
begin
  perform public.require_permission('user.manage');
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'User not found';
  end if;

  update public.moderation_actions
     set status = 'lifted',
         revoked_by = auth.uid(),
         revoked_at = now(),
         revoke_reason = coalesce(revoke_reason, p_reason)
   where user_id = p_user_id
     and status = 'active'
     and action_type = 'suspension';

  get diagnostics v_lifted = row_count;

  update public.profiles set is_banned = false, updated_at = now()
   where id = p_user_id;

  perform public.record_audit(
    'user.reactivate', 'user', p_user_id,
    null,
    jsonb_build_object('suspensions_lifted', v_lifted, 'reason', p_reason)
  );

  begin
    perform public.record_notification(
      p_user_id, 'account_restricted', 'Account reactivated',
      'Your account has been reactivated: ' || p_reason,
      jsonb_build_object('action_type', 'reactivation')
    );
  exception when others then
    null;
  end;
end;
$$;

-- =============================================================
-- Grants
-- =============================================================
revoke all on function
  public.account_operational_gate, public.block_restricted_on_rides,
  public.report_user, public.report_ride, public.get_public_trust_summary,
  public.admin_search_users, public.admin_get_user_profile,
  public.admin_get_user_ride_history, public.admin_suspend_user,
  public.admin_ban_user, public.admin_reactivate_user
  from public;

grant execute on function
  public.report_user(uuid, text, text, jsonb),
  public.report_ride(uuid, text, text, jsonb),
  public.get_public_trust_summary(uuid),
  public.admin_search_users(text, text, text, integer, integer),
  public.admin_get_user_profile(uuid),
  public.admin_get_user_ride_history(uuid, integer, integer),
  public.admin_suspend_user(uuid, text, integer),
  public.admin_ban_user(uuid, text),
  public.admin_reactivate_user(uuid, text)
  to authenticated;
