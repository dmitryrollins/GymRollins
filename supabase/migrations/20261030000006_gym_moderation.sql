-- Report, block and moderate (spec §5 "Sharing, confirming, reporting"). Clients never see user ids, so a block names a
-- gym or listing and the server resolves its author. Items aren't a target: everything visible about one comes through
-- a listing, and removing that listing takes its text out of the public catalogue.

-- The author and status of a public target. Raises when there's no such target.
create function gym_private.public_target(p_target_type text, p_target_id uuid, out author uuid, out status text)
language plpgsql stable security definer set search_path = public as $$
begin
  if p_target_type = 'gym' then
    select g.created_by, g.status into author, status from public.gyms g
      where g.id = p_target_id and g.visibility = 'public';
  elsif p_target_type = 'listing' then
    select e.added_by, e.status into author, status from public.gym_equipment e
      where e.id = p_target_id and e.visibility = 'public';
  end if;
  if status is null then raise exception 'unknown target' using errcode = 'P0001'; end if;
end $$;
revoke execute on function gym_private.public_target(text, uuid) from public, anon, authenticated;

create function gym_private.set_status(p_target_type text, p_target_id uuid, p_status text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_target_type = 'gym' then
    update public.gyms set status = p_status where id = p_target_id;
  else
    update public.gym_equipment set status = p_status where id = p_target_id;
  end if;
end $$;
revoke execute on function gym_private.set_status(text, uuid, text) from public, anon, authenticated;

-- One report per user per target. Three unresolved reports from accounts that still exist hide the target until an
-- admin decides. An author's report of their own content doesn't count towards the three, and neither does one whose
-- author has since deleted their account: otherwise a loop of sign up, report, delete reaches three alone, and the
-- daily limit never applies because it counts per reporter. Such a report stays for the queue.
create or replace function public.report_content(p_target_type text, p_target_id uuid, p_reason text,
                                                 p_note text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.gym_require_user();
  target record;
  reporters bigint;
begin
  select * into target from gym_private.public_target(p_target_type, p_target_id);
  if target.status = 'removed' then raise exception 'unknown target' using errcode = 'P0001'; end if;
  if target.author = me then return jsonb_build_object('status', 'own'); end if;
  if exists (select 1 from public.reports
             where target_type = p_target_type and target_id = p_target_id and reporter_id = me) then
    return jsonb_build_object('status', 'already');
  end if;
  perform gym_private.lock_user(me);
  perform public.gym_check_daily(
    (select count(*) from public.reports where reporter_id = me and created_at > now() - interval '1 day'), 20);
  -- So three reports arriving together still reach the count.
  perform pg_advisory_xact_lock(hashtextextended('gym_report:' || p_target_type || p_target_id::text, 0));
  insert into public.reports (target_type, target_id, reporter_id, reason, note)
  values (p_target_type, p_target_id, me, p_reason, nullif(btrim(p_note), ''))
  on conflict do nothing;
  select count(*) into reporters from public.reports
    where target_type = p_target_type and target_id = p_target_id and resolved_at is null and reporter_id is not null;
  if reporters >= 3 and target.status = 'active' then
    perform gym_private.set_status(p_target_type, p_target_id, 'flagged');
  end if;
  return jsonb_build_object('status', 'reported');
end $$;

create or replace function public.block_author(p_target_type text, p_target_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.gym_require_user();
  blocked uuid := (select author from gym_private.public_target(p_target_type, p_target_id));
begin
  if blocked is not null and blocked <> me then
    insert into public.user_blocks (blocker_id, blocked_id) values (me, blocked) on conflict do nothing;
  end if;
end $$;

-- Returns how many blocks were cleared.
create or replace function public.unblock_all() returns int
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.gym_require_user();
  cleared int;
begin
  delete from public.user_blocks where blocker_id = me;
  get diagnostics cleared = row_count;
  return cleared;
end $$;

-- Admins only. Removing a listing returns its photo for the app to delete through Storage (SQL can't). Removing a gym
-- keeps its listings' photos: the policies hide them, and they aren't what was reported.
create or replace function public.moderate_content(p_target_type text, p_target_id uuid, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  next_status text;
  photo text;
begin
  perform public.gym_require_user();
  if not public.is_app_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  next_status := case p_action when 'restore' then 'active' when 'remove' then 'removed' end;
  if next_status is null then raise exception 'invalid action' using errcode = '22023'; end if;
  perform gym_private.public_target(p_target_type, p_target_id);
  if p_target_type = 'listing' and p_action = 'remove' then
    select photo_path into photo from public.gym_equipment where id = p_target_id;
    update public.gym_equipment set photo_path = null where id = p_target_id;
  end if;
  begin
    perform gym_private.set_status(p_target_type, p_target_id, next_status);
  exception when unique_violation then
    -- Someone created a new gym for this place after the removal.
    raise exception 'place_taken' using errcode = 'P0001';
  end;
  update public.reports set resolved_at = now()
    where target_type = p_target_type and target_id = p_target_id and resolved_at is null;
  return jsonb_build_object('status', next_status, 'photo_path', photo);
end $$;

-- What an admin decides on: everything flagged, most reported first, even when its reports are gone. Never says who.
create or replace function public.moderation_queue()
returns table (target_type text, target_id uuid, title text, photo_path text, report_count bigint, reasons jsonb,
               notes jsonb)
language plpgsql stable security definer set search_path = public as $$
begin
  perform public.gym_require_user();
  if not public.is_app_admin() then raise exception 'not allowed' using errcode = '42501'; end if;
  return query
  select t.target_type, t.target_id, t.title, t.photo_path,
         (select count(*) from public.reports x
          where x.target_type = t.target_type and x.target_id = t.target_id and x.resolved_at is null) as report_count,
         coalesce((select jsonb_object_agg(c.reason, c.n) from (
            select x.reason, count(*) as n from public.reports x
            where x.target_type = t.target_type and x.target_id = t.target_id and x.resolved_at is null
            group by x.reason) c), '{}'::jsonb),
         coalesce((select jsonb_agg(x.note order by x.created_at) from public.reports x
                   where x.target_type = t.target_type and x.target_id = t.target_id and x.resolved_at is null
                     and x.note is not null), '[]'::jsonb)
  from (
    select 'gym'::text as target_type, g.id as target_id, g.name as title, null::text as photo_path
      from public.gyms g where g.visibility = 'public' and g.status = 'flagged'
    union all
    select 'listing'::text, e.id, coalesce(nullif(concat_ws(' ', i.brand, i.model), ''), k.name), e.photo_path
      from public.gym_equipment e
      join public.equipment_items i on i.id = e.item_id
      join public.equipment_kinds k on k.id = i.kind_id
      where e.visibility = 'public' and e.status = 'flagged'
  ) t
  order by report_count desc, t.target_id;
end $$;

-- The caller's photos in both buckets, by owner and not by listing: an upload that was never linked is still theirs,
-- and `delete_my_account` refuses while any remain. The app removes them through Storage first.
create or replace function public.my_gym_photos() returns table (bucket_id text, name text)
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := public.gym_require_user();
begin
  return query select o.bucket_id, o.name from storage.objects o
    where o.owner_id = me::text and o.bucket_id in ('gym-photos', 'gym-photos-private');
end $$;

revoke execute on function public.report_content(text, uuid, text, text), public.block_author(text, uuid),
  public.unblock_all(), public.moderate_content(text, uuid, text), public.moderation_queue(),
  public.my_gym_photos() from public, anon;
grant execute on function public.report_content(text, uuid, text, text), public.block_author(text, uuid),
  public.unblock_all(), public.moderate_content(text, uuid, text), public.moderation_queue(),
  public.my_gym_photos() to authenticated;

-- Account deletion. The app has already removed the user's photos through Storage, and this refuses (`photos_remain`)
-- while any are left, so a client that skipped that step can't leave objects behind that nobody can remove. Shared listings and gyms stay without
-- their author because they describe the gym, but the author's own words go: a listing's notes and photo, the brand and
-- model of an item only they used (their listings fall back to the generic item of the kind, which is what the item
-- would be with the words taken out), and the note on every report they filed. An item others list too stays: it is
-- the catalogue's by then.
create or replace function public.delete_my_account() returns void
language plpgsql security definer set search_path = public, auth as $$
declare
  me uuid := auth.uid();
begin
  if me is null or public.is_mcp_client() then raise exception 'not allowed' using errcode = '42501'; end if;
  if exists (select 1 from storage.objects o
             where o.owner_id = me::text and o.bucket_id in ('gym-photos', 'gym-photos-private')) then
    raise exception 'photos_remain';
  end if;
  update public.gym_equipment set photo_path = null, notes = null where added_by = me and visibility = 'public';
  update public.gym_equipment e
    set item_id = (select g.id from public.equipment_items g
                   where g.kind_id = i.kind_id and g.brand is null and g.model is null)
    from public.equipment_items i
    where e.item_id = i.id and i.created_by = me and (i.brand is not null or i.model is not null)
      and e.added_by = me and e.visibility = 'public'
      and not exists (select 1 from public.gym_equipment o where o.item_id = i.id and o.added_by is distinct from me);
  delete from public.equipment_items i
    where i.created_by = me and not exists (select 1 from public.gym_equipment e where e.item_id = i.id);
  update public.reports set note = null where reporter_id = me;
  delete from auth.users where id = me;
end $$;
revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;

-- Trigger functions need no privileges to fire. This one predates the gym work and was left executable by default.
revoke execute on function public.health_tombstone_guard() from public, anon, authenticated;
