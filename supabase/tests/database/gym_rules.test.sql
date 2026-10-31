-- Rules found in review of plan 21: a cap per gym, an author's words after account deletion, one photo per listing,
-- what a hidden gym reveals, invisible text, and a workout keeping its gym link across phones.
begin;
create extension if not exists pgtap with schema extensions;
select plan(54);

insert into auth.users (id, email, aud, role) values
  ('fafafafa-0000-0000-0000-000000000001', 'rule-a@test.local', 'authenticated', 'authenticated'),
  ('fafafafa-0000-0000-0000-000000000002', 'rule-b@test.local', 'authenticated', 'authenticated'),
  ('fafafafa-0000-0000-0000-000000000003', 'rule-c@test.local', 'authenticated', 'authenticated');

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

-- One photo backs one listing --------------------------------------------------------------------------------------------
reset role;
insert into storage.objects (bucket_id, name, owner_id, metadata) values
  ('gym-photos', 'fafafafa-0000-4000-8000-0000000000d1.jpg', 'fafafafa-0000-0000-0000-000000000003', '{"mimetype":"image/jpeg"}');
select pg_temp.as_user(3);
select is(public.share_listing(gen_random_uuid(), 'fafafafa-0000-4000-8000-0000000000a1', 'dumbbells', null, null,
    '{"type":"none"}', 1, null, 'fafafafa-0000-4000-8000-0000000000d1.jpg', true) ->> 'status', 'created', 'a photo backs a listing');
select throws_ok($$ select public.share_listing(gen_random_uuid(), 'fafafafa-0000-4000-8000-0000000000a1', 'barbell', null, null,
    '{"type":"none"}', 1, null, 'fafafafa-0000-4000-8000-0000000000d1.jpg', true) $$, 'P0001'::char(5), 'photo_in_use',
  'but not a second one');
reset role;
select throws_ok($$ insert into public.gym_equipment (gym_id, item_id, visibility, photo_path)
  values ('fafafafa-0000-4000-8000-0000000000a1', (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null),
          'public', 'fafafafa-0000-4000-8000-0000000000d1.jpg') $$, '23505'::char(5), null,
  'and the table refuses it too, whatever writes');

-- A hidden gym reads like a missing one -----------------------------------------------------------------------------------
select pg_temp.as_user(3);
insert into public.gyms (id, visibility, name) values ('fafafafa-0000-4000-8000-0000000000e0', 'private', 'Hidden gym');
select pg_temp.as_user(2);
select throws_ok($$ insert into public.gym_equipment (gym_id, item_id, visibility)
  values (gen_random_uuid(), (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null), 'public') $$,
  '23503'::char(5), 'unknown gym', 'a public listing on a random id says unknown gym');
select throws_ok($$ insert into public.gym_equipment (gym_id, item_id, visibility)
  values ('fafafafa-0000-4000-8000-0000000000e0', (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null), 'public') $$,
  '23503'::char(5), 'unknown gym', 'and so does one on someone else''s private gym');

-- A flagged gym is its creator's to see, but not Claude's ------------------------------------------------------------------
reset role;
insert into public.gyms (id, visibility, name, maps_place_id, status, created_by)
  values ('fafafafa-0000-4000-8000-0000000000f0', 'public', 'Flagged gym', 'rules-flagged', 'flagged', 'fafafafa-0000-0000-0000-000000000003');
select pg_temp.as_user(3);
select is((select count(*) from public.gyms where id = 'fafafafa-0000-4000-8000-0000000000f0')::int, 1, 'its creator sees a flagged gym');
select pg_temp.as_mcp(3);
select is((select count(*) from public.gyms where id = 'fafafafa-0000-4000-8000-0000000000f0')::int, 0, 'Claude on that account does not');
reset role;
select set_config('request.jwt.claims', '', true);

