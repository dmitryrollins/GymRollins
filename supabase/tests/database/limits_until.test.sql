-- Plan 24: profiles.limits_until, the injury note's optional end date.
begin;
create extension if not exists pgtap with schema extensions;
select plan(4);

insert into auth.users (id, email, aud, role) values
  ('24242424-1111-1111-1111-242424242424', 'limits-until@test.local', 'authenticated', 'authenticated');

set local role authenticated;
set local request.jwt.claims = '{"sub":"24242424-1111-1111-1111-242424242424","role":"authenticated"}';

select lives_ok($$ insert into public.profiles (limits) values ('Knee: no leg loading') $$,
  'a profile needs no end date');
select is((select limits_until from public.profiles), null::date, 'the end date is empty by default');
select lives_ok($$ update public.profiles set limits_until = '2026-10-26',
  client_updated_at = now() + interval '1 second' $$, 'an end date can be set');
select is((select limits_until from public.profiles), '2026-10-26'::date, 'the end date reads back as a day');

select * from finish();
rollback;
