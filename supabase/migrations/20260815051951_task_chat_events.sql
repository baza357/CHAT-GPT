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
