# Gyms and equipment: design spec

Date: 2026-10-30 · Status: approved in brainstorming, waiting for the owner's review of this file.
Wireframes: `docs/design/wireframes/2026-10-30-gym-picker-and-equipment.html`,
`docs/design/wireframes/2026-10-30-add-equipment-and-build.html` (brainstorm fragments; they render without the
companion frame's theme, so colors outside the phones are plain).
Builds on: `docs/specs/2026-09-26-gymrollins-ios-design.md` (the app spec). Where the two disagree, this file wins for
gyms, equipment and gym-aware workouts only.

## 1. Goal

Workouts that only use equipment the gym actually has. Users photograph and catalogue a gym's equipment, the
catalogue is shared between users of the same gym, and the app uses it in two ways: it adapts the planned routine to
the gym, and it builds a new workout for chosen muscles from that gym's equipment.

The trigger: plans written without knowing the equipment don't fit (October 2026 home plans assumed dumbbells when the
owner has a bench and two kettlebells, 20 kg and 24 kg).

### In scope
1. **Gyms:** Apple Maps gyms (shared) and private gyms (home, office; never shared). A gym chip on Today, a gym
   picker with a one-shot "you're near X" suggestion.
2. **Equipment:** a curated list of equipment kinds, a shared catalogue of items (kind plus optional brand and model),
   and per-gym listings with a photo, available loads, confirmations and status.
3. **Add equipment in 4 steps:** photo, kind, duplicate check, loads and sharing.
4. **Three visibility levels**, default "This phone only". The whole feature works with no account and uploads nothing
   until the user shares.
5. **Plan adaptation:** today's routine is adapted to the current gym for the session only.
6. **Build workout:** pick muscles and length; the app builds a workout from the gym's equipment.
7. **Sharing between users:** confirm, report, block, auto-hide after 3 reports, an admin moderation list.
8. **Photos:** downscaled, face-blurred and stripped of metadata on the phone before they are saved.
9. **Claude (MCP):** read-only tools for gyms and their equipment.

### Not in scope
- AI identification of equipment from a photo (manual kind selection only; a v2 idea).
- Barcodes or QR codes on machines.
- Per-gym bar and plate inventories: plate-loaded and barbell loads keep using the profile's `PlateInventory`.
- Saving a built workout as a routine.
- A social feed, comments, messaging, payments, trainer marketplace.
- Gym chains as an entity (each location is its own gym).
- Server-side orphan photo cleanup (see Risks).

### Success criteria (the pasted spec's acceptance scenarios, made testable)
1. **New gym:** a gym with 0 equipment; the user adds 5 photographed listings and builds a chest workout. Every
   equipment exercise links a listing at that gym that has a photo, no exercise needs a kind that isn't listed, and
   any bodyweight fill (section 5) is marked "no equipment".
2. **Two users:** user A shares listings at a gym. User B, and a user with no account, sees them without adding them
   and builds a workout from them.
3. **Same muscles 4 days in a row:** the user builds and completes a workout for the same chips on 4 consecutive
   days. Each of workouts 2, 3 and 4 changes at least half of its exercises compared with the previous one, whenever
   the gym offers at least twice as many available exercises as the workout needs.
4. **Duplicate add:** adding a kind the gym already lists shows the existing listings first and offers "Yes, that's
   it (+1 confirm)" before a new listing can be created, both in the app and in `share_listing`.
5. **Never invents equipment:** for any inventory, every exercise the adapter or builder outputs is backed by active
   listings that cover all of its requirement groups.
6. **Stays on the phone:** a "This phone only" gym or listing never reaches the network layer, signed in or not.

## 2. Decisions (settled in brainstorming, 2026-10-29/30)

