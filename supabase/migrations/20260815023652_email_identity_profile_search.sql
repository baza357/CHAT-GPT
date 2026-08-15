-- Email confirms the account. Full name and phone are required profile data.

drop trigger if exists on_auth_user_phone_verified on auth.users;
drop function if exists private.sync_verified_user_phone();

drop policy if exists "profile_phones_insert_self"
on public.profile_phone_numbers;
create policy "profile_phones_insert_self"
on public.profile_phone_numbers
for insert
to authenticated
with check (profile_id = (select auth.uid()));

drop policy if exists "profile_phones_update_self"
on public.profile_phone_numbers;
create policy "profile_phones_update_self"
on public.profile_phone_numbers
for update
to authenticated
using (profile_id = (select auth.uid()))
with check (profile_id = (select auth.uid()));

revoke all on table public.profile_phone_numbers from authenticated;
grant select, insert, update on table public.profile_phone_numbers to authenticated;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  base_username text;
  generated_username text;
  submitted_name text;
  submitted_phone text;
begin
  submitted_name := trim(
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'display_name', ''),
      ''
    )
  );
  submitted_phone := trim(coalesce(new.raw_user_meta_data ->> 'phone_e164', ''));

  if char_length(submitted_name) < 5 or submitted_name !~ '\s' then
    raise exception 'Full name is required';
  end if;

  if submitted_phone !~ '^\+7[0-9]{10}$' then
    raise exception 'Valid Russian phone is required';
  end if;

  base_username := regexp_replace(lower(submitted_name), '[^a-z0-9_]+', '', 'g');
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
    submitted_name,
    '',
    'offline',
    null,
    now(),
    now()
  )
  on conflict (id) do update
  set display_name = excluded.display_name, updated_at = now();

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

  safe_query := trim(regexp_replace(coalesce(p_query, ''), '\s+', ' ', 'g'));
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
    and p.display_name ilike '%' || safe_query || '%' escape '\'
  order by p.display_name
  limit 20;
end;
$$;

revoke all on function public.search_profiles_by_name(text)
from public, anon, authenticated;
grant execute on function public.search_profiles_by_name(text) to authenticated;
