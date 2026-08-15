-- Shared task calendars, group conversations, profile avatars and audio calls.

-- A narrowly scoped helper avoids recursive RLS checks on chat_members.
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

-- Group chat metadata and membership roles.
alter table public.chats
  add column if not exists title text,
  add column if not exists avatar_url text,
  add column if not exists created_by uuid references auth.users(id) on delete set null;

update public.chats
set title = 'Групповой чат'
where type = 'group' and nullif(trim(title), '') is null;

alter table public.chats
  drop constraint if exists chats_group_title_check;
alter table public.chats
  add constraint chats_group_title_check check (
    type = 'direct'
    or char_length(trim(coalesce(title, ''))) between 1 and 80
  );

create index if not exists chats_created_by_idx
on public.chats (created_by);

alter table public.chat_members
  add column if not exists role text not null default 'member';

alter table public.chat_members
  drop constraint if exists chat_members_role_check;
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

  if coalesce(cardinality(v_members), 0) < 2
    or cardinality(v_members) > 49 then
    raise exception 'A group requires 2 to 49 other members';
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

-- Tasks are visible to their creator and to the assigned user.
drop policy if exists "calendar_tasks_select_own" on public.calendar_tasks;
drop policy if exists "calendar_tasks_select_participant" on public.calendar_tasks;
create policy "calendar_tasks_select_participant"
on public.calendar_tasks
for select
to authenticated
using (
  owner_id = (select auth.uid())
  or contact_id = (select auth.uid())
);

drop policy if exists "calendar_tasks_update_own_contact" on public.calendar_tasks;
drop policy if exists "calendar_tasks_update_participant" on public.calendar_tasks;
create policy "calendar_tasks_update_participant"
on public.calendar_tasks
for update
to authenticated
using (
  owner_id = (select auth.uid())
  or contact_id = (select auth.uid())
)
with check (
  owner_id = (select auth.uid())
  or contact_id = (select auth.uid())
);

revoke update on table public.calendar_tasks from authenticated;
grant update (status) on table public.calendar_tasks to authenticated;

create index if not exists calendar_tasks_contact_starts_idx
on public.calendar_tasks (contact_id, starts_at);

-- Public profile pictures; only the owner may write inside their folder.
insert into storage.buckets (
  id,
  name,
  public,
  file_size_limit,
  allowed_mime_types
)
values (
  'avatars',
  'avatars',
  true,
  5242880,
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

-- WebRTC audio-call signaling. SDP offers/answers contain no media payload.
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
using (
  caller_id = (select auth.uid())
  or callee_id = (select auth.uid())
);

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
using (
  caller_id = (select auth.uid())
  or callee_id = (select auth.uid())
)
with check (
  caller_id = (select auth.uid())
  or callee_id = (select auth.uid())
);

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

-- Profiles of shared-chat members, task participants and call participants
-- must be readable so the UI can show a trusted name and avatar.
drop policy if exists "profiles_select_self_or_contact" on public.profiles;
drop policy if exists "profiles_select_related_user" on public.profiles;
create policy "profiles_select_related_user"
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
  or exists (
    select 1
    from public.chat_members cm
    where cm.user_id = profiles.id
      and private.is_chat_member(cm.chat_id)
  )
  or exists (
    select 1
    from public.calendar_tasks task
    where (
      task.owner_id = (select auth.uid())
      and task.contact_id = profiles.id
    ) or (
      task.contact_id = (select auth.uid())
      and task.owner_id = profiles.id
    )
  )
  or exists (
    select 1
    from public.calls call_row
    where (
      call_row.caller_id = (select auth.uid())
      and call_row.callee_id = profiles.id
    ) or (
      call_row.callee_id = (select auth.uid())
      and call_row.caller_id = profiles.id
    )
  )
);

-- Enable live updates for assigned tasks and call signaling.
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