| Topic | Decision |
|---|---|
| Audience | Shared from day one (multi-user catalogue), not personal-only |
| Sharing model | A shared catalogue of items plus per-gym listings (not per-gym copies, not chain inventories) |
| Gym identity | Apple Maps place (`MKMapItem.identifier`), unique per place; private gyms by hand with an optional address |
| Plan vs builder | Both: the routine is adapted automatically; Build workout is on demand |
| Where rules run | On the phone, in GymCore (offline, testable). Claude reads equipment through MCP and plans on its own |
| Accounts | No account needed for anything except sharing, confirming, reporting and blocking |
| Default visibility | "This phone only" for everything the user adds |
| Muscles | Never tagged by hand; they come from the exercises a kind allows |
| Variety in Build | Skip exercises from the last 3 workouts that trained the same muscle; repeats are explained |
| Moderation | Report with a reason, auto-hide after 3 distinct reporters, admin restore or remove, block user |
| Cloud | Built and tested on the local stack with two test users; creating the cloud project is a separate step that needs the owner's go-ahead |

## 3. Architecture

```
GymCore (pure Swift, no I/O)                 GymData (SwiftData + sync)            Supabase
  EquipmentKind, ExerciseRequirements          Gym, EquipmentItem, GymListing         gyms, equipment_kinds,
  GymInventory, AvailableLoads                 (visibility + upload state)            exercise_requirements,
  InventoryMatcher                             GymCatalogClient (anon reads, cache)   equipment_items,
  GymAdapter        ◄── Today                  ShareOutbox (queued writes)            gym_equipment, confirmations,
  WorkoutBuilder    ◄── Build workout          SyncEngine (synced private gyms)       reports, user_blocks, app_admins
                                                                                      RPCs, gym-photos buckets
App target                                                                            Edge Fn mcp: list_gyms,
  Features/Gyms (picker, equipment, add flow, moderation)                             get_gym_equipment
  Features/Today (gym chip, swap badges, Build workout)
  Media/GymPhotoProcessor (downscale, face blur, metadata strip)
```

### Units and responsibilities

| Unit | Package | Does | Depends on |
|---|---|---|---|
| `EquipmentKind` | GymCore | Curated kind: id, name, category, load type. Loaded from bundled `equipment-kinds.json` | — |
| `ExerciseRequirements` | GymCore | Exercise id → requirement groups (all groups needed, any one kind per group); empty = no equipment; missing = unmapped | `equipment-requirements.json` |
| `GymInventory` | GymCore | The listings the rules may use at one gym: id, kind, loads, confirm count, is-own | — |
| `AvailableLoads` | GymCore | Rounds a suggested load to what exists: weight stack (max, step), fixed set (list of kg), plates (`LoadRounder` + `PlateInventory`), none | `LoadRounder` |
| `InventoryMatcher` | GymCore | "Can this exercise be done here, and on which listings?" | requirements, inventory |
| `GymAdapter` | GymCore | Adapts a routine's exercises to the inventory for one session | matcher, `ExerciseRanking`, `ProgressionEngine` |
| `WorkoutBuilder` | GymCore | Builds a workout for muscle groups and a length | matcher, `MuscleTaxonomy`, `ExerciseRanking`, `ProgressionEngine`, `ModeDefaults` |
| `Gym`, `EquipmentItem`, `GymListing` | GymData | SwiftData models (source of truth on the phone), each with `visibility` and `uploadState` | SwiftData |
| `GymCatalogClient` | GymData | Reads public gyms, items and listings (anon key), caches them, refreshes | Supabase client wrapper |
| `ShareOutbox` | GymData | Persisted queue of share, confirm, report, block calls; retries when online and signed in | `GymCatalogClient` |
| `GymPhotoProcessor` | App (Media) | Downscale, face blur, metadata strip, thumbnail | ImageIO, Vision |
| `GymLocator` | App | One-shot location and nearest-gym suggestion | Core Location, MapKit |
| MCP `gyms` tools | `supabase/functions/mcp/tools/gyms.ts` | `list_gyms`, `get_gym_equipment` | `db.ts` |

## 4. Data model

### Curated data (bundled in the app and seeded on the server)
- `ios/GymRollins/Resources/equipment-kinds.json` (`{"version": 1, "kinds": [...]}`): 46 kinds. Each: `id` (`lat-pulldown`), `name`,
  `category` (`machine`, `cable`, `free-weight`, `bench`, `rack`, `cardio`, `accessory`), `load` (`stack`,
  `plate-loaded`, `fixed-set`, `bodyweight`, `none`). The app builds a generic catalogue item per kind from it.
