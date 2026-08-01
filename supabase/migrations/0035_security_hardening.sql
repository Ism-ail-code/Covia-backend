-- Covia - Phase 10: security hardening
-- ------------------------------------------------------------------
-- Final lockdown pass:
--   * anon loses execute on the entire admin + internal surface
--     (defense in depth; authenticated grants are unchanged)
--   * the new Phase 10 tables are double-revoked from every client
--     role
--   * audit + monitoring tables are append-only (no INSERT/UPDATE/
--     DELETE policies exist; writes flow only through security
--     definer functions)
--
-- The smoke suite asserts these grants and the RLS behaviour.

-- =============================================================
-- anon: no admin surface, no internal helpers
-- =============================================================
revoke execute on function
  public.is_admin(), public.current_admin_role(),
  public.has_permission(text), public.require_permission(text),
  public.record_audit(text, text, uuid, jsonb, jsonb, jsonb),
  public.record_monitoring_event(text, text, text, jsonb),
  public.account_operational_gate(text),
  public.block_restricted_on_rides(),
  public.admin_list_admin_users(), public.admin_set_admin_role(uuid, text),
  public.admin_remove_admin(uuid),
  public.admin_list_audit_log(uuid, text, text, uuid, timestamptz, timestamptz, integer, integer),
  public.admin_list_verifications(text, text, text),
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
  public.admin_search_users(text, text, text, integer, integer),
  public.admin_get_user_profile(uuid),
  public.admin_get_user_ride_history(uuid, integer, integer),
  public.admin_suspend_user(uuid, text, integer),
  public.admin_ban_user(uuid, text),
  public.admin_reactivate_user(uuid, text),
  public.admin_search_rides(text, text, integer, integer),
  public.admin_get_ride_details(uuid),
  public.admin_get_ride_timeline(uuid),
  public.admin_cancel_ride(uuid, text),
  public.admin_get_case_history(uuid),
  public.admin_get_analytics(),
  public.admin_list_monitoring_events(text, text, integer, integer),
  public.get_platform_health(),
  public.admin_update_safety_config(numeric, integer, integer, integer, integer, boolean, integer, integer)
  from anon;

-- =============================================================
-- Tables: no client access at all
-- =============================================================
revoke all on table
  public.admin_roles,
  public.admin_role_permissions,
  public.admin_users,
  public.admin_audit_log,
  public.monitoring_events
  from anon, authenticated;

-- =============================================================
-- RLS: verified enabled everywhere sensitive
-- =============================================================
alter table public.admin_roles enable row level security;
alter table public.admin_role_permissions enable row level security;
alter table public.admin_users enable row level security;
alter table public.admin_audit_log enable row level security;
alter table public.monitoring_events enable row level security;
