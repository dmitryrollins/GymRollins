# Cloud checklist

Everything in this repo runs against the **local** Supabase stack (`scripts/supabase-up.sh`, ports 554xx). The
local `supabase/config.toml` is tuned for tests (auto-confirmed email sign-ups, short passwords), which is fine
locally and wrong in production. Work through this list before pointing a build at a cloud project.

## Before cloud

Auth hardening (security review M2/M3) — set in the cloud project's dashboard (Authentication settings), not
by copying the local `config.toml`:

- [ ] **Email confirmations on.** Local has `[auth.email] enable_confirmations = false`; production must require
      confirmation so nobody can register an address they don't own.
- [ ] **Minimum password length ≥ 12** (local is 6), or **disable the email provider** in production entirely:
      the shipping app signs in with Apple only (email/password exists in DEBUG builds for tests).
- [ ] **Restrict sign-ups after the owner registers.** This is a single-user app: once the owner's account
      exists, turn off `enable_signup` (or gate it behind an allow-list / invite), so strangers can't create
      accounts on the project.
- [ ] **Dynamic client registration (MCP OAuth) consent page** shows the requesting client's **name** and the
      **access it asks for** (read workouts, read body, propose changes) before the owner approves; never
      auto-approve a newly registered client.
- [ ] **Apple provider set up:** `[auth.external.apple]` enabled in the cloud project with the Services ID /
      bundle id as client id, the Sign in with Apple key (team id, key id, private key) stored only in the
      Supabase dashboard, and the app's `com.apple.developer.applesignin` entitlement matching.

Database (already enforced by migrations, verify after the first `db push`):

- [ ] `anon` has no privileges on `public` tables or RPCs (`20260927000002_security_fixes.sql`); run the
      Supabase security advisor and expect no "RLS disabled" / "exposed function" findings.
- [ ] `pgcrypto` lives in the `extensions` schema.
- [ ] Storage bucket **`exercise-photos`** exists (migration `20260929000001_exercise_photos_bucket.sql`): public,
      `allowed_mime_types` = image/jpeg + application/json, 5 MB limit, and **no** `storage.objects` policies for
      anon/authenticated (only the service role uploads). Then upload the photos:
      `node scripts/upload-photos.mjs --target remote` with the cloud `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY`
      in the environment or `app/.env` (gitignored) — see `docs/media/README.md` ("Hosting").

App configuration:

- [ ] Cloud `SUPABASE_URL` / `SUPABASE_ANON_KEY` and `DEVELOPMENT_TEAM` go in `ios/Config/Local.xcconfig`
      (gitignored; it is included last in `Base.xcconfig`, so it overrides the committed defaults). Never put a
      service-role key in the app.
- [ ] `PHOTO_HOSTING = storage` in `Local.xcconfig` once the photos are uploaded (Release builds load Storage photos
      over https only).