- `ios/GymRollins/Resources/equipment-requirements.json`: `{"version": 1, "requirements": {"<exerciseId>":
  [["barbell"], ["flat-bench", "adjustable-bench", "bench-press-station"], ["power-rack", "bench-press-station"]],
  "<bodyweightId>": []}}`. One listing may cover several groups (a bench press station is both bench and rack).
  Generated by `scripts/map-equipment-requirements.mjs` from the library's `eq` and name, with an explicit rule table
  for machines (the library's "leverage machine" and "sled machine" exercises each map to one machine kind, or stay
  unmapped). The script writes `docs/import/equipment-requirements-review.md` for the owner to check, like the
  existing alias reviews. Prototype result (2026-10-30): 1,191 of 1,324 exercises mapped (218 of them need no
  equipment); 133 unmapped (stretches, partner-assisted, `weighted`, and unidentified machines). Unmapped exercises
  can still be logged, swapped in by hand and proposed by Claude, but are never chosen by the adapter or the builder.
- A seed migration loads both files into `equipment_kinds` and `exercise_requirements(exercise_id, groups jsonb)`, and
  a drift test fails when the seeds and the bundled JSON differ.

### Server tables (new migration)

| Table | Columns (all with `created_at`) |
|---|---|
| `gyms` | `id uuid`, `visibility` (`public`, `private`), `owner_id` (required when private), `name` (1–120), `address` (≤ 300), `latitude`, `longitude`, `maps_place_id` (unique, public only), `created_by` (set null on user delete), `status` (`active`, `flagged`, `removed`), `updated_at` |
| `equipment_kinds` | `id text`, `name`, `category`, `load_type` (seeded, read-only) |
| `exercise_requirements` | `exercise_id` → `exercises.id`, `groups jsonb` (array of arrays of kind ids; seeded, read-only) |
| `equipment_items` | `id uuid`, `kind_id`, `brand` (≤ 60), `model` (≤ 80), `reference_photo_path`, `created_by`, `status`; unique on (`kind_id`, lower `brand`, lower `model`). One generic item per kind (no brand, no model) is seeded |
| `gym_equipment` (listings) | `id uuid`, `gym_id`, `item_id`, `visibility` (`public`, `private`), `owner_id` (required when private), `photo_path`, `loads jsonb`, `quantity` (1–50, default 1), `notes` (≤ 280), `added_by` (set null on user delete), `status`, `confirm_count` (kept by a trigger), `updated_at`. A public listing must be on a public gym |
| `equipment_confirmations` | `listing_id`, `user_id`; primary key on both |
| `reports` | `id`, `target_type` (`gym`, `item`, `listing`), `target_id`, `reporter_id`, `reason` (`wrong-info`, `not-here-anymore`, `duplicate`, `inappropriate-photo`, `person-in-photo`, `spam`, `other`), `note` (≤ 280), `resolved_at`; unique on (`target_type`, `target_id`, `reporter_id`) |
| `user_blocks` | `blocker_id`, `blocked_id`; primary key on both |
| `app_admins` | `user_id` (seeded with the owner on the cloud project; a test user locally) |
| `workouts` + `gym_id` | Nullable, set null on delete. Sent only when the gym exists on the server; a "This phone only" gym stays local |
| `workout_entries` + `gym_equipment_id` | Nullable, set null on delete, with the same rule |

