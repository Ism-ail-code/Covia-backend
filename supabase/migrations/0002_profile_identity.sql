-- Covia - profile identity, username rules & emergency contacts
-- ------------------------------------------------------------------
-- Extends public.profiles (created in 0001) with identity fields,
-- reliability metric placeholders and emergency contact columns.
-- Implements username rules: unique, lowercase-normalized, 3–20 chars,
-- [a-z0-9_], and protected against reserved names.
--
-- Run after 0001_profiles.sql in the Supabase SQL Editor.

-- -- Identity & metrics ----------------------------------------------
alter table public.profiles
  add column if not exists username text,
  add column if not exists date_of_birth date,
  add column if not exists gender text,
  add column if not exists country text,
  add column if not exists total_completed_rides integer not null default 0
    check (total_completed_rides >= 0),
  add column if not exists total_cancelled_rides integer not null default 0
    check (total_cancelled_rides >= 0),
  add column if not exists emergency_contact_name text,
  add column if not exists emergency_contact_phone text,
  add column if not exists emergency_contact_relationship text;

-- -- Value hygiene (validated again in the app) ---------------------
alter table public.profiles
  add constraint profiles_username_format
    check (username is null or username ~ '^[a-z0-9_]{3,20}$'),
  add constraint profiles_gender_values
    check (gender is null or gender in ('Female', 'Male', 'Non-binary', 'Prefer not to say')),
  add constraint profiles_dob_not_future
    check (date_of_birth is null or date_of_birth <= current_date),
  add constraint profiles_display_name_length
    check (display_name is null or char_length(btrim(display_name)) <= 60),
  add constraint profiles_bio_length
    check (bio is null or char_length(bio) <= 500),
  add constraint profiles_city_length
    check (home_city is null or char_length(btrim(home_city)) <= 80),
  add constraint profiles_country_length
    check (country is null or char_length(btrim(country)) <= 80),
  add constraint profiles_emergency_contact_all_or_nothing
    check (
      (emergency_contact_name is null and emergency_contact_phone is null
        and emergency_contact_relationship is null)
      or
      (emergency_contact_name is not null and emergency_contact_phone is not null
        and emergency_contact_relationship is not null)
    ),
  add constraint profiles_emergency_contact_required
    check (
      emergency_contact_name is null or btrim(emergency_contact_name) <> ''
    ),
  add constraint profiles_emergency_relationship_length
    check (emergency_contact_relationship is null or char_length(btrim(emergency_contact_relationship)) <= 40),
  add constraint profiles_emergency_phone_length
    check (emergency_contact_phone is null or char_length(btrim(emergency_contact_phone)) between 7 and 20);

-- Unique usernames (case-insensitive, NULLs allowed - username optional).
create unique index if not exists profiles_username_unique
  on public.profiles (username)
  where username is not null;

-- -- Reserved usernames ---------------------------------------------
create table if not exists public.reserved_usernames (
  name text primary key
);

insert into public.reserved_usernames (name) values
  ('admin'), ('administrator'), ('support'), ('staff'), ('official'),
  ('system'), ('root'), ('superuser'), ('moderator'), ('mod'),
  ('community'), ('team'), ('covia'), ('companion'), ('help'),
  ('helpdesk'), ('safety'), ('emergency'), ('police'), ('security'),
  ('service'), ('api'), ('test'), ('testing'), ('demo'), ('guest'),
  ('anonymous'), ('user'), ('users'), ('profile'), ('profiles'),
  ('account'), ('accounts'), ('settings'), ('notification'),
  ('verification'), ('verify'), ('webmaster'), ('hostmaster'),
  ('abuse'), ('info'), ('contact'), ('billing'), ('legal'),
  ('privacy'), ('terms')
on conflict (name) do nothing;

-- Normalize (trim + lowercase, null on empty) and reject reserved names.
create or replace function public.normalize_username()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := lower(btrim(new.username));
begin
  if v_name = '' then
    v_name := null;
  end if;
  if v_name is not null and exists (
    select 1 from public.reserved_usernames where name = v_name
  ) then
    raise exception 'This username is reserved and cannot be used.'
      using errcode = 'P0001';
  end if;
  new.username := v_name;
  return new;
end;
$$;

drop trigger if exists profiles_normalize_username on public.profiles;
create trigger profiles_normalize_username
  before insert or update of username on public.profiles
  for each row
  execute function public.normalize_username();
