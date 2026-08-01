-- Covia - Phase 9: reports, appeals, trust metrics + moderation admin
--
-- Reporting: confidential user/ride reports (chat-message targets are
-- future-ready). Duplicate pending reports on the same target+reason are
-- blocked by partial unique indexes.
--
-- Appeals: restricted users (everything except plain warnings) can
-- contest their action once; the reason is editable while pending.
--
-- Trust metrics: get_trust_summary() (own, full) and
-- get_public_trust_summary(p_user_id) (public subset — never reveals
-- reports or restrictions).
--
-- Moderation workflow (admin, gated on is_admin()): report review
-- (confirm -> engine re-evaluates the target), appeal decisions
-- (approved -> action lifted), manual actions (graduated enforcement
-- step 3) and rule configuration.

-- =============================================================
-- Shared validation
-- =============================================================
create or replace function public.is_valid_report_reason(p_reason text)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_reason in (
    'no_show', 'harassment', 'fake_identity', 'dangerous_behavior',
    'fraud', 'inappropriate_content', 'other'
  );
$$;

create or replace function public.validate_evidence_refs(p_refs jsonb)
returns void
language plpgsql
immutable
set search_path = public
as $$
begin
  if p_refs is null then
    return;
  end if;
  if jsonb_typeof(p_refs) <> 'array' then
    raise exception 'Evidence references must be a list';
  end if;
  if jsonb_array_length(p_refs) > 10 then
    raise exception 'You can attach at most 10 evidence references';
  end if;
  if exists (
    select 1 from jsonb_array_elements_text(p_refs) e
     where e is null or char_length(e) = 0 or char_length(e) > 500
  ) then
    raise exception 'Each evidence reference must be 1-500 characters';
  end if;
end;
$$;

-- =============================================================
-- Reporting (client)
-- =============================================================
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

create or replace function public.get_my_reports(
  p_page integer default 1,
  p_page_size integer default 20
)
returns table (
  id uuid,
  target_type text,
  target_user_id uuid,
  target_ride_id uuid,
  reason text,
  details text,
  status text,
  is_confirmed boolean,
  resolution_note text,
  created_at timestamptz,
  resolved_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 50);
  v_page integer := greatest(p_page, 1);
begin
  return query
    select r.id, r.target_type, r.target_user_id, r.target_ride_id,
           r.reason, r.details, r.status, r.is_confirmed,
           r.resolution_note, r.created_at, r.resolved_at,
           count(*) over ()::bigint
      from public.reports r
     where r.reporter_user_id = auth.uid()
     order by r.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

-- =============================================================
-- Appeals (client)
-- =============================================================
create or replace function public.submit_appeal(
  p_moderation_action_id uuid,
  p_reason text
)
returns public.appeals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_action public.moderation_actions;
  v_appeal public.appeals;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to submit an appeal';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Explain why the restriction should be removed';
  end if;
  if char_length(p_reason) > 2000 then
    raise exception 'Appeals are limited to 2000 characters';
  end if;

  select * into v_action from public.moderation_actions where id = p_moderation_action_id;
  if not found then
    raise exception 'That moderation action does not exist';
  end if;
  if v_action.user_id <> auth.uid() then
    raise exception 'You can only appeal your own restrictions';
  end if;
  if v_action.action_type = 'warning' then
    raise exception 'Warnings cannot be appealed';
  end if;
  if v_action.status not in ('active', 'expired') then
    raise exception 'This action is no longer active';
  end if;

  insert into public.appeals (user_id, moderation_action_id, reason)
  values (auth.uid(), p_moderation_action_id, p_reason)
  returning * into v_appeal;

  return v_appeal;
exception when unique_violation then
  raise exception 'You already have a pending appeal for this action';
end;
$$;

