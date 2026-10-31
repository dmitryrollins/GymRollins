-- The only way to write public gym data (spec §5 "Sharing, confirming, reporting"). Every function needs a signed-in
-- user, refuses MCP clients and counts against a daily limit (the daily* values in DomainLimits.swift and
-- domain-limits.ts). Report, block and moderate are in 20261030000006.

-- The caller's id. Raises for anon callers and MCP clients.
create or replace function public.gym_require_user() returns uuid
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or public.is_mcp_client() then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  return auth.uid();
end $$;
revoke execute on function public.gym_require_user() from public, anon, authenticated;

-- Taken before counting, so concurrent calls by one user can't each see a count under the limit.
create function gym_private.lock_user(me uuid) returns void
language plpgsql set search_path = pg_catalog as $$
begin
  perform pg_advisory_xact_lock(hashtextextended('gym_daily:' || me::text, 0));
end $$;
revoke execute on function gym_private.lock_user(uuid) from public, anon, authenticated;

-- The app shows 'daily_limit' as "You've shared a lot today. Try again tomorrow."
create or replace function public.gym_check_daily(used bigint, allowed int) returns void
language plpgsql as $$
begin
  if used >= allowed then raise exception 'daily_limit' using errcode = 'P0001'; end if;
end $$;
revoke execute on function public.gym_check_daily(bigint, int) from public, anon, authenticated;

-- Returns the public gym for a Maps place, creating it on the first share. A removed gym gives its place back. The
-- first caller's text stands on the server, so the phone keeps showing the name Apple Maps gave it, not this one.
create or replace function public.find_or_create_gym(p_maps_place_id text, p_name text, p_address text,
                                                     p_latitude double precision, p_longitude double precision)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.gym_require_user();
  found_id uuid;
begin
  if p_maps_place_id is null or p_maps_place_id !~ '^[A-Za-z0-9._:+/=-]{1,200}$' then
    raise exception 'invalid place' using errcode = '22023';
  end if;
  select id into found_id from public.gyms
    where visibility = 'public' and status <> 'removed' and maps_place_id = p_maps_place_id;
  if found_id is not null then return found_id; end if;

  perform gym_private.lock_user(me);
  perform public.gym_check_daily(
    (select count(*) from public.gyms
     where visibility = 'public' and created_by = me and created_at > now() - interval '1 day'), 10);

  insert into public.gyms (visibility, name, address, latitude, longitude, maps_place_id, created_by)
  values ('public', btrim(p_name), nullif(btrim(p_address), ''), p_latitude, p_longitude, p_maps_place_id, me)
  on conflict (maps_place_id) where visibility = 'public' and status <> 'removed' do nothing
  returning id into found_id;
  -- Someone else created it in the meantime.
  return coalesce(found_id, (select id from public.gyms
                             where visibility = 'public' and status <> 'removed' and maps_place_id = p_maps_place_id));
end $$;

-- The catalogue row for a kind, brand and model, matched ignoring case, created on first use. Only share_listing calls
-- this, so everything in the catalogue was shared on purpose and is limited by the daily shares.
create or replace function public.ensure_equipment_item(p_kind_id text, p_brand text, p_model text) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.gym_require_user();
  brand_clean text := nullif(btrim(p_brand), '');
  model_clean text := nullif(btrim(p_model), '');
  item uuid;
begin
  if not exists (select 1 from public.equipment_kinds where id = p_kind_id) then
    raise exception 'unknown kind' using errcode = '22023';
  end if;
  select id into item from public.equipment_items
    where kind_id = p_kind_id and lower(coalesce(brand, '')) = lower(coalesce(brand_clean, ''))
      and lower(coalesce(model, '')) = lower(coalesce(model_clean, ''));
  if item is not null then return item; end if;
  insert into public.equipment_items (kind_id, brand, model, created_by)
  values (p_kind_id, brand_clean, model_clean, me)
  on conflict (kind_id, lower(coalesce(brand, '')), lower(coalesce(model, ''))) do nothing
  returning id into item;
  return coalesce(item, (select id from public.equipment_items
    where kind_id = p_kind_id and lower(coalesce(brand, '')) = lower(coalesce(brand_clean, ''))
      and lower(coalesce(model, '')) = lower(coalesce(model_clean, ''))));
end $$;
revoke execute on function public.ensure_equipment_item(text, text, text) from public, anon, authenticated;

