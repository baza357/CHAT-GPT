-- ============================================================
-- Messenger MVP: схема Supabase
-- Запускайте этот файл ОДИН РАЗ в Supabase -> SQL Editor.
-- ============================================================

create extension if not exists pgcrypto;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

-- ---------- Profiles ----------

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique check (
    username = lower(username)
    and char_length(username) between 3 and 320
    and position('@' in username) > 1
  ),
  display_name text not null,
  avatar_url text,
  bio text not null default '',
  status text not null default 'offline',
  last_seen timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists profiles_display_name_idx
on public.profiles (display_name);

create unique index if not exists profiles_username_lower_idx
on public.profiles (lower(username));

alter table public.profiles enable row level security;

drop policy if exists "profiles_select_authenticated" on public.profiles;
drop policy if exists "profiles_select_self_or_contact" on public.profiles;
create policy "profiles_select_self"
on public.profiles
for select
to authenticated
using (id = (select auth.uid()));

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self"
on public.profiles
for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

revoke all on table public.profiles from anon;
grant select on table public.profiles to authenticated;
grant update (
  display_name,
  avatar_url,
  bio,
  status,
  last_seen,
  updated_at
) on table public.profiles to authenticated;

-- Автоматически создаём профиль после регистрации.
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

drop trigger if exists on_auth_user_created on auth.users;
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

-- ---------- Contacts ----------

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

drop policy if exists "contacts_select_own" on public.contacts;
create policy "contacts_select_own"
on public.contacts
for select
to authenticated
using ((select auth.uid()) = owner_id);

drop policy if exists "contacts_insert_own" on public.contacts;
create policy "contacts_insert_own"
on public.contacts
for insert
to authenticated
with check (
  (select auth.uid()) = owner_id
  and owner_id <> contact_id
);

drop policy if exists "contacts_delete_own" on public.contacts;
create policy "contacts_delete_own"
on public.contacts
for delete
to authenticated
using ((select auth.uid()) = owner_id);

revoke all on table public.contacts from anon;
grant select, insert, delete on table public.contacts to authenticated;

drop policy if exists "profiles_select_self" on public.profiles;
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

-- ---------- Verified phone directory ----------

create table if not exists public.profile_phone_numbers (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  phone_e164 text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint profile_phone_numbers_russian_format
    check (phone_e164 ~ '^\+7[0-9]{10}$')
);

alter table public.profile_phone_numbers enable row level security;

drop policy if exists "profile_phones_select_self_or_contact"
on public.profile_phone_numbers;
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

revoke all on table public.profile_phone_numbers from anon;
revoke all on table public.profile_phone_numbers from authenticated;
grant select, insert, update on table public.profile_phone_numbers to authenticated;

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
  select p.id, ph.phone_e164, p.username, p.display_name, p.avatar_url,
    p.bio, p.status, p.last_seen, p.created_at, p.updated_at
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
  select p.id, ph.phone_e164, p.username, p.display_name, p.avatar_url,
    p.bio, p.status, p.last_seen, p.created_at, p.updated_at
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

-- ---------- Chats ----------

create table if not exists public.chats (
  id uuid primary key default gen_random_uuid(),
  type text not null default 'direct' check (type in ('direct', 'group')),
  created_at timestamptz not null default now()
);

create table if not exists public.chat_members (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (chat_id, user_id)
);

create index if not exists chat_members_user_id_idx
on public.chat_members (user_id);

alter table public.chats enable row level security;
alter table public.chat_members enable row level security;

-- Для MVP клиент не читает chat_members напрямую.
-- Доступ к созданию/поиску личного чата выполняет функция start_direct_chat().

-- ---------- Messages ----------

create table if not exists public.messages (
  id bigint generated by default as identity primary key,
  chat_id uuid not null references public.chats(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 4000),
  created_at timestamptz not null default now()
);

create index if not exists messages_chat_created_idx
on public.messages (chat_id, created_at);

create index if not exists messages_sender_id_idx
on public.messages (sender_id);

alter table public.messages enable row level security;

drop policy if exists "messages_select_if_member" on public.messages;
create policy "messages_select_if_member"
on public.messages
for select
to authenticated
using (
  exists (
    select 1
    from public.chat_members cm
    where cm.chat_id = messages.chat_id
      and cm.user_id = (select auth.uid())
  )
);

drop policy if exists "messages_insert_if_member" on public.messages;
create policy "messages_insert_if_member"
on public.messages
for insert
to authenticated
with check (
  sender_id = (select auth.uid())
  and exists (
    select 1
    from public.chat_members cm
    where cm.chat_id = messages.chat_id
      and cm.user_id = (select auth.uid())
  )
);

-- ---------- RPC: открыть или создать личный чат ----------

create or replace function public.start_direct_chat(p_other_user uuid)
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_me uuid := auth.uid();
  v_chat_id uuid;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  if p_other_user is null or p_other_user = v_me then
    raise exception 'Invalid other user';
  end if;

  if not exists (select 1 from auth.users where id = p_other_user) then
    raise exception 'User not found';
  end if;

  -- Ищем direct-чат, где ровно два участника: текущий и выбранный пользователь.
  select c.id
  into v_chat_id
  from public.chats c
  where c.type = 'direct'
    and exists (
      select 1
      from public.chat_members cm
      where cm.chat_id = c.id and cm.user_id = v_me
    )
    and exists (
      select 1
      from public.chat_members cm
      where cm.chat_id = c.id and cm.user_id = p_other_user
    )
    and (
      select count(*)
      from public.chat_members cm
      where cm.chat_id = c.id
    ) = 2
  order by c.created_at
  limit 1;

  if v_chat_id is not null then
    return v_chat_id;
  end if;

  insert into public.chats (type)
  values ('direct')
  returning id into v_chat_id;

  insert into public.chat_members (chat_id, user_id)
  values
    (v_chat_id, v_me),
    (v_chat_id, p_other_user);

  return v_chat_id;
end;
$$;

revoke all on function public.start_direct_chat(uuid) from public, anon;
grant execute on function public.start_direct_chat(uuid) to authenticated;

-- ---------- Realtime ----------

-- Postgres Changes требует публикацию таблицы.
-- Блок ниже безопасно проверяет, добавлена ли таблица messages.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;

-- ---------- Messaging attachments and calendar ----------

-- Fix chat membership checks, add private message attachments and personal contact tasks.

-- Signed-in users may only inspect their own membership row. This makes the
-- messages RLS membership subquery work without exposing other chat members.
drop policy if exists "chat_members_select_self" on public.chat_members;
create policy "chat_members_select_self"
on public.chat_members
for select
to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "chats_select_if_member" on public.chats;
create policy "chats_select_if_member"
on public.chats
for select
to authenticated
using (
  exists (
    select 1
    from public.chat_members cm
    where cm.chat_id = chats.id
      and cm.user_id = (select auth.uid())
  )
);

-- Replace Supabase's broad default table grants with the minimum used by the client.
revoke all on table public.chats from anon, authenticated;
revoke all on table public.chat_members from anon, authenticated;
revoke all on table public.messages from anon, authenticated;
grant select on table public.chats to authenticated;
grant select on table public.chat_members to authenticated;
grant select, insert on table public.messages to authenticated;
grant usage, select on sequence public.messages_id_seq to authenticated;

alter table public.messages
  add column if not exists attachment_path text,
  add column if not exists attachment_name text,
  add column if not exists attachment_type text,
  add column if not exists attachment_size bigint;

alter table public.messages
  alter column body set default '',
  alter column body drop not null;

alter table public.messages
  drop constraint if exists messages_body_check;

alter table public.messages
  drop constraint if exists messages_content_check;

alter table public.messages
  add constraint messages_content_check check (
    char_length(coalesce(body, '')) <= 4000
    and (
      char_length(trim(coalesce(body, ''))) > 0
      or attachment_path is not null
    )
    and (
      attachment_path is null
      or (
        attachment_name is not null
        and attachment_type is not null
        and attachment_size between 1 and 20971520
      )
    )
  );

insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'message-attachments',
  'message-attachments',
  false,
  20971520,
  array[
    'image/jpeg',
    'image/png',
    'image/webp',
    'image/gif',
    'application/pdf',
    'text/plain',
    'application/zip',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
  ]::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "message_attachments_insert_member" on storage.objects;
create policy "message_attachments_insert_member"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'message-attachments'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and exists (
    select 1
    from public.chat_members cm
    where cm.user_id = (select auth.uid())
      and cm.chat_id = ((storage.foldername(name))[2])::uuid
  )
);

drop policy if exists "message_attachments_select_member" on storage.objects;
create policy "message_attachments_select_member"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'message-attachments'
  and exists (
    select 1
    from public.chat_members cm
    where cm.user_id = (select auth.uid())
      and cm.chat_id = ((storage.foldername(name))[2])::uuid
  )
);

drop policy if exists "message_attachments_delete_owner" on storage.objects;
create policy "message_attachments_delete_owner"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'message-attachments'
  and owner_id = (select auth.uid())::text
);

-- Calendar tasks belong to one owner and are assigned to one of their contacts.
create table if not exists public.calendar_tasks (
  id bigint generated by default as identity primary key,
  owner_id uuid not null references auth.users(id) on delete cascade,
  contact_id uuid not null references public.profiles(id) on delete cascade,
  title text not null,
  notes text not null default '',
  starts_at timestamptz not null,
  ends_at timestamptz,
  status text not null default 'planned',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint calendar_tasks_title_check check (char_length(trim(title)) between 1 and 200),
  constraint calendar_tasks_notes_check check (char_length(notes) <= 2000),
  constraint calendar_tasks_status_check check (status in ('planned', 'done')),
  constraint calendar_tasks_time_check check (ends_at is null or ends_at > starts_at)
);

create index if not exists calendar_tasks_owner_starts_idx
on public.calendar_tasks (owner_id, starts_at);

create index if not exists calendar_tasks_contact_id_idx
on public.calendar_tasks (contact_id);

alter table public.calendar_tasks enable row level security;

drop policy if exists "calendar_tasks_select_own" on public.calendar_tasks;
create policy "calendar_tasks_select_own"
on public.calendar_tasks
for select
to authenticated
using (owner_id = (select auth.uid()));

drop policy if exists "calendar_tasks_insert_own_contact" on public.calendar_tasks;
create policy "calendar_tasks_insert_own_contact"
on public.calendar_tasks
for insert
to authenticated
with check (
  owner_id = (select auth.uid())
  and (
    contact_id = (select auth.uid())
    or exists (
      select 1
      from public.contacts c
      where c.owner_id = (select auth.uid())
        and c.contact_id = calendar_tasks.contact_id
    )
  )
);

drop policy if exists "calendar_tasks_update_own_contact" on public.calendar_tasks;
create policy "calendar_tasks_update_own_contact"
on public.calendar_tasks
for update
to authenticated
using (owner_id = (select auth.uid()))
with check (
  owner_id = (select auth.uid())
  and (
    contact_id = (select auth.uid())
    or exists (
      select 1
      from public.contacts c
      where c.owner_id = (select auth.uid())
        and c.contact_id = calendar_tasks.contact_id
    )
  )
);

