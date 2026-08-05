# Changelog

All notable changes to the Covia backend are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/) conventions.

## [Unreleased]

### Security — Full database lockdown (2026-08-05)

- **Migration `0043_full_database_lockdown.sql`** — Phase 12 hardening pass:
  - RLS re-asserted on every public table (drift guard).
  - `REVOKE CREATE ON SCHEMA public` from `anon`, `authenticated`, `public` —
    clients can no longer create objects.
  - `ALTER DEFAULT PRIVILEGES` revoked for client roles — future
    tables/sequences/functions are never auto-granted.
  - `anon` now has zero table and zero function privileges in `public`
    (removes pgcrypto/pg_trgm defaults and trigger-helper exposure).
  - 12 internal cron/trigger helpers are no longer executable by
    `authenticated` (`handle_new_user`, `set_updated_at`,
    `normalize_username`, `handle_account_notifications`,
    `notify_from_ride_timeline`, `broadcast_covia_event`,
    `sync_chat_from_ride_timeline`, `broadcast_chat_message`,
    `sync_safety_from_ride_timeline`, `is_valid_notification_type`,
    `expire_overdue_rides`, `expire_moderation_actions`).
  - RLS enabled on `storage.buckets` and `storage.objects`.
  - `service_role` (NestJS backend) and the authenticated RPC surface
    granted in 0001–0041 are untouched.
- **Smoke suite now 760 checks** (was 739): cron/system functions are
  exercised in owner context (matching their pg_cron execution model),
  plus new lockdown assertions (RLS everywhere, no CREATE, anon zero
  privileges, internal functions not client-callable, storage RLS,
  probe-table grants, default privileges).
- Updated `docs/SECURITY.md`, `docs/RLS_DEPLOYMENT_GUIDE.md`.

### Security — RLS fix for `reserved_usernames` (2026-08-05)

- **Critical fix for Supabase Security Advisor rule `rls_disabled_in_public`:**
  - `public.reserved_usernames` (internal username lookup) was created in
    migration 0002 without RLS; combined with Supabase's default grants this
    made the table readable/writable by anyone with the anon key.
  - Migration `0042_rls_reserved_usernames.sql` enables RLS (deny by default,
    no policies), revokes `anon`/`authenticated`/`public` grants, and keeps
    `FORCE ROW LEVEL SECURITY` off so the SECURITY DEFINER functions
    `is_username_available()` and `normalize_username()` keep working.
  - Added 14 regression assertions to `scripts/sql-smoke.mjs` (smoke suite now
    739 checks) covering the RLS flag, grant revocation and direct-access
    denial for both client roles.
  - Added `docs/RLS_AUDIT_REPORT.md` with the full 34-table public-schema audit.

### Phase 11 — Closed Beta Launch & Feedback System (2026-08-04)

- **In-app feedback system:**
  - Created `feedback.tsx` screen with category selection, description, screenshot support
  - Feedback categories: Bug Report, Feature Request, UI Issue, General Feedback
  - Automatic device diagnostics attached to every submission
  - Local storage with Supabase sync when online
  - Added "Send feedback" link to Settings screen

- **Diagnostics collection:**
  - Created `src/lib/diagnostics.ts` — auto-collects app version, OS, device model, locale
  - Attached to bug reports and analytics events

- **Feature flags system:**
  - Created `src/lib/featureFlags.ts` — simple on/off toggles with AsyncStorage persistence
  - 10 predefined flags: whatsapp_verification, smart_fare, standby_pool, ai_matching, etc.
  - Bulk sync support for remote config

- **Remote configuration:**
  - Created `src/lib/remoteConfig.ts` — centralized config values with 5-min cache
  - Config keys: maintenance_mode, min_app_version, announcement_*, feedback_enabled, etc.
  - Version compatibility checking

- **Structured logging:**
  - Created `src/lib/logger.ts` — debug/info/warn/error levels with AsyncStorage persistence
  - 500-entry ring buffer, export for bug reports
  - Configurable minimum log level

- **Release versioning:**
  - Created `src/lib/version.ts` — semantic versioning helpers from app.json
  - Display version in Settings (dynamic, not hardcoded)
  - Version comparison and compatibility checking

- **Beta dashboard:**
  - Created admin `/beta` route with live metrics
  - Shows: users, rides, completions, verifications, feedback, bug reports
  - Auto-refreshes every 30 seconds
  - Quick actions linking to verification queue, reports, monitoring

- **Documentation generated:**
  - `BETA_OPERATIONS.md` — operational guide for managing the beta
  - `SUPPORT_GUIDE.md` — support team guide with common issues and FAQ
  - `VERSIONING_GUIDE.md` — semantic versioning and build management
  - `RELEASE_PROCESS.md` — step-by-step release process

### Phase 10 — Closed Beta Preparation, QA & Launch (2026-08-04)