-- Text no one can see ---------------------------------------------------------------------------------------------------
select is(gym_private.clean_text('Iron ' || chr(917569) || 'Gym'), false, 'tag characters (U+E0000 block) are refused');
select is(gym_private.clean_text('Iron' || chr(1564) || 'Gym'), false, 'U+061C is refused');
select is(gym_private.clean_text('Iron' || chr(6158) || 'Gym'), false, 'U+180E is refused');
select is(gym_private.clean_text('Iron' || chr(65529) || 'Gym'), false, 'U+FFF9 is refused');
select is(gym_private.clean_text('Iron' || chr(8205) || 'Gym'), false, 'a joiner between ASCII letters is refused');
select is(gym_private.clean_text(chr(8205) || 'Iron'), false, 'or at the start');
select is(gym_private.clean_text(chr(128104) || chr(8205) || chr(128105)), true, 'a joiner in an emoji sequence passes');
select is(gym_private.clean_text('Iron' || chr(8204) || 'Gym'), false, 'a non-joiner between ASCII letters is refused');
select is(gym_private.clean_text(chr(1605) || chr(8204) || chr(1740)), true, 'and passes in a Persian word');
select is(gym_private.clean_text('Iron Gym 💪 ' || chr(2325) || chr(8205) || chr(2359)), true, 'and in a script that needs it');
select throws_ok(format($$ insert into public.reports (target_type, target_id, reason, note)
  values ('gym', gen_random_uuid(), 'other', %L) $$, 'see ' || chr(917569)), '23514'::char(5), null, 'a report note is cleaned too');
select lives_ok($$ insert into public.reports (target_type, target_id, reason, note)
  values ('gym', gen_random_uuid(), 'other', E'two\nlines') $$, 'but may have lines');

-- A workout keeps its gym when a phone cannot resolve it ----------------------------------------------------------------
select pg_temp.as_user(3);
select public.upsert_workout(jsonb_build_object('id', 'fafafafa-0000-4000-8000-000000000a01', 'started_at', now(), 'name', 'W',
  'client_updated_at', '2026-10-31T10:00:00Z', 'gym_id', 'fafafafa-0000-4000-8000-0000000000a1',
  'entries', jsonb_build_array(jsonb_build_object('id', 'fafafafa-0000-4000-8000-000000000a11', 'exercise_id', '0025',
    'position', 0, 'gym_equipment_id', 'fafafafa-0000-4000-8000-0000000000c3'))));
select public.upsert_workout(jsonb_build_object('id', 'fafafafa-0000-4000-8000-000000000a01', 'started_at', now(), 'name', 'W2',
  'client_updated_at', '2026-10-31T11:00:00Z', 'force', true,
  'entries', jsonb_build_array(jsonb_build_object('id', 'fafafafa-0000-4000-8000-000000000a11', 'exercise_id', '0025', 'position', 0))));
select is((select gym_id from public.workouts where id = 'fafafafa-0000-4000-8000-000000000a01'),
  'fafafafa-0000-4000-8000-0000000000a1'::uuid, 'a push with no gym keeps the stored link');
select is((select gym_equipment_id from public.workout_entries where id = 'fafafafa-0000-4000-8000-000000000a11'),
  'fafafafa-0000-4000-8000-0000000000c3'::uuid, 'and an entry with no listing keeps its own');
reset role;
update public.gyms set status = 'removed' where id = 'fafafafa-0000-4000-8000-0000000000a1';
select pg_temp.as_user(3);
select public.upsert_workout(jsonb_build_object('id', 'fafafafa-0000-4000-8000-000000000a01', 'started_at', now(), 'name', 'W3',
  'client_updated_at', '2026-10-31T12:00:00Z', 'force', true,
  'entries', jsonb_build_array(jsonb_build_object('id', 'fafafafa-0000-4000-8000-000000000a11', 'exercise_id', '0025', 'position', 0))));
select is((select gym_id from public.workouts where id = 'fafafafa-0000-4000-8000-000000000a01'), null::uuid,
  'a link to a gym the caller lost is not kept');
select is((select gym_equipment_id from public.workout_entries where id = 'fafafafa-0000-4000-8000-000000000a11'), null::uuid,
  'nor an entry''s link to a listing they lost');
select public.upsert_workout(jsonb_build_object('id', 'fafafafa-0000-4000-8000-000000000a02', 'started_at', now(), 'name', 'W',
  'client_updated_at', '2026-10-31T12:00:00Z', 'gym_id', 'fafafafa-0000-4000-8000-0000000000a1'));
select is((select gym_id from public.workouts where id = 'fafafafa-0000-4000-8000-000000000a02'), null::uuid,
  'and a link sent for a gym the caller cannot read is still dropped');

