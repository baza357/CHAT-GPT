-- Soft-delete scanned products so the QR can be added again while preserving audit history.
-- Keep this after the production ordering and line-access migrations because it
-- extends their RPC implementations with active-product filtering.

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
