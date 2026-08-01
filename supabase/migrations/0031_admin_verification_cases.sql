-- Covia - Phase 10: verification review tools + case history
-- ------------------------------------------------------------------
-- The verification queue gains search + verification-type filters so
-- reviewers can work pending / approved / rejected / resubmission
-- buckets. admin_get_case_history() assembles one user's full
-- moderation dossier (verification, reports both ways, moderation
-- actions, appeals, reliability events, ride activity) for a single
-- dashboard call.

-- =============================================================
-- Verification queue with search + type filters
-- =============================================================
drop function if exists public.admin_list_verifications(text);
create or replace function public.admin_list_verifications(
  p_status text default 'pending',
  p_search text default null,
  p_verification_type text default null
)
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
declare
  v_query text := nullif(btrim(coalesce(p_search, '')), '');
begin
  perform public.require_permission('verification.view');

  if p_status not in ('pending', 'approved', 'rejected', 'expired', 'resubmission_requested', 'all') then
    raise exception 'Unknown status filter: %', p_status;
  end if;
  if p_verification_type is not null
     and p_verification_type not in ('government_id', 'student') then
    raise exception 'Unknown verification type filter: %', p_verification_type;
  end if;

  return query
    select s.id, s.user_id, p.email, p.display_name, s.verification_type,
           s.government_id_kind, s.status, s.submitted_at, s.reviewed_at,
           s.reviewed_by, s.rejection_reason, s.front_document_url,
           s.back_document_url, s.selfie_url, s.student_card_url,
           s.university_email, s.created_at
    from public.verification_submissions s
    left join public.profiles p on p.id = s.user_id
    where (p_status = 'all' or s.status = p_status)
      and (v_query is null
           or p.display_name ilike '%' || v_query || '%'
           or p.email ilike '%' || v_query || '%')
      and (p_verification_type is null
           or s.verification_type = p_verification_type)
    order by s.submitted_at desc nulls last;
end;
$$;

-- =============================================================
-- Case history (one dossier per user)
-- =============================================================
create or replace function public.admin_get_case_history(p_user_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_verifications jsonb;
  v_reports_filed jsonb;
  v_reports_received jsonb;
  v_actions jsonb;
  v_appeals jsonb;
  v_reliability jsonb;
  v_rides jsonb;
begin
  perform public.require_permission('user.view');
  if not exists (select 1 from public.profiles where id = p_user_id) then
    raise exception 'User not found';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', s.id, 'verification_type', s.verification_type,
           'status', s.status, 'submitted_at', s.submitted_at,
           'reviewed_at', s.reviewed_at, 'rejection_reason', s.rejection_reason
         ) order by s.submitted_at desc), '[]'::jsonb)
    into v_verifications
    from public.verification_submissions s
   where s.user_id = p_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'target_type', r.target_type,
           'target_user_id', r.target_user_id, 'target_ride_id', r.target_ride_id,
           'reason', r.reason, 'status', r.status,
           'is_confirmed', r.is_confirmed, 'created_at', r.created_at,
           'resolution_note', r.resolution_note
         ) order by r.created_at desc), '[]'::jsonb)
    into v_reports_filed
    from public.reports r
   where r.reporter_user_id = p_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', r.id, 'reporter_user_id', r.reporter_user_id,
           'reporter_name', pr.display_name,
           'reason', r.reason, 'status', r.status,
           'is_confirmed', r.is_confirmed, 'created_at', r.created_at,
           'resolution_note', r.resolution_note
         ) order by r.created_at desc), '[]'::jsonb)
    into v_reports_received
    from public.reports r
    left join public.profiles pr on pr.id = r.reporter_user_id
   where r.target_user_id = p_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', ma.id, 'action_type', ma.action_type,
           'severity', ma.severity, 'status', ma.status,
           'reason', ma.reason, 'source', ma.source,
           'starts_at', ma.starts_at, 'ends_at', ma.ends_at,
           'created_at', ma.created_at
         ) order by ma.created_at desc), '[]'::jsonb)
    into v_actions
    from public.moderation_actions ma
   where ma.user_id = p_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', a.id, 'moderation_action_id', a.moderation_action_id,
           'reason', a.reason, 'status', a.status,
           'moderator_note', a.moderator_note,
           'decided_at', a.decided_at, 'created_at', a.created_at
         ) order by a.created_at desc), '[]'::jsonb)
    into v_appeals
    from public.appeals a
   where a.user_id = p_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'id', e.id, 'event_type', e.event_type,
           'weight', e.weight, 'reason', e.reason,
           'ride_id', e.ride_id, 'created_at', e.created_at
         ) order by e.created_at desc), '[]'::jsonb)
    into v_reliability
    from public.reliability_events e
   where e.user_id = p_user_id;

  select coalesce(jsonb_agg(jsonb_build_object(
           'ride_id', r.id, 'role', rp.role,
           'origin', r.origin, 'destination', r.destination,
           'ride_status', r.ride_status,
           'departure_time', r.departure_time,
           'created_at', r.created_at
         ) order by r.created_at desc), '[]'::jsonb)
    into v_rides
    from public.rides r
    join public.ride_participants rp on rp.ride_id = r.id
   where rp.user_id = p_user_id;

  return jsonb_build_object(
    'user_id', p_user_id,
    'verifications', v_verifications,
    'reports_filed', v_reports_filed,
    'reports_received', v_reports_received,
    'moderation_actions', v_actions,
    'appeals', v_appeals,
    'reliability_events', v_reliability,
    'rides', v_rides
  );
end;
$$;

-- =============================================================
-- Grants
-- =============================================================
revoke all on function public.admin_list_verifications, public.admin_get_case_history from public;

grant execute on function
  public.admin_list_verifications(text, text, text),
  public.admin_get_case_history(uuid)
  to authenticated;