create or replace function public.update_appeal(
  p_appeal_id uuid,
  p_reason text
)
returns public.appeals
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appeal public.appeals;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'Explain why the restriction should be removed';
  end if;
  if char_length(p_reason) > 2000 then
    raise exception 'Appeals are limited to 2000 characters';
  end if;

  update public.appeals
     set reason = p_reason
   where id = p_appeal_id
     and user_id = auth.uid()
     and status = 'pending'
  returning * into v_appeal;

  if v_appeal is null then
    raise exception 'Appeal not found or no longer editable';
  end if;
  return v_appeal;
end;
$$;

create or replace function public.get_my_appeals()
returns table (
  id uuid,
  moderation_action_id uuid,
  action_type text,
  action_status text,
  action_reason text,
  appeal_reason text,
  status text,
  moderator_note text,
  decided_at timestamptz,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
    select a.id, a.moderation_action_id,
           ma.action_type, ma.status, ma.reason,
           a.reason, a.status, a.moderator_note, a.decided_at, a.created_at
      from public.appeals a
      join public.moderation_actions ma on ma.id = a.moderation_action_id
     where a.user_id = auth.uid()
     order by a.created_at desc;
end;
$$;

-- =============================================================
-- Moderation status (client)
-- =============================================================
create or replace function public.get_my_moderation_status()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_is_suspended boolean;
  v_can_create boolean;
  v_can_join boolean;
begin
  if v_uid is null then
    raise exception 'You must be signed in';
  end if;

  select exists (
    select 1 from public.moderation_actions
     where user_id = v_uid and status = 'active'
       and action_type = 'suspension'
  ) into v_is_suspended;

  select not exists (
    select 1 from public.moderation_actions
     where user_id = v_uid and status = 'active'
       and (ends_at is null or ends_at > now())
       and action_type in ('temporary_restriction', 'ride_creation_disabled', 'suspension')
  ) into v_can_create;

  select not exists (
    select 1 from public.moderation_actions
     where user_id = v_uid and status = 'active'
       and (ends_at is null or ends_at > now())
       and action_type in ('temporary_restriction', 'ride_joining_disabled', 'suspension')
  ) into v_can_join;

  return jsonb_build_object(
    'is_suspended', v_is_suspended,
    'can_create_rides', v_can_create,
    'can_join_rides', v_can_join,
    'restrictions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', id, 'action_type', action_type, 'severity', severity,
        'status', status, 'reason', reason,
        'starts_at', starts_at, 'ends_at', ends_at, 'source', source
      ) order by severity desc)
        from public.moderation_actions
       where user_id = v_uid
         and status = 'active'
         and (ends_at is null or ends_at > now())
    ), '[]'::jsonb)
  );
end;
$$;

