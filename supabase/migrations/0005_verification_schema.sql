-- Covia - identity verification schema
-- ------------------------------------------------------------------
-- Backing tables for the Phase 4 identity verification feature:
--   * verification_submissions  - one row per verification attempt
--                                 (government ID or student status)
--   * verification_audit       - immutable review trail
--   * admin_users              - who is allowed to review submissions
--   * notification_events      - placeholder inbox for review outcomes
--
-- All writes go through security definer functions (see 0007/0008);
-- users and admins never touch these tables directly. Documents are
-- stored as object paths inside the private `verification-documents`
-- bucket (0006) - never as public URLs.

-- ── Submissions ────────────────────────────────────────────────────
create table if not exists public.verification_submissions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  verification_type text not null
    check (verification_type in ('government_id', 'student')),
  government_id_kind text
    check (government_id_kind is null or government_id_kind in ('national_id', 'drivers_license', 'passport')),
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'expired', 'resubmission_requested')),
  submitted_at timestamptz,
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users (id) on delete set null,
  rejection_reason text,
  front_document_url text,
  back_document_url text,
  selfie_url text,
  student_card_url text,
  university_email text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- Each type needs its own required evidence.
  check (
    (verification_type = 'government_id' and front_document_url is not null)
    or (verification_type = 'student' and (student_card_url is not null or university_email is not null))
  ),
  -- Document paths / URLs must look sane.
  check (front_document_url is null or char_length(front_document_url) <= 500),
  check (back_document_url is null or char_length(back_document_url) <= 500),
  check (selfie_url is null or char_length(selfie_url) <= 500),
  check (student_card_url is null or char_length(student_card_url) <= 500),
  check (university_email is null or university_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  -- Only a government ID submission may carry an ID kind.
  check (verification_type <> 'government_id' or government_id_kind is not null)
);

comment on table public.verification_submissions is
  'Identity verification attempts. Document columns hold object paths in the private verification-documents bucket.';

comment on column public.verification_submissions.status is
  'pending | approved | rejected | expired | resubmission_requested';

create index if not exists verification_submissions_user_type_idx
  on public.verification_submissions (user_id, verification_type);
create index if not exists verification_submissions_status_idx
  on public.verification_submissions (status, submitted_at);

-- Only one active submission per (user, type): a user cannot re-submit
-- while one is pending, approved, or awaiting their re-upload.
create unique index if not exists verification_submissions_active_idx
  on public.verification_submissions (user_id, verification_type)
  where status in ('pending', 'approved', 'resubmission_requested');

drop trigger if exists verification_submissions_set_updated_at on public.verification_submissions;
create trigger verification_submissions_set_updated_at
  before update on public.verification_submissions
  for each row
  execute function public.set_updated_at();

-- ── Audit trail ────────────────────────────────────────────────────
create table if not exists public.verification_audit (
  id uuid primary key default gen_random_uuid(),
  submission_id uuid not null references public.verification_submissions (id) on delete cascade,
  action text not null
    check (action in ('submitted', 'approved', 'rejected', 'resubmission_requested', 'expired')),
  performed_by uuid references auth.users (id) on delete set null,
  reason text,
  created_at timestamptz not null default now()
);

create index if not exists verification_audit_submission_idx
  on public.verification_audit (submission_id, created_at);

-- ── Admins ─────────────────────────────────────────────────────────
create table if not exists public.admin_users (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ── Notification placeholders ──────────────────────────────────────
create table if not exists public.notification_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  event_type text not null
    check (event_type in (
      'verification.submitted',
      'verification.approved',
      'verification.rejected',
      'verification.resubmission_requested'
    )),
  payload jsonb not null default '{}'::jsonb,
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists notification_events_user_read_idx
  on public.notification_events (user_id, read_at);

-- ── Row Level Security ─────────────────────────────────────────────
-- No direct writes from the client; everything goes through security
-- definer functions. Users may only read their own submissions.

-- Admin membership check. Security definer so the RLS policies below
-- work even though admin_users itself is RLS-locked (no read policies).
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.admin_users where user_id = auth.uid());
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated;

alter table public.verification_submissions enable row level security;
alter table public.verification_audit enable row level security;
alter table public.admin_users enable row level security;
alter table public.notification_events enable row level security;

drop policy if exists "Users can read their own submissions" on public.verification_submissions;
create policy "Users can read their own submissions"
  on public.verification_submissions
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

drop policy if exists "Users can read their own notifications" on public.notification_events;
create policy "Users can read their own notifications"
  on public.notification_events
  for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- Admin-only reads (the admin RPCs also bypass RLS via security definer,
-- this policy simply allows direct dashboard-style queries).
drop policy if exists "Admins can read all submissions" on public.verification_submissions;
create policy "Admins can read all submissions"
  on public.verification_submissions
  for select
  to authenticated
  using (public.is_admin());

drop policy if exists "Admins can read the audit trail" on public.verification_audit;
create policy "Admins can read the audit trail"
  on public.verification_audit
  for select
  to authenticated
  using (public.is_admin());

drop policy if exists "Admins can read notifications" on public.notification_events;
create policy "Admins can read notifications"
  on public.notification_events
  for select
  to authenticated
  using (public.is_admin());

revoke all on public.verification_submissions from public;
revoke all on public.verification_audit from public;
revoke all on public.admin_users from public;
revoke all on public.notification_events from public;

-- RLS still gates which rows each role sees (own submissions and
-- notifications; admin rows via the policies above).
grant select on public.verification_submissions to authenticated;
grant select on public.verification_audit to authenticated;
grant select on public.notification_events to authenticated;
