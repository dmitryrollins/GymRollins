-- Plan 28: gyms, photos and moderation on D1 (docs/plans/2026-11-08-plan-28-gyms-photos-moderation.md).

-- The catalogue's identity, case-folded in TypeScript (foldKey in server/src/gyms/text.ts): SQLite's lower() folds
-- ASCII only, so "Ä" and "ä" would otherwise be two items where Postgres had one. Every brand and model has its key.
ALTER TABLE equipment_items ADD COLUMN brand_key TEXT CHECK ((brand IS NULL) = (brand_key IS NULL));
ALTER TABLE equipment_items ADD COLUMN model_key TEXT CHECK ((model IS NULL) = (model_key IS NULL));
DROP INDEX equipment_items_identity;
CREATE UNIQUE INDEX equipment_items_identity
  ON equipment_items (kind_id, coalesce(brand_key, ''), coalesce(model_key, ''));

-- At most 100 live private gyms (DomainLimits.privateGymsMax) and 1000 live private listings (privateListingsMax) per
-- user: gym_private.check_private_gym_cap and check_private_listing_cap. Checked when a row becomes live: a new row (an
-- upsert's insert attempt, which SQLite runs before it finds the conflict, as Postgres did), or a tombstone cleared.
-- The row itself is left out of the count, so an upsert of a live row adds nothing. D1 runs one statement at a time,
-- and a trigger's count sees the rows its statement wrote before, so the cap holds without a lock. RAISE fails the whole
-- statement; the server answers 422 with the message as the code (server/src/http/errors.ts).
CREATE TRIGGER gyms_private_cap BEFORE INSERT ON gyms
  WHEN NEW.visibility = 'private' AND NEW.deleted_at IS NULL
    AND (SELECT count(*) FROM gyms WHERE owner_id = NEW.owner_id AND deleted_at IS NULL AND id <> NEW.id) >= 100
BEGIN
  SELECT RAISE(ABORT, 'too_many_gyms');
END;
CREATE TRIGGER gyms_private_cap_revived BEFORE UPDATE OF deleted_at ON gyms
  WHEN NEW.visibility = 'private' AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL
    AND (SELECT count(*) FROM gyms WHERE owner_id = NEW.owner_id AND deleted_at IS NULL AND id <> NEW.id) >= 100
BEGIN
  SELECT RAISE(ABORT, 'too_many_gyms');
END;
CREATE TRIGGER gym_equipment_private_cap BEFORE INSERT ON gym_equipment
  WHEN NEW.visibility = 'private' AND NEW.deleted_at IS NULL
    AND (SELECT count(*) FROM gym_equipment WHERE owner_id = NEW.owner_id AND deleted_at IS NULL AND id <> NEW.id) >= 1000
BEGIN
  SELECT RAISE(ABORT, 'too_many_listings');
END;
CREATE TRIGGER gym_equipment_private_cap_revived BEFORE UPDATE OF deleted_at ON gym_equipment
  WHEN NEW.visibility = 'private' AND OLD.deleted_at IS NOT NULL AND NEW.deleted_at IS NULL
    AND (SELECT count(*) FROM gym_equipment WHERE owner_id = NEW.owner_id AND deleted_at IS NULL AND id <> NEW.id) >= 1000
BEGIN
  SELECT RAISE(ABORT, 'too_many_listings');
END;

-- report_content's daily count (20 a day) reads a reporter's reports by time.
CREATE INDEX reports_reporter_created ON reports (reporter_id, created_at) WHERE reporter_id IS NOT NULL;
