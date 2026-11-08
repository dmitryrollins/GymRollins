-- Plan 29, added after review: the browser session /connect gives an approved browser is marked
-- (src/auth/connect-plugin.ts), so /v1 and the app's get-session refuse it. The column is Better Auth's
-- schema compiler's own SQL for the plugin's field (test/auth.test.ts checks it); older sessions get 0.
alter table "session" add column "claudeConnect" integer default 0;

-- A marked session keeps the 10-minute expiry it was made with. Better Auth renews any session it reads
-- without its dont_remember cookie (a bearer does that), which would make this one last 60 days. Only an
-- extension is undone, so the trigger's own UPDATE doesn't run it again.
CREATE TRIGGER session_connect_expiry AFTER UPDATE OF "expiresAt" ON "session"
  WHEN OLD."claudeConnect" = 1 AND NEW."expiresAt" > OLD."expiresAt"
BEGIN
  UPDATE "session" SET "expiresAt" = OLD."expiresAt" WHERE "id" = OLD."id";
END;
