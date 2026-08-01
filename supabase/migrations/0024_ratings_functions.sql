-- Covia - Phase 9: rating + review functions
--
-- Client-facing surface:
--   * rate_ride                 - rate the counterpart after a COMPLETED
--                                 ride; creates the review when a comment
--                                 is supplied
--   * update_rating / delete_rating - edit/withdraw while unrevealed
--   * get_ride_rating_status    - my ratings for a ride + reveal state
--                                 (never leaks the counterpart's ratings)
--   * get_user_ratings          - revealed ratings about a user
--   * reveal_expired_reviews    - window expiry reveal (lazy + pg_cron)
--
-- Double-blind rules:
--   1. a rating is revealed when BOTH sides rated the pair on that ride
--   2. otherwise it auto-reveals once the review window (trust_config)
--      passes
--   3. a review is revealed exactly when its rating is
-- Revealing one side of a pair reveals the reciprocal too.
--
-- Pair model: a passenger rates the host (one pair). The host rates each
-- active passenger (one pair per passenger). One rating per pair.

-- =============================================================
-- Reveal helpers
-- =============================================================
-- Reveal every rating (and its review) between two users on a ride.
create or replace function public.reveal_pair_reviews(
  p_ride_id uuid,
  p_user_a uuid,
  p_user_b uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.ratings
     set is_revealed = true, revealed_at = coalesce(revealed_at, now())
   where ride_id = p_ride_id
     and is_revealed = false
     and ((rater_user_id = p_user_a and ratee_user_id = p_user_b)
       or (rater_user_id = p_user_b and ratee_user_id = p_user_a));

  update public.reviews
     set is_revealed = true, revealed_at = coalesce(revealed_at, now())
   where ride_id = p_ride_id
     and is_revealed = false
     and ((author_user_id = p_user_a and target_user_id = p_user_b)
       or (author_user_id = p_user_b and target_user_id = p_user_a));
end;
$$;

-- Reveal both sides once the reciprocal rating exists.
create or replace function public.reveal_reciprocal_ratings()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (
    select 1 from public.ratings
     where ride_id = new.ride_id
       and rater_user_id = new.ratee_user_id
       and ratee_user_id = new.rater_user_id
  ) then
    perform public.reveal_pair_reviews(new.ride_id, new.rater_user_id, new.ratee_user_id);
  end if;
  return new;
end;
$$;

create trigger ratings_reveal_reciprocal_trigger
  after insert on public.ratings
  for each row execute function public.reveal_reciprocal_ratings();

-- Reveal any unrevealed rating whose review window has expired.
create or replace function public.reveal_expired_reviews()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_window interval;
  v_count integer := 0;
begin
  select make_interval(hours => review_window_hours)
    into v_window
    from public.trust_config where id = 1;

  update public.ratings
     set is_revealed = true, revealed_at = coalesce(revealed_at, now())
   where is_revealed = false
     and created_at < now() - coalesce(v_window, interval '72 hours');

  get diagnostics v_count = row_count;

  update public.reviews
     set is_revealed = true, revealed_at = coalesce(revealed_at, now())
   where is_revealed = false
     and exists (
       select 1 from public.ratings r
        where r.id = public.reviews.rating_id
          and r.is_revealed = true
     );

  return v_count;
end;
$$;

-- =============================================================
-- Shared helper: who can the caller rate on a completed ride?
-- Passenger -> the host; Host -> each active passenger.
-- =============================================================
create or replace function public.ride_rateable_targets(
  p_ride_id uuid,
  p_user_id uuid
)
returns table (target_user_id uuid, my_role text)
language sql
security definer
set search_path = public
as $$
  select case
           when rp.role = 'Host' then pass.user_id
           else h.user_id
         end,
         rp.role
    from public.ride_participants rp
    join public.rides r on r.id = rp.ride_id and r.ride_status = 'completed'
    left join public.ride_participants pass
      on pass.ride_id = rp.ride_id
     and pass.role = 'Passenger'
     and pass.left_at is null
    left join public.ride_participants h
      on h.ride_id = rp.ride_id
     and h.role = 'Host'
   where rp.ride_id = p_ride_id
     and rp.user_id = p_user_id
     and rp.left_at is null
   order by pass.joined_at nulls last;
$$;

-- =============================================================
-- Rate a ride (double-blind)
-- =============================================================
create or replace function public.rate_ride(
  p_ride_id uuid,
  p_ratee_user_id uuid default null,
  p_overall_rating integer default null,
  p_punctuality integer default null,
  p_communication integer default null,
  p_respectfulness integer default null,
  p_reliability integer default null,
  p_comment text default null
)
returns public.ratings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rater uuid := auth.uid();
  v_ratee uuid;
  v_role text;
  v_rating public.ratings;
  v_targets bigint;
begin
  if v_rater is null then
    raise exception 'You must be signed in to rate a ride';
  end if;

  if exists (
    select 1 from public.moderation_actions
     where user_id = v_rater
       and status = 'active'
       and action_type = 'suspension'
  ) then
    raise exception 'Your account is suspended; you cannot rate rides right now';
  end if;

  if p_overall_rating is null or p_overall_rating not between 1 and 5 then
    raise exception 'Overall rating must be between 1 and 5';
  end if;
  if p_comment is not null and length(trim(p_comment)) = 0 then
    raise exception 'A review must contain some text';
  end if;
  if p_comment is not null and char_length(p_comment) > 1000 then
    raise exception 'Reviews are limited to 1000 characters';
  end if;

  select count(*) into v_targets
    from public.ride_rateable_targets(p_ride_id, v_rater);
  if v_targets > 1 and p_ratee_user_id is null then
    raise exception 'Choose which passenger you are rating';
  end if;

  select target_user_id, my_role
    into v_ratee, v_role
    from public.ride_rateable_targets(p_ride_id, v_rater)
   where target_user_id = coalesce(p_ratee_user_id, target_user_id)
   limit 1;

  if not found then
    if v_targets = 0 then
      if exists (
        select 1 from public.rides
         where id = p_ride_id and ride_status = 'completed'
      ) then
        raise exception 'You can only rate rides you were on';
      end if;
      raise exception 'Rides can only be rated after they are completed and only by riders who stayed on the ride';
    end if;
    raise exception 'You can only rate someone who was on the ride with you';
  end if;

  insert into public.ratings (
    ride_id, rater_user_id, ratee_user_id, role_of_rater,
    overall_rating, punctuality, communication, respectfulness, reliability
  ) values (
    p_ride_id, v_rater, v_ratee, v_role,
    p_overall_rating, p_punctuality, p_communication, p_respectfulness, p_reliability
  ) on conflict (ride_id, rater_user_id, ratee_user_id) do nothing
  returning * into v_rating;

  if v_rating is null then
    raise exception 'You have already rated this ride';
  end if;

  if p_comment is not null then
    insert into public.reviews (rating_id, content)
    values (v_rating.id, p_comment);
  end if;

  return v_rating;
end;
$$;

-- =============================================================
-- Edit / withdraw an unrevealed rating
-- =============================================================
create or replace function public.update_rating(
  p_rating_id uuid,
  p_overall_rating integer default null,
  p_punctuality integer default null,
  p_communication integer default null,
  p_respectfulness integer default null,
  p_reliability integer default null,
  p_comment text default null
)
returns public.ratings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rating public.ratings;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;

  select * into v_rating
    from public.ratings
   where id = p_rating_id and rater_user_id = auth.uid();
  if not found then
    raise exception 'Rating not found';
  end if;
  if v_rating.is_revealed then
    raise exception 'Ratings can no longer be changed once they are revealed';
  end if;

  if p_overall_rating is not null and p_overall_rating not between 1 and 5 then
    raise exception 'Overall rating must be between 1 and 5';
  end if;
  if p_comment is not null and length(trim(p_comment)) = 0 then
    raise exception 'A review must contain some text';
  end if;
  if p_comment is not null and char_length(p_comment) > 1000 then
    raise exception 'Reviews are limited to 1000 characters';
  end if;

  update public.ratings
     set overall_rating  = coalesce(p_overall_rating, overall_rating),
         punctuality     = coalesce(p_punctuality, punctuality),
         communication   = coalesce(p_communication, communication),
         respectfulness  = coalesce(p_respectfulness, respectfulness),
         reliability     = coalesce(p_reliability, reliability)
   where id = p_rating_id
  returning * into v_rating;

  if p_comment is not null then
    update public.reviews
       set content = p_comment
     where rating_id = p_rating_id;
  end if;

  return v_rating;
end;
$$;

create or replace function public.delete_rating(p_rating_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'You must be signed in';
  end if;

  if not exists (
    select 1 from public.ratings
     where id = p_rating_id and rater_user_id = auth.uid() and is_revealed = false
  ) then
    raise exception 'Rating not found or no longer editable';
  end if;

  delete from public.ratings where id = p_rating_id;
end;
$$;

-- =============================================================
-- Reads
-- =============================================================
-- One row per rateable target on the ride (my ratings + reveal state).
-- Never exposes the counterpart's rating values.
create or replace function public.get_ride_rating_status(p_ride_id uuid)
returns table (
  ratee_user_id uuid,
  my_role text,
  rating_id uuid,
  overall_rating smallint,
  punctuality smallint,
  communication smallint,
  respectfulness smallint,
  reliability smallint,
  is_revealed boolean,
  revealed_at timestamptz,
  review text,
  review_profanity_flag boolean,
  reciprocal_submitted boolean,
  window_expired boolean
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rater uuid := auth.uid();
  v_reciprocal boolean;
  v_window_expired boolean;
begin
  if v_rater is null then
    raise exception 'You must be signed in';
  end if;

  return query
    with targets as (
      select t.target_user_id, t.my_role
        from public.ride_rateable_targets(p_ride_id, v_rater) t
    )
    select t.target_user_id,
           t.my_role,
           r.id,
           r.overall_rating,
           r.punctuality,
           r.communication,
           r.respectfulness,
           r.reliability,
           r.is_revealed,
           r.revealed_at,
           rev.content,
           rev.profanity_flag,
           exists (
             select 1 from public.ratings recip
              where recip.ride_id = p_ride_id
                and recip.rater_user_id = t.target_user_id
                and recip.ratee_user_id = v_rater
           )::boolean,
           (r.created_at < now() - make_interval(
              hours => coalesce(
                (select review_window_hours from public.trust_config where id = 1), 72)
            ))::boolean
      from targets t
      left join public.ratings r
        on r.ride_id = p_ride_id
       and r.rater_user_id = v_rater
       and r.ratee_user_id = t.target_user_id
      left join public.reviews rev on rev.rating_id = r.id
     order by t.my_role desc, t.target_user_id;
end;
$$;

-- Revealed ratings about a user (public profile block).
create or replace function public.get_user_ratings(
  p_user_id uuid,
  p_page integer default 1,
  p_page_size integer default 10
)
returns table (
  id uuid,
  ride_id uuid,
  rater_user_id uuid,
  rater_name text,
  overall_rating smallint,
  punctuality smallint,
  communication smallint,
  respectfulness smallint,
  reliability smallint,
  comment text,
  created_at timestamptz,
  total_count bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_size integer := least(greatest(p_page_size, 1), 50);
  v_page integer := greatest(p_page, 1);
begin
  return query
    select r.id,
           r.ride_id,
           r.rater_user_id,
           pr.display_name,
           r.overall_rating,
           r.punctuality,
           r.communication,
           r.respectfulness,
           r.reliability,
           rev.content,
           r.created_at,
           count(*) over ()::bigint
      from public.ratings r
      left join public.reviews rev on rev.rating_id = r.id
      left join public.profiles pr on pr.id = r.rater_user_id
     where r.ratee_user_id = p_user_id
       and r.is_revealed = true
     order by r.created_at desc
     limit v_size offset (v_page - 1) * v_size;
end;
$$;

-- Keep profiles.rating in sync with the revealed average.
create or replace function public.refresh_profile_rating(p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.profiles
     set rating = coalesce((
       select round(avg(overall_rating)::numeric, 1)
         from public.ratings
        where ratee_user_id = p_user_id and is_revealed = true
     ), 5.0)
   where id = p_user_id;
end;
$$;

create or replace function public.sync_profile_rating_on_reveal()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.is_revealed and not old.is_revealed then
    perform public.refresh_profile_rating(new.ratee_user_id);
  end if;
  return new;
end;
$$;

create trigger ratings_sync_profile_rating_trigger
  after update of is_revealed on public.ratings
  for each row execute function public.sync_profile_rating_on_reveal();

-- =============================================================
-- Grants
-- =============================================================
revoke all on function
  public.rate_ride, public.update_rating, public.delete_rating,
  public.get_ride_rating_status, public.get_user_ratings,
  public.reveal_expired_reviews, public.reveal_pair_reviews,
  public.reveal_reciprocal_ratings, public.ride_rateable_targets,
  public.refresh_profile_rating, public.sync_profile_rating_on_reveal
  from public;

grant execute on function
  public.rate_ride(uuid, uuid, integer, integer, integer, integer, integer, text),
  public.update_rating(uuid, integer, integer, integer, integer, integer, text),
  public.delete_rating(uuid),
  public.get_ride_rating_status(uuid),
  public.get_user_ratings(uuid, integer, integer)
  to authenticated;

-- =============================================================
-- Scheduler (guarded: only on databases with pg_cron, e.g. Supabase)
-- =============================================================
do $$
begin
  if to_regnamespace('cron') is not null then
    perform cron.schedule(
      'covia-reveal-expired-reviews',
      '0 * * * *',
      $job$ select public.reveal_expired_reviews(); $job$
    );
  end if;
end;
$$;
