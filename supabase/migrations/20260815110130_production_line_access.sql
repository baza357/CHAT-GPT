-- Restrict production reads to the employee's line unless the profile is a production administrator.

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
