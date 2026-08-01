-- Covia - ride schema extension: structured locations, pickup rules,
-- visibility window, smart fare data, expiry + dropped events
-- ------------------------------------------------------------------
-- Phase 5b. This migration EXTENDS the Phase 5 ride schema (0009-0013)
-- with the fields required for production ride matching:
--
--   * origin_loc / destination_loc / pickup_point_loc /
--     destination_point_loc - structured location objects so future
--     features (route matching, nearby discovery, map rendering, ETA,
--     rerouting) never need a database change. Canonical shape:
--
--       {
--         "display_name": "Jibowu Bus Stop",
--         "latitude": 6.5216,
--         "longitude": 3.3608,
--         "place_id": "ChIJ....",        -- Google Maps place id (optional)
--         "full_address": "Jibowu, Lagos" -- optional
--       }
--
--     The legacy text columns stay as denormalized, indexed, searchable
--     display-name copies so every existing read function keeps working.
--
--   * pickup_type - pickup-point rules: only main-road points, public
--     landmarks, universities, bus stops, metro stations and shopping
--     centres. Arbitrary residential addresses are not allowed.
--
--   * visible_at - optional release date/time: the ride stays invisible
--     to search until this moment (ride visibility window).
--
--   * smart_fare_details - optional jsonb payload for the future smart
--     fare calculation engine (proportional fare). Stored now, consumed
--     later; the engine itself is NOT implemented in this phase.
--
--   * ride_status 'expired' - rides that passed their departure time
--     without ever starting are auto-archived to this state.
--
--   * ride_timeline 'dropped' + 'expired' event types.
--
-- No client writes: the extended write functions live in 0015 and the
-- read/discovery functions in 0016.

-- ── rides: new columns ──────────────────────────────────────────────
alter table public.rides add column if not exists origin_loc jsonb;
alter table public.rides add column if not exists destination_loc jsonb;
alter table public.rides add column if not exists pickup_point_loc jsonb;
alter table public.rides add column if not exists destination_point_loc jsonb;

alter table public.rides add column if not exists pickup_type text;
alter table public.rides add column if not exists visible_at timestamptz;
alter table public.rides add column if not exists smart_fare_details jsonb;

-- Pickup-point rules: only main-road / public meeting points. The
-- allowed kinds are the only ones users can ever pick; a residential
-- address cannot be chosen because the client picker only offers
-- these kinds and the functions below reject anything else.
alter table public.rides drop constraint if exists rides_pickup_type_check;
alter table public.rides add constraint rides_pickup_type_check
  check (pickup_type is null or pickup_type in (
    'main_road', 'landmark', 'university', 'bus_stop', 'metro_station', 'shopping_center'
  ));

-- NOTE: pickup kind is enforced at the function level (create_ride /
-- update_ride require a valid pickup_type), not by a table constraint,
-- because the legacy text-based create_ride (0010) predates pickup_type
-- and published rides without one must keep working.

-- Visibility window sanity: a ride can never become visible after it
-- has departed.
alter table public.rides drop constraint if exists rides_visible_at_before_departure_check;
alter table public.rides add constraint rides_visible_at_before_departure_check
  check (visible_at is null or departure_time > visible_at);

-- Ride status lifecycle gains the archived 'expired' state:
--   draft --> published --> full --> in_progress --> completed
--       \       \        \     \---> cancelled
--        \      \--------\--> cancelled
--         \--> cancelled
--   published / full --(departure passed, never started)--> expired
alter table public.rides drop constraint if exists rides_ride_status_check;
alter table public.rides add constraint rides_ride_status_check
  check (ride_status in ('draft', 'published', 'full', 'in_progress', 'completed', 'cancelled', 'expired'));

-- New search index: visible rides with free seats ordered by departure.
create index if not exists rides_visible_departure_idx
  on public.rides (ride_status, visible_at, departure_time)
  where ride_status in ('published', 'full');

-- ── ride_timeline: new event types ─────────────────────────────────
alter table public.ride_timeline drop constraint if exists ride_timeline_event_type_check;
alter table public.ride_timeline add constraint ride_timeline_event_type_check
  check (event_type in (
    'created', 'published', 'requested', 'request_cancelled', 'approved',
    'rejected', 'joined', 'left', 'ride_full', 'edited', 'started',
    'completed', 'cancelled', 'dropped', 'expired'
  ));

-- ── Location validation helper ─────────────────────────────────────
-- Validates a structured location object and returns the display name
-- (the value stored in the legacy searchable text column). Raises a
-- friendly error for missing/malformed payloads; lat/lng ranges are
-- enforced when both are present.
create or replace function public.ride_location_text(p_loc jsonb, p_field text)
returns text
language plpgsql
immutable
security definer
set search_path = public
as $$
declare
  v_name text;
begin
  if p_loc is null then
    raise exception '% is required', p_field;
  end if;
  if jsonb_typeof(p_loc) <> 'object' then
    raise exception '% must be a location object', p_field;
  end if;

  v_name := nullif(btrim(coalesce(p_loc->>'display_name', '')), '');
  if v_name is null then
    raise exception 'The % needs a display name', p_field;
  end if;
  if char_length(v_name) > 160 then
    raise exception 'The % display name is too long (max 160 characters)', p_field;
  end if;

  if p_loc ? 'latitude' or p_loc ? 'longitude' then
    begin
      if (p_loc->>'latitude')::numeric between -90 and 90
         and (p_loc->>'longitude')::numeric between -180 and 180
      then
        null;
      else
        raise exception 'The % coordinates are out of range', p_field;
      end if;
    exception
      when others then
        raise exception 'The % coordinates must be numbers', p_field;
    end;
  end if;

  return v_name;
end;
$$;

revoke all on function public.ride_location_text(jsonb, text) from public;

-- ── Supabase Realtime (infrastructure only) ────────────────────────
-- Prepare the realtime publication for the ride tables so the future
-- chat / notifications / live activity feed can subscribe. No-op on
-- databases without the Supabase publication (e.g. local Postgres).
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.rides;
    alter publication supabase_realtime add table public.ride_timeline;
  end if;
end $$;
