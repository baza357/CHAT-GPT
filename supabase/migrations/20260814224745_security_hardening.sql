-- Harden the existing MVP messaging schema discovered by Supabase advisors.

revoke all on function public.start_direct_chat(uuid) from public, anon;
grant execute on function public.start_direct_chat(uuid) to authenticated;

create index if not exists chat_members_user_id_idx
on public.chat_members (user_id);

create index if not exists messages_sender_id_idx
on public.messages (sender_id);

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
