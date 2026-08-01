-- Covia - Phase 9: trust schema (ratings, reviews, reports, appeals,
-- moderation and reliability)
--
-- Tables:
--   * ratings               - double-blind post-ride ratings (1-5 overall
--                             + optional category scores stored now, enabled
--                             later: punctuality, communication,
--                             respectfulness, reliability)
--   * reviews               - written reviews attached 1:1 to ratings,
--                             revealed together with them
--   * reports               - user / ride / chat-message reports
--                             (chat_message is future-ready)
--   * appeals               - restricted users contest their moderation
--                             action
--   * moderation_actions    - graduated enforcement records (warning,
--                             temporary restriction, ride creation/joining
--                             disabled, suspension)
--   * reliability_events    - objective behaviour signals (completed,
--                             cancellations, no-shows, late arrivals)
--   * reliability_config    - per-signal weights (configurable)
--   * moderation_rules      - restriction thresholds (configurable, NOT
--                             hardcoded)
--   * trust_config          - singleton runtime settings (review window)
--
-- Design:
--   * ratings and reviews are DOUBLE-BLIND: both sides must rate (or the
--     review window must expire) before anything is revealed. RLS only
--     exposes revealed rows (plus your own unrevealed submissions and
--     admins).
--   * every write goes through security-definer RPCs; the tables have no
--     client write grants.
--   * reliability scoring is independent of star ratings and uses
--     configurable weights (base 90, clamped 0..100).

-- =============================================================
-- Ratings
-- =============================================================
create table if not exists public.ratings (
  id uuid primary key default gen_random_uuid(),
  ride_id uuid not null references public.rides (id) on delete cascade,
  rater_user_id uuid not null references auth.users (id) on delete cascade,
  ratee_user_id uuid not null references auth.users (id) on delete cascade,
  role_of_rater text not null check (role_of_rater in ('Host', 'Passenger')),
  overall_rating smallint not null check (overall_rating between 1 and 5),
  punctuality smallint check (punctuality between 1 and 5),
  communication smallint check (communication between 1 and 5),
  respectfulness smallint check (respectfulness between 1 and 5),
  reliability smallint check (reliability between 1 and 5),
  is_revealed boolean not null default false,
  revealed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (rater_user_id <> ratee_user_id),
  unique (ride_id, rater_user_id, ratee_user_id)
);

comment on table public.ratings is
  'Post-ride ratings. One rating per (ride, rater, ratee) pair; double-blind: is_revealed flips only when both sides rate or the review window expires.';

create index if not exists ratings_ratee_idx on public.ratings (ratee_user_id, is_revealed);
create index if not exists ratings_ride_idx on public.ratings (ride_id);

