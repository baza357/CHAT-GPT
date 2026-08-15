-- Transactional integration tests for the production state machine.
-- The script uses one existing profile, changes its role between steps and rolls every change back.

begin;

do $$
declare
  actor_id uuid;
  test_line_id uuid;
  test_shift_id uuid;
  blocked boolean;
  actual_status text;
  duplicate_message text;
  active_count integer;
  total_count integer;
  defect_id uuid;
  defect_duplicate_message text;
begin
  select id into actor_id from public.profiles order by created_at limit 1;
  select id into test_line_id from public.production_lines where number = 1;
  select id into test_shift_id from public.production_shifts where code = '1';

  if actor_id is null then raise exception 'Для тестов нужен хотя бы один профиль'; end if;
  perform set_config('request.jwt.claim.sub', actor_id::text, true);
  update public.profiles
  set production_role = 'master', production_line_id = test_line_id, shift_id = test_shift_id,
      tester_cube_number = 1
  where id = actor_id;

  -- Test 1: master -> testing -> QC -> packing -> packed.
  perform public.production_transition('91.01.01.000001', 'sent_to_testing', null);
  blocked := false;
  begin
    perform public.production_transition('91.01.01.000001', 'sent_to_testing', null);
  exception when others then
    blocked := true;
    duplicate_message := sqlerrm;
  end;
  if not blocked then raise exception 'Тест 1: повторное сканирование не заблокировано'; end if;
  if position('Дубликат' in duplicate_message) <> 1 then
    raise exception 'Тест 1: ожидалась ошибка «Дубликат», получено: %', duplicate_message;
  end if;
  update public.profiles set production_role = 'tester' where id = actor_id;
  perform public.production_transition('91.01.01.000001', 'sent_to_quality_control', null);
  update public.profiles set production_role = 'quality_control' where id = actor_id;
  perform public.production_transition('91.01.01.000001', 'sent_to_packing', null);
  update public.profiles set production_role = 'packing' where id = actor_id;
  perform public.production_transition('91.01.01.000001', 'packed', null);

  -- Test 2: repair requested by master, then mandatory retest and normal completion.
  update public.profiles set production_role = 'master' where id = actor_id;
  perform public.production_transition('92.01.01.000002', 'sent_to_repair', 'Дефект сборки');
  update public.profiles set production_role = 'repair' where id = actor_id;
  perform public.production_transition('92.01.01.000002', 'repair_started', null);
  perform public.production_transition('92.01.01.000002', 'repair_completed', null);
  update public.profiles set production_role = 'tester' where id = actor_id;
  perform public.production_transition('92.01.01.000002', 'sent_to_quality_control', null);
  update public.profiles set production_role = 'quality_control' where id = actor_id;
  perform public.production_transition('92.01.01.000002', 'sent_to_packing', null);
  update public.profiles set production_role = 'packing' where id = actor_id;
  perform public.production_transition('92.01.01.000002', 'packed', null);

  -- Test 3: tester sends to repair, repair returns to testing, route reaches packing.
  update public.profiles set production_role = 'master' where id = actor_id;
  perform public.production_transition('93.01.01.000003', 'sent_to_testing', null);
  update public.profiles set production_role = 'tester' where id = actor_id;
  perform public.production_transition('93.01.01.000003', 'sent_to_repair', 'Не прошёл тест');
  update public.profiles set production_role = 'repair' where id = actor_id;
  perform public.production_transition('93.01.01.000003', 'repair_started', null);
  perform public.production_transition('93.01.01.000003', 'repair_completed', null);
  update public.profiles set production_role = 'tester' where id = actor_id;
  perform public.production_transition('93.01.01.000003', 'sent_to_quality_control', null);
  update public.profiles set production_role = 'quality_control' where id = actor_id;
  perform public.production_transition('93.01.01.000003', 'sent_to_packing', null);

  -- Test 4: QC sends to rework, master completes it, mandatory retest follows.
  update public.profiles set production_role = 'master' where id = actor_id;
  perform public.production_transition('94.01.01.000004', 'sent_to_testing', null);
  update public.profiles set production_role = 'tester' where id = actor_id;
  perform public.production_transition('94.01.01.000004', 'sent_to_quality_control', null);
  update public.profiles set production_role = 'quality_control' where id = actor_id;
  perform public.production_transition('94.01.01.000004', 'sent_to_rework', 'Замечание ОТК');
  update public.profiles set production_role = 'master' where id = actor_id;
  perform public.production_complete_rework('94.01.01.000004', 'Исправлено крепление камеры');
  update public.profiles set production_role = 'tester' where id = actor_id;
  perform public.production_transition('94.01.01.000004', 'sent_to_quality_control', null);
  update public.profiles set production_role = 'quality_control' where id = actor_id;
  perform public.production_transition('94.01.01.000004', 'sent_to_packing', null);
  update public.profiles set production_role = 'packing' where id = actor_id;
  perform public.production_transition('94.01.01.000004', 'packed', null);

  -- Test 5: testing -> packed must be rejected.
  update public.profiles set production_role = 'master' where id = actor_id;
  perform public.production_transition('95.01.01.000005', 'sent_to_testing', null);
  update public.profiles set production_role = 'quality_control' where id = actor_id;
  blocked := false;
  begin
    perform public.production_transition('95.01.01.000005', 'packed', null);
  exception when others then blocked := true;
  end;
  if not blocked then raise exception 'Тест 5: переход testing -> packed не заблокирован'; end if;

  -- Test 6: repair -> packing must be rejected; repair -> testing -> QC -> packing is allowed.
  update public.profiles set production_role = 'master' where id = actor_id;
  perform public.production_transition('96.01.01.000006', 'sent_to_repair', 'Нужен ремонт');
  update public.profiles set production_role = 'quality_control' where id = actor_id;
  blocked := false;
  begin
    perform public.production_transition('96.01.01.000006', 'sent_to_packing', null);
  exception when others then blocked := true;
  end;
  if not blocked then raise exception 'Тест 6: переход repair -> packing не заблокирован'; end if;
  update public.profiles set production_role = 'repair' where id = actor_id;
  perform public.production_transition('96.01.01.000006', 'repair_started', null);
  perform public.production_transition('96.01.01.000006', 'repair_completed', null);
  update public.profiles set production_role = 'tester' where id = actor_id;
  perform public.production_transition('96.01.01.000006', 'sent_to_quality_control', null);
  update public.profiles set production_role = 'quality_control' where id = actor_id;
  perform public.production_transition('96.01.01.000006', 'sent_to_packing', null);

  select current_status into actual_status from public.products where full_qr = '96.01.01.000006';
  if actual_status <> 'packing' then raise exception 'Тест 6: корректный маршрут не достиг упаковки'; end if;

  -- Additional feature test: delete one active scan and add the same QR again.
  update public.profiles set production_role = 'master' where id = actor_id;
  perform public.production_transition('97.01.01.000007', 'sent_to_testing', null);
  perform public.production_delete_product('97.01.01.000007', 'Ошибочное сканирование');
  perform public.production_transition('97.01.01.000007', 'sent_to_testing', null);

  select count(*)::integer into total_count
  from public.products where full_qr = '97.01.01.000007';
  select count(*)::integer into active_count
  from public.products where full_qr = '97.01.01.000007' and deleted_at is null;

  if total_count <> 2 or active_count <> 1 then
    raise exception 'Удаление и повторное добавление не прошло: всего %, активных %', total_count, active_count;
  end if;
  if not exists (
    select 1
    from public.product_events event
    join public.products item on item.id = event.product_id
    where item.full_qr = '97.01.01.000007' and event.event_type = 'deleted'
  ) then
    raise exception 'Событие удаления не записано в аудит';
  end if;

  if not exists (
    select 1 from public.production_product_list(null) listed
    where listed.full_qr = '97.01.01.000007'
  ) then
    raise exception 'Повторно добавленное изделие отсутствует в общем списке';
  end if;

  -- Workpiece defects: duplicate is blocked, soft delete allows the same QR again.
  perform public.production_record_workpiece_defect('NODE-000001', 'Трещина корпуса узла');
  blocked := false;
  begin
    perform public.production_record_workpiece_defect('NODE-000001', 'Повторная запись');
  exception when others then
    blocked := true;
    defect_duplicate_message := sqlerrm;
  end;
  if not blocked or position('Дубликат' in defect_duplicate_message) <> 1 then
    raise exception 'Дубликат брака заготовки не заблокирован: %', defect_duplicate_message;
  end if;

  select item.id into defect_id
  from public.workpiece_defects item
  where item.qr_code = 'NODE-000001' and item.deleted_at is null;
  perform public.production_delete_workpiece_defect(defect_id, 'Ошибочная запись');
  perform public.production_record_workpiece_defect('NODE-000001', 'Трещина корпуса узла');

  select count(*)::integer into total_count
  from public.workpiece_defects item where item.qr_code = 'NODE-000001';
  select count(*)::integer into active_count
  from public.workpiece_defects item where item.qr_code = 'NODE-000001' and item.deleted_at is null;
  if total_count <> 2 or active_count <> 1 then
    raise exception 'Удаление и повторный учёт брака не прошли: всего %, активных %', total_count, active_count;
  end if;
end;
$$;

select '6/6 routes + product list + cube + rework + workpiece defects passed' as result;

rollback;
