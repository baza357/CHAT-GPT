-- Allow a named group to start with the creator and one contact.
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
