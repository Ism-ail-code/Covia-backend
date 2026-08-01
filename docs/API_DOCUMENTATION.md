# Covia — Ride API (Supabase RPCs)

The ride coordination layer (Phase 5) is exposed as Supabase Postgres
RPCs — there is no HTTP route in the NestJS service. The mobile client
calls `supabase.rpc(...)` with the anon key; the JWT supplies the actor
(`auth.uid()`).

All functions require the **`authenticated`** role. All writes go
through security definer functions (RLS grants the client `select`
only), so every call is re-validated server-side — never trust the
client.

## Permissions summary

| Who | Can do |
| --- | --- |
| Verified user | create a draft ride, publish it, request to join any published/full ride |
| Verified student | additionally create `student_only` rides |
| Host | edit (pre-start), respond to requests, start, complete, cancel their own ride |
| Passenger | withdraw a pending request, leave before the ride starts |
| Unverified user | read/search rides and details only |

"Verified" = `is_user_verified()` true (any verification method
approved).

## Statuses

`ride_status`: `draft → published → full → in_progress → completed`, and
`draft / published / full → cancelled`.

`ride_requests.status`: `pending → approved | rejected | cancelled`.

`ride_timeline.event_type` (15): `created`, `published`, `requested`,
`request_cancelled`, `approved`, `rejected`, `joined`, `left`,
`ride_full`, `edited`, `started`, `completed`, `cancelled`, `dropped`,
`expired`.

## Write functions

### `create_ride`
- Params: `p_origin_loc`, `p_destination_loc`, `p_pickup_point_loc`
  (jsonb, required) — `{ display_name (≤160), latitude?, longitude?,
  place_id?, full_address? }`; `p_departure_time` (timestamptz,
  future); `p_total_seats` (int 1–10); `p_fare_mode`
  (`fixed`|`smart`); `p_fixed_fare` (numeric, required for `fixed`,
  forbidden for `smart`); optional `p_notes` (≤ 1000),
  `p_destination_point_loc`, `p_is_student_only`, `p_is_women_only`,
  `p_estimated_arrival` (> departure), `p_pickup_type` (one of
  `main_road` | `landmark` | `university` | `bus_stop` |
  `metro_station` | `shopping_center`), `p_visible_at` (future,
  before departure), `p_smart_fare_details` (jsonb object, smart
  fares only).
- Display names are extracted into the legacy `origin` /
  `destination` / `pickup_point` columns; lat/lng copies feed the
  distance sort.
- Returns the new **draft** `rides` row.
- Errors: not authenticated (28000); not verified; missing/invalid
  fields; residential pickup points; visibility outside the
  (future, pre-departure) window; student-only without a verified
  student flag.

### `publish_ride(p_ride_id)`
- Draft → published; host inserted as participant (`Host`).
- Errors: not the host (42501); not a draft.

### `update_ride(p_ride_id, p_departure_time?, p_pickup_point?, p_notes?, p_total_seats?, p_fare_mode?, p_fixed_fare?, p_destination?, p_destination_point?, p_pickup_type?, p_visible_at?, p_origin_loc?, p_destination_loc?, p_pickup_point_loc?, p_destination_point_loc?, p_smart_fare_details?)`
- Host-only, pre-start. Departure must stay in the future. Location /
  pickup-type / visibility edits are re-validated like `create_ride`.
  Seat edits cannot drop below approved passengers;
  `available_seats` is recalculated; the ride is restatused `full`
  (0 available) / `published` (otherwise). `edited` event only when
  something changed.
- Errors: not the host (42501); ride started/completed/cancelled;
  invalid seats/fare/locations.

### `delete_draft(p_ride_id)`
- Host-only. Only `draft` rides are deleted; published/started rides
  must be cancelled or completed instead (and expired rides stay
  archived forever). Returns `true`.
- Errors: not the host (42501); not a draft.

### `request_to_join(p_ride_id)`
- Verified passengers only. Rejects: own ride, draft, full, started,
  cancelled, expired, duplicate pending request (23505), and any
  **overlapping** ride — an active seat or pending request on another
  ride departing within 6 hours.
- Returns the pending `ride_requests` row.

### `cancel_ride_request(p_request_id)`
- Passenger withdraws their own **pending** request. Others: 42501.

### `leave_ride(p_ride_id)`
- Passenger leaves before the ride starts: `left_at` set, seat freed,
  `full` → `published`. Errors: not on the ride; after start; cancelled.

