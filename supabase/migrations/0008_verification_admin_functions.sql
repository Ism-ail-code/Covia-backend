-- Covia - verification: admin functions
-- ------------------------------------------------------------------
-- Admin-only review backend. There is no admin UI in this phase; the
-- functions are the API surface for a future dashboard or the NestJS
-- service. Admin membership lives in public.admin_users (check with
-- public.is_admin(), defined in 0005).
--
--   * admin_list_verifications(status)  - queue for review
--   * admin_review_verification(...)    - approve / reject / ask for
--                                         re-upload, keeps an audit
--                                         trail and notifies the user
--
-- On approval the user's profile flags are flipped so the profile
-- badge and the ride-creation gate (is_user_verified) light up.

-- ── Review queue ───────────────────────────────────────────────────
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
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Admin access required' using errcode = '42501';
  end if;

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

-- ── Review (approve / reject / request resubmission) ───────────────
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

  return v_sub;
end;
$$;

-- ── Grants ─────────────────────────────────────────────────────────
revoke all on function public.admin_list_verifications(text) from public;
revoke all on function public.admin_review_verification(uuid, text, text) from public;

-- Only admins can execute the review backend. Grant to `authenticated`
-- so RPC calls work, then rely on the is_admin() guard inside.
grant execute on function public.admin_list_verifications(text) to authenticated;
grant execute on function public.admin_review_verification(uuid, text, text) to authenticated;
