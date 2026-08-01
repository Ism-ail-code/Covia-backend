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