`loads` shapes: `{"type":"stack","maxKg":113.4,"stepKg":4.5}`, `{"type":"fixed","kg":[20,24]}`,
`{"type":"plates"}` (uses the profile's `PlateInventory`), `{"type":"none"}`. Weights are stored in kg; the UI shows
the user's unit first.

Removal is soft (`status = removed`), so workout history keeps its links. Hard deletes happen only on account
deletion: private rows cascade with `owner_id`; public rows keep the data with `added_by`/`created_by` set to null.

### On the phone (SwiftData, GymData)
`Gym`, `EquipmentItem` and `GymListing` mirror the server rows plus:
- `visibility`: `device` (never uploaded), `synced` (private rows on the server, only with sync on), `shared` (public).
- `uploadState`: `local`, `queued`, `uploaded`, `failed(reason)`.
- `remoteId` for rows that exist on the server.

A Maps gym picked without an account is a local `Gym` with its `maps_place_id`. The app looks up the public gym by
that id to download its shared listings. If the gym isn't on the server yet, it stays local until the first share,
when `find_or_create_gym` creates it.

The current gym is a per-device preference (not synced): `nil` means today's behavior, with no adaptation.

## 5. Key behaviors

### Visibility and accounts
| Visibility | Stored | Account |
|---|---|---|
| This phone only (default) | SwiftData only | No |
| Synced to my account | Private server rows through the existing `SyncEngine` | Yes, with sync on |
| Shared at this gym | Public server rows | Yes |

- Everything except sharing, confirming, reporting and blocking works with no account: gyms, equipment with photos,
  plan adaptation, Build workout, logging.
- Browsing a public gym's shared equipment needs no account (anon reads).
- At a public gym the user can keep their own listings "This phone only"; the rules use shared listings plus the
  user's own.
- Sharing is always an explicit tap ("Share with this gym"), which asks for Sign in with Apple if needed. Nothing is
  uploaded in the background except queued writes the user already asked for.
- Private gyms (home) can never be shared; they can only be synced.

### Gym picker and location
- The picker lists My gyms (with visibility badges), an Apple Maps search (`MKLocalSearch`, point-of-interest filter
  `.fitnessCenter`) and "+ Add a private gym" (name, optional address).
- On Today's appearance, at most once every 30 minutes, the app asks for one location fix (When In Use). If one of My
  gyms, or a Maps fitness center, is within 150 m and isn't the current gym, Today shows "You're at X?". It never
  switches gyms by itself.
- No location permission: no suggestion; search and My gyms still work. Maps offline: My gyms and "Add a private gym".

### Adding equipment (4 steps)
1. **Photo:** the camera opens at once, with the reminder "Photograph the equipment, not people. Faces are blurred
   automatically." The user can pick from the library or skip the photo.
2. **Kind:** big tiles for common kinds, grouped (machines; free weights, benches and racks), plus search.
3. **Duplicate check:** if the gym already lists the kind, show those listings with photos and "Yes, that's it (+1
   confirm)". Then catalogue items of that kind from other gyms (by brand and model, with how many gyms list them),
   then "Generic", then "No, it's a different one". Skipped when the gym has no listing of that kind.
4. **Loads and sharing:** a stepper for a weight stack's maximum, weight chips for fixed sets (e.g. 44 and 53 lb), or
   nothing for plate-loaded and bodyweight kinds. Visibility (default "This phone only"), optional note, Save.

Confirming someone else's listing without an account stores nothing on the server; the button asks for sign-in.

### Photos (`GymPhotoProcessor`, before anything is saved)
1. Downscale to a 1600 px long edge; JPEG quality 0.7 (target about 200–400 KB). If the result is over 1 MB, encode
   again at 0.5; if it is still over 1 MB, reject with a message.
2. Blur faces: Vision face detection, then a strong blur over each face rectangle with padding.
3. Strip all metadata (EXIF, GPS, TIFF) when writing the JPEG.
4. A 400 px thumbnail for lists.

The cleaned image is what's stored on the phone and what's uploaded. Storage paths: `gym-photos/<uid>/<uuid>.jpg`
(public bucket, shared listings) and `gym-photos-private/<uid>/<uuid>.jpg` (synced private listings).

### Plan adaptation (`GymAdapter`, for the session only)
For each exercise in today's routine, when a current gym is set:
- Available (the matcher finds listings for every requirement group): keep it and link the listings.
- Not available: swap in the best available exercise, in the Swap screen's order (same target, then same body part;
  more-logged first; then `ExerciseRanking` preferences). The swap is shown with a SWAPPED badge and "for <planned>
  · no <kind> here", plus a note above the list ("1 exercise swapped for this gym. Your plan isn't changed.").
