-- Gyms and their equipment (docs/specs/2026-10-30-gym-equipment-design.md §4, §5, §8).
--
-- Public rows are user-generated content anyone can read: gyms, the shared catalogue of items and per-gym listings.
-- They are only written through the security definer functions in 20261030000002_gym_functions.sql, which validate
-- input, enforce daily limits and refuse MCP clients. Private rows (a synced home gym) follow the usual sync rules: the
-- owner upserts them directly, last write wins by device edit time, MCP clients may only read them, gated by the
-- owner's mcp_read_gyms flag.
--
-- Author columns (owner_id, added_by, created_by) never leave the server: select on them is revoked, and clients read
-- through the *_public views, which offer is_mine instead. Other users' ids are never exposed.

-- Curated data, seeded by 20261030000004_equipment_seed.sql and read-only for everyone ------------------------------
create table public.equipment_kinds (
  id text primary key check (id ~ '^[a-z0-9-]{1,40}$'),
  name text not null check (char_length(name) between 1 and 60),
  category text not null check (category in ('machine','cable','free-weight','bench','rack','cardio','accessory')),
  load_type text not null check (load_type in ('stack','plate-loaded','fixed-set','bodyweight','none')),
  created_at timestamptz not null default now()
);
create table public.exercise_requirements (
  exercise_id text primary key references public.exercises on delete cascade,
  -- All groups are needed, any one kind per group; [] means no equipment.
  groups jsonb not null check (jsonb_typeof(groups) = 'array'),
  created_at timestamptz not null default now()
);

alter table public.equipment_kinds enable row level security;
alter table public.exercise_requirements enable row level security;
create policy equipment_kinds_read on public.equipment_kinds for select to anon, authenticated using (true);
create policy exercise_requirements_read on public.exercise_requirements for select to anon, authenticated using (true);
revoke all on public.equipment_kinds, public.exercise_requirements from public, anon, authenticated;
grant select on public.equipment_kinds, public.exercise_requirements to anon, authenticated;

-- Helpers for policies and constraints that no client should call. PostgREST only exposes public, so these can't be
-- reached as RPCs, which also stops anyone asking "did I block this id?" about a guessed id.
create schema gym_private;
revoke all on schema gym_private from public;
grant usage on schema gym_private to anon, authenticated;

