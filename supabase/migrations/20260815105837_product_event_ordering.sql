-- Guarantee a strict per-product event order even when several transitions run
-- inside one transaction or arrive within the same clock tick.

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