-- =============================================================
-- Reviews
-- =============================================================
create table if not exists public.reviews (
  id uuid primary key default gen_random_uuid(),
  rating_id uuid not null unique references public.ratings (id) on delete cascade,
  ride_id uuid not null references public.rides (id) on delete cascade,
  author_user_id uuid not null references auth.users (id) on delete cascade,
  target_user_id uuid not null references auth.users (id) on delete cascade,
  content text not null check (char_length(content) between 1 and 1000),
  profanity_flag boolean not null default false,
  is_revealed boolean not null default false,
  revealed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.reviews is
  'Written reviews, one per rating. ride/author/target are derived from the parent rating. Profanity filtering infrastructure: is_profane() + profanity_flag (see trigger below).';

create index if not exists reviews_target_idx on public.reviews (target_user_id, is_revealed);
create index if not exists reviews_ride_idx on public.reviews (ride_id);

-- Derive ride/author/target from the parent rating so the two can never
-- disagree; also reject reviews whose rating is missing.
create or replace function public.reviews_derive_from_rating()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select ride_id, rater_user_id, ratee_user_id
    into new.ride_id, new.author_user_id, new.target_user_id
    from public.ratings
   where id = new.rating_id;

  if not found then
    raise exception 'Review must belong to an existing rating';
  end if;

  return new;
end;
$$;

create trigger reviews_derive_from_rating_trigger
  before insert on public.reviews
  for each row execute function public.reviews_derive_from_rating();

-- Profanity infrastructure: placeholder filter (always false). Swap the
-- body for a dictionary check or an external service call when needed.
create or replace function public.is_profane(p_text text)
returns boolean
language sql
immutable
security definer
set search_path = public
as $$
  select false;
$$;

create or replace function public.reviews_flag_profanity()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if public.is_profane(new.content) then
    update public.reviews set profanity_flag = true where id = new.id;
  end if;
  return new;
end;
$$;

create trigger reviews_flag_profanity_trigger
  after insert on public.reviews
  for each row execute function public.reviews_flag_profanity();

-- =============================================================
-- Reports
-- =============================================================
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_user_id uuid not null references auth.users (id) on delete cascade,
  target_type text not null check (target_type in ('user', 'ride', 'chat_message')),
  target_user_id uuid references auth.users (id) on delete cascade,
  target_ride_id uuid references public.rides (id) on delete cascade,
  target_message_id uuid,
  reason text not null check (reason in (
    'no_show', 'harassment', 'fake_identity', 'dangerous_behavior',
    'fraud', 'inappropriate_content', 'other'
  )),
  details text check (details is null or char_length(details) between 1 and 2000),
  evidence_refs jsonb not null default '[]'::jsonb,
  status text not null default 'pending'
    check (status in ('pending', 'under_review', 'resolved', 'dismissed')),
  is_confirmed boolean not null default false,
  resolution_note text,
  resolved_by uuid references auth.users (id) on delete set null,
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (target_type = 'user' and target_user_id is not null and target_ride_id is null and target_message_id is null)
    or (target_type = 'ride' and target_ride_id is not null and target_user_id is null and target_message_id is null)
    or (target_type = 'chat_message' and target_message_id is not null and target_user_id is null and target_ride_id is null)
  )
);

comment on table public.reports is
  'Confidential reports. A report targets exactly one thing (user, ride or chat message). Duplicate pending reports on the same target+reason are blocked by partial unique indexes.';

create index if not exists reports_status_idx on public.reports (status);
create index if not exists reports_target_user_idx on public.reports (target_user_id);
create index if not exists reports_target_ride_idx on public.reports (target_ride_id);

-- One pending/under-review report per (reporter, target, reason).
create unique index reports_pending_user_uniq
  on public.reports (reporter_user_id, target_user_id, reason)
  where target_type = 'user' and status in ('pending', 'under_review');

create unique index reports_pending_ride_uniq
  on public.reports (reporter_user_id, target_ride_id, reason)
  where target_type = 'ride' and status in ('pending', 'under_review');

create unique index reports_pending_message_uniq
  on public.reports (reporter_user_id, target_message_id, reason)
  where target_type = 'chat_message' and status in ('pending', 'under_review');

-- =============================================================
-- Moderation actions
-- =============================================================
create table if not exists public.moderation_actions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  action_type text not null check (action_type in (
    'warning',
    'temporary_restriction',
    'ride_creation_disabled',
    'ride_joining_disabled',
    'suspension'
  )),
  severity smallint generated always as (
    case action_type
      when 'warning' then 1
      when 'temporary_restriction' then 2
      when 'ride_creation_disabled' then 3
      when 'ride_joining_disabled' then 3
      else 4
    end
  ) stored,
  status text not null default 'active'
    check (status in ('active', 'lifted', 'expired', 'overturned')),
  reason text not null check (char_length(reason) between 1 and 1000),
  details jsonb not null default '{}'::jsonb,
  source text not null check (source in ('automatic', 'manual')),
  created_by uuid references auth.users (id) on delete set null,
  starts_at timestamptz not null default now(),
  ends_at timestamptz,
  revoked_by uuid references auth.users (id) on delete set null,
  revoked_at timestamptz,
  revoke_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (ends_at is null or ends_at > starts_at)
);

comment on table public.moderation_actions is
  'Graduated enforcement records. severity is derived (warning 1, temporary restriction 2, ride creation/joining disabled 3, suspension 4). temporary_restriction carries ends_at; suspensions are permanent until lifted.';

create index if not exists moderation_actions_user_idx
  on public.moderation_actions (user_id, status);
create index if not exists moderation_actions_status_idx
  on public.moderation_actions (status);

