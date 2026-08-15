-- The verified phone is now the only user-facing contact number.
alter table public.profiles
  drop column if exists contact_number;
