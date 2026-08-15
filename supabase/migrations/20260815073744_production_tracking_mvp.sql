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
