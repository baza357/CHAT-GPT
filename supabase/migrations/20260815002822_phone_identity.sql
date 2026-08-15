-- Use verified Russian phone numbers as the public contact identifier.

create table public.profile_phone_numbers (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  phone_e164 text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profile_phone_numbers_russian_format
    check (phone_e164 ~ '^\+7[0-9]{10}$')
);

alter table public.profile_phone_numbers enable row level security;

create policy "profile_phones_select_self_or_contact"
on public.profile_phone_numbers
for select
to authenticated
using (
  profile_id = (select auth.uid())
  or exists (
    select 1
    from public.contacts c
    where c.owner_id = (select auth.uid())
      and c.contact_id = profile_phone_numbers.profile_id
  )
);

revoke all on table public.profile_phone_numbers from anon;
revoke all on table public.profile_phone_numbers from authenticated;
grant select on table public.profile_phone_numbers to authenticated;

create or replace function private.sync_verified_user_phone()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.phone is not null and new.phone_confirmed_at is not null then
    insert into public.profile_phone_numbers (
      profile_id,
      phone_e164,
      created_at,
      updated_at
    )
    values (new.id, new.phone, now(), now())
    on conflict (profile_id) do update
    set
      phone_e164 = excluded.phone_e164,
      updated_at = now();
  elsif old.phone is distinct from new.phone or new.phone_confirmed_at is null then
    delete from public.profile_phone_numbers
    where profile_id = new.id;
  end if;

  return new;
end;
$$;

revoke all on function private.sync_verified_user_phone()
from public, anon, authenticated;

create trigger on_auth_user_phone_verified
after update of phone, phone_confirmed_at on auth.users
for each row execute function private.sync_verified_user_phone();

insert into public.profile_phone_numbers (profile_id, phone_e164)
select u.id, u.phone
from auth.users u
where u.phone is not null
  and u.phone_confirmed_at is not null
on conflict (profile_id) do update
set
  phone_e164 = excluded.phone_e164,
  updated_at = now();

create or replace function public.find_profile_by_phone(p_phone_e164 text)
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
begin
  if (select auth.uid()) is null then
    raise exception 'Not authenticated';
  end if;

  if p_phone_e164 is null or p_phone_e164 !~ '^\+7[0-9]{10}$' then
    return;
  end if;

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
  from public.profile_phone_numbers ph
  join public.profiles p on p.id = ph.profile_id
  where ph.phone_e164 = p_phone_e164
    and p.id <> (select auth.uid())
  limit 1;
end;
$$;

revoke all on function public.find_profile_by_phone(text)
from public, anon, authenticated;
grant execute on function public.find_profile_by_phone(text) to authenticated;
