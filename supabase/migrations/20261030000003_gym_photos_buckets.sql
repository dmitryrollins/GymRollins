-- Gym equipment photos (spec §5 "Reads and access rules"). The phone cleans them first: downscaled, faces blurred,
-- metadata gone. A custom client could skip that, so reports and admin removal are the backstop.
--   gym-photos           shared listings: anyone can read (public URLs need no policy), JPEG only, 1 MB.
--   gym-photos-private   synced private listings: owner only.
-- Names are bare random <uuid>.jpg. Ownership is the Storage API's owner_id, never the path: a public URL with a user's
-- folder in it would give every reader that user's id.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('gym-photos', 'gym-photos', true, 1000000, array['image/jpeg']),
       ('gym-photos-private', 'gym-photos-private', false, 1000000, array['image/jpeg'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- The daily photo limit (dailyPhotoUploads in DomainLimits.swift and domain-limits.ts). The policy and the trigger below
-- both read it from here.
create function gym_private.daily_photo_limit() returns int
language sql immutable set search_path = pg_catalog as $$ select 60 $$;
revoke execute on function gym_private.daily_photo_limit() from public, anon;
grant execute on function gym_private.daily_photo_limit() to authenticated;

-- Security definer because storage.objects isn't readable through the caller's own policies for this count.
create function gym_private.photos_today(p_owner text) returns bigint
language sql stable security definer set search_path = '' as $$
  select count(*) from storage.objects
  where owner_id = p_owner and bucket_id in ('gym-photos', 'gym-photos-private')
    and created_at > now() - interval '1 day'
$$;
revoke execute on function gym_private.photos_today(text) from public, anon, authenticated;

-- Whether a signed upload may begin: the account still exists, the daily limit isn't reached, and no listing uses the
-- name. Only an early answer: the policy runs when Storage issues an upload token, but the upload itself runs later as
-- the database owner with no session, so the rules that must hold are in guard_gym_photo below.
create function gym_private.photo_upload_allowed(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from auth.users where id = auth.uid())
     and gym_private.photos_today(auth.uid()::text) < gym_private.daily_photo_limit()
     and not exists (select 1 from public.gym_equipment where photo_path = p_name)
$$;
revoke execute on function gym_private.photo_upload_allowed(text) from public, anon;
grant execute on function gym_private.photo_upload_allowed(text) to authenticated;

-- The rules for every write to the two gym buckets, including the write that happens after an upload token was issued
-- (no session, so no policy) and the ones the policy never sees: copy with its own metadata, resumable uploads, upserts.
-- Everything keys on the row's owner_id, which Storage takes from the token, never on auth.uid().
--
-- Storage 1.77 (the version in the local stack) writes a row twice. First inside the caller's own transaction, as a
-- permission check that is rolled back, with only the type the caller declared (a signed upload token's check declares
-- application/json); then as the database owner, with no session, the full metadata and a new version. A null type has
-- never been seen on either row. So the type is checked only on the write with no session: it must be image/jpeg, which
-- refuses copy with its own metadata and a resumable upload without a content type (stored as
-- application/octet-stream), and a missing type. What remains: a Storage version that committed a row inside the
-- caller's session would skip that check; the bucket's allowed_mime_types still applies to the normal upload path.
--
-- Photos never change: a new photo gets a new name, so an update may not change the name, the bucket, the owner or the
-- version (every upload, upsert included, gets a new version). Other columns such as last_accessed_at pass.
--
-- Deleting a photo frees a slot in the daily count. That is accepted: only 60 stay stored per day, which is what
-- the limit is for. Nothing else writes these buckets: the app uploads and deletes through the Storage API, and
-- moderation removes photos only by deleting (moderate_content returns the name for the app to delete, and
-- moderation_photo_deleted clears it once the object is gone).
create function gym_private.guard_gym_photo() returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  owner uuid;
  mime text := new.metadata ->> 'mimetype';
begin
  if new.name !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$' then
    raise exception 'photo_bad_name' using errcode = '42501';
  end if;
  -- The type is checked on the write with no session, the one that stays.
  if auth.uid() is null and mime is distinct from 'image/jpeg' then
    raise exception 'photo_not_jpeg' using errcode = '42501';
  end if;

  if tg_op = 'UPDATE' then
    if new.name is distinct from old.name or new.bucket_id is distinct from old.bucket_id
       or new.version is distinct from old.version or new.owner_id is distinct from old.owner_id then
      raise exception 'photo_immutable' using errcode = '42501';
    end if;
    return new;
  end if;

  if new.owner_id is null or new.owner_id !~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    raise exception 'photo_owner_missing' using errcode = '42501';
  end if;
  owner := new.owner_id::uuid;
  -- Under the same lock as the other daily limits, so parallel uploads can't each see a count under the limit. Taken
  -- before looking for the owner: delete_my_account holds it until the account is gone, so an upload that waited here
  -- sees the deletion and is refused instead of leaving an object owned by nobody.
  perform gym_private.lock_user(owner);
  if not exists (select 1 from auth.users where id = owner) then
    raise exception 'photo_owner_missing' using errcode = '42501';
  end if;
  if exists (select 1 from public.gym_equipment where photo_path = new.name) then
    raise exception 'photo_name_in_use' using errcode = '42501';
  end if;
  if gym_private.photos_today(new.owner_id) >= gym_private.daily_photo_limit() then
    raise exception 'photo_daily_limit' using errcode = '42501';
  end if;
  return new;
end $$;
revoke execute on function gym_private.guard_gym_photo() from public, anon, authenticated;
create trigger a_gym_photo_guard_insert before insert on storage.objects
  for each row when (new.bucket_id in ('gym-photos', 'gym-photos-private'))
  execute function gym_private.guard_gym_photo();
create trigger a_gym_photo_guard_update before update on storage.objects
  for each row when (old.bucket_id in ('gym-photos', 'gym-photos-private')
                     or new.bucket_id in ('gym-photos', 'gym-photos-private'))
  execute function gym_private.guard_gym_photo();

-- Nobody updates an object: a new photo gets a new name. Owners delete their own; admins may delete any shared one.
create policy gym_photos_insert_own on storage.objects for insert to authenticated
  with check (bucket_id in ('gym-photos', 'gym-photos-private')
              and owner_id = auth.uid()::text
              and name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'
              and not public.is_mcp_client()
              and gym_private.photo_upload_allowed(name));
create policy gym_photos_read_own on storage.objects for select to authenticated
  using (bucket_id in ('gym-photos', 'gym-photos-private')
         and owner_id = auth.uid()::text
         and not public.is_mcp_client());
create policy gym_photos_delete_own on storage.objects for delete to authenticated
  using (bucket_id in ('gym-photos', 'gym-photos-private')
         and owner_id = auth.uid()::text
         and not public.is_mcp_client());
-- The Storage API looks an object up before removing it, so an admin's delete needs this read as well.
create policy gym_photos_read_admin on storage.objects for select to authenticated
  using (bucket_id = 'gym-photos' and public.is_app_admin());
create policy gym_photos_delete_admin on storage.objects for delete to authenticated
  using (bucket_id = 'gym-photos' and public.is_app_admin());