- Nothing fits: keep it, marked "not available here", for the user to remove or replace.
- Unmapped exercises are left as planned, unmarked (the app can't tell either way).
- The swapped-in exercise keeps the planned item's id, sets, reps and superset, drops the planned weight, and takes
  the default increment for its own equipment. Its weight comes from its own history through `ProgressionEngine`,
  fitted by `AvailableLoads`. A replacement is never an exercise already in today's list.

The routine and its progression history are never edited by the adapter.

### Build workout (`WorkoutBuilder`)
Input: muscle chips, length, gym inventory, library, requirements, the last workouts, preferences, a seed.

Muscle chips → `MuscleGroup`: Chest = chest; Back = upper back, lats, lower back, traps; Shoulders = shoulders;
Arms = biceps, triceps, forearms; Legs = quads, hamstrings, glutes, calves, adductors, abductors; Core = abs.

1. **Candidates:** rep-mode exercises whose target maps (`MuscleTaxonomy`) to a selected group, that are available at
   the gym, and not marked `never`.
2. **Slots:** 30 min → 3; 45 min → 4, or 5 with two or more chips; 60 min → 6. Filled round-robin across the
   chips. The finished list shows exercises that train two or more muscle groups (`MuscleTaxonomy.contributions`)
   first, then the rest, then bodyweight fills.
3. **Variety:** skip exercises that appear in the last 3 workouts that trained the same muscle group (a workout
   counts for a chip when one of its exercises has a primary muscle in it). If a slot has no other candidate, use a
   recent one, the least recently done first, with a REPEAT badge and the reason ("also <weekday> · no other
   <group> option here").
4. **Ranking:** `more` first, `less` last; then the score of the exercise's load listing (confirmations, plus one
   for the user's own listing); then how often the user has logged the exercise. Ties are broken by the seed.
5. **Spread:** at most 2 exercises on the same machine listing (a kind that bears load and isn't a free weight:
   weight stacks, cables, plate-loaded machines, the Smith machine). Dumbbells, kettlebells, barbells and benches
   aren't capped. Slots that can't be filled are dropped: the workout gets shorter, never padded with invented
   equipment.
6. **Thin inventory:** when slots are dropped or a chip has fewer candidates than slots, show "Only N <group> items
   catalogued at <gym> so far. Add a photo to unlock more variety." with an "+ Add equipment" link. N is the number
   of active listings at the gym used by at least one candidate exercise for that group.
7. **Bodyweight fill:** exercises with no requirements may fill remaining slots after equipment exercises, marked
   "no equipment".
8. **Sets, reps, weight:** `ModeDefaults` for sets and reps; weight from `ProgressionEngine` on the exercise's own
   history, then fitted by `AvailableLoads`: a weight stack caps at its maximum and snaps to its step (never below
   one step); a fixed set picks the nearest weight it has (ties go to the lighter one). Past the heaviest weight it
   stays there and adds 2 reps to the target.
9. **Determinism and Rebuild:** the seed is the day (UTC), so the same input gives the same workout. Rebuild passes
   the current result's exercises as `avoid`: they are used again only when nothing else fits, and that isn't
   marked as a repeat.

The built workout replaces Today's list for this session (like switching routines); the plan isn't changed.

### Sharing, confirming, reporting (server functions)
All are `security definer` functions callable by `authenticated` only, and rejected for MCP clients
(`is_mcp_client()`).

| Function | Does | Daily limit per user |
|---|---|---|
| `find_or_create_gym(maps_place_id, name, address, lat, lng)` | Returns the existing public gym for a Maps place or creates it | 10 creations |
| `share_listing(gym_id, item, loads, quantity, notes, photo_path, force_new)` | Creates a public listing. When the gym already has active listings of that kind and `force_new` is false, returns them instead. Checks that `photo_path` is in the caller's folder | 30 |
| `confirm_listing(listing_id)` | Adds the caller's confirmation (idempotent) | 100 |
| `report_content(target_type, target_id, reason, note)` | One report per user per target. At 3 unresolved reports from different users the target's status becomes `flagged` | 20 |
| `block_author(target_type, target_id)` / `unblock_all()` | Blocks the author of a gym, item or listing (the client never sees user ids), or clears the caller's blocks | — |
| `moderate_content(target_type, target_id, action)` | Admins only: `restore` (status active, reports resolved) or `remove` | — |

Limits live in `DomainLimits` and the existing drift guard (`_shared/domain-limits-drift.test.ts`) covers them.

### Reads and access rules
- Public gyms, items and listings with `status = active`: readable by `anon` and `authenticated`. For signed-in users
  the policy also hides listings and items whose author the user has blocked.
- The author of a flagged item can still read it ("Under review" in the app). Admins can read everything.
- Private gyms and private listings: only `owner_id = auth.uid()`, with the existing pattern (writes blocked for MCP
  clients, reads gated by `mcp_flag('gyms')`).
- Direct table writes are not granted for public rows; they go through the functions above.
- Reads go through `security_invoker` views (`public_gyms`, `public_equipment_items`, `public_gym_equipment`) that
  drop the author columns and add `is_mine`. Direct `select` on `added_by`, `created_by` and `owner_id` is revoked
  from `anon` and `authenticated`.
- Storage: public bucket readable by anyone; insert only into the caller's own folder, JPEG only, 1 MB limit; no
  update; delete own objects; admins may delete any object in `gym-photos`. The private bucket is owner-only.

### Offline and the outbox
- Opening or picking a public gym downloads its active listings and thumbnails and caches them. Refresh on open (at
  most every 6 hours) or pull to refresh.
- Share, confirm, report and block go into `ShareOutbox` (persisted). It runs when online and signed in, uploads the
  photo first, then calls the function. Items show "Waiting to upload"; failures show the reason and a Retry.
- A `share_listing` response with duplicates is shown as the Step 3 screen when the user next opens the item.

### Moderation UI
- Every shared gym, item and listing has Report (reason list plus optional note) in its menu. User profiles aren't a
  thing, so Block is offered on a listing ("Hide everything from this user"). Settings has "Unblock everyone".
- Settings → Moderation, visible only to admins: flagged items with photo, reasons and counts, plus Restore and
  Remove. Remove also deletes the photo object.
- Settings → About lists a contact address for content complaints (App Store user-generated content guideline).

### Account deletion
Deletes private gyms, private listings, the user's confirmations, reports, blocks and all of the user's photos in
both buckets. Shared listings and gyms stay, without the author (they describe the gym).

### Claude (MCP)
- `list_gyms`: the user's synced private gyms, plus public gyms the user trained at or shared to (from `workouts.gym_id`
  and `gym_equipment.added_by`).
- `get_gym_equipment(gym_id)`: the gym's active listings visible to the user (kind, item, loads, quantity, confirm
  count, visibility) plus the library exercise ids that are available there, computed from `exercise_requirements`.
