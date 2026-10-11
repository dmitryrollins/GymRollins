-- Plan 15 (Apple Health): where a weigh-in came from. null = typed in the app (or logged by Claude / imported);
-- 'apple_health' = read from Apple Health on the owner's iPhone. Synced so another device never writes a
-- Health-imported weigh-in back to Apple Health as if it were its own.
alter table public.bodyweight add column source text check (source is null or source in ('apple_health'));

-- The Apple Health body mass / body fat sample ids a weigh-in was read from: every device dedupes Health imports and
-- applies Health deletions by these, whatever the row id.
alter table public.bodyweight add column health_sample_id uuid, add column health_fat_sample_id uuid;

-- Deleting a weigh-in read from Apple Health wins over edits of it (they are automatic: body fat merges, duplicate
-- cleanup), in both orders. A deleted one stays deleted: a device that hasn't pulled the deletion yet may push a newer
-- edit of the live row, which is dropped like lww_guard drops stale writes. And a deletion arriving after such an edit
-- is accepted, by lifting its edit time to the row's so lww_guard lets it through. Runs first (triggers fire in name
-- order).
create or replace function public.health_tombstone_guard() returns trigger
language plpgsql as $$
begin
  if old.deleted_at is not null and old.health_sample_id is not null and new.deleted_at is null then
    return null;
  end if;
  if new.deleted_at is not null and old.deleted_at is null
     and coalesce(old.health_sample_id, new.health_sample_id) is not null then
    new.client_updated_at := greatest(new.client_updated_at, old.client_updated_at);
  end if;
  return new;
end $$;
create trigger a_health_tombstone before update on public.bodyweight
  for each row execute function public.health_tombstone_guard();