-- Creates a public listing, or returns the gym's active listings of that kind when there are some and p_force_new is
-- false. p_listing_id is the phone's id, so a retry after a lost response finds the listing instead of adding another.
-- The photo must already be uploaded by the caller and unused, so a listing can't borrow someone else's image.
create or replace function public.share_listing(p_listing_id uuid, p_gym_id uuid, p_kind_id text, p_brand text,
                                                p_model text, p_loads jsonb, p_quantity int, p_notes text,
                                                p_photo_path text, p_force_new boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.gym_require_user();
  gym public.gyms;
  existing public.gym_equipment;
  duplicates jsonb;
  item uuid;
begin
  select * into existing from public.gym_equipment where id = p_listing_id;
  if found then
    if existing.added_by is distinct from me or existing.visibility <> 'public' then
      raise exception 'not allowed' using errcode = '42501';
    end if;
    return jsonb_build_object('status', 'created', 'listing_id', existing.id);
  end if;

  select * into gym from public.gyms where id = p_gym_id;
  if not found or gym.visibility <> 'public' or gym.status <> 'active' then
    raise exception 'gym_not_shareable' using errcode = 'P0001';
  end if;
  if p_photo_path is not null then
    if not exists (select 1 from storage.objects
                   where bucket_id = 'gym-photos' and name = p_photo_path and owner_id = me::text) then
      raise exception 'photo_missing' using errcode = 'P0001';
    end if;
    if exists (select 1 from public.gym_equipment where photo_path = p_photo_path) then
      raise exception 'photo_in_use' using errcode = 'P0001';
    end if;
  end if;
  if not gym_private.valid_loads(p_loads) then
    raise exception 'invalid loads' using errcode = '22023';
  end if;

  if not coalesce(p_force_new, false) then
    select jsonb_agg(jsonb_build_object(
        'id', e.id, 'kind_id', i.kind_id, 'brand', i.brand, 'model', i.model, 'photo_path', e.photo_path,
        'loads', e.loads, 'quantity', e.quantity, 'confirm_count', e.confirm_count) order by e.confirm_count desc, e.id)
      into duplicates
      from public.gym_equipment e join public.equipment_items i on i.id = e.item_id
      where e.gym_id = p_gym_id and e.visibility = 'public' and e.status = 'active' and i.kind_id = p_kind_id
        and i.status = 'active' and not gym_private.is_blocked_author(e.added_by)
        and not gym_private.is_blocked_author(i.created_by);
    if duplicates is not null then
      return jsonb_build_object('status', 'duplicates', 'listings', duplicates);
    end if;
  end if;

  perform gym_private.lock_user(me);
  perform public.gym_check_daily(
    (select count(*) from public.gym_equipment
     where visibility = 'public' and added_by = me and created_at > now() - interval '1 day'), 30);
  -- A few accounts adding 30 a day would otherwise fill one gym, and every viewer downloads each photo. The gym's own
  -- lock makes the count exact across users; the order (user, then gym) is the same everywhere. A retry of a listing
  -- already there returned at the top, so it still succeeds at the cap.
  perform pg_advisory_xact_lock(hashtextextended('gym_listings:' || p_gym_id::text, 0));
  if (select count(*) from public.gym_equipment
      where gym_id = p_gym_id and visibility = 'public' and status = 'active' and deleted_at is null) >= 300 then
    raise exception 'gym_full' using errcode = 'P0001';
  end if;

  item := public.ensure_equipment_item(p_kind_id, p_brand, p_model);
  insert into public.gym_equipment (id, gym_id, item_id, visibility, photo_path, loads, quantity, notes, added_by)
  values (p_listing_id, p_gym_id, item, 'public', p_photo_path, p_loads, coalesce(p_quantity, 1),
          nullif(btrim(p_notes), ''), me);
  return jsonb_build_object('status', 'created', 'listing_id', p_listing_id);
end $$;

-- "Yes, that's it (+1 confirm)". Idempotent. Your own listing already counts for you, so it adds nothing there.
-- Returns the listing's confirm count.
create or replace function public.confirm_listing(p_listing_id uuid) returns int
language plpgsql security definer set search_path = public as $$
declare
  me uuid := public.gym_require_user();
  listing public.gym_equipment;
begin
  select * into listing from public.gym_equipment where id = p_listing_id;
  if not found or listing.visibility <> 'public' or listing.status <> 'active'
     or not gym_private.listing_parents_active(listing.gym_id, listing.item_id)
     or gym_private.is_blocked_author(listing.added_by) then
    raise exception 'unknown listing' using errcode = 'P0001';
  end if;
  if listing.added_by = me
     or exists (select 1 from public.equipment_confirmations where listing_id = p_listing_id and user_id = me) then
    return listing.confirm_count;
  end if;
  perform gym_private.lock_user(me);
  perform public.gym_check_daily(
    (select count(*) from public.equipment_confirmations
     where user_id = me and created_at > now() - interval '1 day'), 100);
  insert into public.equipment_confirmations (listing_id, user_id) values (p_listing_id, me)
  on conflict do nothing;
  return (select confirm_count from public.gym_equipment where id = p_listing_id);
end $$;

revoke execute on function public.find_or_create_gym(text, text, text, double precision, double precision),
  public.share_listing(uuid, uuid, text, text, text, jsonb, int, text, text, boolean),
  public.confirm_listing(uuid) from public, anon;
grant execute on function public.find_or_create_gym(text, text, text, double precision, double precision),
  public.share_listing(uuid, uuid, text, text, text, jsonb, int, text, text, boolean),
  public.confirm_listing(uuid) to authenticated;