- Both are read-only and gated by a new `mcp_flag('gyms')`, which the user can switch off like the existing flags.
- "This phone only" data never reaches the server, so Claude can't see it. The Claude settings screen says so.
- Proposals are unchanged. When a proposal adds an exercise the gym can't do, `GymAdapter` swaps it at workout time.

## 6. UI

- **Today:** a glass gym chip under the title (pin icon, gym name, chevron) that opens the picker; tapping the name
  in the picker header opens the gym's equipment. "Build workout" (glass) sits next to "Start workout" (prominent).
  Linked listings' photos replace the exercise thumbnail when present.
- **Gym equipment:** title, address, item count; coverage badges per chip group, amber when a group has fewer than 3
  items; photo tiles grouped by category with loads and a badge (`✓ N`, `Only me`, `Flagged`, `Under review`);
  floating "+ Add equipment".
- **Build workout:** a sheet with 6 large muscle chips (multi-select), a 30 / 45 / 60 min segmented control, Build.
  The result screen lists exercises with the listing photo, sets, reps and load; the thin-inventory banner; REPEAT
  badges; Rebuild and Start.
- Gym-floor rules: touch targets ≥ 44 pt (main actions full width), Dynamic Type, high contrast in the dark theme, no
  typing needed except search and optional notes.
- The tab bar doesn't change.

## 7. Error handling

| Situation | Behavior |
|---|---|
| No signal | Cached gyms, adaptation and Build work; writes wait in the outbox |
| Signed out and the user taps Share, Confirm, Report or Block | Sign in with Apple sheet; nothing is queued until signed in |
| Daily limit hit | The function's error is shown as "You've shared a lot today. Try again tomorrow." The item stays local |
| Duplicate returned by `share_listing` | Step 3 is shown with the existing listings |
| Photo still too big after re-encoding | "This photo couldn't be made small enough. Try another one." |
| Vision fails | The photo is not saved; the user can retry or skip the photo (no unblurred fallback) |
| Location denied or Maps offline | No suggestion; My gyms and "Add a private gym" stay available |
| Listing removed after use | History keeps the exercise and the link; the item shows as removed |
| Unknown kind or item id from the server (newer app version) | The listing is ignored by the rules and shown as "Update the app to use this item" |

