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

`ride_timeline.event_type` (13): `created`, `published`, `requested`,
`request_cancelled`, `approved`, `rejected`, `joined`, `left`,
`ride_full`, `edited`, `started`, `completed`, `cancelled`.

## Write functions

### `create_ride`
- Params: `p_origin`, `p_destination`, `p_pickup_point` (text, required,
  trimmed); `p_departure_time` (timestamptz, future); `p_total_seats`
  (int 1–10); `p_fare_mode` (`fixed`|`smart`); `p_fixed_fare` (numeric,
  required for `fixed`, forbidden for `smart`); optional `p_notes`
  (≤ 1000), `p_destination_point`, `p_is_student_only`,
  `p_is_women_only`, `p_estimated_arrival` (> departure).
- Returns the new **draft** `rides` row.
- Errors: not authenticated (28000); not verified; missing/invalid
  fields; student-only without a verified student flag.

### `publish_ride(p_ride_id)`
- Draft → published; host inserted as participant (`Host`).
- Errors: not the host (42501); not a draft.

### `update_ride(p_ride_id, p_departure_time?, p_pickup_point?, p_notes?, p_total_seats?, p_fare_mode?, p_fixed_fare?)`
- Host-only, pre-start. Departure must stay in the future. Seat edits
  cannot drop below approved passengers; `available_seats` is
  recalculated; the ride is restatused `full` (0 available) /
  `published` (otherwise). `edited` event only when something changed.
- Errors: not the host (42501); ride started/completed/cancelled;
  invalid seats/fare.

### `request_to_join(p_ride_id)`
- Verified passengers only. Rejects: own ride, draft, full, started,
  cancelled, duplicate pending request (23505), and any **overlapping**
  ride — an active seat or pending request on another ride departing
  within 6 hours.
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

### `start_ride(p_ride_id)` / `complete_ride(p_ride_id)` / `cancel_ride(p_ride_id)`
- Host only. Start: `published`/`full` → `in_progress`. Complete:
  `in_progress` → `completed`, increments `total_completed_rides` for
  host + staying passengers. Cancel: pre-start only (never
  `in_progress`/`completed`, no double cancel), closes pending requests,
  increments `total_cancelled_rides` for the host.

## Read functions

### `search_rides(...)`
- Returns `published`/`full` rides only, joined with the host's public
  profile. Filters (all optional): `p_origin`, `p_destination`
  (ILIKE `%…%`), `p_date` (date), `p_time_from` (time), 
  `p_available_seats` (≥), `p_student_only`, `p_women_only`.
- Sorting (`p_sort`): `departure` (default), `recent`, `distance`
  (haversine against `p_origin_lat`/`p_origin_lng`; rides without
  coordinates sort last, and without coordinates it falls back to
  departure).
- Pagination: `p_page` (1-based), `p_page_size` (default 20, max 50).
  Every row carries `total_count` (window count of the filtered set).
- Distance is computed only when both the caller and the ride have
  coordinates — `distance_km` is null otherwise.

### `get_ride(p_ride_id)`
- Ride + host public profile. Non-draft rides: any authenticated user.
  Drafts: host only (others get "Ride not found").

### `get_ride_requests(p_ride_id)`
- Host only (42501 otherwise). All requests for the ride with the
  passenger's public profile, newest first.

### `get_ride_participants(p_ride_id)`
- Members only (42501 otherwise). Host first, then by join time.

### `get_ride_timeline(p_ride_id)`
- Members only (42501 otherwise). Chronological events with actor
  display names.

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
- `edited`: `{ field: newValue, … }` — only the fields that changed.
- Other events: empty.