drop policy if exists "calendar_tasks_delete_own" on public.calendar_tasks;
create policy "calendar_tasks_delete_own"
on public.calendar_tasks
for delete
to authenticated
using (owner_id = (select auth.uid()));

revoke all on table public.calendar_tasks from anon, authenticated;
grant select, insert, update, delete on table public.calendar_tasks to authenticated;
grant usage, select on sequence public.calendar_tasks_id_seq to authenticated;

create or replace function private.set_calendar_task_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function private.set_calendar_task_updated_at()
from public, anon, authenticated;

drop trigger if exists calendar_tasks_set_updated_at on public.calendar_tasks;
create trigger calendar_tasks_set_updated_at
before update on public.calendar_tasks
for each row execute function private.set_calendar_task_updated_at();

-- ---------- Shared tasks, groups, avatars and audio calls ----------

create or replace function private.is_chat_member(p_chat_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
    and exists (
      select 1
      from public.chat_members cm
      where cm.chat_id = p_chat_id
        and cm.user_id = (select auth.uid())
    );
$$;

grant usage on schema private to authenticated;
revoke all on function private.is_chat_member(uuid) from public, anon, authenticated;
grant execute on function private.is_chat_member(uuid) to authenticated;

alter table public.chats
  add column if not exists title text,
  add column if not exists avatar_url text,
  add column if not exists created_by uuid references auth.users(id) on delete set null;

update public.chats
set title = 'Групповой чат'
where type = 'group' and nullif(trim(title), '') is null;

alter table public.chats drop constraint if exists chats_group_title_check;
alter table public.chats add constraint chats_group_title_check check (
  type = 'direct'
  or char_length(trim(coalesce(title, ''))) between 1 and 80
);

create index if not exists chats_created_by_idx on public.chats (created_by);

alter table public.chat_members
  add column if not exists role text not null default 'member';
alter table public.chat_members drop constraint if exists chat_members_role_check;
alter table public.chat_members
  add constraint chat_members_role_check check (role in ('owner', 'member'));

drop policy if exists "chat_members_select_self" on public.chat_members;
drop policy if exists "chat_members_select_shared_chat" on public.chat_members;
create policy "chat_members_select_shared_chat"
on public.chat_members
for select
to authenticated
using (private.is_chat_member(chat_id));

drop policy if exists "chats_select_if_member" on public.chats;
create policy "chats_select_if_member"
on public.chats
for select
to authenticated
using (private.is_chat_member(id));

drop policy if exists "messages_select_if_member" on public.messages;
create policy "messages_select_if_member"
on public.messages
for select
to authenticated
using (private.is_chat_member(chat_id));

drop policy if exists "messages_insert_if_member" on public.messages;
create policy "messages_insert_if_member"
on public.messages
for insert
to authenticated
with check (
  sender_id = (select auth.uid())
  and private.is_chat_member(chat_id)
);

create or replace function public.create_group_chat(
  p_title text,
  p_member_ids uuid[]
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_me uuid := auth.uid();
  v_title text := trim(coalesce(p_title, ''));
  v_members uuid[];
  v_chat_id uuid;
begin
  if v_me is null then
    raise exception 'Not authenticated';
  end if;

  if char_length(v_title) < 1 or char_length(v_title) > 80 then
    raise exception 'Group title must contain 1 to 80 characters';
  end if;

  select array_agg(distinct member_id)
  into v_members
  from unnest(coalesce(p_member_ids, array[]::uuid[])) as member_id
  where member_id is not null and member_id <> v_me;

  if coalesce(cardinality(v_members), 0) < 1
    or cardinality(v_members) > 49 then
    raise exception 'A group requires 1 to 49 other members';
  end if;

  if exists (
    select 1
    from unnest(v_members) as member_id
    where not exists (
      select 1
      from public.contacts c
      where c.owner_id = v_me and c.contact_id = member_id
    )
  ) then
    raise exception 'Every group member must be in your contacts';
  end if;

  insert into public.chats (type, title, created_by)
  values ('group', v_title, v_me)
  returning id into v_chat_id;

  insert into public.chat_members (chat_id, user_id, role)
  values (v_chat_id, v_me, 'owner');

  insert into public.chat_members (chat_id, user_id, role)
  select v_chat_id, member_id, 'member'
  from unnest(v_members) as member_id;

  return v_chat_id;
end;
$$;

revoke all on function public.create_group_chat(text, uuid[])
from public, anon, authenticated;
grant execute on function public.create_group_chat(text, uuid[]) to authenticated;

drop policy if exists "calendar_tasks_select_own" on public.calendar_tasks;
drop policy if exists "calendar_tasks_select_participant" on public.calendar_tasks;
create policy "calendar_tasks_select_participant"
on public.calendar_tasks
for select
to authenticated
using (owner_id = (select auth.uid()) or contact_id = (select auth.uid()));

drop policy if exists "calendar_tasks_update_own_contact" on public.calendar_tasks;
drop policy if exists "calendar_tasks_update_participant" on public.calendar_tasks;
create policy "calendar_tasks_update_participant"
on public.calendar_tasks
for update
to authenticated
using (owner_id = (select auth.uid()) or contact_id = (select auth.uid()))
with check (owner_id = (select auth.uid()) or contact_id = (select auth.uid()));

revoke update on table public.calendar_tasks from authenticated;
grant update (status) on table public.calendar_tasks to authenticated;

create index if not exists calendar_tasks_contact_starts_idx
on public.calendar_tasks (contact_id, starts_at);

insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
values (
  'avatars', 'avatars', true, 5242880,
  array['image/jpeg', 'image/png', 'image/webp']::text[]
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "avatars_insert_own" on storage.objects;
create policy "avatars_insert_own"
on storage.objects
for insert
to authenticated
with check (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists "avatars_select_own" on storage.objects;
create policy "avatars_select_own"
on storage.objects
for select
to authenticated
using (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists "avatars_update_own" on storage.objects;
create policy "avatars_update_own"
on storage.objects
for update
to authenticated
using (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
)
with check (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

drop policy if exists "avatars_delete_own" on storage.objects;
create policy "avatars_delete_own"
on storage.objects
for delete
to authenticated
using (
  bucket_id = 'avatars'
  and (storage.foldername(name))[1] = (select auth.uid())::text
);

create table if not exists public.calls (
  id uuid primary key default gen_random_uuid(),
  caller_id uuid not null references public.profiles(id) on delete cascade,
  callee_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'ringing',
  offer jsonb not null,
  answer jsonb,
  created_at timestamptz not null default now(),
  accepted_at timestamptz,
  ended_at timestamptz,
  updated_at timestamptz not null default now(),
  constraint calls_different_users_check check (caller_id <> callee_id),
  constraint calls_status_check check (status in ('ringing', 'accepted', 'declined', 'ended', 'missed')),
  constraint calls_offer_object_check check (jsonb_typeof(offer) = 'object' and octet_length(offer::text) <= 65536),
  constraint calls_answer_object_check check (answer is null or (jsonb_typeof(answer) = 'object' and octet_length(answer::text) <= 65536))
);

create index if not exists calls_callee_status_created_idx
on public.calls (callee_id, status, created_at desc);
create index if not exists calls_caller_created_idx
on public.calls (caller_id, created_at desc);

alter table public.calls enable row level security;

drop policy if exists "calls_select_participant" on public.calls;
create policy "calls_select_participant"
on public.calls
for select
to authenticated
using (caller_id = (select auth.uid()) or callee_id = (select auth.uid()));

drop policy if exists "calls_insert_caller_contact" on public.calls;
create policy "calls_insert_caller_contact"
on public.calls
for insert
to authenticated
with check (
  caller_id = (select auth.uid())
  and status = 'ringing'
  and exists (
    select 1
    from public.contacts c
    where c.owner_id = (select auth.uid())
      and c.contact_id = calls.callee_id
  )
);

drop policy if exists "calls_update_participant" on public.calls;
create policy "calls_update_participant"
on public.calls
for update
to authenticated
using (caller_id = (select auth.uid()) or callee_id = (select auth.uid()))
with check (caller_id = (select auth.uid()) or callee_id = (select auth.uid()));

revoke all on table public.calls from anon, authenticated;
grant select, insert on table public.calls to authenticated;
grant update (status, answer, accepted_at, ended_at) on table public.calls to authenticated;

create or replace function private.set_call_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function private.set_call_updated_at()
from public, anon, authenticated;

drop trigger if exists calls_set_updated_at on public.calls;
create trigger calls_set_updated_at
before update on public.calls
for each row execute function private.set_call_updated_at();

drop policy if exists "profiles_select_self_or_contact" on public.profiles;
drop policy if exists "profiles_select_related_user" on public.profiles;
create policy "profiles_select_related_user"
on public.profiles
for select
to authenticated
using (
  id = (select auth.uid())
  or exists (
    select 1 from public.contacts c
    where c.owner_id = (select auth.uid()) and c.contact_id = profiles.id
  )
  or exists (
    select 1 from public.chat_members cm
    where cm.user_id = profiles.id and private.is_chat_member(cm.chat_id)
  )
  or exists (
    select 1 from public.calendar_tasks task
    where (
      task.owner_id = (select auth.uid()) and task.contact_id = profiles.id
    ) or (
      task.contact_id = (select auth.uid()) and task.owner_id = profiles.id
    )
  )
  or exists (
    select 1 from public.calls call_row
    where (
      call_row.caller_id = (select auth.uid()) and call_row.callee_id = profiles.id
    ) or (
      call_row.callee_id = (select auth.uid()) and call_row.caller_id = profiles.id
    )
  )
);

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'calendar_tasks'
  ) then
    alter publication supabase_realtime add table public.calendar_tasks;
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'calls'
  ) then
    alter publication supabase_realtime add table public.calls;
  end if;
end $$;

-- ---------- Notifications and read states ----------

create table if not exists public.chat_read_states (
  chat_id uuid not null references public.chats(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (chat_id, user_id)
);

create index if not exists chat_read_states_user_read_idx
on public.chat_read_states (user_id, last_read_at);

alter table public.chat_read_states enable row level security;

drop policy if exists "chat_read_states_select_self" on public.chat_read_states;
create policy "chat_read_states_select_self"
on public.chat_read_states for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "chat_read_states_insert_self" on public.chat_read_states;
create policy "chat_read_states_insert_self"
on public.chat_read_states for insert to authenticated
with check (user_id = (select auth.uid()) and private.is_chat_member(chat_id));

drop policy if exists "chat_read_states_update_self" on public.chat_read_states;
create policy "chat_read_states_update_self"
on public.chat_read_states for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()) and private.is_chat_member(chat_id));

revoke all on table public.chat_read_states from anon, authenticated;
grant select, insert, update on table public.chat_read_states to authenticated;

insert into public.chat_read_states (chat_id, user_id, last_read_at)
select cm.chat_id, cm.user_id, now()
from public.chat_members cm
on conflict (chat_id, user_id) do nothing;

create or replace function public.get_unread_chat_counts()
returns table (chat_id uuid, unread_count bigint)
language sql
stable
security invoker
set search_path = ''
as $$
  select cm.chat_id, count(message_row.id)::bigint as unread_count
  from public.chat_members cm
  left join public.chat_read_states read_state
    on read_state.chat_id = cm.chat_id and read_state.user_id = cm.user_id
  join public.messages message_row
    on message_row.chat_id = cm.chat_id
   and message_row.sender_id <> cm.user_id
   and message_row.created_at > coalesce(read_state.last_read_at, 'epoch'::timestamptz)
  where cm.user_id = (select auth.uid())
  group by cm.chat_id;
$$;

revoke all on function public.get_unread_chat_counts()
from public, anon, authenticated;
grant execute on function public.get_unread_chat_counts() to authenticated;

create table if not exists public.calendar_task_receipts (
  task_id bigint not null references public.calendar_tasks(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  seen_at timestamptz not null default now(),
  primary key (task_id, user_id)
);

create index if not exists calendar_task_receipts_user_seen_idx
on public.calendar_task_receipts (user_id, seen_at);

alter table public.calendar_task_receipts enable row level security;

drop policy if exists "calendar_task_receipts_select_self" on public.calendar_task_receipts;
create policy "calendar_task_receipts_select_self"
on public.calendar_task_receipts for select to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "calendar_task_receipts_insert_assignee" on public.calendar_task_receipts;
create policy "calendar_task_receipts_insert_assignee"
on public.calendar_task_receipts for insert to authenticated
with check (
  user_id = (select auth.uid())
  and exists (
    select 1 from public.calendar_tasks task
    where task.id = calendar_task_receipts.task_id
      and task.contact_id = (select auth.uid())
      and task.owner_id <> (select auth.uid())
  )
);

drop policy if exists "calendar_task_receipts_update_self" on public.calendar_task_receipts;
create policy "calendar_task_receipts_update_self"
on public.calendar_task_receipts for update to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

revoke all on table public.calendar_task_receipts from anon, authenticated;
grant select, insert, update on table public.calendar_task_receipts to authenticated;

-- Mirror assigned tasks and read receipts into a protected direct conversation.

alter table public.messages
  add column if not exists task_id bigint references public.calendar_tasks(id) on delete cascade,
  add column if not exists task_event text;

alter table public.messages
  drop constraint if exists messages_task_event_check;
alter table public.messages
  add constraint messages_task_event_check check (
    task_event is null or task_event in ('assignment', 'read')
  );

create index if not exists messages_task_id_idx
on public.messages (task_id)
where task_id is not null;

create unique index if not exists messages_task_event_unique_idx
on public.messages (task_id, task_event)
where task_id is not null and task_event is not null;

-- A browser client may send ordinary messages, but task events are server-only.
revoke insert on table public.messages from authenticated;
grant insert (
  chat_id,
  sender_id,
  body,
  attachment_path,
  attachment_name,
  attachment_type,
  attachment_size
) on table public.messages to authenticated;

create or replace function private.ensure_direct_chat(
  p_first_user uuid,
  p_second_user uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_chat_id uuid;
begin
  if p_first_user is null or p_second_user is null or p_first_user = p_second_user then
    raise exception 'Invalid direct chat participants';
  end if;

  select chat.id
  into v_chat_id
  from public.chats chat
  where chat.type = 'direct'
    and exists (
      select 1 from public.chat_members member
      where member.chat_id = chat.id and member.user_id = p_first_user
    )
    and exists (
      select 1 from public.chat_members member
      where member.chat_id = chat.id and member.user_id = p_second_user
    )
    and (
      select count(*) from public.chat_members member
      where member.chat_id = chat.id
    ) = 2
  order by chat.created_at
  limit 1;

  if v_chat_id is null then
    insert into public.chats (type, created_by)
    values ('direct', p_first_user)
    returning id into v_chat_id;

    insert into public.chat_members (chat_id, user_id, role)
    values
      (v_chat_id, p_first_user, 'member'),
      (v_chat_id, p_second_user, 'member');
  end if;

  return v_chat_id;
end;
$$;

revoke all on function private.ensure_direct_chat(uuid, uuid)
from public, anon, authenticated;

create or replace function private.mirror_calendar_task_to_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_chat_id uuid;
begin
  if new.owner_id = new.contact_id then
    return new;
  end if;

  v_chat_id := private.ensure_direct_chat(new.owner_id, new.contact_id);

  insert into public.messages (
    chat_id,
    sender_id,
    body,
    task_id,
    task_event
  )
  values (
    v_chat_id,
    new.owner_id,
    'Вам назначена задача: ' || new.title,
    new.id,
    'assignment'
  )
  on conflict do nothing;

  return new;
end;
$$;

revoke all on function private.mirror_calendar_task_to_message()
from public, anon, authenticated;

drop trigger if exists calendar_tasks_mirror_to_message on public.calendar_tasks;
create trigger calendar_tasks_mirror_to_message
after insert on public.calendar_tasks
for each row execute function private.mirror_calendar_task_to_message();

create or replace function private.mirror_task_receipt_to_message()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.calendar_tasks%rowtype;
  v_chat_id uuid;
begin
  select task.*
  into v_task
  from public.calendar_tasks task
  where task.id = new.task_id;

  if not found or new.user_id <> v_task.contact_id or v_task.owner_id = v_task.contact_id then
    return new;
  end if;

  v_chat_id := private.ensure_direct_chat(v_task.owner_id, v_task.contact_id);

  insert into public.messages (
    chat_id,
    sender_id,
    body,
    task_id,
    task_event
  )
  values (
    v_chat_id,
    new.user_id,
    'Задача прочитана: ' || v_task.title,
    v_task.id,
    'read'
  )
  on conflict do nothing;

  return new;
end;
$$;

revoke all on function private.mirror_task_receipt_to_message()
from public, anon, authenticated;

drop trigger if exists calendar_task_receipts_mirror_to_message on public.calendar_task_receipts;
create trigger calendar_task_receipts_mirror_to_message
after insert on public.calendar_task_receipts
for each row execute function private.mirror_task_receipt_to_message();

-- Show message read state to chat participants and deliver task receipts as notifications.

drop policy if exists "chat_read_states_select_self" on public.chat_read_states;
drop policy if exists "chat_read_states_select_participants" on public.chat_read_states;
create policy "chat_read_states_select_participants"
on public.chat_read_states
for select
to authenticated
using (
  user_id = (select auth.uid())
  or private.is_chat_member(chat_id)
);

create or replace function public.mark_chat_read(p_chat_id uuid)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.chat_read_states (chat_id, user_id, last_read_at)
  values (p_chat_id, (select auth.uid()), now())
  on conflict (chat_id, user_id) do update
  set last_read_at = greatest(
    public.chat_read_states.last_read_at,
    excluded.last_read_at
  );
$$;

revoke all on function public.mark_chat_read(uuid)
from public, anon, authenticated;
grant execute on function public.mark_chat_read(uuid) to authenticated;

drop policy if exists "calendar_task_receipts_select_self" on public.calendar_task_receipts;
drop policy if exists "calendar_task_receipts_select_participants" on public.calendar_task_receipts;
create policy "calendar_task_receipts_select_participants"
on public.calendar_task_receipts
for select
to authenticated
using (
  user_id = (select auth.uid())
  or exists (
    select 1
    from public.calendar_tasks task
    where task.id = calendar_task_receipts.task_id
      and task.owner_id = (select auth.uid())
  )
);

-- Task-read acknowledgements are notifications, not chat messages.
drop trigger if exists calendar_task_receipts_mirror_to_message on public.calendar_task_receipts;
drop function if exists private.mirror_task_receipt_to_message();
delete from public.messages where task_event = 'read';

do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'chat_read_states'
  ) then
    alter publication supabase_realtime add table public.chat_read_states;
  end if;

  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'calendar_task_receipts'
  ) then
    alter publication supabase_realtime add table public.calendar_task_receipts;
  end if;
end;
$$;

-- Employee profile fields and reliable task completion attribution.

alter table public.profiles
  add column if not exists personal_number text,
  add column if not exists shift_number smallint,
  add column if not exists job_title text;

alter table public.profiles
  drop constraint if exists profiles_personal_number_check;
alter table public.profiles
  add constraint profiles_personal_number_check check (
    personal_number is null or personal_number ~ '^[0-9]{1,4}$'
  );

alter table public.profiles
  drop constraint if exists profiles_shift_number_check;
alter table public.profiles
  add constraint profiles_shift_number_check check (
    shift_number is null or shift_number in (1, 2, 5)
  );

alter table public.profiles
  drop constraint if exists profiles_job_title_check;
alter table public.profiles
  add constraint profiles_job_title_check check (
    job_title is null or char_length(trim(job_title)) between 1 and 120
  );

create unique index if not exists profiles_personal_number_unique_idx
on public.profiles (personal_number)
where personal_number is not null;

grant update (
  personal_number,
  shift_number,
  job_title
) on table public.profiles to authenticated;

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
  submitted_personal_number text;
  submitted_shift_text text;
  submitted_shift smallint;
  submitted_job_title text;
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
  submitted_personal_number := nullif(trim(coalesce(new.raw_user_meta_data ->> 'personal_number', '')), '');
  submitted_shift_text := nullif(trim(coalesce(new.raw_user_meta_data ->> 'shift_number', '')), '');
  submitted_job_title := nullif(trim(coalesce(new.raw_user_meta_data ->> 'job_title', '')), '');

  if position('@' in submitted_email) <= 1 then
    raise exception 'Valid email is required';
  end if;
  if char_length(submitted_name) < 5 or submitted_name !~ '\s' then
    raise exception 'Full name is required';
  end if;
  if submitted_phone !~ '^\+7[0-9]{10}$' then
    raise exception 'Valid Russian phone is required';
  end if;
  if submitted_personal_number is not null and submitted_personal_number !~ '^[0-9]{1,4}$' then
    raise exception 'Personal number must contain up to four digits';
  end if;
  if submitted_shift_text is not null and submitted_shift_text not in ('1', '2', '5') then
    raise exception 'Shift number must be 1, 2 or 5/2';
  end if;
  if submitted_job_title is not null and char_length(submitted_job_title) > 120 then
    raise exception 'Job title is too long';
  end if;

  submitted_shift := submitted_shift_text::smallint;

  insert into public.profiles (
    id,
    username,
    display_name,
    personal_number,
    shift_number,
    job_title,
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
    submitted_personal_number,
    submitted_shift,
    submitted_job_title,
    '',
    'offline',
    null,
    now(),
    now()
  )
  on conflict (id) do update
  set username = excluded.username,
      display_name = excluded.display_name,
      personal_number = excluded.personal_number,
      shift_number = excluded.shift_number,
      job_title = excluded.job_title,
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

alter table public.calendar_tasks
  add column if not exists completed_by uuid references public.profiles(id) on delete set null,
  add column if not exists completed_at timestamptz;

create index if not exists calendar_tasks_completed_by_idx
on public.calendar_tasks (completed_by)
where completed_by is not null;

create or replace function private.set_calendar_task_completion()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.status = 'done' and old.status is distinct from 'done' then
    new.completed_by := (select auth.uid());
    new.completed_at := now();
  elsif new.status = 'planned' and old.status is distinct from 'planned' then
    new.completed_by := null;
    new.completed_at := null;
  end if;
  return new;
end;
$$;

revoke all on function private.set_calendar_task_completion()
from public, anon, authenticated;

drop trigger if exists calendar_tasks_set_completion on public.calendar_tasks;
create trigger calendar_tasks_set_completion
before update of status on public.calendar_tasks
for each row execute function private.set_calendar_task_completion();

-- Completion notifications filter by task owner, so this index is unnecessary.
drop index if exists public.calendar_tasks_completed_by_idx;

-- Fixed workplace directory for employee profiles.

alter table public.profiles
  add column if not exists workplace text;

alter table public.profiles
  drop constraint if exists profiles_workplace_check;
alter table public.profiles
  add constraint profiles_workplace_check check (
    workplace is null
    or workplace in ('ПЦ Рябиновая', 'ПЦ Алтуфьево-1', 'ПЦ Алтуфьево-2')
  );

grant update (workplace) on table public.profiles to authenticated;

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
  submitted_personal_number text;
  submitted_shift_text text;
  submitted_shift smallint;
  submitted_job_title text;
  submitted_workplace text;
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
  submitted_personal_number := nullif(trim(coalesce(new.raw_user_meta_data ->> 'personal_number', '')), '');
  submitted_shift_text := nullif(trim(coalesce(new.raw_user_meta_data ->> 'shift_number', '')), '');
  submitted_job_title := nullif(trim(coalesce(new.raw_user_meta_data ->> 'job_title', '')), '');
  submitted_workplace := nullif(trim(coalesce(new.raw_user_meta_data ->> 'workplace', '')), '');

  if position('@' in submitted_email) <= 1 then
    raise exception 'Valid email is required';
  end if;
  if char_length(submitted_name) < 5 or submitted_name !~ '\s' then
    raise exception 'Full name is required';
  end if;
  if submitted_phone !~ '^\+7[0-9]{10}$' then
    raise exception 'Valid Russian phone is required';
  end if;
  if submitted_personal_number is not null and submitted_personal_number !~ '^[0-9]{1,4}$' then
    raise exception 'Personal number must contain up to four digits';
  end if;
  if submitted_shift_text is not null and submitted_shift_text not in ('1', '2', '5') then
    raise exception 'Shift number must be 1, 2 or 5/2';
  end if;
  if submitted_job_title is not null and char_length(submitted_job_title) > 120 then
    raise exception 'Job title is too long';
  end if;
  if submitted_workplace is not null and submitted_workplace not in (
    'ПЦ Рябиновая',
    'ПЦ Алтуфьево-1',
    'ПЦ Алтуфьево-2'
  ) then
    raise exception 'Unknown workplace';
  end if;

  submitted_shift := submitted_shift_text::smallint;

  insert into public.profiles (
    id,
    username,
    display_name,
    personal_number,
    shift_number,
    job_title,
    workplace,
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
    submitted_personal_number,
    submitted_shift,
    submitted_job_title,
    submitted_workplace,
    '',
    'offline',
    null,
    now(),
    now()
  )
  on conflict (id) do update
  set username = excluded.username,
      display_name = excluded.display_name,
      personal_number = excluded.personal_number,
      shift_number = excluded.shift_number,
      job_title = excluded.job_title,
      workplace = excluded.workplace,
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

-- Violet production tracking MVP.
-- All product status mutations are performed by guarded RPC functions.

create table if not exists public.production_lines (
  id uuid primary key default gen_random_uuid(),
  number integer not null unique check (number between 1 and 999),
  name text not null check (char_length(trim(name)) between 1 and 120),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.production_shifts (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code in ('1', '2', '5/2')),
  name text not null check (char_length(trim(name)) between 1 and 80),
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.production_lines (number, name)
select number, 'Линия ' || number
from generate_series(1, 10) as number
on conflict (number) do update set name = excluded.name;

insert into public.production_shifts (code, name)
values ('1', 'Смена 1'), ('2', 'Смена 2'), ('5/2', 'Смена 5/2')
on conflict (code) do update set name = excluded.name;

alter table public.profiles
  add column if not exists production_role text,
  add column if not exists production_line_id uuid references public.production_lines(id),
  add column if not exists shift_id uuid references public.production_shifts(id),
  add column if not exists production_admin boolean not null default false;

alter table public.profiles
  drop constraint if exists profiles_production_role_check;
alter table public.profiles
  add constraint profiles_production_role_check check (
    production_role is null
    or production_role in ('master', 'tester', 'repair', 'quality_control', 'packing')
  );

create index if not exists profiles_production_line_idx
on public.profiles (production_line_id)
where production_line_id is not null;

create index if not exists profiles_production_shift_idx
on public.profiles (shift_id)
where shift_id is not null;

create index if not exists profiles_production_role_idx
on public.profiles (production_role)
where production_role is not null;

create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  full_qr text not null unique,
  release text not null,
  serial_number text not null,
  current_status text not null default 'assembly',
  current_line_id uuid references public.production_lines(id),
  current_shift_id uuid references public.production_shifts(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint products_full_qr_format_check check (full_qr ~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{6}$'),
  constraint products_release_format_check check (release ~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{2}$'),
  constraint products_serial_format_check check (serial_number ~ '^[0-9]{6}$'),
  constraint products_qr_parts_check check (full_qr = release || '.' || serial_number),
  constraint products_status_check check (
    current_status in ('assembly', 'testing', 'repair', 'quality_control', 'rework', 'packing', 'packed')
  )
);

create index if not exists products_status_line_updated_idx
on public.products (current_status, current_line_id, updated_at desc);

create index if not exists products_current_line_idx
on public.products (current_line_id);

create index if not exists products_current_shift_idx
on public.products (current_shift_id);

create index if not exists products_serial_number_idx
on public.products (serial_number);

create table if not exists public.product_events (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id) on delete restrict,
  event_type text not null,
  from_status text,
  to_status text,
  line_id uuid references public.production_lines(id),
  shift_id uuid references public.production_shifts(id),
  user_id uuid not null references public.profiles(id) on delete restrict,
  reason_text text,
  created_at timestamptz not null default now(),
  constraint product_events_type_check check (
    event_type in (
      'sent_to_testing',
      'sent_to_repair',
      'repair_started',
      'repair_completed',
      'sent_to_quality_control',
      'sent_to_rework',
      'rework_started',
      'rework_completed',
      'sent_to_packing',
      'packed'
    )
  ),
  constraint product_events_from_status_check check (
    from_status is null
    or from_status in ('assembly', 'testing', 'repair', 'quality_control', 'rework', 'packing', 'packed')
  ),
  constraint product_events_to_status_check check (
    to_status is null
    or to_status in ('assembly', 'testing', 'repair', 'quality_control', 'rework', 'packing', 'packed')
  ),
  constraint product_events_reason_check check (reason_text is null or char_length(trim(reason_text)) between 1 and 2000)
);

create index if not exists product_events_product_created_idx
on public.product_events (product_id, created_at desc);

create index if not exists product_events_user_created_idx
on public.product_events (user_id, created_at desc);

create index if not exists product_events_type_line_created_idx
on public.product_events (event_type, line_id, created_at desc);

create index if not exists product_events_line_idx
on public.product_events (line_id);

create index if not exists product_events_shift_idx
on public.product_events (shift_id);

create or replace function private.set_product_event_created_at()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  latest_created_at timestamptz;
begin
  select max(event.created_at) into latest_created_at
  from public.product_events event
  where event.product_id = new.product_id;

  new.created_at := greatest(
    clock_timestamp(),
    coalesce(latest_created_at + interval '1 microsecond', '-infinity'::timestamptz)
  );
  return new;
end;
$$;

revoke all on function private.set_product_event_created_at()
from public, anon, authenticated;

drop trigger if exists product_events_set_created_at on public.product_events;
create trigger product_events_set_created_at
before insert on public.product_events
for each row execute function private.set_product_event_created_at();

alter table public.production_lines enable row level security;
alter table public.production_shifts enable row level security;
alter table public.products enable row level security;
alter table public.product_events enable row level security;

drop policy if exists "production_lines_select_authenticated" on public.production_lines;
create policy "production_lines_select_authenticated"
on public.production_lines for select to authenticated
using ((select auth.uid()) is not null);

drop policy if exists "production_shifts_select_authenticated" on public.production_shifts;
create policy "production_shifts_select_authenticated"
on public.production_shifts for select to authenticated
using ((select auth.uid()) is not null);

drop policy if exists "products_select_production_staff" on public.products;
create policy "products_select_production_staff"
on public.products for select to authenticated
using (
  exists (
    select 1
    from public.profiles profile
    where profile.id = (select auth.uid())
      and (
        profile.production_admin
        or (
          profile.production_role is not null
          and profile.production_line_id = products.current_line_id
        )
      )
  )
);

drop policy if exists "product_events_select_production_staff" on public.product_events;
create policy "product_events_select_production_staff"
on public.product_events for select to authenticated
using (
  exists (
    select 1
    from public.products item
    where item.id = product_events.product_id
  )
);

revoke all on table public.production_lines from anon, authenticated;
revoke all on table public.production_shifts from anon, authenticated;
revoke all on table public.products from anon, authenticated;
revoke all on table public.product_events from anon, authenticated;
grant select on table public.production_lines to authenticated;
grant select on table public.production_shifts to authenticated;
grant select on table public.products to authenticated;
grant select on table public.product_events to authenticated;

create or replace function private.set_product_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function private.set_product_updated_at()
from public, anon, authenticated;

drop trigger if exists products_set_updated_at on public.products;
create trigger products_set_updated_at
before update on public.products
for each row execute function private.set_product_updated_at();

create or replace function public.configure_my_production_profile(
  p_role text,
  p_line_number integer,
  p_shift_code text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  selected_line_id uuid;
  selected_shift_id uuid;
begin
  if caller_id is null then
    raise exception 'Требуется вход в аккаунт';
  end if;
  if p_role not in ('master', 'tester', 'repair', 'quality_control', 'packing') then
    raise exception 'Неизвестная производственная должность';
  end if;

  select line.id into selected_line_id
  from public.production_lines line
  where line.number = p_line_number and line.is_active;

  select shift.id into selected_shift_id
  from public.production_shifts shift
  where shift.code = p_shift_code and shift.is_active;

  if selected_line_id is null then raise exception 'Производственная линия не найдена'; end if;
  if selected_shift_id is null then raise exception 'Производственная смена не найдена'; end if;

  update public.profiles
  set production_role = p_role,
      production_line_id = selected_line_id,
      shift_id = selected_shift_id,
      job_title = case p_role
        when 'master' then 'Мастер'
        when 'tester' then 'Тестировщик'
        when 'repair' then 'Ремонт'
        when 'quality_control' then 'ОТК'
        when 'packing' then 'Упаковка'
      end,
      updated_at = now()
  where id = caller_id;
end;
$$;

revoke all on function public.configure_my_production_profile(text, integer, text)
from public, anon, authenticated;
grant execute on function public.configure_my_production_profile(text, integer, text)
to authenticated;

create or replace function public.admin_configure_production_profile(
  p_profile_id uuid,
  p_role text,
  p_line_number integer,
  p_shift_code text,
  p_production_admin boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  selected_line_id uuid;
  selected_shift_id uuid;
begin
  if caller_id is null or not exists (
    select 1 from public.profiles profile
    where profile.id = caller_id and profile.production_admin
  ) then
    raise exception 'Недостаточно прав администратора производства';
  end if;
  if p_role not in ('master', 'tester', 'repair', 'quality_control', 'packing') then
    raise exception 'Неизвестная производственная должность';
  end if;

  select line.id into selected_line_id from public.production_lines line
  where line.number = p_line_number and line.is_active;
  select shift.id into selected_shift_id from public.production_shifts shift
  where shift.code = p_shift_code and shift.is_active;

  if selected_line_id is null then raise exception 'Производственная линия не найдена'; end if;
  if selected_shift_id is null then raise exception 'Производственная смена не найдена'; end if;

  update public.profiles
  set production_role = p_role,
      production_line_id = selected_line_id,
      shift_id = selected_shift_id,
      production_admin = p_production_admin,
      job_title = case p_role
        when 'master' then 'Мастер'
        when 'tester' then 'Тестировщик'
        when 'repair' then 'Ремонт'
        when 'quality_control' then 'ОТК'
        when 'packing' then 'Упаковка'
      end,
      updated_at = now()
  where id = p_profile_id;

  if not found then raise exception 'Профиль сотрудника не найден'; end if;
end;
$$;

revoke all on function public.admin_configure_production_profile(uuid, text, integer, text, boolean)
from public, anon, authenticated;
grant execute on function public.admin_configure_production_profile(uuid, text, integer, text, boolean)
to authenticated;

create or replace function public.production_transition(
  p_full_qr text,
  p_action text,
  p_reason_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  product public.products%rowtype;
  normalized_qr text := trim(coalesce(p_full_qr, ''));
  normalized_reason text := nullif(trim(coalesce(p_reason_text, '')), '');
  expected_status text;
  next_status text;
  result_event text := p_action;
  last_work_event text;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;

  select * into actor from public.profiles where id = caller_id;
  if actor.production_role is null then raise exception 'В профиле не указана производственная должность'; end if;
  if actor.production_line_id is null then raise exception 'В профиле не указана производственная линия'; end if;
  if actor.shift_id is null then raise exception 'В профиле не указана производственная смена'; end if;
  if normalized_qr !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{6}$' then
    raise exception 'QR должен соответствовать формату 00.00.00.123456';
  end if;
  if char_length(normalized_reason) > 2000 then raise exception 'Причина слишком длинная'; end if;

  if p_action = 'sent_to_testing' then
    if actor.production_role <> 'master' then raise exception 'Только мастер может отправить изделие на тестирование этим действием'; end if;
    expected_status := 'assembly';
    next_status := 'testing';
  elsif p_action = 'sent_to_repair' then
    if actor.production_role not in ('master', 'tester') then raise exception 'Эта должность не может отправлять изделия в ремонт'; end if;
    if normalized_reason is null then raise exception 'Укажите причину ремонта'; end if;
    expected_status := case actor.production_role when 'master' then 'assembly' else 'testing' end;
    next_status := 'repair';
  elsif p_action = 'sent_to_quality_control' then
    if actor.production_role <> 'tester' then raise exception 'Только тестировщик может отправить изделие в ОТК'; end if;
    expected_status := 'testing';
    next_status := 'quality_control';
  elsif p_action = 'sent_to_packing' then
    if actor.production_role <> 'quality_control' then raise exception 'Только ОТК может отправить изделие на упаковку'; end if;
    expected_status := 'quality_control';
    next_status := 'packing';
  elsif p_action = 'sent_to_rework' then
    if actor.production_role <> 'quality_control' then raise exception 'Только ОТК может отправить изделие на доработку'; end if;
    if normalized_reason is null then raise exception 'Укажите причину доработки'; end if;
    expected_status := 'quality_control';
    next_status := 'rework';
  elsif p_action = 'repair_started' then
    if actor.production_role <> 'repair' then raise exception 'Только сотрудник ремонта может начать ремонт'; end if;
    expected_status := 'repair';
    next_status := 'repair';
  elsif p_action = 'repair_completed' then
    if actor.production_role <> 'repair' then raise exception 'Только сотрудник ремонта может завершить ремонт'; end if;
    expected_status := 'repair';
    next_status := 'testing';
  elsif p_action = 'rework_started' then
    if actor.production_role <> 'master' then raise exception 'Только мастер может начать доработку'; end if;
    expected_status := 'rework';
    next_status := 'rework';
  elsif p_action = 'rework_completed' then
    if actor.production_role <> 'master' then raise exception 'Только мастер может завершить доработку'; end if;
    expected_status := 'rework';
    next_status := 'testing';
  elsif p_action = 'packed' then
    if actor.production_role not in ('packing', 'quality_control') then raise exception 'Эта должность не может завершать упаковку'; end if;
    expected_status := 'packing';
    next_status := 'packed';
  else
    raise exception 'Неизвестное производственное действие';
  end if;

  if actor.production_role = 'master' and p_action in ('sent_to_testing', 'sent_to_repair') then
    insert into public.products (
      full_qr,
      release,
      serial_number,
      current_status,
      current_line_id,
      current_shift_id
    )
    values (
      normalized_qr,
      left(normalized_qr, 8),
      right(normalized_qr, 6),
      'assembly',
      actor.production_line_id,
      actor.shift_id
    )
    on conflict (full_qr) do nothing;
  end if;

  select * into product
  from public.products item
  where item.full_qr = normalized_qr
  for update;

  if product.id is null then raise exception 'Изделие не найдено. Сначала его должен отсканировать мастер'; end if;
  if not actor.production_admin and product.current_line_id is distinct from actor.production_line_id then
    raise exception 'Изделие относится к другой производственной линии';
  end if;
  if product.current_status <> expected_status then
    raise exception 'Недопустимый переход. Текущий этап изделия: %', product.current_status;
  end if;

  if p_action in ('repair_started', 'repair_completed') then
    select event.event_type into last_work_event
    from public.product_events event
    where event.product_id = product.id
      and event.event_type in ('sent_to_repair', 'repair_started', 'repair_completed')
    order by event.created_at desc, event.id desc
    limit 1;

    if p_action = 'repair_started' and last_work_event <> 'sent_to_repair' then
      raise exception 'Ремонт уже начат или завершён';
    end if;
    if p_action = 'repair_completed' and last_work_event <> 'repair_started' then
      raise exception 'Сначала нажмите «Начать ремонт»';
    end if;
  end if;

  if p_action in ('rework_started', 'rework_completed') then
    select event.event_type into last_work_event
    from public.product_events event
    where event.product_id = product.id
      and event.event_type in ('sent_to_rework', 'rework_started', 'rework_completed')
    order by event.created_at desc, event.id desc
    limit 1;

    if p_action = 'rework_started' and last_work_event <> 'sent_to_rework' then
      raise exception 'Доработка уже начата или завершена';
    end if;
    if p_action = 'rework_completed' and last_work_event <> 'rework_started' then
      raise exception 'Сначала нажмите «Начать доработку»';
    end if;
  end if;

  if p_action = 'repair_completed' then
    insert into public.product_events (
      product_id, event_type, from_status, to_status, line_id, shift_id, user_id
    ) values (
      product.id, 'repair_completed', 'repair', 'repair', actor.production_line_id, actor.shift_id, caller_id
    );
    result_event := 'sent_to_testing';
  elsif p_action = 'rework_completed' then
    insert into public.product_events (
      product_id, event_type, from_status, to_status, line_id, shift_id, user_id
    ) values (
      product.id, 'rework_completed', 'rework', 'rework', actor.production_line_id, actor.shift_id, caller_id
    );
    result_event := 'sent_to_testing';
  end if;

  if p_action not in ('repair_started', 'rework_started') then
    update public.products
    set current_status = next_status,
        current_shift_id = actor.shift_id
    where id = product.id;
  end if;

  insert into public.product_events (
    product_id,
    event_type,
    from_status,
    to_status,
    line_id,
    shift_id,
    user_id,
    reason_text
  ) values (
    product.id,
    result_event,
    product.current_status,
    next_status,
    actor.production_line_id,
    actor.shift_id,
    caller_id,
    normalized_reason
  );

  return jsonb_build_object(
    'product_id', product.id,
    'full_qr', product.full_qr,
    'release', product.release,
    'serial_number', product.serial_number,
    'from_status', product.current_status,
    'to_status', next_status,
    'event_type', result_event
  );
end;
$$;

revoke all on function public.production_transition(text, text, text)
from public, anon, authenticated;
grant execute on function public.production_transition(text, text, text)
to authenticated;

create or replace function public.production_dashboard()
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  event_counts jsonb;
  status_counts jsonb;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles where id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;
  if actor.production_line_id is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная линия';
  end if;

  select coalesce(jsonb_object_agg(counts.event_type, counts.total), '{}'::jsonb)
  into event_counts
  from (
    select event.event_type, count(*)::integer as total
    from public.product_events event
    where event.user_id = caller_id
      and event.created_at >= date_trunc('day', now())
    group by event.event_type
  ) counts;

  select coalesce(jsonb_object_agg(counts.current_status, counts.total), '{}'::jsonb)
  into status_counts
  from (
    select item.current_status, count(*)::integer as total
    from public.products item
    where actor.production_admin
      or actor.production_line_id is null
      or item.current_line_id = actor.production_line_id
    group by item.current_status
  ) counts;

  return jsonb_build_object('events_today', event_counts, 'status_counts', status_counts);
end;
$$;

revoke all on function public.production_dashboard()
from public, anon, authenticated;
grant execute on function public.production_dashboard() to authenticated;

create or replace function public.production_queue(p_status text)
returns table (
  id uuid,
  full_qr text,
  release text,
  serial_number text,
  current_status text,
  line_number integer,
  shift_name text,
  reason_text text,
  sent_by text,
  event_type text,
  event_time timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles where profiles.id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;
  if actor.production_line_id is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная линия';
  end if;
  if p_status not in ('assembly', 'testing', 'repair', 'quality_control', 'rework', 'packing', 'packed') then
    raise exception 'Неизвестный производственный этап';
  end if;
  if not actor.production_admin and not (
    (actor.production_role = 'master' and p_status = 'rework')
    or (actor.production_role = 'tester' and p_status = 'testing')
    or (actor.production_role = 'repair' and p_status = 'repair')
    or (actor.production_role = 'quality_control' and p_status = 'quality_control')
    or (actor.production_role = 'packing' and p_status = 'packing')
  ) then
    raise exception 'Эта очередь недоступна для вашей должности';
  end if;

  return query
  select
    item.id,
    item.full_qr,
    item.release,
    item.serial_number,
    item.current_status,
    line.number,
    shift.name,
    latest.reason_text,
    sender.display_name,
    latest.event_type,
    latest.created_at
  from public.products item
  left join public.production_lines line on line.id = item.current_line_id
  left join public.production_shifts shift on shift.id = item.current_shift_id
  left join lateral (
    select event.reason_text, event.user_id, event.event_type, event.created_at
    from public.product_events event
    where event.product_id = item.id
    order by event.created_at desc, event.id desc
    limit 1
  ) latest on true
  left join public.profiles sender on sender.id = latest.user_id
  where item.current_status = p_status
    and (
      actor.production_admin
      or actor.production_line_id is null
      or item.current_line_id = actor.production_line_id
    )
  order by latest.created_at nulls last, item.updated_at;
end;
$$;

revoke all on function public.production_queue(text)
from public, anon, authenticated;
grant execute on function public.production_queue(text) to authenticated;

create or replace function public.production_product_details(p_query text)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  item public.products%rowtype;
  event_history jsonb;
  line_number integer;
  shift_name text;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles where id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;

  select * into item
  from public.products product
  where product.full_qr = trim(coalesce(p_query, ''))
     or product.serial_number = trim(coalesce(p_query, ''))
  order by product.updated_at desc
  limit 1;

  if item.id is null then raise exception 'Изделие не найдено'; end if;
  if not actor.production_admin and item.current_line_id is distinct from actor.production_line_id then
    raise exception 'Изделие относится к другой производственной линии';
  end if;

  select line.number into line_number from public.production_lines line where line.id = item.current_line_id;
  select shift.name into shift_name from public.production_shifts shift where shift.id = item.current_shift_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', event.id,
    'event_type', event.event_type,
    'from_status', event.from_status,
    'to_status', event.to_status,
    'reason_text', event.reason_text,
    'created_at', event.created_at,
    'user_id', event.user_id,
    'user_name', profile.display_name,
    'line_number', line.number,
    'shift_name', shift.name
  ) order by event.created_at, event.id), '[]'::jsonb)
  into event_history
  from public.product_events event
  left join public.profiles profile on profile.id = event.user_id
  left join public.production_lines line on line.id = event.line_id
  left join public.production_shifts shift on shift.id = event.shift_id
  where event.product_id = item.id;

  return jsonb_build_object(
    'product', jsonb_build_object(
      'id', item.id,
      'full_qr', item.full_qr,
      'release', item.release,
      'serial_number', item.serial_number,
      'current_status', item.current_status,
      'line_number', line_number,
      'shift_name', shift_name,
      'created_at', item.created_at,
      'updated_at', item.updated_at
    ),
    'events', event_history
  );
end;
$$;

revoke all on function public.production_product_details(text)
from public, anon, authenticated;
grant execute on function public.production_product_details(text) to authenticated;

do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'products'
  ) then
    alter publication supabase_realtime add table public.products;
  end if;
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'product_events'
  ) then
    alter publication supabase_realtime add table public.product_events;
  end if;
end;
$$;

-- ---------- Product duplicate detection and recoverable deletion ----------

-- Soft-delete scanned products so the QR can be added again while preserving audit history.

alter table public.products
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid references public.profiles(id) on delete restrict,
  add column if not exists deletion_reason text;

alter table public.products
  drop constraint if exists products_deletion_reason_check;
alter table public.products
  add constraint products_deletion_reason_check check (
    deletion_reason is null or char_length(trim(deletion_reason)) between 1 and 2000
  );

alter table public.products
  drop constraint if exists products_full_qr_key;

create unique index if not exists products_full_qr_active_unique_idx
on public.products (full_qr)
where deleted_at is null;

create index if not exists products_deleted_by_idx
on public.products (deleted_by)
where deleted_by is not null;

drop index if exists public.products_status_line_updated_idx;
create index products_status_line_updated_idx
on public.products (current_status, current_line_id, updated_at desc)
where deleted_at is null;

drop index if exists public.products_serial_number_idx;
create index products_serial_number_idx
on public.products (serial_number)
where deleted_at is null;

alter table public.product_events
  drop constraint if exists product_events_type_check;
alter table public.product_events
  add constraint product_events_type_check check (
    event_type in (
      'sent_to_testing',
      'sent_to_repair',
      'repair_started',
      'repair_completed',
      'sent_to_quality_control',
      'sent_to_rework',
      'rework_started',
      'rework_completed',
      'sent_to_packing',
      'packed',
      'deleted'
    )
  );

drop policy if exists "products_select_production_staff" on public.products;
create policy "products_select_production_staff"
on public.products for select to authenticated
using (
  exists (
    select 1
    from public.profiles profile
    where profile.id = (select auth.uid())
      and (
        profile.production_admin
        or (
          products.deleted_at is null
          and profile.production_role is not null
          and profile.production_line_id = products.current_line_id
        )
      )
  )
);

create or replace function public.production_transition(
  p_full_qr text,
  p_action text,
  p_reason_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  product public.products%rowtype;
  normalized_qr text := trim(coalesce(p_full_qr, ''));
  normalized_reason text := nullif(trim(coalesce(p_reason_text, '')), '');
  expected_status text;
  next_status text;
  result_event text := p_action;
  last_work_event text;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;

  select * into actor from public.profiles where id = caller_id;
  if actor.production_role is null then raise exception 'В профиле не указана производственная должность'; end if;
  if actor.production_line_id is null then raise exception 'В профиле не указана производственная линия'; end if;
  if actor.shift_id is null then raise exception 'В профиле не указана производственная смена'; end if;
  if normalized_qr !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{6}$' then
    raise exception 'QR должен соответствовать формату 00.00.00.123456';
  end if;
  if char_length(normalized_reason) > 2000 then raise exception 'Причина слишком длинная'; end if;

  if p_action = 'sent_to_testing' then
    if actor.production_role <> 'master' then raise exception 'Только мастер может отправить изделие на тестирование этим действием'; end if;
    expected_status := 'assembly';
    next_status := 'testing';
  elsif p_action = 'sent_to_repair' then
    if actor.production_role not in ('master', 'tester') then raise exception 'Эта должность не может отправлять изделия в ремонт'; end if;
    if normalized_reason is null then raise exception 'Укажите причину ремонта'; end if;
    expected_status := case actor.production_role when 'master' then 'assembly' else 'testing' end;
    next_status := 'repair';
  elsif p_action = 'sent_to_quality_control' then
    if actor.production_role <> 'tester' then raise exception 'Только тестировщик может отправить изделие в ОТК'; end if;
    expected_status := 'testing';
    next_status := 'quality_control';
  elsif p_action = 'sent_to_packing' then
    if actor.production_role <> 'quality_control' then raise exception 'Только ОТК может отправить изделие на упаковку'; end if;
    expected_status := 'quality_control';
    next_status := 'packing';
  elsif p_action = 'sent_to_rework' then
    if actor.production_role <> 'quality_control' then raise exception 'Только ОТК может отправить изделие на доработку'; end if;
    if normalized_reason is null then raise exception 'Укажите причину доработки'; end if;
    expected_status := 'quality_control';
    next_status := 'rework';
  elsif p_action = 'repair_started' then
    if actor.production_role <> 'repair' then raise exception 'Только сотрудник ремонта может начать ремонт'; end if;
    expected_status := 'repair';
    next_status := 'repair';
  elsif p_action = 'repair_completed' then
    if actor.production_role <> 'repair' then raise exception 'Только сотрудник ремонта может завершить ремонт'; end if;
    expected_status := 'repair';
    next_status := 'testing';
  elsif p_action = 'rework_started' then
    if actor.production_role <> 'master' then raise exception 'Только мастер может начать доработку'; end if;
    expected_status := 'rework';
    next_status := 'rework';
  elsif p_action = 'rework_completed' then
    if actor.production_role <> 'master' then raise exception 'Только мастер может завершить доработку'; end if;
    expected_status := 'rework';
    next_status := 'testing';
  elsif p_action = 'packed' then
    if actor.production_role not in ('packing', 'quality_control') then raise exception 'Эта должность не может завершать упаковку'; end if;
    expected_status := 'packing';
    next_status := 'packed';
  else
    raise exception 'Неизвестное производственное действие';
  end if;

  if actor.production_role = 'master' and p_action in ('sent_to_testing', 'sent_to_repair') then
    select * into product
    from public.products item
    where item.full_qr = normalized_qr
      and item.deleted_at is null
    for update;

    if product.id is not null then
      raise exception 'Дубликат: QR % уже добавлен. Текущий этап: %', normalized_qr, product.current_status;
    end if;

    begin
      insert into public.products (
        full_qr,
        release,
        serial_number,
        current_status,
        current_line_id,
        current_shift_id
      )
      values (
        normalized_qr,
        left(normalized_qr, 8),
        right(normalized_qr, 6),
        'assembly',
        actor.production_line_id,
        actor.shift_id
      )
      returning * into product;
    exception when unique_violation then
      raise exception 'Дубликат: этот QR уже добавлен';
    end;
  else
    select * into product
    from public.products item
    where item.full_qr = normalized_qr
      and item.deleted_at is null
    for update;
  end if;

  if product.id is null then raise exception 'Изделие не найдено. Сначала его должен отсканировать мастер'; end if;
  if not actor.production_admin and product.current_line_id is distinct from actor.production_line_id then
    raise exception 'Изделие относится к другой производственной линии';
  end if;
  if product.current_status <> expected_status then
    raise exception 'Недопустимый переход. Текущий этап изделия: %', product.current_status;
  end if;

  if p_action in ('repair_started', 'repair_completed') then
    select event.event_type into last_work_event
    from public.product_events event
    where event.product_id = product.id
      and event.event_type in ('sent_to_repair', 'repair_started', 'repair_completed')
    order by event.created_at desc, event.id desc
    limit 1;

    if p_action = 'repair_started' and last_work_event <> 'sent_to_repair' then
      raise exception 'Ремонт уже начат или завершён';
    end if;
    if p_action = 'repair_completed' and last_work_event <> 'repair_started' then
      raise exception 'Сначала нажмите «Начать ремонт»';
    end if;
  end if;

  if p_action in ('rework_started', 'rework_completed') then
    select event.event_type into last_work_event
    from public.product_events event
    where event.product_id = product.id
      and event.event_type in ('sent_to_rework', 'rework_started', 'rework_completed')
    order by event.created_at desc, event.id desc
    limit 1;

    if p_action = 'rework_started' and last_work_event <> 'sent_to_rework' then
      raise exception 'Доработка уже начата или завершена';
    end if;
    if p_action = 'rework_completed' and last_work_event <> 'rework_started' then
      raise exception 'Сначала нажмите «Начать доработку»';
    end if;
  end if;

  if p_action = 'repair_completed' then
    insert into public.product_events (
      product_id, event_type, from_status, to_status, line_id, shift_id, user_id
    ) values (
      product.id, 'repair_completed', 'repair', 'repair', actor.production_line_id, actor.shift_id, caller_id
    );
    result_event := 'sent_to_testing';
  elsif p_action = 'rework_completed' then
    insert into public.product_events (
      product_id, event_type, from_status, to_status, line_id, shift_id, user_id
    ) values (
      product.id, 'rework_completed', 'rework', 'rework', actor.production_line_id, actor.shift_id, caller_id
    );
    result_event := 'sent_to_testing';
  end if;

  if p_action not in ('repair_started', 'rework_started') then
    update public.products
    set current_status = next_status,
        current_shift_id = actor.shift_id
    where id = product.id;
  end if;

  insert into public.product_events (
    product_id,
    event_type,
    from_status,
    to_status,
    line_id,
    shift_id,
    user_id,
    reason_text
  ) values (
    product.id,
    result_event,
    product.current_status,
    next_status,
    actor.production_line_id,
    actor.shift_id,
    caller_id,
    normalized_reason
  );

  return jsonb_build_object(
    'product_id', product.id,
    'full_qr', product.full_qr,
    'release', product.release,
    'serial_number', product.serial_number,
    'from_status', product.current_status,
    'to_status', next_status,
    'event_type', result_event
  );
end;
$$;

revoke all on function public.production_transition(text, text, text)
from public, anon, authenticated;
grant execute on function public.production_transition(text, text, text)
to authenticated;

create or replace function public.production_delete_product(
  p_full_qr text,
  p_reason_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  product public.products%rowtype;
  normalized_qr text := trim(coalesce(p_full_qr, ''));
  normalized_reason text := nullif(trim(coalesce(p_reason_text, '')), '');
  deleted_timestamp timestamptz := clock_timestamp();
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;

  select * into actor from public.profiles where id = caller_id;
  if actor.production_role <> 'master' and not actor.production_admin then
    raise exception 'Удалять изделия может только мастер или администратор производства';
  end if;
  if actor.production_line_id is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная линия';
  end if;
  if normalized_qr !~ '^[0-9]{2}\.[0-9]{2}\.[0-9]{2}\.[0-9]{6}$' then
    raise exception 'QR должен соответствовать формату 00.00.00.123456';
  end if;
  if char_length(normalized_reason) > 2000 then raise exception 'Причина слишком длинная'; end if;

  select * into product
  from public.products item
  where item.full_qr = normalized_qr
    and item.deleted_at is null
  for update;

  if product.id is null then raise exception 'Изделие уже удалено или не найдено'; end if;
  if not actor.production_admin and product.current_line_id is distinct from actor.production_line_id then
    raise exception 'Изделие относится к другой производственной линии';
  end if;

  insert into public.product_events (
    product_id,
    event_type,
    from_status,
    to_status,
    line_id,
    shift_id,
    user_id,
    reason_text
  ) values (
    product.id,
    'deleted',
    product.current_status,
    null,
    actor.production_line_id,
    actor.shift_id,
    caller_id,
    normalized_reason
  );

  update public.products
  set deleted_at = deleted_timestamp,
      deleted_by = caller_id,
      deletion_reason = normalized_reason
  where id = product.id;

  return jsonb_build_object(
    'product_id', product.id,
    'full_qr', product.full_qr,
    'deleted_at', deleted_timestamp
  );
end;
$$;

revoke all on function public.production_delete_product(text, text)
from public, anon, authenticated;
grant execute on function public.production_delete_product(text, text)
to authenticated;

create or replace function public.production_dashboard()
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  event_counts jsonb;
  status_counts jsonb;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles where id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;
  if actor.production_line_id is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная линия';
  end if;

  select coalesce(jsonb_object_agg(counts.event_type, counts.total), '{}'::jsonb)
  into event_counts
  from (
    select event.event_type, count(*)::integer as total
    from public.product_events event
    where event.user_id = caller_id
      and event.created_at >= date_trunc('day', now())
    group by event.event_type
  ) counts;

  select coalesce(jsonb_object_agg(counts.current_status, counts.total), '{}'::jsonb)
  into status_counts
  from (
    select item.current_status, count(*)::integer as total
    from public.products item
    where item.deleted_at is null
      and (
        actor.production_admin
        or actor.production_line_id is null
        or item.current_line_id = actor.production_line_id
      )
    group by item.current_status
  ) counts;

  return jsonb_build_object('events_today', event_counts, 'status_counts', status_counts);
end;
$$;

revoke all on function public.production_dashboard()
from public, anon, authenticated;
grant execute on function public.production_dashboard() to authenticated;

create or replace function public.production_queue(p_status text)
returns table (
  id uuid,
  full_qr text,
  release text,
  serial_number text,
  current_status text,
  line_number integer,
  shift_name text,
  reason_text text,
  sent_by text,
  event_type text,
  event_time timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles where profiles.id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;
  if actor.production_line_id is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная линия';
  end if;
  if p_status not in ('assembly', 'testing', 'repair', 'quality_control', 'rework', 'packing', 'packed') then
    raise exception 'Неизвестный производственный этап';
  end if;
  if not actor.production_admin and not (
    (actor.production_role = 'master' and p_status = 'rework')
    or (actor.production_role = 'tester' and p_status = 'testing')
    or (actor.production_role = 'repair' and p_status = 'repair')
    or (actor.production_role = 'quality_control' and p_status = 'quality_control')
    or (actor.production_role = 'packing' and p_status = 'packing')
  ) then
    raise exception 'Эта очередь недоступна для вашей должности';
  end if;

  return query
  select
    item.id,
    item.full_qr,
    item.release,
    item.serial_number,
    item.current_status,
    line.number,
    shift.name,
    latest.reason_text,
    sender.display_name,
    latest.event_type,
    latest.created_at
  from public.products item
  left join public.production_lines line on line.id = item.current_line_id
  left join public.production_shifts shift on shift.id = item.current_shift_id
  left join lateral (
    select event.reason_text, event.user_id, event.event_type, event.created_at
    from public.product_events event
    where event.product_id = item.id
    order by event.created_at desc, event.id desc
    limit 1
  ) latest on true
  left join public.profiles sender on sender.id = latest.user_id
  where item.deleted_at is null
    and item.current_status = p_status
    and (
      actor.production_admin
      or actor.production_line_id is null
      or item.current_line_id = actor.production_line_id
    )
  order by latest.created_at nulls last, item.updated_at;
end;
$$;

revoke all on function public.production_queue(text)
from public, anon, authenticated;
grant execute on function public.production_queue(text) to authenticated;

create or replace function public.production_product_details(p_query text)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  item public.products%rowtype;
  event_history jsonb;
  line_number integer;
  shift_name text;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles where id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;

  select * into item
  from public.products product
  where product.deleted_at is null
    and (
      product.full_qr = trim(coalesce(p_query, ''))
      or product.serial_number = trim(coalesce(p_query, ''))
    )
  order by product.updated_at desc
  limit 1;

  if item.id is null then raise exception 'Изделие не найдено'; end if;
  if not actor.production_admin and item.current_line_id is distinct from actor.production_line_id then
    raise exception 'Изделие относится к другой производственной линии';
  end if;

  select line.number into line_number from public.production_lines line where line.id = item.current_line_id;
  select shift.name into shift_name from public.production_shifts shift where shift.id = item.current_shift_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', event.id,
    'event_type', event.event_type,
    'from_status', event.from_status,
    'to_status', event.to_status,
    'reason_text', event.reason_text,
    'created_at', event.created_at,
    'user_id', event.user_id,
    'user_name', profile.display_name,
    'line_number', line.number,
    'shift_name', shift.name
  ) order by event.created_at, event.id), '[]'::jsonb)
  into event_history
  from public.product_events event
  left join public.profiles profile on profile.id = event.user_id
  left join public.production_lines line on line.id = event.line_id
  left join public.production_shifts shift on shift.id = event.shift_id
  where event.product_id = item.id;

  return jsonb_build_object(
    'product', jsonb_build_object(
      'id', item.id,
      'full_qr', item.full_qr,
      'release', item.release,
      'serial_number', item.serial_number,
      'current_status', item.current_status,
      'line_number', line_number,
      'shift_name', shift_name,
      'created_at', item.created_at,
      'updated_at', item.updated_at
    ),
    'events', event_history
  );
end;
$$;

revoke all on function public.production_product_details(text)
from public, anon, authenticated;
grant execute on function public.production_product_details(text) to authenticated;

-- Product list, tester workstations and workpiece-defect accounting.
-- This migration must run after all earlier production RPC replacements.

alter table public.profiles
  add column if not exists tester_cube_number smallint;

alter table public.profiles
  drop constraint if exists profiles_tester_cube_number_check;
alter table public.profiles
  add constraint profiles_tester_cube_number_check check (
    tester_cube_number is null or tester_cube_number between 1 and 10
  );

alter table public.product_events
  add column if not exists workstation_name text;

alter table public.product_events
  drop constraint if exists product_events_workstation_name_check;
alter table public.product_events
  add constraint product_events_workstation_name_check check (
    workstation_name is null
    or char_length(trim(workstation_name)) between 1 and 100
  );

create or replace function private.set_product_event_workstation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  actor_role text;
  cube_number smallint;
begin
  select profile.production_role, profile.tester_cube_number
  into actor_role, cube_number
  from public.profiles profile
  where profile.id = new.user_id;

  if actor_role = 'tester' then
    if cube_number is null then
      raise exception 'Для тестировщика укажите рабочее место «Куб №» от 1 до 10 в профиле';
    end if;
    new.workstation_name := 'Куб №' || cube_number::text;
  end if;

  return new;
end;
$$;

revoke all on function private.set_product_event_workstation()
from public, anon, authenticated;

drop trigger if exists product_events_set_workstation on public.product_events;
create trigger product_events_set_workstation
before insert on public.product_events
for each row execute function private.set_product_event_workstation();

create table if not exists public.workpiece_defects (
  id uuid primary key default gen_random_uuid(),
  qr_code text not null,
  reason_text text not null,
  production_line_id uuid not null references public.production_lines(id),
  shift_id uuid not null references public.production_shifts(id),
  reported_by uuid not null references public.profiles(id) on delete restrict,
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete restrict,
  deletion_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint workpiece_defects_qr_code_check check (
    char_length(trim(qr_code)) between 4 and 160
    and qr_code !~ '[[:cntrl:]]'
  ),
  constraint workpiece_defects_reason_text_check check (
    char_length(trim(reason_text)) between 1 and 2000
  ),
  constraint workpiece_defects_deletion_reason_check check (
    deletion_reason is null
    or char_length(trim(deletion_reason)) between 1 and 2000
  ),
  constraint workpiece_defects_deleted_state_check check (
    (deleted_at is null and deleted_by is null)
    or (deleted_at is not null and deleted_by is not null)
  )
);

create unique index if not exists workpiece_defects_active_qr_unique_idx
on public.workpiece_defects (lower(qr_code))
where deleted_at is null;

create index if not exists workpiece_defects_active_line_created_idx
on public.workpiece_defects (production_line_id, created_at desc)
where deleted_at is null;

create index if not exists workpiece_defects_shift_id_idx
on public.workpiece_defects (shift_id);

create index if not exists workpiece_defects_reported_by_idx
on public.workpiece_defects (reported_by, created_at desc);

create index if not exists workpiece_defects_deleted_by_idx
on public.workpiece_defects (deleted_by)
where deleted_by is not null;

create or replace function private.set_workpiece_defect_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function private.set_workpiece_defect_updated_at()
from public, anon, authenticated;

drop trigger if exists workpiece_defects_set_updated_at on public.workpiece_defects;
create trigger workpiece_defects_set_updated_at
before update on public.workpiece_defects
for each row execute function private.set_workpiece_defect_updated_at();

alter table public.workpiece_defects enable row level security;

drop policy if exists "workpiece_defects_select_production_staff" on public.workpiece_defects;
create policy "workpiece_defects_select_production_staff"
on public.workpiece_defects for select to authenticated
using (
  exists (
    select 1
    from public.profiles profile
    where profile.id = (select auth.uid())
      and (
        profile.production_admin
        or (
          profile.production_role is not null
          and profile.production_line_id = workpiece_defects.production_line_id
        )
      )
  )
);

revoke all on table public.workpiece_defects from public, anon, authenticated;
grant select on table public.workpiece_defects to authenticated;

create or replace function public.production_product_list(p_search text default null)
returns table (
  id uuid,
  full_qr text,
  release text,
  serial_number text,
  current_status text,
  line_number integer,
  shift_name text,
  last_event_type text,
  last_event_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  normalized_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles profile where profile.id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;
  if actor.production_line_id is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная линия';
  end if;

  return query
  select
    item.id,
    item.full_qr,
    item.release,
    item.serial_number,
    item.current_status,
    line.number,
    shift.name,
    latest.event_type,
    latest.created_at,
    item.created_at,
    item.updated_at
  from public.products item
  left join public.production_lines line on line.id = item.current_line_id
  left join public.production_shifts shift on shift.id = item.current_shift_id
  left join lateral (
    select event.event_type, event.created_at
    from public.product_events event
    where event.product_id = item.id
    order by event.created_at desc, event.id desc
    limit 1
  ) latest on true
  where item.deleted_at is null
    and (
      actor.production_admin
      or item.current_line_id = actor.production_line_id
    )
    and (
      normalized_search is null
      or item.full_qr ilike '%' || normalized_search || '%'
      or item.serial_number ilike '%' || normalized_search || '%'
      or item.release ilike '%' || normalized_search || '%'
    )
  order by item.updated_at desc, item.id;
end;
$$;

revoke all on function public.production_product_list(text)
from public, anon, authenticated;
grant execute on function public.production_product_list(text) to authenticated;

create or replace function public.production_complete_rework(
  p_full_qr text,
  p_reason_text text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  normalized_qr text := trim(coalesce(p_full_qr, ''));
  normalized_reason text := nullif(trim(coalesce(p_reason_text, '')), '');
  item_id uuid;
  last_rework_event text;
  transition_result jsonb;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  if normalized_reason is null then raise exception 'Опишите, что было доработано'; end if;
  if char_length(normalized_reason) > 2000 then raise exception 'Описание доработки слишком длинное'; end if;

  select item.id into item_id
  from public.products item
  where item.full_qr = normalized_qr
    and item.deleted_at is null;

  if item_id is null then raise exception 'Изделие не найдено'; end if;

  select event.event_type into last_rework_event
  from public.product_events event
  where event.product_id = item_id
    and event.event_type in ('sent_to_rework', 'rework_started', 'rework_completed')
  order by event.created_at desc, event.id desc
  limit 1;

  if last_rework_event = 'sent_to_rework' then
    perform public.production_transition(normalized_qr, 'rework_started', null);
  elsif last_rework_event is distinct from 'rework_started' then
    raise exception 'Изделие не ожидает завершения доработки';
  end if;

  transition_result := public.production_transition(
    normalized_qr,
    'rework_completed',
    normalized_reason
  );

  return transition_result || jsonb_build_object('event_type', 'rework_completed');
end;
$$;

revoke all on function public.production_complete_rework(text, text)
from public, anon, authenticated;
grant execute on function public.production_complete_rework(text, text) to authenticated;

create or replace function public.production_record_workpiece_defect(
  p_qr_code text,
  p_reason_text text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  normalized_qr text := trim(coalesce(p_qr_code, ''));
  normalized_reason text := nullif(trim(coalesce(p_reason_text, '')), '');
  existing_id uuid;
  defect public.workpiece_defects%rowtype;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles profile where profile.id = caller_id;
  if actor.production_role is null then raise exception 'В профиле не указана производственная должность'; end if;
  if actor.production_line_id is null then raise exception 'В профиле не указана производственная линия'; end if;
  if actor.shift_id is null then raise exception 'В профиле не указана производственная смена'; end if;
  if char_length(normalized_qr) not between 4 and 160 or normalized_qr ~ '[[:cntrl:]]' then
    raise exception 'QR заготовки должен содержать от 4 до 160 печатных символов';
  end if;
  if normalized_reason is null then raise exception 'Укажите причину брака заготовки'; end if;
  if char_length(normalized_reason) > 2000 then raise exception 'Причина брака слишком длинная'; end if;

  select item.id into existing_id
  from public.workpiece_defects item
  where lower(item.qr_code) = lower(normalized_qr)
    and item.deleted_at is null
  for update;

  if existing_id is not null then
    raise exception 'Дубликат: QR заготовки % уже учтён как брак', normalized_qr;
  end if;

  begin
    insert into public.workpiece_defects (
      qr_code,
      reason_text,
      production_line_id,
      shift_id,
      reported_by
    ) values (
      normalized_qr,
      normalized_reason,
      actor.production_line_id,
      actor.shift_id,
      caller_id
    )
    returning * into defect;
  exception when unique_violation then
    raise exception 'Дубликат: этот QR заготовки уже учтён как брак';
  end;

  return jsonb_build_object(
    'id', defect.id,
    'qr_code', defect.qr_code,
    'reason_text', defect.reason_text,
    'created_at', defect.created_at
  );
end;
$$;

revoke all on function public.production_record_workpiece_defect(text, text)
from public, anon, authenticated;
grant execute on function public.production_record_workpiece_defect(text, text) to authenticated;

create or replace function public.production_delete_workpiece_defect(
  p_defect_id uuid,
  p_reason_text text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  defect public.workpiece_defects%rowtype;
  normalized_reason text := nullif(trim(coalesce(p_reason_text, '')), '');
  deleted_timestamp timestamptz := clock_timestamp();
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles profile where profile.id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;
  if char_length(normalized_reason) > 2000 then raise exception 'Причина удаления слишком длинная'; end if;

  select * into defect
  from public.workpiece_defects item
  where item.id = p_defect_id
    and item.deleted_at is null
  for update;

  if defect.id is null then raise exception 'Запись уже удалена или не найдена'; end if;
  if not actor.production_admin and defect.production_line_id is distinct from actor.production_line_id then
    raise exception 'Запись относится к другой производственной линии';
  end if;
  if not actor.production_admin
     and actor.production_role <> 'master'
     and defect.reported_by <> caller_id then
    raise exception 'Удалить запись может автор, мастер линии или администратор';
  end if;

  update public.workpiece_defects
  set deleted_at = deleted_timestamp,
      deleted_by = caller_id,
      deletion_reason = normalized_reason
  where id = defect.id;

  return jsonb_build_object(
    'id', defect.id,
    'qr_code', defect.qr_code,
    'deleted_at', deleted_timestamp
  );
end;
$$;

revoke all on function public.production_delete_workpiece_defect(uuid, text)
from public, anon, authenticated;
grant execute on function public.production_delete_workpiece_defect(uuid, text) to authenticated;

create or replace function public.production_workpiece_defect_list(p_search text default null)
returns table (
  id uuid,
  qr_code text,
  reason_text text,
  line_number integer,
  shift_name text,
  reported_by uuid,
  reporter_name text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  normalized_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles profile where profile.id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;
  if actor.production_line_id is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная линия';
  end if;

  return query
  select
    defect.id,
    defect.qr_code,
    defect.reason_text,
    line.number,
    shift.name,
    defect.reported_by,
    reporter.display_name,
    defect.created_at,
    defect.updated_at
  from public.workpiece_defects defect
  join public.production_lines line on line.id = defect.production_line_id
  join public.production_shifts shift on shift.id = defect.shift_id
  join public.profiles reporter on reporter.id = defect.reported_by
  where defect.deleted_at is null
    and (
      actor.production_admin
      or defect.production_line_id = actor.production_line_id
    )
    and (
      normalized_search is null
      or defect.qr_code ilike '%' || normalized_search || '%'
      or defect.reason_text ilike '%' || normalized_search || '%'
      or reporter.display_name ilike '%' || normalized_search || '%'
    )
  order by defect.created_at desc, defect.id;
end;
$$;

revoke all on function public.production_workpiece_defect_list(text)
from public, anon, authenticated;
grant execute on function public.production_workpiece_defect_list(text) to authenticated;

create or replace function public.production_product_details(p_query text)
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  item public.products%rowtype;
  event_history jsonb;
  line_number integer;
  shift_name text;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles where id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;

  select * into item
  from public.products product
  where product.deleted_at is null
    and (
      product.full_qr = trim(coalesce(p_query, ''))
      or product.serial_number = trim(coalesce(p_query, ''))
    )
  order by product.updated_at desc
  limit 1;

  if item.id is null then raise exception 'Изделие не найдено'; end if;
  if not actor.production_admin and item.current_line_id is distinct from actor.production_line_id then
    raise exception 'Изделие относится к другой производственной линии';
  end if;

  select line.number into line_number from public.production_lines line where line.id = item.current_line_id;
  select shift.name into shift_name from public.production_shifts shift where shift.id = item.current_shift_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', event.id,
    'event_type', event.event_type,
    'from_status', event.from_status,
    'to_status', event.to_status,
    'reason_text', event.reason_text,
    'workstation_name', event.workstation_name,
    'created_at', event.created_at,
    'user_id', event.user_id,
    'user_name', profile.display_name,
    'line_number', line.number,
    'shift_name', shift.name
  ) order by event.created_at, event.id), '[]'::jsonb)
  into event_history
  from public.product_events event
  left join public.profiles profile on profile.id = event.user_id
  left join public.production_lines line on line.id = event.line_id
  left join public.production_shifts shift on shift.id = event.shift_id
  where event.product_id = item.id;

  return jsonb_build_object(
    'product', jsonb_build_object(
      'id', item.id,
      'full_qr', item.full_qr,
      'release', item.release,
      'serial_number', item.serial_number,
      'current_status', item.current_status,
      'line_number', line_number,
      'shift_name', shift_name,
      'created_at', item.created_at,
      'updated_at', item.updated_at
    ),
    'events', event_history
  );
end;
$$;

revoke all on function public.production_product_details(text)
from public, anon, authenticated;
grant execute on function public.production_product_details(text) to authenticated;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'workpiece_defects'
     ) then
    alter publication supabase_realtime add table public.workpiece_defects;
  end if;
end;
$$;
