-- Covia — profiles table for Supabase Auth
-- ------------------------------------------------------------------
-- Creates the public.profiles table that mirrors auth.users, auto-creates
-- a row on signup via a trigger, and locks it down with Row Level
-- Security so users can only read/update their own row.
--
-- Run this in the Supabase SQL Editor (or via `supabase db push` with the
-- Supabase CLI). See docs/SUPABASE_SETUP.md for full instructions.

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  display_name text,
  full_name text,
  avatar_url text,
  phone text,
  home_city text,
  bio text,
  verification_status text not null default 'Pending'
    check (verification_status in ('Pending', 'In Review', 'Verified', 'Rejected')),
  rating numeric(2, 1) not null default 5.0
    check (rating >= 0 and rating <= 5),
  reliability_score integer not null default 90
    check (reliability_score >= 0 and reliability_score <= 100),
  is_government_id_verified boolean not null default false,
  is_student_verified boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is 'User-facing profile data, one row per auth user.';

-- Keep updated_at fresh on every update.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row
  execute function public.set_updated_at();

-- Auto-create a profile row the moment an auth user is created.
-- Signup metadata (full_name, phone) is carried over when present.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name, full_name, phone)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data ->> 'full_name', split_part(new.email, '@', 1)),
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'phone'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_user();

-- Row Level Security: users may read and update only their own profile.
alter table public.profiles enable row level security;

drop policy if exists "Users can read their own profile" on public.profiles;
create policy "Users can read their own profile"
  on public.profiles
  for select
  to authenticated
  using ((select auth.uid()) = id);

drop policy if exists "Users can update their own profile" on public.profiles;
create policy "Users can update their own profile"
  on public.profiles
  for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);
