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

-- Whether this upload may happen: the account still exists (an access token outlives a deleted account), a daily limit
-- (dailyPhotoUploads in DomainLimits) so the bucket isn't free hosting, and a name no listing has used, so a confirmed
-- listing's picture can't be swapped by deleting and uploading again.
create function gym_private.photo_upload_allowed(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from auth.users where id = auth.uid())
     and (select count(*) from storage.objects
          where owner_id = auth.uid()::text and bucket_id in ('gym-photos', 'gym-photos-private')
            and created_at > now() - interval '1 day') < 60
     and not exists (select 1 from public.gym_equipment where photo_path = p_name)
$$;
revoke execute on function gym_private.photo_upload_allowed(text) from public, anon;
grant execute on function gym_private.photo_upload_allowed(text) to authenticated;

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