-- More text no one can see ------------------------------------------------------------------------------------------------
select is((select array_agg(h order by h) from unnest(array['AD', '34F', '115F', '1160', '17B4', '17B5', '180B', '180C',
    '180D', '180E', '180F', '2028', '2029', '3164', 'FE00', 'FE0A', 'FE0E', 'FFA0', 'FFFC', 'E000', 'F8FF', 'F0000',
    'FFFFD', '100000', '10FFFD', '1D173', '1D17A', 'E0080', 'E01EF']) h
  where gym_private.clean_text('Iron' || chr(('x' || lpad(h, 8, '0'))::bit(32)::int) || 'Gym')), null,
  'every hidden character in the later review is refused, at both ends of each range');
select is((select array_agg(h order by h) from unnest(array['AC', 'AE', '34E', '350', '115E', '1161', '17B3', '17B6',
    '180A', '1810', '2027', '202F', '3163', '3165', 'FDFF', 'FE10', 'FF9F', 'FFA1', 'FFFD', 'D7FF', 'F900', 'EFFFF',
    'FFFFE', '1D172', '1D17B', 'E01F0', '1F4AA']) h
  where not gym_private.clean_text('Iron' || chr(('x' || lpad(h, 8, '0'))::bit(32)::int) || 'Gym')), null,
  'and the characters next to those ranges still pass');
select is(gym_private.clean_text('Équinoxe Fitness – 24/7 (Nørre) 健身房 Спорт-зал'), true, 'ordinary text in several scripts passes');
select is(gym_private.clean_text('Heart ' || chr(10084) || chr(65039)), true, 'an emoji presentation selector after a non-ASCII character passes');
select is(gym_private.clean_text('Iron' || chr(65039) || 'Gym'), false, 'but not between ASCII letters');
select is(gym_private.clean_text(chr(65039) || 'Iron'), false, 'nor at the start');
select is(gym_private.clean_text('Iron ' || chr(65039)), false, 'nor after ASCII at the end');
select is(gym_private.clean_text(E'two\nlines' || chr(8232), true), false, 'the line separator is refused even where lines are allowed');
reset role;
select throws_ok(format($$ insert into public.gyms (visibility, name, maps_place_id) values ('public', %L, 'rules-hidden') $$,
  'Iron' || chr(173) || 'Gym'), '23514'::char(5), null, 'a gym name is checked by the same rule');
select throws_ok(format($$ insert into public.equipment_items (kind_id, brand) values ('barbell', %L) $$, 'Ac' || chr(983040) || 'me'),
  '23514'::char(5), null, 'and a brand');

-- A brief flag does not cut a workout's links -----------------------------------------------------------------------------
insert into public.gyms (id, visibility, name, maps_place_id)
  values ('fafafafa-0000-4000-8000-0000000010a0', 'public', 'Link Gym', 'rules-link');
insert into public.gym_equipment (id, gym_id, item_id, visibility, added_by)
  select v.id, 'fafafafa-0000-4000-8000-0000000010a0',
         (select id from public.equipment_items where kind_id = 'flat-bench' and brand is null), 'public',
         'fafafafa-0000-0000-0000-000000000002'
  from (values ('fafafafa-0000-4000-8000-0000000010b1'::uuid), ('fafafafa-0000-4000-8000-0000000010b2')) v(id);
create function pg_temp.push(ts text, with_links boolean) returns void language sql as $$
  select public.upsert_workout(jsonb_build_object('id', 'fafafafa-0000-4000-8000-000000001001', 'started_at', now(), 'name', 'L',
    'client_updated_at', ts, 'force', true) || case when with_links then jsonb_build_object('gym_id', 'fafafafa-0000-4000-8000-0000000010a0') else '{}'::jsonb end
    || jsonb_build_object('entries', jsonb_build_array(
      jsonb_build_object('id', 'fafafafa-0000-4000-8000-000000001011', 'exercise_id', '0025', 'position', 0)
        || case when with_links then jsonb_build_object('gym_equipment_id', 'fafafafa-0000-4000-8000-0000000010b1') else '{}'::jsonb end,
      jsonb_build_object('id', 'fafafafa-0000-4000-8000-000000001012', 'exercise_id', '0025', 'position', 1)
        || case when with_links then jsonb_build_object('gym_equipment_id', 'fafafafa-0000-4000-8000-0000000010b2') else '{}'::jsonb end)))
