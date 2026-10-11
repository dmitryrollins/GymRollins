-- Public, read-only bucket for GymRollins' own exercise photos (own-<exerciseId>-<frame>.jpg, AI-generated) and the
-- manifest.json the app reads to know which exercises have hosted photos (docs/media/README.md, "Hosting").
-- Public = anyone can GET /storage/v1/object/public/exercise-photos/<name>; that path needs no RLS policy.
-- Deliberately NO storage.objects policies: anon and signed-in users can't upload, overwrite, delete or list objects
-- through the API. Only the service role (scripts/upload-photos.mjs), which bypasses RLS, writes.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('exercise-photos', 'exercise-photos', true, 5242880, array['image/jpeg', 'application/json'])
on conflict (id) do update
  set public = excluded.public,
      file_size_limit = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;
