# Exercise photos

The app shows its own photos first, named `own-<id>-<frame>.jpg` (frame 0 = start position, frame 1 = end position,
1536×1024 JPEG, 3:2). They live in two places:

- `media/photos/` (repo root, gitignored): where the generator writes. Not bundled; served from R2 behind the Worker
  (see [Hosting](#4-hosting)).
- `ios/GymRollins/Resources/OwnPhotos/`: bundled in the app. `BundledOwnPhotoProvider` picks up any file dropped
  there on the next build; copy photos here for exercises you train while the app still uses `PHOTO_HOSTING = bundle`.
 `own-0453-0.jpg` / `own-0453-1.jpg` are the style reference: same man, same clothes, light-grey
concrete studio.

## 1. Prompts

`node scripts/build-photo-prompts.mjs` writes `docs/media/photo-prompts.csv` (gitignored): one start + one end prompt
for every library exercise that has no photo yet, the exercises you've trained first (`priority` 1 — 18 exercises,
36 images). Done rows drop out when you re-run it.

## 2. Generate with Gemini ("Nano Banana Pro")

`scripts/generate-photos.mjs` sends each prompt to `gemini-3-pro-image` (`generateContent`, 3:2, 2K) and saves the
result into `media/photos/` as an exact 1536×1024 JPEG (quality 82) via `scripts/photo-postprocess.py` (Pillow + numpy; a non-3:2 result
is widened by extending the studio background at the sides, never cropped through the person).

```bash
# once: the key (never committed — app/.env is gitignored)
export GEMINI_API_KEY=...            # or put GEMINI_API_KEY=... in app/.env

# see what would be generated (no network, no key needed)
node scripts/generate-photos.mjs --priority 1 --dry-run

# generate the test batch: 18 exercises × 2 frames = 36 images ≈ $4.80
node scripts/generate-photos.mjs --priority 1
```

- Per exercise, frame 0 is generated first with `own-0453-0.jpg` attached as the identity/style reference ("same
  man, clothes and studio; different exercise"); frame 1 then gets the new frame 0 attached so the end position
  matches it. If frame 0 fails, frame 1 is not attempted.
- **Resumable:** existing files (in `media/photos/` or `Resources/OwnPhotos/`) are skipped. Re-run the same command after a failure or quota stop. To redo a bad
  photo, delete it (delete both frames if the start frame is the problem) and re-run.
- Writes are atomic (temp file, then rename). 429/5xx are retried with exponential backoff + jitter (5 tries,
  `Retry-After` honoured). Safety-blocked or no-image responses are logged as failures and the run continues; an
  invalid key (401/403) stops the run.
- Run log: `docs/media/generation-log.jsonl` (gitignored; id, frame, status, ms, attempts, error — never the key).
  The summary prints done / skipped / failed and the billed image count with an estimate ($0.134 per 1K/2K image,
  <https://ai.google.dev/gemini-api/docs/pricing>).
- Flags: `--priority N`, `--ids 0215,0227`, `--limit N` (exercises, frames stay paired), `--concurrency N`
  (default 2), `--model <id>` (default `gemini-3-pro-image`), `--image-size 1K|2K|4K` (default 2K), `--dry-run`.
- Tests (mocked `fetch`, no API calls): `node --test scripts/generate-photos.test.mjs` (also in
  `scripts/test-all.sh`).

## 3. Review, then reinstall

1. Look through the new `media/photos/own-*.jpg` files (Finder Quick Look / Preview). Check: same man and clothes, correct
   exercise and equipment, start vs end actually differ, no extra people, no text or logos, body fully in frame.
2. Delete any bad ones and re-run the generate command (only the deleted files are regenerated).
3. Re-run `node scripts/build-photo-prompts.mjs` so done rows drop out of the CSV.
4. Either upload them ([Hosting](#4-hosting)), or, while the app still bundles photos, copy the
   ones you want into `ios/GymRollins/Resources/OwnPhotos/` and rebuild/reinstall the app.

## 4. Hosting

The full set (2,046 photos × ~110 KB ≈ 225 MB) is far too big for the app bundle, so own photos are hosted in the
**`exercise-photos`** R2 bucket behind the Worker (`server/`). Anyone can read them at
`<API_URL>/photos/exercises/<name>`. The route serves only `own-<id>-<frame>.jpg`, `kind-<kindId>.jpg` and
`manifest.json`, and takes no writes (`server/test/public-photos.test.ts`); only `scripts/upload-photos.mjs` writes
the bucket.

**How the app finds them.** The bucket holds `manifest.json`:

```json
{ "version": 1, "updatedAt": "2026-09-29T10:00:00.000Z", "photos": { "0453": 2, "0227": 2 }, "rev": { "0453": "ab12cd34ef56" } }
```

`photos` = frame count per exercise id, `rev` = a content hash per exercise. The app fetches the manifest once per
launch (in the background; the last good copy is cached in Caches/ExercisePhotoManifest and used meanwhile and
offline) and builds `<API_URL>/photos/exercises/own-<id>-<frame>.jpg?v=<rev>` — the `?v=` makes a regenerated photo
bypass the long-lived photo caches. Photos download on demand into the existing 150 MB photo cache. If the manifest
can't be loaded (first launch offline, error), the app silently falls back.

**Provider order** with `PHOTO_HOSTING = storage`: photo URLs on the exercise record → hosted photos → photos bundled
in the app → free-exercise-db → wger.de (Creative Commons, credited on the detail photo; only fills gaps — see
`docs/licenses/wger.md`) → body-part illustration. With `bundle` (the default) the hosted step is skipped.

### Upload

`scripts/upload-photos.mjs` uploads every `own-*.jpg` and `kind-*.jpg` in `media/photos/` and
`ios/GymRollins/Resources/OwnPhotos/` (`content-type: image/jpeg`, `cache-control: max-age=31536000`), then rebuilds
`manifest.json` (`max-age=60`) from what the bucket holds: the local photos, plus every photo the stored manifest
already listed. Idempotent: objects with the same size and MD5 (the ETag) are skipped, and an unchanged manifest isn't
rewritten. Nothing local is moved or deleted; nothing in the bucket is deleted.

```bash
# the local Worker (the default target), with scripts/server-up.sh running; no Cloudflare account
node scripts/upload-photos.mjs --dry-run      # what would be uploaded
node scripts/upload-photos.mjs

# the deployed Worker, only with the owner's approval for this upload (docs/cloudflare-checklist.md, section 8)
GYM_CLOUD_APPROVED=1 WORKER_URL=https://api.gymrollins.com node scripts/upload-photos.mjs --target cloud --dry-run
GYM_CLOUD_APPROVED=1 WORKER_URL=https://api.gymrollins.com node scripts/upload-photos.mjs --target cloud
```

- `--target worker` writes with `wrangler r2 object put --local` into `server/.wrangler/state` (`WORKER_STATE` names
  another local state folder), and accepts only a loopback `WORKER_URL` (default `http://127.0.0.1:8787`).
- `--target cloud` writes with `wrangler r2 object put --remote` (the owner's `wrangler login`), needs an https
  `WORKER_URL`, and refuses to run without `GYM_CLOUD_APPROVED=1`.
- Both read through the Worker's public route. `--dir <folder>` (repeatable) uploads from other folders instead.

### Switch the app to the hosted photos

Set `PHOTO_HOSTING = storage` in `ios/Config/Local.xcconfig` (gitignored; default `bundle` in `Base.xcconfig`), then
rebuild. The photos come from `<API_URL>/photos/exercises/` of whatever `API_URL` the build uses:

- **Local Worker (DEBUG only):** the default `API_URL = http://127.0.0.1:8787` works in the simulator once
  `node scripts/upload-photos.mjs` has filled it. Plain http is allowed only in DEBUG builds and only for 127.0.0.1 /
  localhost, or the configured `API_URL` host when it is a loopback/LAN address — see `PhotoURLPolicy`. Release builds
  load photos over https only; with an http `API_URL` a Release build keeps the bundled photos.
- **Deployed Worker:** set its https `API_URL` in `Local.xcconfig` once the owner has deployed it
  (`docs/cloudflare-checklist.md`, section 9).

In DEBUG, the environment variables `PHOTO_HOSTING` and `API_URL` (Xcode scheme) override the build settings. UI tests
(`-uiTesting`) never load hosted photos.

### When the Worker is deployed

1. The owner creates the `exercise-photos` bucket with the others (`docs/cloudflare-checklist.md`, section 2). It stays
   private: the Worker serves it.
2. Upload with `--target cloud` (above), then check `curl -s https://<the Worker>/photos/exercises/manifest.json`.
3. App: the deployed `API_URL` and `PHOTO_HOSTING = storage` in `Local.xcconfig`.
4. Once hosting is live, the bundled `own-*` photos can be removed from `Resources/OwnPhotos/` (keep `own-0453-*`: it is the
   generator's style reference) — the bundle stays a fallback only for what's left in it. Keep every `kind-*.jpg`: they are
   the offline fallback for the equipment stock photos, and a test needs them.

### Tests

- Uploader: `node --test scripts/upload-photos.test.mjs` (a fake Worker route and a fake wrangler; in
  `scripts/test-all.sh`).
- Server: `server/test/public-photos.test.ts` (the public route: names, ETag, 304, cache times, no writes).
- App: `StoragePhotoHostingTests` (URL policy, config switch, manifest parsing/caching/failure, URL building,
  provider order) run in `scripts/ios-test.sh` without network.
- End-to-end: `scripts/test-photo-hosting.sh` (or `PHOTO_E2E=1 scripts/test-all.sh`) starts a throwaway local Worker,
  uploads two generated test photos into its R2 with the script, checks the second upload is a no-op, and loads them
  through the manifest, provider and photo store in the simulator. The Worker and its state are removed afterwards.
