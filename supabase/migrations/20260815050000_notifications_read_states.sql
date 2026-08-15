-- Persistent unread message counts and acknowledgements for assigned tasks.

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
on public.chat_read_states
for select
to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "chat_read_states_insert_self" on public.chat_read_states;
create policy "chat_read_states_insert_self"
on public.chat_read_states
for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and private.is_chat_member(chat_id)
);

drop policy if exists "chat_read_states_update_self" on public.chat_read_states;
create policy "chat_read_states_update_self"
on public.chat_read_states
for update
to authenticated
using (user_id = (select auth.uid()))
with check (
  user_id = (select auth.uid())
  and private.is_chat_member(chat_id)
);

revoke all on table public.chat_read_states from anon, authenticated;
grant select, insert, update on table public.chat_read_states to authenticated;

-- Existing conversations start as read so users are not flooded by historical badges.
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
    on read_state.chat_id = cm.chat_id
   and read_state.user_id = cm.user_id
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
on public.calendar_task_receipts
for select
to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "calendar_task_receipts_insert_assignee" on public.calendar_task_receipts;
create policy "calendar_task_receipts_insert_assignee"
on public.calendar_task_receipts
for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and exists (
    select 1
    from public.calendar_tasks task
    where task.id = calendar_task_receipts.task_id
      and task.contact_id = (select auth.uid())
      and task.owner_id <> (select auth.uid())
  )
);

drop policy if exists "calendar_task_receipts_update_self" on public.calendar_task_receipts;
create policy "calendar_task_receipts_update_self"
on public.calendar_task_receipts
for update
to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

revoke all on table public.calendar_task_receipts from anon, authenticated;
grant select, insert, update on table public.calendar_task_receipts to authenticated;