-- =============================================================
-- Trust metrics
-- =============================================================
-- Shared builder (internal; no client grant).
create or replace function public.build_trust_summary(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles;
  v_avg numeric;
  v_count bigint;
  v_reports_total bigint;
  v_reports_confirmed bigint;
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

  select count(*), count(*) filter (where is_confirmed)
    into v_reports_total, v_reports_confirmed
    from public.reports
   where target_user_id = p_user_id;

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
    'reports_received_total', v_reports_total,
    'reports_received_confirmed', v_reports_confirmed,
    'account_age_days', v_age_days,
    'restrictions', coalesce((
      select jsonb_agg(jsonb_build_object(
        'action_type', action_type, 'severity', severity,
        'status', status, 'source', source,
        'starts_at', starts_at, 'ends_at', ends_at
      ) order by severity desc)
        from public.moderation_actions
       where user_id = p_user_id and status = 'active'
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.get_trust_summary()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;
  return public.build_trust_summary(auth.uid());
end;
$$;

create or replace function public.admin_get_trust_summary(p_user_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;
  return public.build_trust_summary(p_user_id);
end;
$$;

-- Public profile block: revealed data only — never reports/restrictions.
create or replace function public.get_public_trust_summary(p_user_id uuid)
returns jsonb
language plpgsql
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
    'account_age_days', v_age_days
  );
end;
$$;

-- =============================================================
-- Moderation workflow (admin)
-- =============================================================
create or replace function public.admin_list_reports(
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 20
)
returns table (
  id uuid,
  reporter_user_id uuid,
  reporter_name text,
  target_type text,
  target_user_id uuid,
  target_user_name text,
  target_ride_id uuid,
  reason text,
  details text,
  evidence_refs jsonb,
  status text,
  is_confirmed boolean,
  resolution_note text,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 50);
  v_page integer := greatest(p_page, 1);
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  return query
    select r.id, r.reporter_user_id, rep.display_name,
           r.target_type, r.target_user_id, tgt.display_name,
           r.target_ride_id, r.reason, r.details, r.evidence_refs,
           r.status, r.is_confirmed, r.resolution_note, r.created_at,
           count(*) over ()::bigint
      from public.reports r
      left join public.profiles rep on rep.id = r.reporter_user_id
      left join public.profiles tgt on tgt.id = r.target_user_id
     where (p_status is null or r.status = p_status)
     order by r.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

create or replace function public.admin_review_report(
  p_report_id uuid,
  p_confirm boolean,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_report public.reports;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  select * into v_report from public.reports where id = p_report_id;
  if not found then
    raise exception 'Report not found';
  end if;

  update public.reports
     set status = case when p_confirm then 'resolved' else 'dismissed' end,
         is_confirmed = p_confirm,
         resolution_note = p_note,
         resolved_by = auth.uid(),
         resolved_at = now()
   where id = p_report_id;

  begin
    perform public.record_notification(
      v_report.reporter_user_id, 'report_resolved',
      case when p_confirm then 'Report resolved' else 'Report closed' end,
      case when p_confirm
           then 'We reviewed your report and took action. Thank you for keeping Covia safe.'
           else 'We reviewed your report and could not confirm it this time.'
      end,
      jsonb_build_object('report_id', p_report_id, 'confirmed', p_confirm)
    );
  exception when others then
    null;
  end;

  if p_confirm and v_report.target_type = 'user' and v_report.target_user_id is not null then
    perform public.run_moderation_engine(v_report.target_user_id);
  end if;
end;
$$;

create or replace function public.admin_list_appeals(
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 20
)
returns table (
  id uuid,
  user_id uuid,
  user_name text,
  moderation_action_id uuid,
  action_type text,
  appeal_reason text,
  status text,
  moderator_note text,
  decided_at timestamptz,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 50);
  v_page integer := greatest(p_page, 1);
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  return query
    select a.id, a.user_id, pr.display_name,
           a.moderation_action_id, ma.action_type,
           a.reason, a.status, a.moderator_note, a.decided_at, a.created_at,
           count(*) over ()::bigint
      from public.appeals a
      join public.moderation_actions ma on ma.id = a.moderation_action_id
      left join public.profiles pr on pr.id = a.user_id
     where (p_status is null or a.status = p_status)
     order by a.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

create or replace function public.admin_decide_appeal(
  p_appeal_id uuid,
  p_approve boolean,
  p_note text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_appeal public.appeals;
  v_action public.moderation_actions;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  select * into v_appeal from public.appeals where id = p_appeal_id;
  if not found then
    raise exception 'Appeal not found';
  end if;
  if v_appeal.status not in ('pending', 'under_review') then
    raise exception 'This appeal has already been decided';
  end if;

  select * into v_action from public.moderation_actions
   where id = v_appeal.moderation_action_id;

  update public.appeals
     set status = case when p_approve then 'approved' else 'rejected' end,
         moderator_id = auth.uid(),
         moderator_note = p_note,
         decided_at = now()
   where id = p_appeal_id;

  if p_approve and v_action.id is not null then
    update public.moderation_actions
       set status = 'lifted',
           revoked_by = auth.uid(),
           revoked_at = now(),
           revoke_reason = 'appeal approved'
     where id = v_action.id;
  end if;

  begin
    perform public.record_notification(
      v_appeal.user_id, 'appeal_decided',
      case when p_approve then 'Appeal approved' else 'Appeal rejected' end,
      case when p_approve
           then 'Your appeal was approved and the restriction on your account has been lifted.'
           else 'Your appeal was not approved. The restriction stays in place.' end,
      jsonb_build_object('appeal_id', p_appeal_id, 'approved', p_approve)
    );
  exception when others then
    null;
  end;
end;
$$;

-- Manual moderation (graduated enforcement, human review).
create or replace function public.admin_apply_moderation_action(
  p_user_id uuid,
  p_action_type text,
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
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'User not found';
  end if;
  if p_action_type not in (
    'warning', 'temporary_restriction', 'ride_creation_disabled',
    'ride_joining_disabled', 'suspension'
  ) then
    raise exception 'Unknown moderation action';
  end if;
  if p_reason is null or length(trim(p_reason)) = 0 then
    raise exception 'A reason is required';
  end if;
  if p_action_type = 'temporary_restriction' and p_duration_hours is null then
    raise exception 'Temporary restrictions need a duration';
  end if;

  insert into public.moderation_actions (
    user_id, action_type, reason, source, created_by, ends_at
  ) values (
    p_user_id, p_action_type, p_reason, 'manual', auth.uid(),
    case when p_duration_hours is not null
         then now() + make_interval(hours => p_duration_hours) else null end
  ) returning * into v_action;

  begin
    perform public.record_notification(
      p_user_id,
      case when v_action.action_type = 'warning' then 'warning_issued' else 'account_restricted' end,
      case when v_action.action_type = 'warning' then 'Account warning' else 'Account restriction' end,
      p_reason,
      jsonb_build_object('action_type', v_action.action_type)
    );
  exception when others then
    null;
  end;

  return v_action;
end;
$$;

create or replace function public.admin_lift_moderation_action(
  p_action_id uuid,
  p_reason text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  update public.moderation_actions
     set status = 'lifted',
         revoked_by = auth.uid(),
         revoked_at = now(),
         revoke_reason = p_reason
   where id = p_action_id and status = 'active';

  if not found then
    raise exception 'Moderation action not found or not active';
  end if;
end;
$$;

create or replace function public.admin_list_moderation_actions(
  p_user_id uuid default null,
  p_status text default null,
  p_page integer default 1,
  p_page_size integer default 20
)
returns table (
  id uuid,
  user_id uuid,
  user_name text,
  action_type text,
  severity smallint,
  status text,
  reason text,
  source text,
  starts_at timestamptz,
  ends_at timestamptz,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 50);
  v_page integer := greatest(p_page, 1);
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  return query
    select ma.id, ma.user_id, pr.display_name,
           ma.action_type, ma.severity, ma.status, ma.reason, ma.source,
           ma.starts_at, ma.ends_at, ma.created_at,
           count(*) over ()::bigint
      from public.moderation_actions ma
      left join public.profiles pr on pr.id = ma.user_id
     where (p_user_id is null or ma.user_id = p_user_id)
       and (p_status is null or ma.status = p_status)
     order by ma.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

-- Rules are configurable at runtime — never hardcoded thresholds.
create or replace function public.admin_update_moderation_rule(
  p_rule_name text,
  p_threshold numeric default null,
  p_action_type text default null,
  p_duration_hours integer default null,
  p_enabled boolean default null
)
returns public.moderation_rules
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rule public.moderation_rules;
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;
  if p_action_type is not null and p_action_type not in (
    'warning', 'temporary_restriction', 'ride_creation_disabled',
    'ride_joining_disabled', 'suspension'
  ) then
    raise exception 'Unknown moderation action';
  end if;

  update public.moderation_rules
     set threshold = coalesce(p_threshold, threshold),
         action_type = coalesce(p_action_type, action_type),
         duration_hours = coalesce(p_duration_hours, duration_hours),
         enabled = coalesce(p_enabled, enabled),
         severity = case
           when coalesce(p_action_type, action_type) = 'warning' then 1
           when coalesce(p_action_type, action_type) = 'temporary_restriction' then 2
           when coalesce(p_action_type, action_type) in ('ride_creation_disabled', 'ride_joining_disabled') then 3
           else 4
         end
   where rule_name = p_rule_name
  returning * into v_rule;

  if v_rule is null then
    raise exception 'Unknown moderation rule';
  end if;
  return v_rule;
end;
$$;

create or replace function public.admin_list_reliability_events(
  p_user_id uuid default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns table (
  id uuid,
  user_id uuid,
  user_name text,
  event_type text,
  weight numeric,
  reason text,
  ride_id uuid,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 100);
  v_page integer := greatest(p_page, 1);
begin
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  return query
    select e.id, e.user_id, pr.display_name,
           e.event_type, e.weight, e.reason, e.ride_id, e.created_at,
           count(*) over ()::bigint
      from public.reliability_events e
      left join public.profiles pr on pr.id = e.user_id
     where (p_user_id is null or e.user_id = p_user_id)
     order by e.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

-- Rules are configurable at runtime — never hardcoded thresholds.
create or replace function public.admin_list_moderation_rules(
  p_page integer default 1,
  p_page_size integer default 100
)
returns table (
  rule_name text,
  threshold numeric,
  action_type text,
  duration_hours integer,
  severity smallint,
  enabled boolean,
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
  if not public.is_admin() then
    raise exception 'Admin access required';
  end if;

  return query
    select mr.rule_name, mr.threshold, mr.action_type, mr.duration_hours,
           mr.severity, mr.enabled,
           count(*) over ()::bigint
      from public.moderation_rules mr
     order by mr.rule_name
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

-- Config is runtime-tunable; clients read the review window to render
-- "rating closes in X" countdowns without touching the RLS-locked table.
create or replace function public.get_trust_config()
returns table (
  review_window_hours integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  return query
    select tc.review_window_hours
      from public.trust_config tc
     where tc.id = 1;
end;
$$;

-- =============================================================
-- Grants
-- =============================================================
revoke all on function
  public.is_valid_report_reason, public.validate_evidence_refs,
  public.report_user, public.report_ride, public.get_my_reports,
  public.submit_appeal, public.update_appeal, public.get_my_appeals,
  public.get_my_moderation_status, public.get_trust_summary,
  public.build_trust_summary, public.admin_get_trust_summary,
  public.get_public_trust_summary,
  public.admin_list_reports, public.admin_review_report,
  public.admin_list_appeals, public.admin_decide_appeal,
  public.admin_apply_moderation_action, public.admin_lift_moderation_action,
  public.admin_list_moderation_actions, public.admin_update_moderation_rule,
  public.admin_list_reliability_events, public.get_trust_config,
  public.admin_list_moderation_rules
  from public;

grant execute on function public.admin_list_moderation_rules(integer, integer) to authenticated;
grant execute on function
  public.admin_list_reports(text, integer, integer),
  public.admin_review_report(uuid, boolean, text),
  public.admin_list_appeals(text, integer, integer),
  public.admin_decide_appeal(uuid, boolean, text),
  public.admin_apply_moderation_action(uuid, text, text, integer),
  public.admin_lift_moderation_action(uuid, text),
  public.admin_list_moderation_actions(uuid, text, integer, integer),
  public.admin_update_moderation_rule(text, numeric, text, integer, boolean),
  public.admin_list_reliability_events(uuid, integer, integer),
  public.admin_get_trust_summary(uuid)
  to authenticated;

grant execute on function
  public.report_user(uuid, text, text, jsonb),
  public.report_ride(uuid, text, text, jsonb),
  public.get_my_reports(integer, integer),
  public.submit_appeal(uuid, text),
  public.update_appeal(uuid, text),
  public.get_my_appeals(),
  public.get_my_moderation_status(),
  public.get_trust_summary(),
  public.get_public_trust_summary(uuid),
  public.get_trust_config()
  to authenticated;
