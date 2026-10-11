-- Plan 15: bodyweight.source — null for app weigh-ins, 'apple_health' for ones read from Apple Health.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email, aud, role) values
  ('15151515-1111-1111-1111-151515151515', 'health-a@test.local', 'authenticated', 'authenticated');

set local role authenticated;
set local request.jwt.claims = '{"sub":"15151515-1111-1111-1111-151515151515","role":"authenticated"}';

select lives_ok(
  $$ insert into public.bodyweight (id, measured_at, w_kg) values
     ('15151515-0000-0000-0000-000000000001', '2026-09-30T07:00:00Z', 81) $$,
  'an app weigh-in needs no source');
select lives_ok(
  $$ insert into public.bodyweight (id, measured_at, w_kg, source) values
     ('15151515-0000-0000-0000-000000000002', '2026-09-30T07:05:00Z', 81.2, 'apple_health') $$,
  'a weigh-in read from Apple Health is marked apple_health');
select is((select source from public.bodyweight where id = '15151515-0000-0000-0000-000000000002'), 'apple_health',
  'the source reads back');
select throws_ok(
  $$ insert into public.bodyweight (id, measured_at, w_kg, source) values
     ('15151515-0000-0000-0000-000000000003', '2026-09-30T07:10:00Z', 81, 'fitbit') $$,
  '23514', null, 'unknown sources are rejected');

select lives_ok(
  $$ update public.bodyweight set health_sample_id = '15151515-9999-0000-0000-000000000001',
       health_fat_sample_id = '15151515-9999-0000-0000-000000000002'
     where id = '15151515-0000-0000-0000-000000000002' $$,
  'the Health sample ids are stored');

-- A deleted Health weigh-in isn't brought back by a newer edit from a device that missed the deletion.
update public.bodyweight set deleted_at = '2099-01-01T08:00:00Z', client_updated_at = '2099-01-01T08:00:00Z'
  where id = '15151515-0000-0000-0000-000000000002';
update public.bodyweight set deleted_at = null, bf_pct = 14, client_updated_at = '2099-01-01T09:00:00Z'
  where id = '15151515-0000-0000-0000-000000000002';
select isnt((select deleted_at from public.bodyweight where id = '15151515-0000-0000-0000-000000000002'), null,
  'a deleted Health weigh-in stays deleted');
update public.bodyweight set deleted_at = '2099-01-01T08:00:00Z', client_updated_at = '2099-01-01T08:00:00Z'
  where id = '15151515-0000-0000-0000-000000000001';
update public.bodyweight set deleted_at = null, client_updated_at = '2099-01-01T09:00:00Z'
  where id = '15151515-0000-0000-0000-000000000001';
select is((select deleted_at from public.bodyweight where id = '15151515-0000-0000-0000-000000000001'), null,
  'an app weigh-in can still be restored by a newer edit');

-- An older deletion of a Health weigh-in still beats a newer automatic edit.
insert into public.bodyweight (id, measured_at, w_kg, source, health_sample_id, client_updated_at) values
  ('15151515-0000-0000-0000-000000000005', '2026-09-30T07:00:00Z', 81, 'apple_health',
   '15151515-9999-0000-0000-000000000005', '2099-01-01T10:00:00Z');
update public.bodyweight set deleted_at = '2099-01-01T09:30:00Z', client_updated_at = '2099-01-01T09:30:00Z'
  where id = '15151515-0000-0000-0000-000000000005';
select isnt((select deleted_at from public.bodyweight where id = '15151515-0000-0000-0000-000000000005'), null,
  'an older deletion of a Health weigh-in is accepted');

select * from finish();
rollback;