- **Code quality fixes:**
  - Created `ErrorBoundary` component wrapping root layout — render crashes now show recovery UI instead of white screen
  - Extracted duplicated `naira` helper to shared `src/lib/format.ts` — removed 7 independent copies across mobile
  - Removed 3 unused safety service exports (`setPlannedRoute`, `suspendRideMonitoring`, `resumeRideMonitoring`)
  - Removed dead `types.ts` file (153 lines) from admin console
  - Removed dead `Brand` component from admin console
  - Removed dead `configuration.ts` file from backend

- **Accessibility improvements:**
  - Fixed color contrast: `mutedForeground` darkened (#6a727e → #535d6b) for WCAG AA compliance
  - Fixed color contrast: `success` darkened (#00a062 → #008a55) for successSoft backgrounds
  - Fixed color contrast: `destructive` darkened (#db2a3d → #c92031) for destructiveSoft backgrounds
  - Checkbox: touch target increased (16→20px + hitSlop), added `accessibilityRole="checkbox"` + `accessibilityState`
  - TopBar back button: touch target increased (40→44px)
  - BottomNav: added `accessibilityRole="tab"` + `accessibilityState={{ selected }}` + `accessibilityLabel`
  - Tabs: added `accessibilityRole="tab"` + `accessibilityState={{ selected }}`
  - Progress: added `accessibilityRole="progressbar"` + `accessibilityState` + `accessibilityValue`
  - BottomSheet: added `accessibilityViewIsModal` to Modal
  - Dialog: added `accessibilityViewIsModal` to Modal

- **New abstractions:**
  - `src/lib/analytics.ts` — Centralized analytics layer with 30+ event definitions, provider interface, dev implementation. Ready for PostHog/Mixpanel/Amplitude integration
  - `src/lib/crashLogger.ts` — Centralized crash logging with provider interface, global error handler, breadcrumb support. Ready for Sentry/Bugsnag integration

- **Documentation generated:**
  - `QA_REPORT.md` — Complete end-to-end QA report across all flows
  - `BUG_FIX_SUMMARY.md` — Summary of all bugs found and fixed
  - `CODE_CLEANUP_REPORT.md` — Dead code removal and cleanup report
  - `ACCESSIBILITY_REPORT.md` — Comprehensive accessibility audit
  - `BETA_TESTING_GUIDE.md` — User-friendly guide for beta testers
  - `BUG_REPORT_TEMPLATE.md` — Structured template for bug reports
  - `KNOWN_ISSUES.md` — 12 documented known issues
  - `RELEASE_NOTES.md` — Version 1.0.0-beta.1 release notes
  - `TEST_SCENARIOS.md` — 47 test scenarios across 9 categories
  - `ANALYTICS_ARCHITECTURE.md` — Analytics abstraction documentation
  - `CRASH_LOGGING_ARCHITECTURE.md` — Crash logging abstraction documentation
  - `FINAL_PHASE10_REPORT.md` — Comprehensive Phase 10 final report

- **Build verification:** All 3 projects (`covia-mobile`, `covia-backend`, `covia-admin`) compile clean (`tsc --noEmit`)

### Phase 9 — Performance Optimization & Closed Beta Prep (2026-08-04)

- **Mobile performance optimizations:**
  - Converted `chat.tsx` from `ScrollView`+`.map` to `FlatList` for virtualized message rendering
  - Converted `notifications.tsx` from `ScrollView`+`.map` to `FlatList` for virtualized notification list
  - Converted `activity.tsx` from `ScrollView`+`.map` to `FlatList` for virtualized ride history
  - Converted `explore.tsx` from `ScrollView`+`.map` to `FlatList` for virtualized ride search results
  - Added `React.memo` to `Bubble`, `NotificationItem`, `HistoryCard`, and `RideCard` components to prevent unnecessary re-renders
  - Stagger animations now only apply to visible items (FlatList virtualization)

- **Database performance:**
  - New migration `0041_performance_phase9.sql` with 5 targeted indexes:
    - `message_reads_message_id_idx` — accelerates chat read-count subqueries
    - `notifications_data_idx` — GIN index on JSONB data column for ride_id lookups
    - `rides_search_active_idx` — partial index for active ride search (published/full + visibility)
    - `ride_participants_member_idx` — covers `is_ride_member()` visibility checks
    - `verification_submissions_status_submitted_idx` — covers admin verification queue pagination

- **Production build configuration:**
  - Created `eas.json` with 3 build profiles: development (simulator), preview (internal), production (store)
  - Updated `app.json` with `ios.bundleIdentifier` and `android.package` (`app.covia.mobile`)
  - Added `splash` configuration to `app.json` (splash screen during app load)
  - Created `.env.production` template for production builds

### Phase 8 — Production Security Audit & Hardening (2026-08-04)

- **Security audit (14 tasks completed):**
  - Task 1: Authentication audit — PKCE flows, session lifecycle, deep link validation
  - Task 2: Authorization & RBAC audit — 4 roles, 17 permissions, server-side enforcement
  - Task 3: Supabase RLS audit — 27 tables, 40+ policies, zero client grants on admin tables
  - Task 4: Database integrity — 40+ FKs, 30+ unique, 40+ check constraints, 40+ indexes
  - Task 5: RPC security — 95+ functions, all SECURITY DEFINER, parameterized queries
  - Task 6: Storage security — 3 buckets, 9 storage policies, signed URLs (5-min TTL)
  - Task 7: API security — Helmet, CORS, rate limiting, validation pipe, safe error responses
  - Task 8: Input validation — CHECK constraints, PL/pgSQL validation, client-side checks
  - Task 9: Secrets & environment — .gitignore coverage, no service role key in clients
  - Task 10: Logging & audit — header redaction, admin audit trail, request ID tracing
  - Task 11: Dependency audit — 0 critical/high vulnerabilities, moderate Expo transitive
  - Task 12: Production configuration — CORS lockdown, Swagger disabled, PKCE configured
  - Task 13: Penetration testing — 14 scenarios, all critical/high blocked
  - Task 14: Security performance — RLS optimization, indexed policy lookups

- **Security fixes applied:**
  - Root `.gitignore` created to prevent accidental secret commits
  - Production CORS blocks all origins if `CORS_ORIGINS` not configured
  - Admin route guards added to `/standby` and `/tickets` pages
  - Input `maxLength=500` on all admin free-text fields
  - Client-side login rate limiting with exponential backoff (mobile + admin)
  - Database error messages sanitized (no raw PostgreSQL errors to clients)

- **Documentation generated:**
  - `SECURITY_AUDIT.md` — comprehensive audit report with findings and resolutions
  - `SECURITY_CHECKLIST.md` — 103-item checklist across 12 categories
  - `PENETRATION_TEST_REPORT.md` — 14 test scenarios with detailed results
  - `PRODUCTION_READINESS.md` — scores, requirements, and approval
  - `KNOWN_LIMITATIONS.md` — deferred features, technical debt, beta limitations

- **Scores:** Security 8.5/10, Production Readiness 8.0/10
- **Status:** Approved for closed beta deployment

### Phase 7 — Bug Fix & Stabilization Sprint (2026-08-04)

- **Mobile app stabilization:**
  - Added unmount guards in `activity.tsx` and `ride/[rideId].tsx` to prevent state updates after component unmount (BUG-007, BUG-008)
  - Removed no-op `useMemo` in `home.tsx` (BUG-010)
  - Added chip toggle behavior in `explore.tsx` - tapping active chip resets to "All" (BUG-011)
- **Admin console:**
  - Fixed `SafetyConfigRow.id` type from `boolean` to `string` (BUG-003)
  - Split shared reason state in user detail page (BUG-004)
  - Added `.catch()` handler for unhandled promise rejection in auth (BUG-005)
  - Removed hardcoded badge counts in app shell (BUG-006)
- **Documentation:**
  - Created `STABILIZATION_REPORT.md` with bug fix summary
  - Created `RELEASE_READINESS.md` with beta readiness checklist
  - Updated `PROJECT_CONTEXT.md` with Phase 7 status
- **Build verification:**
  - All projects compile clean (`tsc --noEmit`)
  - All projects build successfully
  - No new lint errors introduced

### Auth & onboarding — phone verification removed (2026-08-03, mobile + docs)

- The phone number is collected as a **required, unverified** contact field
  during onboarding (register screen) and stored on `public.profiles.phone`.
  **No schema change** — the column already exists and stays nullable; the
  signup trigger (0001) still copies `phone` from signup metadata.
- Email confirmation remains the only account verification method (untouched).
- Removed from the mobile client: the `"phone"` member of the `Verification`
  badge type (`src/types/verification.ts`), the Phone verification badge
  (`src/components/app/Badges.tsx`), and the stale "Email or phone" login
  label (login is email + password only).
- Validation is now shared and modular: `PHONE_PATTERN` / `isValidPhone` /
  `validatePhone` in `src/lib/validation.ts` (reused by emergency contacts).
  WhatsApp/SMS verification can be added in a future phase on top of
  `profiles.phone` without refactoring the email flow.
- Docs: new `AUTH_FLOW.md`, updated `PROJECT_CONTEXT.md`.

### Phase 10 — Admin dashboard backend (RBAC, user/ride management, analytics, monitoring, hardening)

- `supabase/migrations/0027_admin_rbac.sql` — role-based access control:
  `admin_roles` (super_admin / admin / moderator / support_agent), the
  `admin_role_permissions` matrix (every role × permission pair),
  `admin_users.role_name` (default `support_agent`); helpers
  `is_admin()` (now "member of any admin role", backwards compatible
  with every earlier gate), `has_permission(text)`,
  `require_permission(text)` (raises 42501, super_admin bypasses),
  `current_admin_role()`; role-management RPCs `admin_set_admin_role`
  (can't change your own role; support agents can't escalate),
  `admin_remove_admin` (can't remove yourself; Covia must always keep
  one super admin), `admin_list_admin_users`.
- `supabase/migrations/0028_audit_log.sql` — append-only
  `admin_audit_log` (actor, actor_role snapshot, action, target,
  old/new values, metadata) written exclusively by security-definer
  `record_audit()` (no client grants); `admin_list_audit_log(actor,
  action, target, from/to, page, page_size)` with filters +
  `total_count`; every Phase 4 + Phase 9 admin function re-created
  with `require_permission(...)` gates + `record_audit(...)` calls.
- `supabase/migrations/0029_admin_user_management.sql` —
  `profiles.is_banned` flag; `account_operational_gate` (banned or
  actively suspended users cannot create/join rides, rate or report);
  ride-facing gates replaced the Phase 9 creation/joining triggers
  with a single per-table gate (`block_restricted_on_rides`) that
  distinguishes ban / suspension / temporary restriction, respects
  `ends_at` (lifted = unlocked) and preserves the
  "restricted from creating/joining rides" messages; `report_user` /
  `report_ride` / `get_public_trust_summary` re-created with the gate
  + `is_banned`; user-management RPCs — `admin_search_users(query,
  status, ban, page, page_size)`, `admin_get_user_profile` (jsonb:
  identity, verification, stats, restrictions, trust, audit trail),
  `admin_get_user_ride_history`, `admin_suspend_user`,
  `admin_reactivate_user` (lifts suspensions + clears the ban,
  warning stays), `admin_ban_user` (indefinite suspension +
  `is_banned`).
- `supabase/migrations/0030_admin_ride_management.sql` —
  `admin_search_rides(query, status, page, page_size)`,
  `admin_get_ride_details` (jsonb: ride + host + requests +
  participants), `admin_get_ride_timeline`, `admin_cancel_ride` —
  writes a new `cancelled_by_admin` timeline event that
  `reliability_from_ride_timeline` never penalizes (host score
  untouched); `notify_from_ride_timeline` ignores unknown event
  types.
- `supabase/migrations/0031_admin_verification_cases.sql` —
  `admin_list_verifications(status, search, verification_type)`
  (signature changed — old `(text)` overload dropped), `admin_review_verification`
  re-gated + audited, `admin_get_case_history(user_id)` (jsonb
  dossier: verifications, rides, reports, moderation actions).
- `supabase/migrations/0032_admin_analytics.sql` — `admin_get_analytics()`
  one jsonb payload: users (overview incl. banned/suspended, 14-day
  registrations, weekly retention cohorts), rides (overview +
  average occupancy + top routes), safety (events, reports,
  resolution), platform (db size/connections/cache hit/commit rate,
  per-bucket storage, RPC latency + largest tables — guarded
  `pg_stat_user_functions` / `pg_stat_user_tables` via dynamic SQL,
  storage `size` column probed before planning).
- `supabase/migrations/0033_admin_monitoring.sql` — `monitoring_events`
  (source/level/message/details) written only by server-side
  `record_monitoring_event`; `admin_list_monitoring_events(level)`;
  `get_platform_health()` (status ok/degraded, checks array, database
  size); `admin_update_safety_config(...)` audited wrapper over
  `safety_config`.
- `supabase/migrations/0034_performance_indexes.sql` — guarded
  `pg_trgm` GIN indexes (profiles.display_name, rides.origin /
  rides.destination — skipped when the extension is missing) + btree
  indexes for profile lookups (email, verification_status,
  created_at), admin searches (rides host/created_at, reports,
  appeals, moderation, reliability, safety, notifications,
  monitoring_events) + `analyze`.
- `supabase/migrations/0035_security_hardening.sql` — `anon` revoked
  from the entire admin + internal surface (all `admin_*`,
  `record_audit`, `record_monitoring_event`, `get_platform_health`,
  `has_permission`); `admin_roles`, `admin_role_permissions`,
  `admin_users`, `admin_audit_log`, `monitoring_events` revoked from
  `anon, authenticated` (direct reads/writes 42501 — moderators use
  the RPCs); RLS stays enforced on all four admin tables.
- `scripts/sql-smoke.mjs` — Phase 10 suite (bob promoted super_admin;
  gina/heidi/ivan users): RBAC matrix per role, role management
  guardrails, user search/filters/profiles/history, suspension/ban/
  reactivation gates (ban blocks rides + reports, reactivation
  unlocks), ride search/details/timeline/admin cancel (host
  reliability unchanged), verification queue + case history, analytics
  (baselines vs totals, 14-day registrations, retention shape),
  monitoring + health + config wrapper, audit immutability (insert/
  update/delete 42501, moderator reads via RPC only), security
  lockdown (anon function privileges, table revokes, RLS).
  **725/725 pass** (Phases 1–10).
- `docs/CHANGELOG.md`, `docs/DATABASE_SCHEMA.md`,
  `docs/API_DOCUMENTATION.md` — Phase 10 schema, RBAC/audit model and
  RPC reference documented. New `docs/DEPLOYMENT.md` (production
  rollout: SQL Editor migrations, extension/Realtime/pg_cron notes,
  index strategy, monitoring + backup) and `docs/SECURITY.md`
  (permission matrix, anon lockdown, audit trail, operational gates,
  secure defaults checklist).

### Phase 9 — Trust (ratings, reliability, reports, appeals, moderation)

- `supabase/migrations/0023_trust_schema.sql` — `ratings` (one per
  ride/rater/ratee, double-blind `is_revealed`), `reviews` (1:1 with
  ratings; ride/author/target derived by trigger; profanity flag
  infra), `reports` (user/ride/chat_message targets, 7 reasons,
  partial unique indexes blocking duplicate pending reports),
  `appeals` (unique per user+action while pending), `moderation_actions`
  (severity generated from action type), `reliability_events`,
  `reliability_config` (weights: completed +3, host cancel −8,
  passenger cancel/leave −5, no-show −15, late −5), `moderation_rules`
  (11 configurable thresholds, disabled-friendly),
  `trust_config` (72h review window); RLS — revealed ratings public,
  own unrevealed submissions only, reports/actions/events owner+admin,
  config tables private; Realtime publication of `ratings` +
  `reviews`.
- `supabase/migrations/0024_ratings_functions.sql` — `rate_ride`
  (integer stars, explicit `p_ratee_user_id` when the host rates
  multiple passengers, participants-only, post-completion, 5–1000
  char reviews), `ride_rateable_targets`, `reveal_pair_reviews` /
  `reveal_reciprocal_ratings` (instant reveal on reciprocal),
  `reveal_expired_reviews` (lazy + guarded pg_cron
  `covia-reveal-expired-reviews`), `get_ride_rating_status` (never
  leaks the counterpart's submission), `get_user_ratings`,
  `update_rating`/`delete_rating` (hidden-only; revealed immutable),
  `refresh_profile_rating` + `sync_profile_rating_on_reveal` trigger.
- `supabase/migrations/0025_reliability_moderation.sql` —
  `record_reliability_event`, `recalculate_reliability_score`
  (90 baseline, clamped 0–100), `reliability_from_ride_timeline`
  trigger, `run_moderation_engine` (graduated: warning → restriction
  → suspension, never repeats a severity), creation/joining/rating
  gates (`assert_ride_creation_allowed`, `assert_ride_joining_allowed`,
  `assert_not_suspended_on_ratings` — the last also enforced inside
  `rate_ride`), `expire_moderation_actions` (guarded pg_cron);
  notification vocabulary extended with `warning_issued`,
  `account_restricted`, `appeal_decided`, `report_resolved`
  (`notifications_type_check` + `record_notification` +
  `is_valid_notification_type` recreated, chat types preserved).
- `supabase/migrations/0026_trust_service.sql` — `report_user` /
  `report_ride` (confidential, evidence-ref lists), `get_my_reports`,
  `submit_appeal` (one pending per action; warnings not appealable) /
  `update_appeal` / `get_my_appeals`, `get_my_moderation_status`
  (jsonb: suspended/creation/joining flags + active restrictions),
  `get_trust_summary` (own) / `get_public_trust_summary` (public
  subset) / `admin_get_trust_summary`, `get_trust_config`;
  admin surface — `admin_list_reports`, `admin_review_report`
  (confirm → engine), `admin_list_appeals`, `admin_decide_appeal`
  (approve lifts the action), `admin_apply_moderation_action`,
  `admin_lift_moderation_action`, `admin_list_moderation_actions`,
  `admin_update_moderation_rule`, `admin_list_moderation_rules`,
  `admin_list_reliability_events` — all granted to `authenticated`
  with in-body `is_admin()` gates.
- `scripts/sql-smoke.mjs` — Phase 9 suite: dan/erin/frank scenario
  covering schema + grants, double-blind ratings (RLS hides the
  target's unrevealed rating), instant reciprocal reveal, 72h window
  expiry, immutability, reliability weights from the timeline,
  graduated enforcement (warning → temporary restriction → suspension
  with creation/joining/rating gates), report confidentiality +
  duplicate slots + dismissal, appeals (edit/reject/approve → lift),
  manual moderation, trust summaries (own/public/admin), admin queues
  and RLS over the trust tables. **656/656 pass** (Phases 1–9).
- `docs/DATABASE_SCHEMA.md`, `docs/API_DOCUMENTATION.md` — trust
  tables, RLS, engine behaviour and RPC reference documented.
  (Also corrected the Phase 8 outbound queue table name:
  `outbound_notifications`, not `outbound_notification_queue`.)

### Phase 8 — Safety (emergency contacts, SOS, ride monitoring)

- `supabase/migrations/0021_safety_schema.sql` — `emergency_contacts`
  (validated phone, max 5/user), `safety_config` (monitor settings),
  `safety_events` (sos/check_in/emergency lifecycle), `live_locations`
  (throttled upsert), `ride_monitoring` (active/suspended),
  `safety_event_reports`, `outbound_notifications` (service-role
  only) + helpers (`is_active_ride_member` — strict passenger-not-left —
  to avoid clobbering the original `is_ride_member` semantics from 0009,
  `is_valid_phone`, haversine/route-distance); RLS — users manage their
  own data, contacts may SELECT the owner's location/events; Realtime
  publication of `live_locations` + `safety_events`.
- `supabase/migrations/0022_safety_service.sql` — `trigger_sos` /
  `perform_sos`, `respond_safety_check` (only the prompted rider; safe
  unlocks with client biometrics), `perform_safety_check`,
  `update_live_location`/`stop_live_location`, `set_planned_route`,
  `suspend_ride_monitoring`/`resume_ride_monitoring`,
  `report_safety_incident`, `run_safety_monitor` (check-in sweep,
  SOS escalation, route deviation + timeout detection, incident reports,
  contact-notification queue — guarded pg_cron),
  `sync_safety_from_ride_timeline` (ride start/end wiring) + contact
  CRUD + config RPCs.
- `scripts/sql-smoke.mjs` — Phase 8 suite: contacts (CRUD + validation),
  SOS + notifications to contacts, biometric check-in responses, live
  location upsert + visibility, monitoring lifecycle, escalation
  (safety_check → emergency → incident report), outbound queue RLS.
  **534/534 pass** (Phases 1–8).
- `docs/DATABASE_SCHEMA.md`, `docs/API_DOCUMENTATION.md` — safety
  tables, RLS, Realtime, RPC reference documented.

### Phase 7 — Ride chat

- `supabase/migrations/0019_chat_schema.sql` — `ride_chats` (one per
  ride, auto-created on publish, archived on ride end, locked 2h
  after), `chat_messages` (text ≤ 2000 chars / image with `media_url`,
  soft delete, image expiry), `message_reads` receipts
  (PK message_id+user_id); `chat_enabled` preference added to
  `notification_preferences`; Realtime publication of
  `chat_messages` + `message_reads`; RLS — participants select-only.
- `supabase/migrations/0020_chat_service.sql` — `ensure_ride_chat`,
  `get_chat` (ride + host + `participant_count`), `get_chat_messages`
  (newest-first cursor pagination, `total_count`),
  `send_chat_message(p_chat_id, p_message?, p_message_type?, p_media_url?)`,
  `edit_chat_message`, `delete_chat_message` (soft),
  `mark_messages_read(p_through)`, `search_chat_messages`,
  `add_chat_system_message`, `broadcast_chat_message`,
  `sync_chat_from_ride_timeline` (archive/lock on ride end),
  `purge_expired_chat_messages` (guarded pg_cron).
- `scripts/sql-smoke.mjs` — Phase 7 suite: chat creation on publish,
  participant gating, send/edit/delete rules, cursors + totals,
  read receipts, search, archive/lock behaviour. Part of the 534 pass.
- `docs/DATABASE_SCHEMA.md`, `docs/API_DOCUMENTATION.md` — chat
  tables, RLS, Realtime, RPC reference documented.

### Phase 6 — Notifications

- `supabase/migrations/0017_notifications_schema.sql` —
  `notifications` feed (21 types, `data` payloads, request-scoped
  dedupe index), `notification_preferences` (per-category opt-in),
  `push_tokens` (registration only — delivery is a later phase);
  `record_notification` (preference gate, silent-skip design),
  `broadcast_covia_event` (NOTIFY + Realtime broadcast, never raises),
  `handle_account_notifications` (auth trigger);
  RLS — select-only for the recipient; Realtime publication of
  `notifications`.
- `supabase/migrations/0018_notifications_service.sql` — feed RPCs
  (`get_notifications` with `total_count`, `get_unread_notification_count`,
  `mark_notification_read`, `mark_all_notifications_read`,
  `delete_notification`), preferences + push-token RPCs;
  `notify_from_ride_timeline` trigger → `ride_*` notifications;
  `submit_verification`/`resubmit_verification`/`admin_review_verification`
  extended to emit `verification_*` notifications.
- `scripts/sql-smoke.mjs` — Phase 6 suite: feed pagination/filters,
  unread counts, mark-read/delete, preferences gating, push-token
  platform rules, ride + verification emission. Part of the 534 pass.
- `docs/DATABASE_SCHEMA.md`, `docs/API_DOCUMENTATION.md` — feed,
  preferences, tokens, RLS, Realtime, RPC reference documented.

### Phase 5 — Ride management & matching

- `supabase/migrations/0009_rides_schema.sql` — `rides` (statuses
  draft/published/full/in_progress/completed/cancelled, fare modes
  fixed/smart, seat + point + time checks, search indexes), `ride_requests`
  (manual approval workflow, one-pending partial unique index),
  `ride_participants` (Host/Passenger, `left_at`), `ride_timeline` (13
  event types, metadata) + security definer `record_ride_event` helper;
  RLS — select-only grants, `is_ride_member()` helper so policies don't
  recurse.
- `supabase/migrations/0010_rides_creation_functions.sql` — `create_ride`
  (verified hosts only, full validation), `publish_ride` (draft →
  published, host joins as participant), `update_ride` (host, pre-start,
  seat floor, auto full/published restatus, `edited` events only on
  change).
- `supabase/migrations/0011_rides_request_functions.sql` — `request_to_join`
  (verified only, no own ride, duplicates 23505, no overlapping rides
  within 6h — active seats + pending requests), `cancel_ride_request`,
  `leave_ride` (pre-start, frees the seat), `host_respond_to_request`
  (capacity-checked approval, last seat → `full` + `ride_full` event,
  rejection reason).
- `supabase/migrations/0012_rides_lifecycle_functions.sql` — `start_ride`,
  `complete_ride` (increments `total_completed_rides` for host + staying
  passengers), `cancel_ride` (pre-start, no double cancel, closes pending
  requests, increments `total_cancelled_rides`).
- `supabase/migrations/0013_rides_read_functions.sql` — `search_rides`
  (published/full only, ILIKE filters, date/time/seats/student/women
  filters, departure/recent/distance sort with haversine + nulls-last
  fallback, pagination ≤ 50, `total_count` window, host profile joins),
  `get_ride` (drafts host-only), `get_ride_requests` (host queue),
  `get_ride_participants` (members), `get_ride_timeline` (members).
- `supabase/migrations/0014_rides_locations_schema.sql` — structured
  locations on `rides`: `pickup_type` (main-road/landmark/university/
  bus-stop/metro-station/shopping-centre — residential rejected),
  jsonb `origin_loc` / `destination_loc` / `pickup_point_loc` /
  `destination_point_loc` (`display_name`, `latitude`, `longitude`,
  `place_id`, `full_address`), `smart_fare_details`, `visible_at`
  (scheduled search visibility); `ride_location_text()` validator
  helper (revoked from `public`); guarded Supabase Realtime publication
  for `rides` + `ride_timeline`.
- `supabase/migrations/0015_rides_write_functions.sql` — jsonb
  `create_ride` (canonical; legacy text overload dropped — never
  deployed, would be ambiguous), extended `update_ride` (locations,
  pickup type, visibility, smart-fare details), `delete_draft`
  (drafts only — everything else is cancelled/expired), `remove_passenger`
  (pre-start, seat freed, `dropped` event), `expire_overdue_rides()`
  (published/full rides past departure → `expired`; guarded pg_cron job
  `covia-expire-rides` every 15 min, skipped if pg_cron is missing).
- `supabase/migrations/0016_rides_read_functions.sql` — extended
  `search_rides` (`p_verified_host` filter; lazy expiry purge) and
  `get_ride` (expired rides stay visible to host + members);
  `is_user_verified(uuid)`; security-barrier `ride_history` view
  (scoped to `auth.uid()`) + `get_ride_history(p_relation, p_status,
  p_page, p_page_size)`; "rides published read" RLS policy recreated to
  include `expired` status.
- `scripts/sql-smoke.mjs` — Phase 5 assertions: schema/grants, verified
  gates, creation validations, publish/republish, request/approve/reject/
  withdraw, overlap + duplicate + capacity rules, seat floor, lifecycle
  transitions incl. invalid ones, counter updates, timeline event sets,
  search filters/sort/pagination, RPC member gating, direct-write
  blocking. **303/303 pass** (Phases 1–4 + 5), including the Phase 5b
  suite: structured locations (validation, lat/lng bounds, display-name
  extraction), pickup-type rules, visibility scheduling, expiry
  (cron + lazy paths), delete_draft, remove_passenger, verified-host
  filter, ride history view + RPC.
- `docs/DATABASE_SCHEMA.md` — ride tables, lifecycle matrix, RLS and
  functions documented; `docs/API_DOCUMENTATION.md` — RPC reference with
  permissions, statuses and error conventions.

### Phase 1 — Infrastructure (in progress)

- NestJS 11 application scaffolded with pnpm, strict TypeScript.
- Global request-id middleware (`X-Request-Id` / generated UUID, echoed on
  responses, logs, and envelopes).
- Global exception filter → standardized error envelope with friendly
  messages for common Prisma error codes (P2002, P2003, P2025).
- Global transform interceptor → standardized success envelope; pass-through
  for `success`-bearing payloads (enriched with traceability).
- Structured logging with pino (request correlation, redaction, pretty-print
  in development).
- Global validation pipe (whitelist + transform), Helmet, CORS from config,
  gzip compression, URI versioning (`/api/v1`), rate limiting.
- Boot-time environment validation (fails fast on missing/invalid config).
- Prisma 7 integration: `prisma-client` generator (commonjs module format),
  `@prisma/adapter-pg` driver adapter, config via `prisma.config.ts`,
  client regenerated on install.
- Global `PrismaService` with connection lifecycle hooks (global module).
- Embedded PostgreSQL development database (`scripts/dev-db.mjs`, port 5433,
  zero Docker/system install) + pnpm scripts for start/stop/migrate/studio.
- Health check endpoint `GET /api/v1/health` (server + database probe).
- Swagger/OpenAPI documentation at `/api/docs` (development only).
- Unit tests (Jest) and end-to-end tests (supertest against the real DB).
- Documentation: README, PROJECT_ARCHITECTURE, BACKEND_SETUP, src/ layout notes.

### Phase 2 — Supabase Auth support (mobile)

- Added `supabase/migrations/0001_profiles.sql`: `public.profiles` table
  (defaults: verification `Pending`, rating 5.0, reliability 90,
  `is_government_id_verified` / `is_student_verified` false), trigger-based
  profile creation on `auth.users` insert (carries `full_name` / `phone`
  from signup metadata), `updated_at` trigger, RLS restricted to own row.
- Added `docs/SUPABASE_SETUP.md`: project creation, auth settings
  (email signups + confirmation, password policy), redirect URLs for the
  `companion` scheme, SQL application, and manual test checklist.
- Note: authentication itself lives in the mobile client (Supabase Auth);
  the NestJS API remains the Phase 3+ server for business endpoints.

### Phase 4 — Identity verification (mobile)

- `supabase/migrations/0005_verification_schema.sql` — `verification_submissions`
  (type, ID kind, status lifecycle incl. `expired` + `resubmission_requested`,
  review fields, per-type evidence checks, active-row partial unique index),
  `verification_audit`, `admin_users`, `notification_events` (placeholder
  inbox); `is_admin()` security definer helper; RLS — no client writes,
  users read own submissions/notifications only, admins read everything.
- `supabase/migrations/0006_verification_storage.sql` — **private**
  `verification-documents` Storage bucket (10 MB, jpeg/png/webp) with RLS:
  owners insert/update/delete/read only `verification/<uid>/…`, admins may
  read all; documents are referenced by path and rendered via signed URLs.
- `supabase/migrations/0007_verification_user_functions.sql` —
  `submit_verification` (validates evidence, rejects duplicates with 23505),
  `resubmit_verification` (owner-only, for rejected/re-upload requests),
  `get_my_verification`, `is_user_verified` (ride-creation gate).
- `supabase/migrations/0008_verification_admin_functions.sql` —
  `admin_list_verifications(status)` queue (joins user email/name) and
  `admin_review_verification(id, approve|reject|request_resubmission, reason)`
  — approve flips `verification_status` → `Verified` + the matching
  verified flag on `profiles`; every action writes audit + notification.
- `scripts/sql-smoke.mjs` — Phase 4 assertions added: schema/constraints,
  submit/duplicate/evidence rules, admin gating (42501 for non-admins),
  approve/reject/resubmit flows, profile badge updates, notifications,
  audit RLS, storage folder policies + private bucket config. **84/84 pass.**
- `docs/DATABASE_SCHEMA.md` — verification tables, functions, storage, RLS
  and signed-URL guidance documented.

### Phase 3 — User profiles & identity (mobile)

- `supabase/migrations/0002_profile_identity.sql` — identity fields
  (username, date of birth, gender, country), ride-metric placeholders
  (`total_completed_rides`, `total_cancelled_rides`), emergency contact
  columns (all-or-nothing), username rules (unique index, format check
  `[a-z0-9_]{3,20}`, lowercase-normalizing trigger, `reserved_usernames`
  table + rejection trigger), value-hygiene checks (lengths, DOB future,
  gender whitelist).
- `supabase/migrations/0003_public_profiles.sql` — `public_profiles`
  security-barrier view (public columns only — email/phone/DOB/gender/
  emergency contact never exposed) + `get_public_profile(uuid)`,
  `search_profiles(text, int)` and `is_username_available(text)` RPCs
  (security definer, authenticated-only execute) + explicit table grants.
- `supabase/migrations/0004_avatars_storage.sql` — public `avatars`
  Storage bucket (5 MB, jpeg/png/webp) + RLS policies scoped to each
  user's own folder (`avatars/<user-id>/…`), public read.
- `scripts/sql-smoke.mjs` — applies all migrations to a scratch database
  (stubbed `auth`/`storage` schemas) and asserts auto-creation, username
  rules, emergency contacts, public/private split, RLS and bucket config
  (39 checks; `pg` added as a dev dependency).
- `docs/DATABASE_SCHEMA.md` — full schema reference (tables, view,
  functions, storage, RLS, mobile model mapping).
- Note: profile logic lives in the mobile client + Supabase RPCs; the
  NestJS API remains for business endpoints (rides, chat, ratings).
