-- Covia - Phase 10 follow-up: onboarding progress tracking
-- ------------------------------------------------------------------
-- Persists the onboarding lifecycle on public.profiles so that:
--   * reinstalling the app cannot bypass onboarding (state lives in the
--     database, not AsyncStorage)
--   * closing the app mid-setup resumes at the exact step
--
-- Lifecycle (driven by the mobile app):
--   onboard  → post-verification welcome screens
--   profile  → profile setup (create-profile)
--   verify   → identity verification introduction
--   complete → normal app (tabs)
--
-- New signups start at 'onboard' (column default). Existing rows are
-- migrated to 'complete' so current users are not sent backwards through
-- onboarding. Idempotent and safe to re-run.

alter table public.profiles
  add column if not exists onboarding_step text not null default 'onboard',
  add column if not exists onboarding_completed boolean not null default false;

alter table public.profiles
  add constraint profiles_onboarding_step_values
    check (onboarding_step in ('onboard', 'profile', 'verify', 'complete')),
  add constraint profiles_onboarding_completed_consistent
    check (
      (onboarding_completed and onboarding_step = 'complete')
      or
      (not onboarding_completed and onboarding_step <> 'complete')
    );

-- Existing users stay in the app (never forced back through onboarding).
update public.profiles
  set onboarding_step = 'complete', onboarding_completed = true
  where onboarding_step = 'onboard' and onboarding_completed = false
    and exists (select 1 from auth.users u where u.id = public.profiles.id);
