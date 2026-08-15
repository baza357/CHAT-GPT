-- The confirmed Auth email is the public username used for contact search.

alter table public.profiles
  drop constraint if exists profiles_username_format;

alter table public.profiles
  drop constraint if exists profiles_username_check;

update public.profiles p
set username = lower(trim(u.email))
from auth.users u
where u.id = p.id
  and u.email is not null
  and trim(u.email) <> '';

alter table public.profiles
  add constraint profiles_username_is_email
  check (
    username = lower(username)
    and char_length(username) between 3 and 320
    and position('@' in username) > 1
  );

drop index if exists public.profiles_username_lower_idx;
create unique index profiles_username_lower_idx
on public.profiles (lower(username));

revoke update (username) on public.profiles from authenticated;

drop policy if exists "profiles_select_authenticated" on public.profiles;
drop policy if exists "profiles_select_self_or_contact" on public.profiles;
create policy "profiles_select_self_or_contact"
on public.profiles
for select
to authenticated
using (
  id = (select auth.uid())
  or exists (
    select 1
    from public.contacts c
    where c.owner_id = (select auth.uid())
      and c.contact_id = profiles.id
  )
);

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  submitted_email text;
  submitted_name text;
  submitted_phone text;
begin
  submitted_email := lower(trim(coalesce(new.email, '')));
  submitted_name := trim(
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'display_name', ''),
      ''
    )
  );
  submitted_phone := trim(coalesce(new.raw_user_meta_data ->> 'phone_e164', ''));

  if position('@' in submitted_email) <= 1 then
    raise exception 'Valid email is required';
  end if;
  if char_length(submitted_name) < 5 or submitted_name !~ '\s' then
    raise exception 'Full name is required';
  end if;
  if submitted_phone !~ '^\+7[0-9]{10}$' then
    raise exception 'Valid Russian phone is required';
  end if;

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
    submitted_email,
    submitted_name,
    '',
    'offline',
    null,
    now(),
    now()
  )
  on conflict (id) do update
  set username = excluded.username,
      display_name = excluded.display_name,
      updated_at = now();

  insert into public.profile_phone_numbers (profile_id, phone_e164)
  values (new.id, submitted_phone)
  on conflict (profile_id) do update
  set phone_e164 = excluded.phone_e164, updated_at = now();

  return new;
end;
$$;

revoke all on function private.handle_new_user()
from public, anon, authenticated;

create or replace function public.search_profiles_by_name(p_query text)
returns table (
  id uuid,
  phone_e164 text,
  username text,
  display_name text,
  avatar_url text,
  bio text,
  status text,
  last_seen timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  safe_query text;
begin
  if (select auth.uid()) is null then
    raise exception 'Not authenticated';
  end if;

  safe_query := lower(trim(regexp_replace(coalesce(p_query, ''), '\s+', ' ', 'g')));
  if char_length(safe_query) < 3 then
    return;
  end if;

  safe_query := replace(replace(replace(safe_query, '\', '\\'), '%', '\%'), '_', '\_');

  return query
  select
    p.id,
    ph.phone_e164,
    p.username,
    p.display_name,
    p.avatar_url,
    p.bio,
    p.status,
    p.last_seen,
    p.created_at,
    p.updated_at
  from public.profiles p
  left join public.profile_phone_numbers ph on ph.profile_id = p.id
  where p.id <> (select auth.uid())
    and (
      p.display_name ilike '%' || safe_query || '%' escape '\'
      or p.username ilike '%' || safe_query || '%' escape '\'
    )
  order by p.display_name
  limit 20;
end;
$$;

revoke all on function public.search_profiles_by_name(text)
from public, anon, authenticated;
grant execute on function public.search_profiles_by_name(text) to authenticated;