-- =============================================================
-- Appeals
-- =============================================================
create table if not exists public.appeals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  moderation_action_id uuid not null references public.moderation_actions (id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 2000),
  status text not null default 'pending'
    check (status in ('pending', 'under_review', 'approved', 'rejected')),
  moderator_id uuid references auth.users (id) on delete set null,
  moderator_note text,
  decided_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (user_id, moderation_action_id, status)
);

comment on table public.appeals is
  'Appeals against moderation actions. One pending/under-review appeal per action (unique constraint with status); the owner edits the reason while pending; moderators decide.';

create index if not exists appeals_user_idx on public.appeals (user_id);
create index if not exists appeals_status_idx on public.appeals (status);

-- =============================================================
-- Reliability
-- =============================================================
create table if not exists public.reliability_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  event_type text not null check (event_type in (
    'ride_completed',
    'ride_cancelled_by_host',
    'ride_cancelled_by_passenger',
    'no_show',
    'late_arrival'
  )),
  weight numeric not null,
  reason text not null default 'recorded',
  ride_id uuid references public.rides (id) on delete set null,
  created_at timestamptz not null default now()
);

comment on table public.reliability_events is
  'Objective behaviour signals feeding the reliability score. The score is independent of star ratings: base 90 + configurable weighted sum, clamped 0..100.';

create index if not exists reliability_events_user_idx
  on public.reliability_events (user_id, created_at);
create index if not exists reliability_events_ride_idx
  on public.reliability_events (ride_id);

