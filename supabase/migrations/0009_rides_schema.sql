-- Covia - ride management schema
-- ------------------------------------------------------------------
-- Core tables for the Phase 5 ride lifecycle. Covia is NOT a
-- ride-hailing platform: rides connect verified travellers sharing a
-- vehicle booked through Uber/inDrive/Yango etc. This schema only
-- manages the coordination layer:
--
--   * rides             - one ride posting, owned by the host
--   * ride_requests     - manual approval workflow (no instant join)
--   * ride_participants - who is on the ride (host + approved guests)
--   * ride_timeline     - every event, timestamped (powers the future
--                         activity feed + notifications)
--
-- Ride status lifecycle (every transition is validated in the
-- functions in 0010-0012):
--
--   draft --> published --> full --> in_progress --> completed
--       \       \        \     \---> cancelled
--        \      \---------\--> cancelled
--         \--> cancelled
--
-- No client writes: all writes go through security definer functions;
-- RLS below only gates direct reads.

-- ── rides ──────────────────────────────────────────────────────────
create table if not exists public.rides (
  id uuid primary key default gen_random_uuid(),
  host_id uuid not null references auth.users (id) on delete cascade,
  origin text not null check (char_length(btrim(origin)) between 1 and 120),
  destination text not null check (char_length(btrim(destination)) between 1 and 120),
  pickup_point text not null check (char_length(btrim(pickup_point)) between 1 and 160),
  destination_point text check (destination_point is null or char_length(btrim(destination_point)) between 1 and 160),
  origin_lat numeric(9, 6),
  origin_lng numeric(9, 6),
  destination_lat numeric(9, 6),
  destination_lng numeric(9, 6),
  departure_time timestamptz not null,
  estimated_arrival timestamptz check (estimated_arrival is null or estimated_arrival > departure_time),
  total_seats integer not null check (total_seats between 1 and 10),
  available_seats integer not null check (available_seats >= 0 and available_seats <= total_seats),
  fare_mode text not null check (fare_mode in ('fixed', 'smart')),
  fixed_fare numeric(10, 2) check (fixed_fare is null or fixed_fare > 0),
  ride_status text not null default 'draft'
    check (ride_status in ('draft', 'published', 'full', 'in_progress', 'completed', 'cancelled')),
  is_student_only boolean not null default false,
  is_women_only boolean not null default false,
  notes text check (notes is null or char_length(notes) <= 1000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((fare_mode = 'fixed' and fixed_fare is not null) or (fare_mode = 'smart' and fixed_fare is null))
);

comment on table public.rides is
  'Ride coordination postings. host_id owns the ride; every state change is logged in ride_timeline.';

comment on column public.rides.fare_mode is 'fixed = host sets fixed_fare per seat; smart = proportional calculation (engine in a later phase)';

create index if not exists rides_status_departure_idx on public.rides (ride_status, departure_time);
create index if not exists rides_origin_idx on public.rides (origin);
create index if not exists rides_destination_idx on public.rides (destination);
create index if not exists rides_host_idx on public.rides (host_id);
create index if not exists rides_student_only_idx on public.rides (is_student_only);
create index if not exists rides_women_only_idx on public.rides (is_women_only);

drop trigger if exists rides_set_updated_at on public.rides;
create trigger rides_set_updated_at
  before update on public.rides
  for each row
  execute function public.set_updated_at();

-- ── ride_requests ──────────────────────────────────────────────────
create table if not exists public.ride_requests (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.rides (id) on delete cascade,
  passenger_id uuid not null references auth.users (id) on delete cascade,
  status text not null default 'pending'
    check (status in ('pending', 'approved', 'rejected', 'cancelled')),
  requested_at timestamptz not null default now(),
  responded_at timestamptz
);

comment on table public.ride_requests is
  'Manual approval workflow: a passenger may request to join, the host approves or rejects. One pending request per (ride, passenger).';

create unique index if not exists ride_requests_one_pending_idx
  on public.ride_requests (ride_id, passenger_id)
  where status = 'pending';

create index if not exists ride_requests_ride_status_idx on public.ride_requests (ride_id, status);
create index if not exists ride_requests_passenger_idx on public.ride_requests (passenger_id);

-- ── ride_participants ──────────────────────────────────────────────
create table if not exists public.ride_participants (
  ride_id uuid not null references public.rides (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null check (role in ('Host', 'Passenger')),
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  primary key (ride_id, user_id)
);

comment on table public.ride_participants is
  'Who is on the ride. The host row is created on publish; approved passengers are added on approval. left_at marks departures (pre-start only).';

create index if not exists ride_participants_ride_idx on public.ride_participants (ride_id);
create index if not exists ride_participants_user_idx on public.ride_participants (user_id);

-- ── ride_timeline ──────────────────────────────────────────────────
create table if not exists public.ride_timeline (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.rides (id) on delete cascade,
  event_type text not null
    check (event_type in (
      'created', 'published', 'requested', 'request_cancelled', 'approved',
      'rejected', 'joined', 'left', 'ride_full', 'edited', 'started',
      'completed', 'cancelled'
    )),
  actor_id uuid references auth.users (id) on delete set null,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

comment on table public.ride_timeline is
  'Every ride event, timestamped. Will power the activity feed and notifications in later phases.';

create index if not exists ride_timeline_ride_idx on public.ride_timeline (ride_id, created_at);

-- ── Timeline helper (internal, security definer) ───────────────────
create or replace function public.record_ride_event(
  p_ride_id uuid,
  p_event text,
  p_actor uuid default null,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.ride_timeline (ride_id, event_type, actor_id, metadata)
  values (p_ride_id, p_event, p_actor, p_metadata);
end;
$$;

revoke all on function public.record_ride_event(uuid, text, uuid, jsonb) from public;

-- Membership helper for RLS: rides/requests/timeline policies need to know
-- whether the caller is on a ride without recursively evaluating the
-- ride_participants policies. Security definer: bypasses RLS internally.
create or replace function public.is_ride_member(p_ride_id uuid, p_user_id uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.ride_participants
    where ride_id = p_ride_id and user_id = p_user_id
  );
$$;

revoke all on function public.is_ride_member(uuid, uuid) from public;
grant execute on function public.is_ride_member(uuid, uuid) to authenticated;

-- ── Row Level Security ─────────────────────────────────────────────
alter table public.rides enable row level security;
alter table public.ride_requests enable row level security;
alter table public.ride_participants enable row level security;
alter table public.ride_timeline enable row level security;

-- Rides: the host sees everything; participants see their ride; everyone
-- else sees rides that are out of the draft (published/full/started/done).
drop policy if exists "rides host read" on public.rides;
create policy "rides host read"
  on public.rides
  for select
  to authenticated
  using ((select auth.uid()) = host_id);

drop policy if exists "rides participant read" on public.rides;
create policy "rides participant read"
  on public.rides
  for select
  to authenticated
  using (public.is_ride_member(rides.id, (select auth.uid())));

drop policy if exists "rides published read" on public.rides;
create policy "rides published read"
  on public.rides
  for select
  to authenticated
  using (ride_status in ('published', 'full', 'in_progress', 'completed', 'cancelled'));

-- Requests: the passenger sees their own; the host sees requests for
-- their rides. No direct writes (functions only).
drop policy if exists "ride_requests passenger read" on public.ride_requests;
create policy "ride_requests passenger read"
  on public.ride_requests
  for select
  to authenticated
  using ((select auth.uid()) = passenger_id);

drop policy if exists "ride_requests host read" on public.ride_requests;
create policy "ride_requests host read"
  on public.ride_requests
  for select
  to authenticated
  using (exists (
    select 1 from public.rides r
    where r.id = ride_requests.ride_id and r.host_id = (select auth.uid())
  ));

-- Participants: only people on the ride see who is on it.
drop policy if exists "ride_participants member read" on public.ride_participants;
create policy "ride_participants member read"
  on public.ride_participants
  for select
  to authenticated
  using (public.is_ride_member(ride_participants.ride_id, (select auth.uid())));

-- Timeline: the host and participants read the ride's timeline.
drop policy if exists "ride_timeline member read" on public.ride_timeline;
create policy "ride_timeline member read"
  on public.ride_timeline
  for select
  to authenticated
  using (
    exists (
      select 1 from public.rides r
      where r.id = ride_timeline.ride_id and r.host_id = (select auth.uid())
    )
    or public.is_ride_member(ride_timeline.ride_id, (select auth.uid()))
  );

revoke all on public.rides from public;
revoke all on public.ride_requests from public;
revoke all on public.ride_participants from public;
revoke all on public.ride_timeline from public;

grant select on public.rides to authenticated;
grant select on public.ride_requests to authenticated;
grant select on public.ride_participants to authenticated;
grant select on public.ride_timeline to authenticated;
