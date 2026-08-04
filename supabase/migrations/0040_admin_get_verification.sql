-- Covia - Phase 7: admin_get_verification single-item fetch
-- ------------------------------------------------------------------
-- The verification detail page previously fetched ALL verifications
-- via admin_list_verifications and filtered client-side. This new
-- RPC fetches only the specific verification by ID.

-- =============================================================
-- Single verification fetch
-- =============================================================
create or replace function public.admin_get_verification(p_id uuid)
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

  return query
    select s.id, s.user_id, p.email, p.display_name, s.verification_type,
           s.government_id_kind, s.status, s.submitted_at, s.reviewed_at,
           s.reviewed_by, s.rejection_reason, s.front_document_url,
           s.back_document_url, s.selfie_url, s.student_card_url,
           s.university_email, s.created_at
    from public.verification_submissions s
    left join public.profiles p on p.id = s.user_id
    where s.id = p_id;
end;
$$;

-- =============================================================
-- Grants
-- =============================================================
revoke all on function public.admin_get_verification(uuid) from public;

grant execute on function
  public.admin_get_verification(uuid)
  to authenticated;
