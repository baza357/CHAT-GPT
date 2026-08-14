-- Stage 1: complete user profiles and secure automatic profile creation.

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

alter table public.profiles
  add column if not exists username text,
  add column if not exists bio text,
  add column if not exists status text,
  add column if not exists last_seen timestamptz,
  add column if not exists updated_at timestamptz;

update public.profiles
set
  display_name = coalesce(nullif(trim(display_name), ''), 'Пользователь'),
  username = coalesce(
    nullif(username, ''),
    'user_' || replace(substring(id::text from 1 for 8), '-', '')
  ),
  bio = coalesce(bio, ''),
  status = coalesce(nullif(status, ''), 'offline'),
  updated_at = coalesce(updated_at, created_at, now());

alter table public.profiles
  alter column display_name set not null,
  alter column username set not null,
  alter column bio set default '',
  alter column status set default 'offline',
  alter column status set not null,
  alter column updated_at set default now(),
  alter column updated_at set not null;

alter table public.profiles
  drop constraint if exists profiles_username_format;
alter table public.profiles
  add constraint profiles_username_format
  check (username ~ '^[a-z0-9_]{3,32}$');

create unique index if not exists profiles_username_lower_idx
on public.profiles (lower(username));

create index if not exists profiles_display_name_idx
on public.profiles (display_name);

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_authenticated" on public.profiles;
create policy "profiles_select_authenticated"
on public.profiles
for select
to authenticated
using ((select auth.uid()) is not null);

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self"
on public.profiles
for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

revoke all on table public.profiles from anon;
grant select, update on table public.profiles to authenticated;

drop trigger if exists on_auth_user_created on auth.users;
drop function if exists public.handle_new_user();

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_username text;
  generated_username text;
begin
  base_username := regexp_replace(
    lower(
      coalesce(
        nullif(new.raw_user_meta_data ->> 'display_name', ''),
        split_part(coalesce(new.email, 'user'), '@', 1),
        'user'
      )
    ),
    '[^a-z0-9_]+',
    '',
    'g'
  );

  if char_length(base_username) < 3 then
    base_username := 'user';
  end if;

  generated_username := left(base_username, 23) || '_' ||
    replace(substring(new.id::text from 1 for 8), '-', '');

  insert into public.profiles (
    id,
    username,
    display_name,
    bio,
    status,
    last_seen,
    created_at,
    updated_at
  )
  values (
    new.id,
    generated_username,
    coalesce(
      nullif(trim(new.raw_user_meta_data ->> 'display_name'), ''),
      split_part(coalesce(new.email, 'user'), '@', 1)
    ),
    '',
    'offline',
    null,
    now(),
    now()
  )
  on conflict (id) do nothing;

  return new;
end;
$$;

revoke all on function private.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function private.handle_new_user();

create or replace function private.set_profile_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function private.set_profile_updated_at()
from public, anon, authenticated;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function private.set_profile_updated_at();
