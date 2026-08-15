-- Per-user message hiding and sender-only deletion for everyone.

create table if not exists public.message_hidden_for_user (
  message_id bigint not null references public.messages(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  hidden_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

create index if not exists message_hidden_for_user_user_idx
on public.message_hidden_for_user (user_id, message_id);

alter table public.message_hidden_for_user enable row level security;

drop policy if exists "message_hidden_select_own" on public.message_hidden_for_user;
create policy "message_hidden_select_own"
on public.message_hidden_for_user
for select
to authenticated
using (user_id = (select auth.uid()));

drop policy if exists "message_hidden_insert_own" on public.message_hidden_for_user;
create policy "message_hidden_insert_own"
on public.message_hidden_for_user
for insert
to authenticated
with check (
  user_id = (select auth.uid())
  and exists (
    select 1
    from public.messages m
    join public.chat_members cm on cm.chat_id = m.chat_id
    where m.id = message_hidden_for_user.message_id
      and cm.user_id = (select auth.uid())
  )
);

drop policy if exists "message_hidden_delete_own" on public.message_hidden_for_user;
create policy "message_hidden_delete_own"
on public.message_hidden_for_user
for delete
to authenticated
using (user_id = (select auth.uid()));

revoke all on table public.message_hidden_for_user from anon, authenticated;
grant select, insert, delete on table public.message_hidden_for_user to authenticated;

-- A user may delete a message for every participant only when they sent it.
drop policy if exists "messages_delete_own_for_everyone" on public.messages;
create policy "messages_delete_own_for_everyone"
on public.messages
for delete
to authenticated
using (
  sender_id = (select auth.uid())
  and exists (
    select 1
    from public.chat_members cm
    where cm.chat_id = messages.chat_id
      and cm.user_id = (select auth.uid())
  )
);

grant delete on table public.messages to authenticated;
