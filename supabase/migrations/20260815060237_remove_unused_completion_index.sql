-- Completion notifications filter by task owner, so this index is unnecessary.
drop index if exists public.calendar_tasks_completed_by_idx;