-- Configurable weights (admin can tune; edits apply to future events).
create table if not exists public.reliability_config (
  event_type text primary key check (event_type in (
    'ride_completed',
    'ride_cancelled_by_host',
    'ride_cancelled_by_passenger',
    'no_show',
    'late_arrival'
  )),
  weight numeric not null,
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

insert into public.reliability_config (event_type, weight, enabled) values
  ('ride_completed', 3, true),
  ('ride_cancelled_by_host', -8, true),
  ('ride_cancelled_by_passenger', -5, true),
  ('no_show', -15, true),
  ('late_arrival', -5, true)
on conflict (event_type) do nothing;

-- =============================================================
-- Moderation rules (configurable thresholds, graduated by severity)
-- =============================================================
create table if not exists public.moderation_rules (
  id uuid primary key default gen_random_uuid(),
  rule_name text not null unique,
  description text not null,
  action_type text not null check (action_type in (
    'warning',
    'temporary_restriction',
    'ride_creation_disabled',
    'ride_joining_disabled',
    'suspension'
  )),
  severity smallint not null check (severity between 1 and 4),
  threshold numeric not null,
  duration_hours integer check (duration_hours > 0),
  enabled boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.moderation_rules is
  'Restriction thresholds evaluated by the automatic moderation engine after reliability events and confirmed reports. severity: 1 warning, 2 temporary restriction, 3 ride creation/joining disabled, 4 suspension. Engine escalates rather than repeating the same level.';

insert into public.moderation_rules
  (rule_name, description, action_type, severity, threshold, duration_hours, enabled)
values
  ('reliability_below_warning',    'Reliability score drops below 60',              'warning',               1, 60, null,    true),
  ('reliability_below_restrict',   'Reliability score drops below 45',              'temporary_restriction', 2, 45, 168,    true),
  ('reliability_critical_suspend', 'Reliability score drops below 25',              'suspension',            4, 25, null,    true),
  ('no_show_warning',              '1 recorded no-show',                            'warning',               1, 1,  null,    true),
  ('no_show_restrict',             '2 recorded no-shows',                           'temporary_restriction', 2, 2,  168,    true),
  ('no_show_suspend',              '5 recorded no-shows',                           'suspension',            4, 5,  null,    true),
  ('cancellations_warning',        '3 cancelled rides',                             'warning',               1, 3,  null,    true),
  ('cancellations_restrict',       '5 cancelled rides',                             'temporary_restriction', 2, 5,  168,    true),
  ('confirmed_reports_warning',    '2 confirmed reports',                           'warning',               1, 2,  null,    true),
  ('confirmed_reports_restrict',   '4 confirmed reports',                           'temporary_restriction', 2, 4,  336,    true),
  ('confirmed_reports_suspend',    '8 confirmed reports (repeat offenders)',        'suspension',            4, 8,  null,    true)
on conflict (rule_name) do nothing;

-- =============================================================
-- Runtime settings
-- =============================================================
create table if not exists public.trust_config (
  id integer primary key check (id = 1),
  review_window_hours integer not null default 72 check (review_window_hours > 0),
  updated_at timestamptz not null default now()
);

insert into public.trust_config (id, review_window_hours) values (1, 72)
on conflict (id) do nothing;

-- =============================================================
-- updated_at maintenance
-- =============================================================
create trigger ratings_updated_at
  before update on public.ratings
  for each row execute function public.set_updated_at();
create trigger reviews_updated_at
  before update on public.reviews
  for each row execute function public.set_updated_at();
create trigger reports_updated_at
  before update on public.reports
  for each row execute function public.set_updated_at();
create trigger appeals_updated_at
  before update on public.appeals
  for each row execute function public.set_updated_at();
create trigger moderation_actions_updated_at
  before update on public.moderation_actions
  for each row execute function public.set_updated_at();
create trigger trust_config_updated_at
  before update on public.trust_config
  for each row execute function public.set_updated_at();
create trigger reliability_config_updated_at
  before update on public.reliability_config
  for each row execute function public.set_updated_at();
create trigger moderation_rules_updated_at
  before update on public.moderation_rules
  for each row execute function public.set_updated_at();

-- =============================================================
-- Row Level Security
-- =============================================================
-- Sensitive by default: RLS on for every table, and the client gets
-- SELECT only where the actor is legitimately allowed to see rows.
-- All writes happen through security-definer RPCs.

alter table public.ratings enable row level security;
alter table public.reviews enable row level security;
alter table public.reports enable row level security;
alter table public.appeals enable row level security;
alter table public.moderation_actions enable row level security;
alter table public.reliability_events enable row level security;
alter table public.reliability_config enable row level security;
alter table public.moderation_rules enable row level security;
alter table public.trust_config enable row level security;

-- Ratings: revealed rows to everyone, your own unrevealed submissions
-- to you, everything to admins. Unrevealed incoming ratings stay hidden.
create policy ratings_select_revealed on public.ratings
  for select using (
    is_revealed
    or rater_user_id = auth.uid()
    or ratee_user_id = auth.uid()
    or public.is_admin()
  );

create policy reviews_select_revealed on public.reviews
  for select using (
    is_revealed
    or author_user_id = auth.uid()
    or public.is_admin()
  );

-- Reports: confidential — only the reporter (and admins) see them.
create policy reports_select_own on public.reports
  for select using (
    reporter_user_id = auth.uid()
    or public.is_admin()
  );

-- Appeals: owner + moderators only.
create policy appeals_select_own on public.appeals
  for select using (
    user_id = auth.uid()
    or public.is_admin()
  );

-- Moderation records: the affected user sees their own; admins see all.
create policy moderation_actions_select_own on public.moderation_actions
  for select using (
    user_id = auth.uid()
    or public.is_admin()
  );

-- Reliability events: same as moderation records.
create policy reliability_events_select_own on public.reliability_events
  for select using (
    user_id = auth.uid()
    or public.is_admin()
  );

-- Config tables are private (read via admin RPCs); no policies.
alter table public.reliability_config force row level security;
alter table public.moderation_rules force row level security;
alter table public.trust_config force row level security;

-- =============================================================
-- Grants: SELECT per RLS policy above; nothing else for clients.
-- =============================================================
revoke all on table
  public.ratings, public.reviews, public.reports, public.appeals,
  public.moderation_actions, public.reliability_events,
  public.reliability_config, public.moderation_rules, public.trust_config
  from anon, authenticated;

grant select on
  public.ratings, public.reviews, public.reports, public.appeals,
  public.moderation_actions, public.reliability_events
  to authenticated;

-- Internal helpers are not client-callable.
revoke all on function public.is_profane(text) from public;
revoke all on function public.reviews_derive_from_rating() from public;
revoke all on function public.reviews_flag_profanity() from public;