### `host_respond_to_request(p_request_id, p_approve, p_reason?)`
- Host only (42501 otherwise). Pending requests only, and the ride must
  be `published`/`full`. Approving checks remaining capacity (refuses
  when full), adds the passenger, flips the ride to `full` on the last
  seat (`ride_full` event). Rejecting records `p_reason` in the event
  metadata.

### `remove_passenger(p_ride_id, p_passenger_id)`
- Host only (42501 otherwise). Removes a passenger before the ride
  starts: their participant row is closed (`left_at`), the seat is
  freed, `full` → `published`, and a `dropped` event is recorded.
- Errors: ride started/expired/cancelled; passenger not on the ride.

### `start_ride(p_ride_id)` / `complete_ride(p_ride_id)` / `cancel_ride(p_ride_id)`
- Host only. Start: `published`/`full` → `in_progress`. Complete:
  `in_progress` → `completed`, increments `total_completed_rides` for
  host + staying passengers. Cancel: pre-start only (never
  `in_progress`/`completed`, no double cancel), closes pending requests,
  increments `total_cancelled_rides` for the host.

### `expire_overdue_rides()`
- Archives every `published`/`full` ride whose departure time has
  passed as `expired`: leaves search, pending requests are cancelled,
  `expired` events are recorded, riders are removed from participants.
  Scheduled via pg_cron (`covia-expire-rides`, every 15 min) and run
  lazily inside `search_rides`/`get_ride`; idempotent, callable by
  anyone.

## Read functions

### `search_rides(...)`
- Returns `published`/`full` rides only (expired/draft/cancelled
  excluded), joined with the host's public profile. Filters (all
  optional): `p_origin`, `p_destination` (ILIKE `%…%`), `p_date`
  (date), `p_time_from` (time), `p_available_seats` (≥),
  `p_student_only`, `p_women_only`, `p_verified_host` (only hosts with
  an active verification).
- Sorting (`p_sort`): `departure` (default), `recent`, `distance`
  (haversine against `p_origin_lat`/`p_origin_lng`; rides without
  coordinates sort last, and without coordinates it falls back to
  departure).
- Pagination: `p_page` (1-based), `p_page_size` (default 20, max 50).
  Every row carries `total_count` (window count of the filtered set).
- Distance is computed only when both the caller and the ride have
  coordinates — `distance_km` is null otherwise.
- Expired rides are purged lazily on every call (see
  `expire_overdue_rides`).

### `get_ride(p_ride_id)`
- Ride + host public profile. Non-draft rides: any authenticated user.
  Drafts: host only (others get "Ride not found"). Expired rides
  remain visible to their host and members (read-only history).

### `get_ride_requests(p_ride_id)`
- Host only (42501 otherwise). All requests for the ride with the
  passenger's public profile, newest first.

### `get_ride_participants(p_ride_id)`
- Members only (42501 otherwise). Host first, then by join time.

### `get_ride_timeline(p_ride_id)`
- Members only (42501 otherwise). Chronological events with actor
  display names.

### `get_ride_history(p_relation?, p_status?, p_page?, p_page_size?)`
- The caller's **own** history, via the security-barrier `ride_history`
  view (scoped to `auth.uid()`). `p_relation` filters to `hosted` /
  `joined` / `requested` (null = all three). `p_status` filters by ride
  status (any of the lifecycle statuses). Paginated like
  `search_rides` with a `total_count` window on every row.
- Errors: not authenticated (28000); invalid relation.

### `is_user_verified(p_user_id)`
- Boolean — same rule as `is_user_verified()` but for an arbitrary
  user id. Backs the `p_verified_host` search filter.

## Notifications (Phase 6)

### `get_notifications(p_page?, p_page_size?, p_unread_only?, p_type?)`
- The caller's own feed, newest first. `p_type` filters by type,
  `p_unread_only` by read state. Pagination like `search_rides` (page
  size default 20, max 50); every row carries `total_count`.

### `get_unread_notification_count()`
- Integer — unread rows for the caller.

### `mark_notification_read(p_notification_id)` / `mark_all_notifications_read()` / `delete_notification(p_notification_id)`
- Feed mutations. Mark-read returns the updated row; mark-all returns
  the affected count.
- Errors: not authenticated (28000).

