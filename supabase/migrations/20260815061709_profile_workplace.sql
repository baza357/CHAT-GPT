-- Fixed workplace directory for employee profiles.

alter table public.profiles
  add column if not exists workplace text;

alter table public.profiles
  drop constraint if exists profiles_workplace_check;
alter table public.profiles
  add constraint profiles_workplace_check check (
    workplace is null
    or workplace in ('ПЦ Рябиновая', 'ПЦ Алтуфьево-1', 'ПЦ Алтуфьево-2')
  );

grant update (workplace) on table public.profiles to authenticated;

create or replace function private.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  submitted_email text;
  submitted_name text;
  submitted_phone text;
  submitted_personal_number text;
  submitted_shift_text text;
  submitted_shift smallint;
  submitted_job_title text;
  submitted_workplace text;
begin
  submitted_email := lower(trim(coalesce(new.email, '')));
  submitted_name := trim(
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'display_name', ''),
      ''
    )
  );
  submitted_phone := trim(coalesce(new.raw_user_meta_data ->> 'phone_e164', ''));
  submitted_personal_number := nullif(trim(coalesce(new.raw_user_meta_data ->> 'personal_number', '')), '');
  submitted_shift_text := nullif(trim(coalesce(new.raw_user_meta_data ->> 'shift_number', '')), '');
  submitted_job_title := nullif(trim(coalesce(new.raw_user_meta_data ->> 'job_title', '')), '');
  submitted_workplace := nullif(trim(coalesce(new.raw_user_meta_data ->> 'workplace', '')), '');

  if position('@' in submitted_email) <= 1 then
    raise exception 'Valid email is required';
  end if;
  if char_length(submitted_name) < 5 or submitted_name !~ '\s' then
    raise exception 'Full name is required';
  end if;
  if submitted_phone !~ '^\+7[0-9]{10}$' then
    raise exception 'Valid Russian phone is required';
  end if;
  if submitted_personal_number is not null and submitted_personal_number !~ '^[0-9]{1,4}$' then
    raise exception 'Personal number must contain up to four digits';
  end if;
  if submitted_shift_text is not null and submitted_shift_text not in ('1', '2') then
    raise exception 'Shift number must be 1 or 2';
  end if;
  if submitted_job_title is not null and char_length(submitted_job_title) > 120 then
    raise exception 'Job title is too long';
  end if;
  if submitted_workplace is not null and submitted_workplace not in (
    'ПЦ Рябиновая',
    'ПЦ Алтуфьево-1',
    'ПЦ Алтуфьево-2'
  ) then
    raise exception 'Unknown workplace';
  end if;

  submitted_shift := submitted_shift_text::smallint;

  insert into public.profiles (
    id,
    username,
    display_name,
    personal_number,
    shift_number,
    job_title,
    workplace,
    bio,
    status,
    last_seen,
    created_at,
    updated_at
  )
  values (
    new.id,
    submitted_email,
    submitted_name,
    submitted_personal_number,
    submitted_shift,
    submitted_job_title,
    submitted_workplace,
    '',
    'offline',
    null,
    now(),
    now()
  )
  on conflict (id) do update
  set username = excluded.username,
      display_name = excluded.display_name,
      personal_number = excluded.personal_number,
      shift_number = excluded.shift_number,
      job_title = excluded.job_title,
      workplace = excluded.workplace,
      updated_at = now();

  insert into public.profile_phone_numbers (profile_id, phone_e164)
  values (new.id, submitted_phone)
  on conflict (profile_id) do update
  set phone_e164 = excluded.phone_e164, updated_at = now();

  return new;
end;
$$;

revoke all on function private.handle_new_user()
from public, anon, authenticated;