$$;
grant execute on function pg_temp.push(text, boolean) to authenticated;
select pg_temp.as_user(3);
select pg_temp.push('2026-11-01T10:00:00Z', true);
select is((select gym_id from public.workouts where id = 'fafafafa-0000-4000-8000-000000001001'),
  'fafafafa-0000-4000-8000-0000000010a0'::uuid, 'a workout is linked to a public gym');
reset role;
update public.gyms set status = 'flagged' where id = 'fafafafa-0000-4000-8000-0000000010a0';
select pg_temp.as_user(3);
select pg_temp.push('2026-11-01T11:00:00Z', true);
select is((select gym_id from public.workouts where id = 'fafafafa-0000-4000-8000-000000001001'),
  'fafafafa-0000-4000-8000-0000000010a0'::uuid, 'a re-push while the gym is flagged keeps the link');
select is((select count(*) from public.workout_entries where workout_id = 'fafafafa-0000-4000-8000-000000001001'
           and gym_equipment_id is not null)::int, 2, 'and the entries'' links');
select pg_temp.push('2026-11-01T12:00:00Z', false);
select is((select gym_id from public.workouts where id = 'fafafafa-0000-4000-8000-000000001001'),
  'fafafafa-0000-4000-8000-0000000010a0'::uuid, 'so does a push that sends none');
select is((select count(*) from public.workout_entries where workout_id = 'fafafafa-0000-4000-8000-000000001001'
           and gym_equipment_id is not null)::int, 2, 'and its entries');
reset role;
update public.gyms set status = 'active' where id = 'fafafafa-0000-4000-8000-0000000010a0';
select pg_temp.as_user(3);
select pg_temp.push('2026-11-01T13:00:00Z', true);
select is((select count(*) from public.workout_entries where workout_id = 'fafafafa-0000-4000-8000-000000001001'
           and gym_equipment_id is not null)::int, 2, 'the links are still there after the restore');
reset role;
update public.gym_equipment set status = 'flagged' where id = 'fafafafa-0000-4000-8000-0000000010b1';
select pg_temp.as_user(3);
select pg_temp.push('2026-11-01T14:00:00Z', true);
select is((select gym_equipment_id from public.workout_entries where id = 'fafafafa-0000-4000-8000-000000001011'),
  'fafafafa-0000-4000-8000-0000000010b1'::uuid, 'a flagged listing keeps an entry''s link too');
reset role;
update public.gym_equipment set status = 'removed' where id = 'fafafafa-0000-4000-8000-0000000010b1';
select pg_temp.as_user(3);
select pg_temp.push('2026-11-01T15:00:00Z', true);
select is((select gym_equipment_id from public.workout_entries where id = 'fafafafa-0000-4000-8000-000000001011'),
  null::uuid, 'but a removed one does not');
select is((select gym_equipment_id from public.workout_entries where id = 'fafafafa-0000-4000-8000-000000001012'),
  'fafafafa-0000-4000-8000-0000000010b2'::uuid, 'and the other entry is untouched');
select public.block_author('listing', 'fafafafa-0000-4000-8000-0000000010b2');
select pg_temp.push('2026-11-01T16:00:00Z', false);
select is((select gym_equipment_id from public.workout_entries where id = 'fafafafa-0000-4000-8000-000000001012'),
  null::uuid, 'a listing whose author the caller blocked is lost, so its link goes');
reset role;
update public.gyms set status = 'removed' where id = 'fafafafa-0000-4000-8000-0000000010a0';
select pg_temp.as_user(3);
select pg_temp.push('2026-11-01T17:00:00Z', true);
select is((select gym_id from public.workouts where id = 'fafafafa-0000-4000-8000-000000001001'), null::uuid,
  'a removed gym is not linked, even when the phone sends it');
select is((select count(*) from public.workout_entries where workout_id = 'fafafafa-0000-4000-8000-000000001001'
           and gym_equipment_id is not null)::int, 0, 'nor its listings');

select * from finish();
rollback;