-- No control characters, invisible characters or text-direction overrides. Line breaks only where text has lines. Gym
-- names reach Claude, so anything the eye can't see but a model can read is refused: the tag characters (U+E0000
-- block, which spell ASCII invisibly), the Arabic and Mongolian format characters, the interlinear annotation marks.
-- U+200D and U+200C (the zero width joiners) are also emoji and script characters (a rainbow flag, Indic conjuncts,
-- Persian words, so a gym's name from Apple Maps can hold them). They stay, but only next to non-ASCII text: between
-- ASCII letters they can only hide something.
create function gym_private.clean_text(t text, lines boolean default false) returns boolean
language sql immutable set search_path = pg_catalog as $$
  select t !~ (case when lines then '[\u0001-\u0009\u000B\u000C\u000E-\u001F]' else '[\u0001-\u001F]' end)
     and t !~ '[\u007F-\u009F\u061C\u180E\u200B\u200E\u200F\u202A-\u202E\u2060-\u206F\uFEFF\uFFF9-\uFFFB\U000E0000-\U000E007F]'
     and t !~ '(^|[\u0001-\u007F])[\u200C\u200D]|[\u200C\u200D]([\u0001-\u007F]|$)'
$$;
revoke execute on function gym_private.clean_text(text, boolean) from public;
grant execute on function gym_private.clean_text(text, boolean) to authenticated;

-- Moderation tables, used by the policies below ------------------------------------------------------------------
create table public.app_admins (
  user_id uuid primary key references auth.users on delete cascade,
  created_at timestamptz not null default now()
);
create table public.user_blocks (
  blocker_id uuid not null references auth.users on delete cascade,
  blocked_id uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);
create table public.reports (
  id uuid primary key default gen_random_uuid(),
  target_type text not null check (target_type in ('gym','item','listing')),
  target_id uuid not null,
  -- A report outlives its reporter, so deleting three throwaway accounts can't clear a flag's history.
  reporter_id uuid references auth.users on delete set null,
  reason text not null check (reason in ('wrong-info','not-here-anymore','duplicate','inappropriate-photo',
                                         'person-in-photo','spam','other')),
  note text check (note is null or (char_length(note) <= 280 and gym_private.clean_text(note, true))),
  resolved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (target_type, target_id, reporter_id)
);
-- No policies: nobody reads or writes these directly. The functions in 20261030000002 and plan 22 do.
alter table public.app_admins enable row level security;
alter table public.user_blocks enable row level security;
alter table public.reports enable row level security;
revoke all on public.app_admins, public.user_blocks, public.reports from public, anon, authenticated;

-- Claude acts for its user but is never an admin, even on an admin's account.
create or replace function public.is_app_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select not public.is_mcp_client() and exists (select 1 from public.app_admins where user_id = auth.uid())
$$;
revoke execute on function public.is_app_admin() from public;
grant execute on function public.is_app_admin() to anon, authenticated;
-- Whether the caller blocked this author. Security definer so a policy can ask without exposing user_blocks.
create function gym_private.is_blocked_author(author uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select author is not null
    and exists (select 1 from public.user_blocks where blocker_id = auth.uid() and blocked_id = author)
$$;
revoke execute on function gym_private.is_blocked_author(uuid) from public;
grant execute on function gym_private.is_blocked_author(uuid) to anon, authenticated;

-- Claude's access to gym data, switched off like the other flags ----------------------------------------------------
alter table public.profiles add column mcp_read_gyms boolean not null default true;
create or replace function public.mcp_flag(flag text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select case flag
      when 'workouts' then mcp_read_workouts when 'body' then mcp_read_body when 'propose' then mcp_propose
      when 'plan' then mcp_read_plan when 'gyms' then mcp_read_gyms end
    from public.profiles where user_id = auth.uid()), true)
$$;
revoke execute on function public.mcp_flag(text) from public, anon;
grant execute on function public.mcp_flag(text) to authenticated;

-- Gyms ---------------------------------------------------------------------------------------------------------------
create table public.gyms (
  id uuid primary key default gen_random_uuid(),
  visibility text not null check (visibility in ('public','private')),
  owner_id uuid references auth.users on delete cascade,
  name text not null check (char_length(name) between 1 and 120 and gym_private.clean_text(name)),
  address text check (address is null or (char_length(address) <= 300 and gym_private.clean_text(address))),
  latitude double precision check (latitude is null or latitude between -90 and 90),
  longitude double precision check (longitude is null or longitude between -180 and 180),
  maps_place_id text check (maps_place_id is null or maps_place_id ~ '^[A-Za-z0-9._:+/=-]{1,200}$'),
  created_by uuid references auth.users on delete set null,
  status text not null default 'active' check (status in ('active','flagged','removed')),
  client_updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint gyms_private_has_owner check ((visibility = 'private') = (owner_id is not null)),
  constraint gyms_public_is_a_place check ((visibility = 'public') = (maps_place_id is not null))
);
-- A removed gym gives its place back, so one bad gym can't block a real place forever.
create unique index gyms_maps_place on public.gyms (maps_place_id) where visibility = 'public' and status <> 'removed';
create index gyms_owner_updated on public.gyms (owner_id, updated_at, id) where owner_id is not null;
create index gyms_created_by on public.gyms (created_by, created_at) where created_by is not null;

-- Owner and author come from the session, never from the client (their columns aren't writable anyway). With no
-- session (the functions, seeds and tests running as postgres) the given values stand.
create or replace function public.gyms_stamp_author() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.visibility = 'private' then
    new.owner_id := auth.uid();
    new.created_by := auth.uid();
  end if;
  return new;
end $$;
revoke execute on function public.gyms_stamp_author() from public, anon, authenticated;
create trigger a_author before insert on public.gyms
  for each row execute function public.gyms_stamp_author();

-- At most 100 live private gyms per user (privateGymsMax). Checked when a gym becomes live: a new row, or a tombstone
-- cleared, since a row inserted with deleted_at set and cleared later would otherwise slip past. Tombstones don't count,
-- so deleting frees a slot. Under the user's lock, so parallel requests can't each see a count under the limit. It
-- fires after a_lww, so an update that last-write-wins skips never reaches it. The row itself is left out of the count:
-- an upsert of a live gym adds nothing.
create function gym_private.check_private_gym_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.visibility = 'private' and new.deleted_at is null
     and (tg_op = 'INSERT' or old.deleted_at is not null) then
    perform gym_private.lock_user(new.owner_id);
    if (select count(*) from public.gyms where owner_id = new.owner_id and deleted_at is null and id <> new.id) >= 100 then
      raise exception 'too_many_gyms' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
revoke execute on function gym_private.check_private_gym_cap() from public, anon, authenticated;
create trigger a_lww before update on public.gyms
  for each row execute function public.lww_guard();
create trigger b_updated_at before insert or update on public.gyms
  for each row execute function public.set_updated_at();
create trigger c_cap before insert or update of deleted_at on public.gyms
  for each row execute function gym_private.check_private_gym_cap();

alter table public.gyms enable row level security;
create policy gyms_read_anon on public.gyms for select to anon
  using (visibility = 'public' and status = 'active');
create policy gyms_read on public.gyms for select to authenticated
  using (
    (visibility = 'public' and (status = 'active' or public.is_app_admin()
                                or (status = 'flagged' and created_by = auth.uid() and not public.is_mcp_client())))
    or (visibility = 'private' and owner_id = auth.uid() and (not public.is_mcp_client() or public.mcp_flag('gyms')))
  );
create policy gyms_write_private on public.gyms for all to authenticated
  using (visibility = 'private' and owner_id = auth.uid() and not public.is_mcp_client())
  with check (visibility = 'private' and owner_id = auth.uid() and not public.is_mcp_client());

revoke all on public.gyms from public, anon, authenticated;
grant select (id, visibility, name, address, latitude, longitude, maps_place_id, status, client_updated_at, deleted_at,
              created_at, updated_at) on public.gyms to anon, authenticated;
grant insert (id, visibility, name, address, latitude, longitude, client_updated_at, deleted_at),
      -- id and visibility look odd here, but a PostgREST upsert sets every column it sends. The policy and the trigger
      -- are what stop a private gym becoming public.
      update (id, visibility, name, address, latitude, longitude, client_updated_at, deleted_at),
      delete on public.gyms to authenticated;

-- The shared catalogue of items ----------------------------------------------------------------------------------------
create table public.equipment_items (
  id uuid primary key default gen_random_uuid(),
  kind_id text not null references public.equipment_kinds,
  brand text check (brand is null or (char_length(brand) between 1 and 60 and gym_private.clean_text(brand))),
  model text check (model is null or (char_length(model) between 1 and 80 and gym_private.clean_text(model))),
  created_by uuid references auth.users on delete set null,
  status text not null default 'active' check (status in ('active','flagged','removed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index equipment_items_identity
  on public.equipment_items (kind_id, lower(coalesce(brand, '')), lower(coalesce(model, '')));
create index equipment_items_created_by on public.equipment_items (created_by) where created_by is not null;
create trigger b_updated_at before insert or update on public.equipment_items
  for each row execute function public.set_updated_at();

-- Listings -----------------------------------------------------------------------------------------------------------
-- Shape of gym_equipment.loads; immutable so it can back a check constraint. The numeric ranges match DomainLimits.
-- Exact keys and a short number form, because every client decodes these rows: a number like 1e-400 passes a range
-- check as 0.000... but breaks JSONDecoder, and one such row would break a whole gym.
create function gym_private.valid_kg(v jsonb, top numeric) returns boolean
language sql immutable set search_path = pg_catalog as $$
  select jsonb_typeof(v) = 'number' and length(v::text) <= 24 and v::text::numeric between 0.25 and top
$$;
create function gym_private.valid_loads(l jsonb) returns boolean
language plpgsql immutable set search_path = pg_catalog as $$
declare
  w jsonb;
  keys text[];
begin
  if l is null or jsonb_typeof(l) <> 'object' or length(l::text) > 2048 then return false; end if;
  select array_agg(k order by k collate "C") into keys from jsonb_object_keys(l) k;
  case l ->> 'type'
    when 'none', 'plates' then return keys = array['type'];
    when 'stack' then
      if not (keys = array['maxKg', 'type'] or keys = array['maxKg', 'stepKg', 'type']) then return false; end if;
      if not gym_private.valid_kg(l -> 'maxKg', 1000) then return false; end if;
      if not l ? 'stepKg' or jsonb_typeof(l -> 'stepKg') = 'null' then return true; end if;
      return gym_private.valid_kg(l -> 'stepKg', 50) and (l ->> 'stepKg')::numeric <= (l ->> 'maxKg')::numeric;
    when 'fixed' then
      if keys <> array['kg', 'type'] or jsonb_typeof(l -> 'kg') <> 'array' then return false; end if;
      if jsonb_array_length(l -> 'kg') not between 1 and 60 then return false; end if;
      for w in select * from jsonb_array_elements(l -> 'kg') loop
        if not gym_private.valid_kg(w, 500) then return false; end if;
      end loop;
      return true;
    else
      return false;
  end case;
end $$;
revoke execute on function gym_private.valid_kg(jsonb, numeric), gym_private.valid_loads(jsonb) from public;
grant execute on function gym_private.valid_kg(jsonb, numeric), gym_private.valid_loads(jsonb) to authenticated;

create table public.gym_equipment (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms on delete cascade,
  item_id uuid not null references public.equipment_items,
  visibility text not null check (visibility in ('public','private')),
  owner_id uuid references auth.users on delete cascade,
  -- A bare random name: a folder per user would give every reader the uploader's id.
  photo_path text check (photo_path is null
                         or photo_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'),
  loads jsonb not null default '{"type":"none"}' check (gym_private.valid_loads(loads)),
  quantity int not null default 1 check (quantity between 1 and 50),
  notes text check (notes is null or (char_length(notes) <= 280 and gym_private.clean_text(notes, true))),
  -- A private listing points at its kind's generic item and keeps any brand and model here, so private text never
  -- enters the shared catalogue.
  private_brand text check (private_brand is null
                            or (char_length(private_brand) between 1 and 60 and gym_private.clean_text(private_brand))),
  private_model text check (private_model is null
                            or (char_length(private_model) between 1 and 80 and gym_private.clean_text(private_model))),
  added_by uuid references auth.users on delete set null,
  status text not null default 'active' check (status in ('active','flagged','removed')),
  confirm_count int not null default 0,
  client_updated_at timestamptz not null default now(),
  deleted_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint gym_equipment_private_has_owner check ((visibility = 'private') = (owner_id is not null)),
  constraint gym_equipment_private_text check (visibility = 'private' or (private_brand is null and private_model is null))
);
create index gym_equipment_gym on public.gym_equipment (gym_id, status);
-- One photo backs one listing, so a name can't be shared by two and the first listing's picture can't be kept alive
-- (or lost) through the second.
create unique index gym_equipment_photo on public.gym_equipment (photo_path) where photo_path is not null;
create index gym_equipment_item on public.gym_equipment (item_id);
create index gym_equipment_owner_updated on public.gym_equipment (owner_id, updated_at, id) where owner_id is not null;
create index gym_equipment_added_by on public.gym_equipment (added_by, created_at) where added_by is not null;

-- Owner and author from the session; a listing can't go on someone else's private gym; a public listing must be on a
-- public gym; a private one on the caller's own gym, with a generic item and the caller's own photo. Security definer
-- because it must see the gym even when the caller can't, to refuse someone else's private gym. That refusal reads the
-- same as "no such gym", whichever kind of listing was sent, so ids can't be probed. (share_listing's 'not allowed' on
-- a private listing's id isn't a probe: listing ids are random and the caller already needs to know one.)
create or replace function public.gym_equipment_check() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  gym public.gyms;
begin
  select * into gym from public.gyms where id = new.gym_id;
  if gym.id is null or (me is not null and gym.visibility = 'private' and gym.owner_id <> me) then
    raise exception 'unknown gym' using errcode = '23503';
  end if;
  if new.visibility = 'public' and gym.visibility <> 'public' then
    raise exception 'a public listing must be on a public gym' using errcode = '23514';
  end if;
  if new.visibility = 'private' and me is not null then
    new.owner_id := me;
    new.added_by := me;
    if not exists (select 1 from public.equipment_items where id = new.item_id and brand is null and model is null) then
      raise exception 'a private listing uses a generic item' using errcode = '23514';
    end if;
    if new.photo_path is not null and (tg_op = 'INSERT' or new.photo_path is distinct from old.photo_path)
       and not exists (select 1 from storage.objects
                       where bucket_id = 'gym-photos-private' and name = new.photo_path and owner_id = me::text) then
      raise exception 'photo_missing' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
revoke execute on function public.gym_equipment_check() from public, anon, authenticated;
create trigger a_check before insert or update on public.gym_equipment
  for each row execute function public.gym_equipment_check();
create trigger a_lww before update on public.gym_equipment
  for each row execute function public.lww_guard();
create trigger b_updated_at before insert or update on public.gym_equipment
  for each row execute function public.set_updated_at();

-- At most 1000 live private listings per user (privateListingsMax), checked like the gym cap above: when a listing
-- becomes live, under the user's lock, and tombstones don't count.
create function gym_private.check_private_listing_cap() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and new.visibility = 'private' and new.deleted_at is null
     and (tg_op = 'INSERT' or old.deleted_at is not null) then
    perform gym_private.lock_user(new.owner_id);
    if (select count(*) from public.gym_equipment
        where owner_id = new.owner_id and deleted_at is null and id <> new.id) >= 1000 then
      raise exception 'too_many_listings' using errcode = 'P0001';
    end if;
  end if;
  return new;
end $$;
revoke execute on function gym_private.check_private_listing_cap() from public, anon, authenticated;
create trigger c_cap before insert or update of deleted_at on public.gym_equipment
  for each row execute function gym_private.check_private_listing_cap();

-- A public listing is only readable while its gym and item are active. In the policy, not just the views, because the
-- table itself is readable too. Security definer so these policies don't recurse into each other.
create function gym_private.listing_parents_active(p_gym uuid, p_item uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.gyms where id = p_gym and status = 'active')
     and exists (select 1 from public.equipment_items where id = p_item and status = 'active')
$$;
revoke execute on function gym_private.listing_parents_active(uuid, uuid) from public;
grant execute on function gym_private.listing_parents_active(uuid, uuid) to anon, authenticated;

alter table public.gym_equipment enable row level security;
create policy gym_equipment_read_anon on public.gym_equipment for select to anon
  using (visibility = 'public' and status = 'active' and gym_private.listing_parents_active(gym_id, item_id));
create policy gym_equipment_read on public.gym_equipment for select to authenticated
  using (
    (visibility = 'public' and not gym_private.is_blocked_author(added_by)
     and (public.is_app_admin()
          or (status = 'active' and gym_private.listing_parents_active(gym_id, item_id))
          or (status = 'flagged' and added_by = auth.uid() and not public.is_mcp_client())))
    or (visibility = 'private' and owner_id = auth.uid() and (not public.is_mcp_client() or public.mcp_flag('gyms')))
  );
create policy gym_equipment_write_private on public.gym_equipment for all to authenticated
  using (visibility = 'private' and owner_id = auth.uid() and not public.is_mcp_client())
  with check (visibility = 'private' and owner_id = auth.uid() and not public.is_mcp_client());

revoke all on public.gym_equipment from public, anon, authenticated;
grant select (id, gym_id, item_id, visibility, photo_path, loads, quantity, notes, status, confirm_count,
              client_updated_at, deleted_at, created_at, updated_at) on public.gym_equipment to anon, authenticated;
grant select (private_brand, private_model) on public.gym_equipment to authenticated;
grant insert (id, gym_id, item_id, visibility, photo_path, loads, quantity, notes, private_brand, private_model,
              client_updated_at, deleted_at),
      -- A PostgREST upsert sets every column it sends; the policy and the check trigger guard the values.
      update (id, gym_id, item_id, visibility, photo_path, loads, quantity, notes, private_brand, private_model,
              client_updated_at, deleted_at),
      delete on public.gym_equipment to authenticated;

-- An item is public once a public active listing uses it, or when it's a kind's generic item. Items only come from
-- sharing, so their text was always meant to be public.
alter table public.equipment_items enable row level security;
create policy equipment_items_read_anon on public.equipment_items for select to anon
  using (status = 'active' and ((brand is null and model is null) or exists (
    select 1 from public.gym_equipment e
    where e.item_id = equipment_items.id and e.visibility = 'public' and e.status = 'active')));
create policy equipment_items_read on public.equipment_items for select to authenticated
  using (
    not gym_private.is_blocked_author(created_by) and (
      public.is_app_admin()
      or (created_by = auth.uid() and (not public.is_mcp_client() or public.mcp_flag('gyms')))
      or (status = 'active' and ((brand is null and model is null) or exists (
        select 1 from public.gym_equipment e
        where e.item_id = equipment_items.id and e.visibility = 'public' and e.status = 'active')))));

revoke all on public.equipment_items from public, anon, authenticated;
grant select (id, kind_id, brand, model, status, created_at, updated_at)
  on public.equipment_items to anon, authenticated;

-- Confirmations ------------------------------------------------------------------------------------------------------
create table public.equipment_confirmations (
  listing_id uuid not null references public.gym_equipment on delete cascade,
  user_id uuid not null references auth.users on delete cascade,
  created_at timestamptz not null default now(),
  primary key (listing_id, user_id)
);
create index equipment_confirmations_user on public.equipment_confirmations (user_id, created_at);
alter table public.equipment_confirmations enable row level security;
revoke all on public.equipment_confirmations from public, anon, authenticated;

create or replace function public.gym_equipment_count_confirmations() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  target uuid := coalesce(new.listing_id, old.listing_id);
begin
  update public.gym_equipment
    set confirm_count = (select count(*) from public.equipment_confirmations where listing_id = target)
    where id = target;
  return null;
end $$;
revoke execute on function public.gym_equipment_count_confirmations() from public, anon, authenticated;
create trigger keep_count after insert or delete on public.equipment_confirmations
  for each row execute function public.gym_equipment_count_confirmations();

-- What clients read ----------------------------------------------------------------------------------------------------
-- Security definer so the invoker views can answer without the author columns being readable. With the gyms flag off
-- Claude gets false from all of these: what a user created or confirmed is theirs to withhold.
create function gym_private.my_gym_data_visible() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (not public.is_mcp_client() or public.mcp_flag('gyms'))
$$;
revoke execute on function gym_private.my_gym_data_visible() from public, anon, authenticated;
create or replace function public.is_my_listing(listing uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select gym_private.my_gym_data_visible()
    and exists (select 1 from public.gym_equipment where id = listing and added_by = auth.uid())
$$;
create or replace function public.did_i_confirm(listing uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select gym_private.my_gym_data_visible()
    and exists (select 1 from public.equipment_confirmations where listing_id = listing and user_id = auth.uid())
$$;
create or replace function public.is_my_item(item uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select gym_private.my_gym_data_visible()
    and exists (select 1 from public.equipment_items where id = item and created_by = auth.uid())
$$;
create or replace function public.is_my_gym(gym uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select gym_private.my_gym_data_visible()
    and exists (select 1 from public.gyms where id = gym and created_by = auth.uid())
$$;
revoke execute on function public.is_my_listing(uuid), public.did_i_confirm(uuid), public.is_my_item(uuid),
  public.is_my_gym(uuid) from public;
grant execute on function public.is_my_listing(uuid), public.did_i_confirm(uuid), public.is_my_item(uuid),
  public.is_my_gym(uuid) to anon, authenticated;

create view public.public_gyms with (security_invoker = true) as
  select g.id, g.name, g.address, g.latitude, g.longitude, g.maps_place_id, g.status, g.created_at, g.updated_at,
         public.is_my_gym(g.id) as is_mine
  from public.gyms g
  where g.visibility = 'public';

-- An item's photo is read from its best shared listing, never stored on the item: when that listing is removed, flagged
-- or loses its photo, or its author is blocked, the next one shows, so there's nothing to clean up. photo_listing_id is
-- what the app reports when someone flags the photo.
create view public.public_equipment_items with (security_invoker = true) as
  select i.id, i.kind_id, i.brand, i.model, p.photo_path, p.id as photo_listing_id, i.status, i.created_at, i.updated_at,
         public.is_my_item(i.id) as is_mine,
         (select count(distinct e.gym_id) from public.gym_equipment e
          where e.item_id = i.id and e.visibility = 'public' and e.status = 'active') as gym_count
  from public.equipment_items i
  left join lateral (
    select e.id, e.photo_path from public.gym_equipment e
    where e.item_id = i.id and e.visibility = 'public' and e.status = 'active' and e.photo_path is not null
    order by e.confirm_count desc, e.created_at, e.id
    limit 1
  ) p on true;

create view public.public_gym_equipment with (security_invoker = true) as
  select e.id, e.gym_id, e.item_id, i.kind_id, i.brand, i.model, e.photo_path, e.loads, e.quantity, e.notes, e.status,
         e.confirm_count, e.created_at, e.updated_at,
         public.is_my_listing(e.id) as is_mine, public.did_i_confirm(e.id) as confirmed_by_me
  from public.gym_equipment e
  join public.equipment_items i on i.id = e.item_id
  join public.gyms g on g.id = e.gym_id
  where e.visibility = 'public';

revoke all on public.public_gyms, public.public_equipment_items, public.public_gym_equipment
  from public, anon, authenticated;
grant select on public.public_gyms, public.public_equipment_items, public.public_gym_equipment to anon, authenticated;

-- Workouts link to where they happened. Sent only when the gym exists on the server. --------------------------------
alter table public.workouts add column gym_id uuid references public.gyms on delete set null;
alter table public.workout_entries add column gym_equipment_id uuid references public.gym_equipment on delete set null;
create index workouts_gym on public.workouts (gym_id) where gym_id is not null;

-- A link stands only if the caller can read the row (security invoker, so the policies decide). Anything else becomes
-- null instead of an error, so a gym the caller lost access to can't block their workout and ids can't be probed.
create function gym_private.workout_gym_link() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.gym_id is not null and (tg_op = 'INSERT' or new.gym_id is distinct from old.gym_id) then
    new.gym_id := (select g.id from public.gyms g where g.id = new.gym_id);
  end if;
  return new;
end $$;
create function gym_private.workout_entry_gym_link() returns trigger
language plpgsql set search_path = public as $$
begin
  if new.gym_equipment_id is not null and (tg_op = 'INSERT' or new.gym_equipment_id is distinct from old.gym_equipment_id) then
    new.gym_equipment_id := (select e.id from public.gym_equipment e where e.id = new.gym_equipment_id);
  end if;
  return new;
end $$;
revoke execute on function gym_private.workout_gym_link(), gym_private.workout_entry_gym_link() from public;
grant execute on function gym_private.workout_gym_link(), gym_private.workout_entry_gym_link() to authenticated;
create trigger a_gym_link before insert or update of gym_id on public.workouts
  for each row execute function gym_private.workout_gym_link();
create trigger a_gym_link before insert or update of gym_equipment_id on public.workout_entries
  for each row execute function gym_private.workout_entry_gym_link();
