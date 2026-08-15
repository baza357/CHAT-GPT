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