### `get_notification_preferences()` / `update_notification_preferences(p_push_enabled?, p_email_enabled?, p_ride_enabled?, p_verification_enabled?, p_safety_enabled?, p_marketing_enabled?, p_chat_enabled?)`
- Preferences row (created on first read). Updates coalesce — only
  provided values change.

### `register_push_token(p_token, p_device_id?, p_platform?)` / `remove_push_token(p_token)`
- Token registry; `p_platform` must be `'android'` or `'ios'`. Delivery
  is a later phase. Errors: `P0001` for invalid platform / oversized
  token.

Realtime: the `notifications` table is published — subscribe with
`postgres_changes` on `INSERT` (RLS scopes it to the recipient).

Phase 9 adds four account-level types — `warning_issued`,
`account_restricted`, `appeal_decided`, `report_resolved` — always
delivered (not preference-gated); emitted by the moderation engine and
moderation RPCs.

## Ride chat (Phase 7)

### `get_chat(p_chat_id)`
- Chat + ride context (status, locations, departure, host) and
  `participant_count` (active passengers + 1). Participant-only
  (42501 otherwise).

### `get_chat_messages(p_chat_id, p_before?, p_page_size?)`
- Newest-first; `p_before` is the cursor (`sent_at` of the oldest
  message already loaded; null = newest page). Rows carry `total_count`.

### `send_chat_message(p_chat_id, p_message?, p_message_type?='text', p_media_url?)`
- Text messages ≤ 2000 characters; images require `p_media_url`.
- Errors: 42501 (not a participant), archived chat, locked chat,
  message too long, `P0001` for invalid type (`text`/`image` only).

### `edit_chat_message(p_message_id, p_message)` / `delete_chat_message(p_message_id)`
- Own messages only; delete is a soft delete. Errors: 42501,
  "Message not found".

### `mark_messages_read(p_chat_id, p_through?)`
- Marks everything up to the cursor read (null = all); returns the
  count newly read.

### `search_chat_messages(p_chat_id, p_query, p_page_size?)`
- ILIKE search within the chat; rows carry `total_count`.

Realtime: `chat_messages` (INSERT) and `message_reads` (INSERT/UPDATE)
are published — use `postgres_changes` with a `chat_id=eq.<id>` filter.

## Safety (Phase 8)

### `get_emergency_contacts()` / `add_emergency_contact(p_name, p_phone, p_relationship?)` / `update_emergency_contact(p_contact_id, p_name?, p_phone?, p_relationship?)` / `delete_emergency_contact(p_contact_id)`
- Contact CRUD (max 5). Phone validated (`P0001` on invalid).
- Errors: 42501 (not your contact).

### `get_safety_config()` / `update_safety_config(p_* )`
- Monitor settings (intervals, escalation windows, defaults).

### `trigger_sos()`
- Creates an SOS event for the caller's active ride (or standalone);
  notifies emergency contacts per config.

### `respond_safety_check(p_event_id, p_safe)`
- Only the prompted rider may respond. `p_safe` marks the event safe
  (client gates it behind a biometric check); unsafe escalates.
- Errors: 42501 ("Only the rider can respond").

### `update_live_location(p_location, p_accuracy?)` / `stop_live_location()`
- Throttled upsert of the caller's live location (min interval from
  config).

### `set_planned_route(p_start_loc, p_end_loc)` / `suspend_ride_monitoring()` / `resume_ride_monitoring()`
- Route + pause/resume for the caller's active ride.

### `report_safety_incident(p_ride_id, p_message?, p_severity?)`
- Manual incident report on a ride the caller is on.

Realtime: `live_locations` and `safety_events` are published — contacts
and riders subscribe via `postgres_changes`.

## Trust (Phase 9)

### Ratings (double-blind)

### `rate_ride(p_ride_id, p_ratee_user_id?, p_overall_rating, p_punctuality?, p_communication?, p_respectfulness?, p_reliability?, p_comment?)`
- Stars are **integers 1–5** (safe for PostgREST); comment becomes the
  review (1–1000 chars).
- The explicit `p_ratee_user_id` is required when the host rates a ride
  with several passengers ("Choose which passenger you are rating").
- Gates: participants only, ride completed, rater stayed on the ride,
  suspended users blocked, one rating per pair per ride.
- The returned row has `is_revealed = false`; revealing happens after
  the insert (reciprocal or window), so re-read the row if you need the
  final state.
