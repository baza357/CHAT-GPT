-- Product list, tester workstations and workpiece-defect accounting.
-- This migration must run after all earlier production RPC replacements.

alter table public.profiles
  add column if not exists tester_cube_number smallint;

alter table public.profiles
  drop constraint if exists profiles_tester_cube_number_check;
alter table public.profiles
  add constraint profiles_tester_cube_number_check check (
    tester_cube_number is null or tester_cube_number between 1 and 10
  );

alter table public.product_events
  add column if not exists workstation_name text;

alter table public.product_events
  drop constraint if exists product_events_workstation_name_check;
alter table public.product_events
  add constraint product_events_workstation_name_check check (
    workstation_name is null
    or char_length(trim(workstation_name)) between 1 and 100
  );

create or replace function private.set_product_event_workstation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  actor_role text;
  cube_number smallint;
begin
  select profile.production_role, profile.tester_cube_number
  into actor_role, cube_number
  from public.profiles profile
  where profile.id = new.user_id;

  if actor_role = 'tester' then
    if cube_number is null then
      raise exception 'Для тестировщика укажите рабочее место «Куб №» от 1 до 10 в профиле';
    end if;
    new.workstation_name := 'Куб №' || cube_number::text;
  end if;

  return new;
end;
$$;

revoke all on function private.set_product_event_workstation()
from public, anon, authenticated;

drop trigger if exists product_events_set_workstation on public.product_events;
create trigger product_events_set_workstation
before insert on public.product_events
for each row execute function private.set_product_event_workstation();

create table if not exists public.workpiece_defects (
  id uuid primary key default gen_random_uuid(),
  qr_code text not null,
  reason_text text not null,
  production_line_id uuid not null references public.production_lines(id),
  shift_id uuid not null references public.production_shifts(id),
  reported_by uuid not null references public.profiles(id) on delete restrict,
  deleted_at timestamptz,
  deleted_by uuid references public.profiles(id) on delete restrict,
  deletion_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint workpiece_defects_qr_code_check check (
    char_length(trim(qr_code)) between 4 and 160
    and qr_code !~ '[[:cntrl:]]'
  ),
  constraint workpiece_defects_reason_text_check check (
    char_length(trim(reason_text)) between 1 and 2000
  ),
  constraint workpiece_defects_deletion_reason_check check (
    deletion_reason is null
    or char_length(trim(deletion_reason)) between 1 and 2000
  ),
  constraint workpiece_defects_deleted_state_check check (
    (deleted_at is null and deleted_by is null)
    or (deleted_at is not null and deleted_by is not null)
  )
);

create unique index if not exists workpiece_defects_active_qr_unique_idx
on public.workpiece_defects (lower(qr_code))
where deleted_at is null;

create index if not exists workpiece_defects_active_line_created_idx
on public.workpiece_defects (production_line_id, created_at desc)
where deleted_at is null;

create index if not exists workpiece_defects_shift_id_idx
on public.workpiece_defects (shift_id);

create index if not exists workpiece_defects_reported_by_idx
on public.workpiece_defects (reported_by, created_at desc);

create index if not exists workpiece_defects_deleted_by_idx
on public.workpiece_defects (deleted_by)
where deleted_by is not null;

create or replace function private.set_workpiece_defect_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke all on function private.set_workpiece_defect_updated_at()
from public, anon, authenticated;

drop trigger if exists workpiece_defects_set_updated_at on public.workpiece_defects;
create trigger workpiece_defects_set_updated_at
before update on public.workpiece_defects
for each row execute function private.set_workpiece_defect_updated_at();

alter table public.workpiece_defects enable row level security;

drop policy if exists "workpiece_defects_select_production_staff" on public.workpiece_defects;
create policy "workpiece_defects_select_production_staff"
on public.workpiece_defects for select to authenticated
using (
  exists (
    select 1
    from public.profiles profile
    where profile.id = (select auth.uid())
      and (
        profile.production_admin
        or (
          profile.production_role is not null
          and profile.production_line_id = workpiece_defects.production_line_id
        )
      )
  )
);

revoke all on table public.workpiece_defects from public, anon, authenticated;
grant select on table public.workpiece_defects to authenticated;

