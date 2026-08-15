-- Add immutable ICQ-style contact numbers and private contact lists.

alter table public.profiles
  add column if not exists contact_number bigint
  generated always as identity (start with 10000000);

create unique index if not exists profiles_contact_number_idx
on public.profiles (contact_number);

revoke update on table public.profiles from authenticated;
grant update (
  username,
  display_name,
  avatar_url,
  bio,
  status,
  last_seen,
  updated_at
) on table public.profiles to authenticated;

create table if not exists public.contacts (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  contact_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (owner_id, contact_id),
  constraint contacts_cannot_add_self check (owner_id <> contact_id)
);

create index if not exists contacts_contact_id_idx
on public.contacts (contact_id);

alter table public.contacts enable row level security;

create policy "contacts_select_own"
on public.contacts
for select
to authenticated
using ((select auth.uid()) = owner_id);

create policy "contacts_insert_own"
on public.contacts
for insert
to authenticated
with check (
  (select auth.uid()) = owner_id
  and owner_id <> contact_id
);

create policy "contacts_delete_own"
on public.contacts
for delete
to authenticated
using ((select auth.uid()) = owner_id);

revoke all on table public.contacts from anon;
revoke all on table public.contacts from authenticated;
grant select, insert, delete on table public.contacts to authenticated;
