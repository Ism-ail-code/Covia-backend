-- Covia - Phase 10: immutable admin audit log
-- ------------------------------------------------------------------
-- Every administrative action writes an immutable row to
-- admin_audit_log: who, what, target, and old/new values where they
-- matter. The table has no INSERT/UPDATE/DELETE policies and no client
-- grants, so the only writer is the security definer record_audit().
--
-- All admin functions from Phases 4 and 9 are recreated here so the
-- whole surface is (a) gated on the Phase 10 RBAC permissions and
-- (b) audited. Signatures are unchanged, so existing clients keep
-- working; only the permission model inside the bodies changed.

-- =============================================================
-- Audit table
-- =============================================================
create table if not exists public.admin_audit_log (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid not null references auth.users (id) on delete restrict,
  actor_role text,
  action text not null check (char_length(action) between 1 and 80),
  target_type text check (target_type is null or char_length(target_type) <= 60),
  target_id uuid,
  old_values jsonb not null default '{}'::jsonb,
  new_values jsonb not null default '{}'::jsonb,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists admin_audit_log_actor_idx
  on public.admin_audit_log (actor_user_id, created_at desc);
create index if not exists admin_audit_log_target_idx
  on public.admin_audit_log (target_type, target_id, created_at desc);
create index if not exists admin_audit_log_action_idx
  on public.admin_audit_log (action, created_at desc);
create index if not exists admin_audit_log_created_idx
  on public.admin_audit_log (created_at desc);

comment on table public.admin_audit_log is
  'Immutable record of every administrative action. Writes only via record_audit().';

alter table public.admin_audit_log enable row level security;

drop policy if exists "admins read audit log" on public.admin_audit_log;
create policy "admins read audit log"
  on public.admin_audit_log
  for select
  to authenticated
  using (public.has_permission('audit.view'));

revoke all on public.admin_audit_log from public;
revoke all on table public.admin_audit_log from anon, authenticated;

-- =============================================================
-- record_audit: the only writer
-- =============================================================
create or replace function public.record_audit(
  p_action text,
  p_target_type text default null,
  p_target_id uuid default null,
  p_old_values jsonb default '{}'::jsonb,
  p_new_values jsonb default '{}'::jsonb,
  p_details jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_actor uuid := auth.uid();
  v_id uuid;
begin
  if v_actor is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  insert into public.admin_audit_log (
    actor_user_id, actor_role, action, target_type, target_id,
    old_values, new_values, details
  ) values (
    v_actor, public.current_admin_role(), p_action, p_target_type, p_target_id,
    coalesce(p_old_values, '{}'::jsonb), coalesce(p_new_values, '{}'::jsonb),
    coalesce(p_details, '{}'::jsonb)
  ) returning id into v_id;
  return v_id;
end;
$$;

-- =============================================================
-- Read API
-- =============================================================
create or replace function public.admin_list_audit_log(
  p_actor_user_id uuid default null,
  p_action text default null,
  p_target_type text default null,
  p_target_id uuid default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_page integer default 1,
  p_page_size integer default 50
)
returns table (
  id uuid,
  actor_user_id uuid,
  actor_name text,
  actor_role text,
  action text,
  target_type text,
  target_id uuid,
  old_values jsonb,
  new_values jsonb,
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
  perform public.require_permission('audit.view');

  return query
    select l.id, l.actor_user_id, p.display_name, l.actor_role,
           l.action, l.target_type, l.target_id, l.old_values, l.new_values,
           l.details, l.created_at,
           count(*) over ()::bigint
      from public.admin_audit_log l
      left join public.profiles p on p.id = l.actor_user_id
     where (p_actor_user_id is null or l.actor_user_id = p_actor_user_id)
       and (p_action is null or l.action = p_action)
       and (p_target_type is null or l.target_type = p_target_type)
       and (p_target_id is null or l.target_id = p_target_id)
       and (p_from is null or l.created_at >= p_from)
       and (p_to is null or l.created_at <= p_to)
     order by l.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

-- =============================================================
-- Phase 4 recreation: verification admin surface
-- =============================================================
create or replace function public.admin_list_verifications(p_status text default 'pending')
returns table (
  id uuid,
  user_id uuid,
  user_email text,
  user_display_name text,
  verification_type text,
  government_id_kind text,
  status text,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid,
  rejection_reason text,
  front_document_url text,
  back_document_url text,
  selfie_url text,
  student_card_url text,
  university_email text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_permission('verification.view');

  if p_status not in ('pending', 'approved', 'rejected', 'expired', 'resubmission_requested', 'all') then
    raise exception 'Unknown status filter: %', p_status;
  end if;

  return query
    select s.id, s.user_id, p.email, p.display_name, s.verification_type,
           s.government_id_kind, s.status, s.submitted_at, s.reviewed_at,
           s.reviewed_by, s.rejection_reason, s.front_document_url,
           s.back_document_url, s.selfie_url, s.student_card_url,
           s.university_email, s.created_at
    from public.verification_submissions s
    left join public.profiles p on p.id = s.user_id
    where p_status = 'all' or s.status = p_status
    order by s.submitted_at desc nulls last;
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
  v_old_status text;
  v_event text;
begin
  perform public.require_permission('verification.review');
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
  v_old_status := v_sub.status;

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

  perform public.record_audit(
    'verification.review', 'verification_submission', p_submission_id,
    jsonb_build_object('status', v_old_status),
    jsonb_build_object('status', v_sub.status),
    jsonb_build_object('action', p_action, 'reason', p_reason)
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

  return v_sub;
end;
$$;

-- =============================================================
-- Phase 9 recreation: trust / moderation admin surface
-- =============================================================
create or replace function public.admin_get_trust_summary(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_permission('user.view');
  return public.build_trust_summary(p_user_id);
end;
$$;

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
stable
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 50);
  v_page integer := greatest(p_page, 1);
begin
  perform public.require_permission('report.view');

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
  perform public.require_permission('report.review');

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

  perform public.record_audit(
    'report.review', 'report', p_report_id,
    jsonb_build_object('status', v_report.status, 'is_confirmed', v_report.is_confirmed),
    jsonb_build_object('status', case when p_confirm then 'resolved' else 'dismissed' end,
                       'is_confirmed', p_confirm, 'resolution_note', p_note),
    jsonb_build_object('target_type', v_report.target_type,
                       'target_user_id', v_report.target_user_id,
                       'target_ride_id', v_report.target_ride_id)
  );

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
stable
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 50);
  v_page integer := greatest(p_page, 1);
begin
  perform public.require_permission('appeal.view');

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
  perform public.require_permission('appeal.decide');

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

  perform public.record_audit(
    'appeal.decide', 'appeal', p_appeal_id,
    jsonb_build_object('status', v_appeal.status),
    jsonb_build_object('status', case when p_approve then 'approved' else 'rejected' end,
                       'approved', p_approve, 'note', p_note,
                       'moderation_action_id', v_appeal.moderation_action_id)
  );

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
  perform public.require_permission('moderation.apply');
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

  perform public.record_audit(
    'moderation.apply', 'user', p_user_id,
    null,
    jsonb_build_object('moderation_action_id', v_action.id,
                       'action_type', v_action.action_type,
                       'reason', p_reason,
                       'duration_hours', p_duration_hours)
  );

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
declare
  v_old public.moderation_actions;
begin
  perform public.require_permission('moderation.apply');

  select * into v_old from public.moderation_actions where id = p_action_id;

  update public.moderation_actions
     set status = 'lifted',
         revoked_by = auth.uid(),
         revoked_at = now(),
         revoke_reason = p_reason
   where id = p_action_id and status = 'active';

  if not found then
    raise exception 'Moderation action not found or not active';
  end if;

  perform public.record_audit(
    'moderation.lift', 'moderation_action', p_action_id,
    jsonb_build_object('status', v_old.status),
    jsonb_build_object('status', 'lifted', 'revoke_reason', p_reason)
  );
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
stable
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 50);
  v_page integer := greatest(p_page, 1);
begin
  perform public.require_permission('config.view');

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
  v_old public.moderation_rules;
  v_rule public.moderation_rules;
begin
  perform public.require_permission('moderation.configure');
  if p_action_type is not null and p_action_type not in (
    'warning', 'temporary_restriction', 'ride_creation_disabled',
    'ride_joining_disabled', 'suspension'
  ) then
    raise exception 'Unknown moderation action';
  end if;

  select * into v_old from public.moderation_rules where rule_name = p_rule_name;

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

  perform public.record_audit(
    'moderation.rule_update', 'moderation_rule', null,
    jsonb_build_object('rule_name', p_rule_name, 'threshold', v_old.threshold,
                       'action_type', v_old.action_type, 'enabled', v_old.enabled),
    jsonb_build_object('rule_name', p_rule_name, 'threshold', v_rule.threshold,
                       'action_type', v_rule.action_type, 'enabled', v_rule.enabled)
  );

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
  perform public.require_permission('config.view');

  return query
    select mr.rule_name, mr.threshold, mr.action_type, mr.duration_hours,
           mr.severity, mr.enabled,
           count(*) over ()::bigint
      from public.moderation_rules mr
     order by mr.rule_name
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

-- =============================================================
-- Phase 10 recreation: RBAC management + audit
-- =============================================================
create or replace function public.admin_set_admin_role(
  p_user_id uuid,
  p_role_name text
)
returns public.admin_users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.admin_users;
  v_old_role text;
  v_actor uuid := auth.uid();
begin
  perform public.require_permission('admin.manage');
  if v_actor is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.admin_roles where role_name = p_role_name) then
    raise exception 'Unknown admin role: %', p_role_name;
  end if;
  if p_user_id = v_actor then
    raise exception 'You cannot change your own role';
  end if;

  select role_name into v_old_role from public.admin_users where user_id = p_user_id;

  insert into public.admin_users (user_id, role_name)
  values (p_user_id, p_role_name)
  on conflict (user_id) do update
    set role_name = excluded.role_name
  returning * into v_row;

  perform public.record_audit(
    'admin.set_role', 'user', p_user_id,
    jsonb_build_object('role', v_old_role),
    jsonb_build_object('role', v_row.role_name)
  );

  return v_row;
end;
$$;

create or replace function public.admin_remove_admin(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row public.admin_users;
  v_actor uuid := auth.uid();
  v_super_remaining bigint;
begin
  perform public.require_permission('admin.manage');
  if v_actor is null then
    raise exception 'Not authenticated' using errcode = '28000';
  end if;
  if p_user_id = v_actor then
    raise exception 'You cannot remove yourself from the admin team';
  end if;

  select * into v_row from public.admin_users where user_id = p_user_id;
  if not found then
    raise exception 'That user is not an admin';
  end if;

  if v_row.role_name = 'super_admin' then
    select count(*) into v_super_remaining
      from public.admin_users
     where role_name = 'super_admin';
    if v_super_remaining <= 1 then
      raise exception 'Covia must keep at least one super admin';
    end if;
  end if;

  delete from public.admin_users where user_id = p_user_id;

  perform public.record_audit(
    'admin.remove', 'user', p_user_id,
    jsonb_build_object('role', v_row.role_name),
    null,
    null
  );
end;
$$;

-- =============================================================
-- Grants
-- =============================================================
revoke all on function
  public.record_audit, public.admin_list_audit_log,
  public.admin_list_verifications, public.admin_review_verification,
  public.admin_get_trust_summary, public.admin_list_reports,
  public.admin_review_report, public.admin_list_appeals,
  public.admin_decide_appeal, public.admin_apply_moderation_action,
  public.admin_lift_moderation_action, public.admin_list_moderation_actions,
  public.admin_update_moderation_rule, public.admin_list_reliability_events,
  public.admin_list_moderation_rules, public.admin_set_admin_role,
  public.admin_remove_admin
  from public;

-- record_audit is internal: only the postgres owner may call it.
grant execute on function
  public.admin_list_audit_log(uuid, text, text, uuid, timestamptz, timestamptz, integer, integer),
  public.admin_list_verifications(text),
  public.admin_review_verification(uuid, text, text),
  public.admin_get_trust_summary(uuid),
  public.admin_list_reports(text, integer, integer),
  public.admin_review_report(uuid, boolean, text),
  public.admin_list_appeals(text, integer, integer),
  public.admin_decide_appeal(uuid, boolean, text),
  public.admin_apply_moderation_action(uuid, text, text, integer),
  public.admin_lift_moderation_action(uuid, text),
  public.admin_list_moderation_actions(uuid, text, integer, integer),
  public.admin_update_moderation_rule(text, numeric, text, integer, boolean),
  public.admin_list_reliability_events(uuid, integer, integer),
  public.admin_list_moderation_rules(integer, integer),
  public.admin_set_admin_role(uuid, text),
  public.admin_remove_admin(uuid)
  to authenticated;