- Errors: `P0001` ("already rated", "between 1 and 5", "must contain
  some text", "1000 characters", "after they are completed", "suspended").

### `update_rating(p_rating_id, p_overall_rating, …)` / `delete_rating(p_rating_id)`
- Only while hidden; revealed ratings are immutable
  ("no longer be changed"). Owner-only (`42501` "Rating not found").

### `get_ride_rating_status(p_ride_id)`
- One row per rateable counterpart: `ratee_user_id`, `my_role`,
  `rating_id` + submitted values (yours only), `is_revealed`,
  `reciprocal_submitted`, `window_expired`, `review`. Never exposes the
  counterpart's hidden values.

### `get_user_ratings(p_user_id, p_page?, p_page_size?)`
- Revealed ratings + reviews for a profile block (newest first,
  `total_count`).

### `get_trust_config()`
- `review_window_hours` (default 72) for "rating closes in X" countdowns.

### Reports (confidential)

### `report_user(p_user_id, p_reason, p_details?, p_evidence_refs?)` / `report_ride(p_ride_id, p_reason, p_details?, p_evidence_refs?)`
- Reasons: `no_show` | `harassment` | `fake_identity` |
  `dangerous_behavior` | `fraud` | `inappropriate_content` | `other`.
- `p_evidence_refs` must be a jsonb list. No self-reports; one pending
  report per (reporter, target, reason).
- Errors: `P0001` ("cannot report yourself", "not recognised", "must be
  a list", "already reported", "does not exist").

### `get_my_reports(p_page?, p_page_size?)`
- The caller's own reports (newest first, `total_count`).

### Appeals

### `submit_appeal(p_moderation_action_id, p_reason)`
- One pending appeal per action; warnings cannot be appealed; reason
  1–2000 chars.
- Errors: `P0001` ("Warnings cannot be appealed", "already have a
  pending appeal", "no longer active").

### `update_appeal(p_appeal_id, p_reason)` / `get_my_appeals()`
- Edit while pending (owner-only, `42501` "not found or no longer
  editable"); list own appeals with action context.

### Moderation status

### `get_my_moderation_status()`
- jsonb: `is_suspended`, `can_create_rides`, `can_join_rides`,
  `restrictions[]` (active actions with `action_type`, `severity`,
  `ends_at`, `source`).

### Trust summaries

### `get_trust_summary()` (own) / `get_public_trust_summary(p_user_id)`
- Private: average (revealed only), rating count, reliability,
  completed/cancelled rides, verification badges, confidential report
  counts, account age, active restrictions. Public subset omits the
  report counts. Both return a single jsonb column.

### Admin (all `is_admin()`-gated, granted to `authenticated`)

- `admin_list_reports(p_status?)`, `admin_review_report(id, p_confirm, p_note?)`
  — confirm runs the moderation engine against the target user.
- `admin_list_appeals(p_status?)`, `admin_decide_appeal(id, p_approve, p_note?)`
  — approve lifts the action (status `lifted`).
- `admin_apply_moderation_action(p_user_id, p_action_type, p_reason, p_duration_hours?)`
  / `admin_lift_moderation_action(p_action_id, p_reason)` — types
  validated (`warning`…`suspension`); warnings not appealable.
- `admin_list_moderation_actions(p_user_id?, p_status?)`,
  `admin_list_moderation_rules()`,
  `admin_update_moderation_rule(p_rule_name, p_threshold?, p_action_type?, p_duration_hours?, p_enabled?)`,
  `admin_list_reliability_events(p_user_id?)`.
- `admin_get_trust_summary(p_user_id)` — full summary for any user.
- Errors: `P0001` "Admin access required".

Realtime: `ratings` and `reviews` are published (`supabase_realtime`) —
the client refreshes profile blocks on reveal.

## Admin dashboard (Phase 10)

### RBAC helpers (callable by anyone — they never raise for non-admins)

- `is_admin()` — boolean; true for members of any admin role.
- `current_admin_role()` — `super_admin` / `admin` / `moderator` /
  `support_agent`, or null for regular users.
- `has_permission(text)` — boolean; `super_admin` always true.
  (All other Phase 10 RPCs call `require_permission` internally and
  raise `P0001` "Permission denied: <role> cannot <permission>" — a
  `42501` SQLSTATE — when the caller lacks the permission.)

### Team management (`admin.manage` / `role.manage`)

- `admin_list_admin_users()` — id, email, display name, role.
- `admin_set_admin_role(p_user_id, p_role_name)` — grants/revokes a
  role. Guardrails: you cannot change your own role; `support_agent`
  cannot grant anything (`role.manage` required).
- `admin_remove_admin(p_user_id)` — revokes membership. You cannot
  remove yourself; Covia must keep at least one super admin.

### User management (`user.view` / `user.manage` / `user.suspend` / `user.ban`)

- `admin_search_users(p_query?, p_status?, p_banned?, p_page?, p_page_size?)`
  — name/email ILIKE, verification-status + ban filters,
  `total_count`.
- `admin_get_user_profile(p_user_id)` — jsonb dossier: identity,
  verification, ride stats, active restrictions, trust summary,
  recent audit trail.
- `admin_get_user_ride_history(p_user_id, p_page?, p_page_size?)` —
  rides hosted/joined/requested with relation + status.
- `admin_suspend_user(p_user_id, p_duration_hours, p_reason)` —
  temporary suspension (ride creation/joining/rating/reporting
  blocked while active).
- `admin_reactivate_user(p_user_id, p_reason)` — lifts active
  suspensions, clears the ban flag; warnings stay on record.
- `admin_ban_user(p_user_id, p_reason)` — permanent ban (indefinite
  suspension + `is_banned`); banned users cannot create/join rides,
  rate, or file reports.

### Ride management (`ride.view` / `ride.cancel`)

- `admin_search_rides(p_query?, p_status?, p_page?, p_page_size?)` —
  route/host ILIKE, status filter, passenger counts.
- `admin_get_ride_details(p_ride_id)` — jsonb (ride, host, pending
  requests, participants).
- `admin_get_ride_timeline(p_ride_id)` — full event history.
- `admin_cancel_ride(p_ride_id, p_reason)` — flips the ride to
  `cancelled` and writes a `cancelled_by_admin` timeline event.
  **Never affects the host's reliability score.**

### Verification desk (`verification.review`)

- `admin_list_verifications(p_status?, p_search?, p_type?, p_page?,
  p_page_size?)` — queue with text + document-type filters.
- `admin_review_verification(p_submission_id, p_action, p_reason?)` —
  approve / reject / request_resubmission (audited).
- `admin_get_case_history(p_user_id)` — jsonb dossier
  (verifications, rides, reports, moderation actions) for a full
  picture before deciding.

### Analytics (`analytics.view`)

- `admin_get_analytics()` — one jsonb payload with `users`
  (overview, 14-day registrations, weekly retention cohorts),
  `rides` (overview, average occupancy, top routes), `safety`
  (events + reports), `platform` (db/storage stats, outbound queue).

### Monitoring (`monitor.view`)

- `get_platform_health()` — `status` (`ok`/`degraded`), `checks[]`,
  `database_size_mb`. Degraded when the outbound queue > 50, errors
  occurred in 24h, or an SOS is unresolved.
- `admin_list_monitoring_events(p_level?)` — server-written events
  (info/warning/error/critical), newest first, `total_count`.
- `admin_update_safety_config(p_route_deviation_meters?, …)` — audited
  tuning of `safety_config` (old/new values recorded in the audit log).

### Audit log (`audit.view`)

- `admin_list_audit_log(p_actor?, p_action?, p_target?, p_from?,
  p_to?, p_page?, p_page_size?)` — filterable, newest first,
  `total_count`. Direct table access raises 42501 for every client
  role — the RPC is the only read path; writes flow exclusively
  through the server-side `record_audit`.

Errors: `P0001` "Permission denied: …" (42501) for missing
permissions; `P0001` friendly text for guardrail violations
("cannot change your own role", "cannot remove yourself", "Covia
must keep at least one super admin", "User not found", …).

## Error conventions

RPCs raise with a friendly `message` and a SQLSTATE `code`:

- `28000` — not authenticated
- `42501` — wrong actor (not host / not owner / not member)
- `23505` — duplicate (pending request already exists)
- `P0001` — validation failures (friendly message text)

The mobile service (`src/services/rides.ts`) maps these to user-facing
messages via `RideError`.

## Timeline metadata

- `requested` / `request_cancelled` / `approved` / `rejected` /
  `joined`: `{ request_id, passenger_id }` (+ `reason` for rejections).
- `dropped`: `{ passenger_id }` (host removed the passenger).
- `edited`: `{ field: newValue, … }` — only the fields that changed.
- Other events (incl. `left`, `expired`): empty.