## 8. Security and privacy

- Public user-generated data is new for this app. All writes go through functions with input validation (lengths,
  enums, `loads` shape, numeric ranges from `DomainLimits`), rate limits and ownership checks.
- Photos are cleaned on the phone before saving (faces blurred, metadata stripped); the upload path is tied to the
  caller's folder.
- "This phone only" data has no code path to the network; a test guards it.
- Anonymous reads expose only public, active rows. Uploader ids are never returned to other users (the views expose
  `is_mine`, and blocks are resolved inside the policy).
- MCP stays read-only for gym data.
- The App Store user-generated content guideline is covered by: report, auto-hide, admin removal, block, and a
  published contact address.

## 9. Testing

| What | Where | Tests |
|---|---|---|
| `InventoryMatcher`, `GymAdapter`, `WorkoutBuilder`, `AvailableLoads` | GymCore, Swift Testing (keeps the ≥ 90% coverage gate) | Criterion 5 as a property test over generated inventories; max 2 per machine listing; thin-inventory notices; repeat reasons; fixed-set rounding (20, 24 kg) and the rep fallback; determinism and Rebuild |
| Criteria 1 and 3 | GymCore | Scenario tests with fixture inventories |
| Requirements data | `node --test scripts/map-equipment-requirements.test.mjs` | Mapping rules, the machine table, review file output; drift test between the bundled JSON and the seed |
| Access rules, functions, buckets | pgTAP, `supabase/tests/database/gyms.test.sql` | Anon reads only public active rows and can't write; private rows owner-only; share, confirm, report, block, moderate; limits; 3-report auto-hide and restore; blocked authors hidden; MCP clients can't write and are gated by `mcp_flag('gyms')`; bucket folder, size and type rules |
| Criterion 4 | pgTAP plus XCUITest | `share_listing` returns existing listings; the Step 3 screen |
| Criterion 2 | Docker suite, opt-in `GYM_E2E=1` in `scripts/test-all.sh` | Two local test users plus an anon client |
| Criterion 6 | GymData with the fake transport | No request for `device` rows, signed in or not; outbox retry after offline |
| `GymPhotoProcessor` | App unit tests with a fixture photo containing a face | Long edge ≤ 1600 px, < 1 MB, no EXIF/GPS, face region blurred |
| MCP tools | deno with `FakeDb` | `list_gyms`, `get_gym_equipment`, flag off → denied, no device data |
| Screens | XCUITest | Add equipment with a fixture photo, picker with a simulated location, Build workout, SWAPPED badge on Today; the existing accessibility and Dynamic Type audits include the new screens |

## 10. Milestones (each becomes an implementation plan)

1. **Rules and data:** kinds and requirements JSON, the mapping script and review file, GymCore units and tests.
2. **On the phone, no account:** SwiftData models, gym picker and locator, gym equipment screen, add flow, photo
   processor, Today adaptation and Build workout.
3. **Shared catalogue:** migration, access rules, functions, buckets, `GymCatalogClient`, `ShareOutbox`, sync of
   private gyms, the two-user suite.
4. **Moderation and Claude:** report, block, admin list, account deletion, MCP tools and flag.

## 11. Risks

| Risk | Mitigation |
|---|---|
| The requirements mapping is wrong for some exercises | The review file for the owner; unmapped exercises are never generated; reports with `wrong-info` |
| Thin catalogues at launch make Build feel empty | Thin-inventory banner with a direct add link; bodyweight fill; plan adaptation still works with partial data |
| Abuse or bad photos | Phone-side face blur, rate limits, 3-report auto-hide, admin removal, block |
| Orphan photos (uploaded, never linked) | Accepted for now; a cleanup job is a follow-up once the cloud project exists |
| Apple Maps ids change or a place is missing | Fallback to manual gyms; `maps_place_id` is unique but nullable |
| Shared features need the cloud project | Milestones 1–2 are useful alone; 3–4 run on the local stack until the owner approves the cloud project |
