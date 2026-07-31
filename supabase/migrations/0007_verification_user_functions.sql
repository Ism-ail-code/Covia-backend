-- Covia - verification: user functions
-- ------------------------------------------------------------------
-- Everything a normal user can do with verification:
--   * submit_verification       - start a government ID or student check
--   * resubmit_verification     - re-upload after a rejection
--   * get_my_verification       - fetch the current submission for a type
--   * is_user_verified          - gate for ride creation / joining
-- All are security definer so they can insert into the RLS-locked
-- tables; they validate the caller is authenticated via auth.uid().

-- ── Submit ─────────────────────────────────────────────────────────
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

  return v_sub;
end;
$$;

-- ── Resubmit after rejection / re-upload request ───────────────────
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

  return v_sub;
end;
$$;

-- ── Read my submission for a type ──────────────────────────────────
create or replace function public.get_my_verification(p_verification_type text)
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
  where user_id = v_user and verification_type = p_verification_type
  order by created_at desc
  limit 1;
  return v_sub;
end;
$$;

-- ── Rides gate: has any method been approved? ──────────────────────
create or replace function public.is_user_verified()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.verification_submissions
    where user_id = auth.uid() and status = 'approved'
  );
$$;

-- ── Grants ─────────────────────────────────────────────────────────
revoke all on function public.submit_verification(text, text, text, text, text, text, text) from public;
revoke all on function public.resubmit_verification(uuid, text, text, text, text, text, text) from public;
revoke all on function public.get_my_verification(text) from public;
revoke all on function public.is_user_verified() from public;

grant execute on function public.submit_verification(text, text, text, text, text, text, text) to authenticated;
grant execute on function public.resubmit_verification(uuid, text, text, text, text, text, text) to authenticated;
grant execute on function public.get_my_verification(text) to authenticated;
grant execute on function public.is_user_verified() to authenticated;