create or replace function public.production_product_list(p_search text default null)
returns table (
  id uuid,
  full_qr text,
  release text,
  serial_number text,
  current_status text,
  line_number integer,
  shift_name text,
  last_event_type text,
  last_event_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  normalized_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles profile where profile.id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;
  if actor.production_line_id is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная линия';
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
    latest.event_type,
    latest.created_at,
    item.created_at,
    item.updated_at
  from public.products item
  left join public.production_lines line on line.id = item.current_line_id
  left join public.production_shifts shift on shift.id = item.current_shift_id
  left join lateral (
    select event.event_type, event.created_at
    from public.product_events event
    where event.product_id = item.id
    order by event.created_at desc, event.id desc
    limit 1
  ) latest on true
  where item.deleted_at is null
    and (
      actor.production_admin
      or item.current_line_id = actor.production_line_id
    )
    and (
      normalized_search is null
      or item.full_qr ilike '%' || normalized_search || '%'
      or item.serial_number ilike '%' || normalized_search || '%'
      or item.release ilike '%' || normalized_search || '%'
    )
  order by item.updated_at desc, item.id;
end;
$$;

revoke all on function public.production_product_list(text)
from public, anon, authenticated;
grant execute on function public.production_product_list(text) to authenticated;

create or replace function public.production_complete_rework(
  p_full_qr text,
  p_reason_text text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  normalized_qr text := trim(coalesce(p_full_qr, ''));
  normalized_reason text := nullif(trim(coalesce(p_reason_text, '')), '');
  item_id uuid;
  last_rework_event text;
  transition_result jsonb;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  if normalized_reason is null then raise exception 'Опишите, что было доработано'; end if;
  if char_length(normalized_reason) > 2000 then raise exception 'Описание доработки слишком длинное'; end if;

  select item.id into item_id
  from public.products item
  where item.full_qr = normalized_qr
    and item.deleted_at is null;

  if item_id is null then raise exception 'Изделие не найдено'; end if;

  select event.event_type into last_rework_event
  from public.product_events event
  where event.product_id = item_id
    and event.event_type in ('sent_to_rework', 'rework_started', 'rework_completed')
  order by event.created_at desc, event.id desc
  limit 1;

  if last_rework_event = 'sent_to_rework' then
    perform public.production_transition(normalized_qr, 'rework_started', null);
  elsif last_rework_event is distinct from 'rework_started' then
    raise exception 'Изделие не ожидает завершения доработки';
  end if;

  transition_result := public.production_transition(
    normalized_qr,
    'rework_completed',
    normalized_reason
  );

  return transition_result || jsonb_build_object('event_type', 'rework_completed');
end;
$$;

revoke all on function public.production_complete_rework(text, text)
from public, anon, authenticated;
grant execute on function public.production_complete_rework(text, text) to authenticated;

create or replace function public.production_record_workpiece_defect(
  p_qr_code text,
  p_reason_text text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  normalized_qr text := trim(coalesce(p_qr_code, ''));
  normalized_reason text := nullif(trim(coalesce(p_reason_text, '')), '');
  existing_id uuid;
  defect public.workpiece_defects%rowtype;
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles profile where profile.id = caller_id;
  if actor.production_role is null then raise exception 'В профиле не указана производственная должность'; end if;
  if actor.production_line_id is null then raise exception 'В профиле не указана производственная линия'; end if;
  if actor.shift_id is null then raise exception 'В профиле не указана производственная смена'; end if;
  if char_length(normalized_qr) not between 4 and 160 or normalized_qr ~ '[[:cntrl:]]' then
    raise exception 'QR заготовки должен содержать от 4 до 160 печатных символов';
  end if;
  if normalized_reason is null then raise exception 'Укажите причину брака заготовки'; end if;
  if char_length(normalized_reason) > 2000 then raise exception 'Причина брака слишком длинная'; end if;

  select item.id into existing_id
  from public.workpiece_defects item
  where lower(item.qr_code) = lower(normalized_qr)
    and item.deleted_at is null
  for update;

  if existing_id is not null then
    raise exception 'Дубликат: QR заготовки % уже учтён как брак', normalized_qr;
  end if;

  begin
    insert into public.workpiece_defects (
      qr_code,
      reason_text,
      production_line_id,
      shift_id,
      reported_by
    ) values (
      normalized_qr,
      normalized_reason,
      actor.production_line_id,
      actor.shift_id,
      caller_id
    )
    returning * into defect;
  exception when unique_violation then
    raise exception 'Дубликат: этот QR заготовки уже учтён как брак';
  end;

  return jsonb_build_object(
    'id', defect.id,
    'qr_code', defect.qr_code,
    'reason_text', defect.reason_text,
    'created_at', defect.created_at
  );
end;
$$;

revoke all on function public.production_record_workpiece_defect(text, text)
from public, anon, authenticated;
grant execute on function public.production_record_workpiece_defect(text, text) to authenticated;

create or replace function public.production_delete_workpiece_defect(
  p_defect_id uuid,
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
  defect public.workpiece_defects%rowtype;
  normalized_reason text := nullif(trim(coalesce(p_reason_text, '')), '');
  deleted_timestamp timestamptz := clock_timestamp();
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles profile where profile.id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;
  if char_length(normalized_reason) > 2000 then raise exception 'Причина удаления слишком длинная'; end if;

  select * into defect
  from public.workpiece_defects item
  where item.id = p_defect_id
    and item.deleted_at is null
  for update;

  if defect.id is null then raise exception 'Запись уже удалена или не найдена'; end if;
  if not actor.production_admin and defect.production_line_id is distinct from actor.production_line_id then
    raise exception 'Запись относится к другой производственной линии';
  end if;
  if not actor.production_admin
     and actor.production_role <> 'master'
     and defect.reported_by <> caller_id then
    raise exception 'Удалить запись может автор, мастер линии или администратор';
  end if;

  update public.workpiece_defects
  set deleted_at = deleted_timestamp,
      deleted_by = caller_id,
      deletion_reason = normalized_reason
  where id = defect.id;

  return jsonb_build_object(
    'id', defect.id,
    'qr_code', defect.qr_code,
    'deleted_at', deleted_timestamp
  );
end;
$$;

revoke all on function public.production_delete_workpiece_defect(uuid, text)
from public, anon, authenticated;
grant execute on function public.production_delete_workpiece_defect(uuid, text) to authenticated;

create or replace function public.production_workpiece_defect_list(p_search text default null)
returns table (
  id uuid,
  qr_code text,
  reason_text text,
  line_number integer,
  shift_name text,
  reported_by uuid,
  reporter_name text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  caller_id uuid := (select auth.uid());
  actor public.profiles%rowtype;
  normalized_search text := nullif(trim(coalesce(p_search, '')), '');
begin
  if caller_id is null then raise exception 'Требуется вход в аккаунт'; end if;
  select * into actor from public.profiles profile where profile.id = caller_id;
  if actor.production_role is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная должность';
  end if;
  if actor.production_line_id is null and not actor.production_admin then
    raise exception 'В профиле не указана производственная линия';
  end if;

  return query
  select
    defect.id,
    defect.qr_code,
    defect.reason_text,
    line.number,
    shift.name,
    defect.reported_by,
    reporter.display_name,
    defect.created_at,
    defect.updated_at
  from public.workpiece_defects defect
  join public.production_lines line on line.id = defect.production_line_id
  join public.production_shifts shift on shift.id = defect.shift_id
  join public.profiles reporter on reporter.id = defect.reported_by
  where defect.deleted_at is null
    and (
      actor.production_admin
      or defect.production_line_id = actor.production_line_id
    )
    and (
      normalized_search is null
      or defect.qr_code ilike '%' || normalized_search || '%'
      or defect.reason_text ilike '%' || normalized_search || '%'
      or reporter.display_name ilike '%' || normalized_search || '%'
    )
  order by defect.created_at desc, defect.id;
end;
$$;

revoke all on function public.production_workpiece_defect_list(text)
from public, anon, authenticated;
grant execute on function public.production_workpiece_defect_list(text) to authenticated;

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
    'workstation_name', event.workstation_name,
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
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'workpiece_defects'
     ) then
    alter publication supabase_realtime add table public.workpiece_defects;
  end if;
end;
$$;
