-- Rules found in review of plan 21: a cap per gym, an author's words after account deletion, one photo per listing,
-- what a hidden gym reveals, invisible text, and a workout keeping its gym link across phones.
begin;
create extension if not exists pgtap with schema extensions;
select plan(8);

insert into auth.users (id, email, aud, role) values
  ('fafafafa-0000-0000-0000-000000000001', 'rule-a@test.local', 'authenticated', 'authenticated'),
  ('fafafafa-0000-0000-0000-000000000002', 'rule-b@test.local', 'authenticated', 'authenticated');

create function pg_temp.as_user(n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    format('{"sub":"fafafafa-0000-0000-0000-00000000000%s","role":"authenticated"}', n), true);
end $$;
create function pg_temp.as_mcp(n int) returns void language plpgsql as $$
begin
  perform set_config('role', 'authenticated', true);
  perform set_config('request.jwt.claims',
    format('{"sub":"fafafafa-0000-0000-0000-00000000000%s","role":"authenticated","client_id":"claude"}', n), true);
end $$;
grant execute on function pg_temp.as_user(int), pg_temp.as_mcp(int) to authenticated;

-- A cap per gym -----------------------------------------------------------------------------------------------------
insert into public.gyms (id, visibility, name, maps_place_id)
  values ('fafafafa-0000-4000-8000-0000000000a0', 'public', 'Full Gym', 'rules-full');
insert into public.gym_equipment (id, gym_id, item_id, visibility, added_by, created_at)
  select gen_random_uuid(), 'fafafafa-0000-4000-8000-0000000000a0',
         (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null), 'public',
         'fafafafa-0000-0000-0000-000000000002', now() - interval '3 days'
  from generate_series(1, 299) n;
insert into public.gym_equipment (id, gym_id, item_id, visibility, added_by)
  values ('fafafafa-0000-4000-8000-0000000000b1', 'fafafafa-0000-4000-8000-0000000000a0',
          (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null), 'public',
          'fafafafa-0000-0000-0000-000000000001');
select pg_temp.as_user(1);
select throws_ok($$ select public.share_listing(gen_random_uuid(), 'fafafafa-0000-4000-8000-0000000000a0', 'barbell', null, null,
    '{"type":"none"}', 1, null, null, true) $$, 'P0001'::char(5), 'gym_full', 'a gym with 300 active listings takes no more');
select is(public.share_listing('fafafafa-0000-4000-8000-0000000000b1', 'fafafafa-0000-4000-8000-0000000000a0', 'flat-bench', null,
    null, '{"type":"none"}', 1, null, null, true) ->> 'status', 'created', 'a retry of a listing already there still succeeds at the cap');
reset role;
update public.gym_equipment set status = 'removed' where id = 'fafafafa-0000-4000-8000-0000000000b1';
select pg_temp.as_user(1);
select lives_ok($$ select public.share_listing(gen_random_uuid(), 'fafafafa-0000-4000-8000-0000000000a0', 'barbell', null, null,
    '{"type":"none"}', 1, null, null, true) $$, 'a removed listing frees a place');

-- An author's words after account deletion -------------------------------------------------------------------------------
reset role;
insert into public.gyms (id, visibility, name, maps_place_id)
  values ('fafafafa-0000-4000-8000-0000000000a1', 'public', 'Leaver Gym', 'rules-leaver');
select pg_temp.as_user(1);
select public.share_listing('fafafafa-0000-4000-8000-0000000000c1', 'fafafafa-0000-4000-8000-0000000000a1', 'lat-pulldown',
  'Call H at 555-0100', 'X1', '{"type":"none"}', 1, null, null, true);
select public.share_listing('fafafafa-0000-4000-8000-0000000000c2', 'fafafafa-0000-4000-8000-0000000000a1', 'barbell',
  'SharedBrand', 'S1', '{"type":"none"}', 1, null, null, true);
select pg_temp.as_user(2);
select public.share_listing('fafafafa-0000-4000-8000-0000000000c3', 'fafafafa-0000-4000-8000-0000000000a1', 'barbell',
  'SharedBrand', 'S1', '{"type":"none"}', 1, null, null, true);
select pg_temp.as_user(1);
select public.report_content('listing', 'fafafafa-0000-4000-8000-0000000000c3', 'spam', 'Their number is 555-0199');
select public.delete_my_account();
reset role;
select set_config('request.jwt.claims', '', true);
select is((select count(*) from public.equipment_items where brand like 'Call H%')::int, 0,
  'an item only the leaver used loses its brand and model');
select is((select i.brand from public.gym_equipment e join public.equipment_items i on i.id = e.item_id
           where e.id = 'fafafafa-0000-4000-8000-0000000000c1'), null,
  'and its listing points at the generic item of the kind');
select is((select i.kind_id from public.gym_equipment e join public.equipment_items i on i.id = e.item_id
           where e.id = 'fafafafa-0000-4000-8000-0000000000c1'), 'lat-pulldown', 'of the same kind');
select is((select i.brand from public.gym_equipment e join public.equipment_items i on i.id = e.item_id
           where e.id = 'fafafafa-0000-4000-8000-0000000000c3'), 'SharedBrand', 'an item others list too stays');
select ok(exists (select 1 from public.reports where target_id = 'fafafafa-0000-4000-8000-0000000000c3' and reporter_id is null
                  and note is null and reason = 'spam'), 'a report stays, with the reporter''s note gone');

select * from finish();
rollback;
