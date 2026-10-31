# Plan 21: Shared gym catalogue

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** People at the same gym see each other's equipment. A user can share a listing with a gym, confirm someone
else's, and sync their private gyms to their account. A user with no account can browse. "This phone only" stays on the
phone.

**Architecture:** Public rows are written only by `security definer` functions and read through `security_invoker`
views (already drafted and tested in Task 1). On the phone, `GymData` gets a `GymCatalogTransport` protocol, a
`GymCatalogClient` that caches a gym's public listings as ordinary local rows, and a persisted `ShareOutbox`. `GymSync`
implements the protocol with Supabase and syncs private rows through the existing `SyncEngine`. The rules in GymCore
don't change: they keep reading `GymRepository.inventory(gymId:)`.

**Tech stack:** Postgres, pgTAP, Supabase Storage, Swift 6.2, SwiftData, SwiftUI, Swift Testing, XCUITest.

**Spec:** `docs/specs/2026-10-30-gym-equipment-design.md`, sections 4, 5, 7, 8, 9. Criteria 2, 4 and 6 are closed here.

**Branch:** `feat-gym-shared`, stacked on `feat-gym-phone`. No push. Supabase stays local.

---

## Decisions this plan makes

Each of these settles something the spec leaves open.

1. **Where the code lives.** The spec puts `GymCatalogClient` and `ShareOutbox` in GymData, which can't depend on
   GymSync. So GymData owns the protocol `GymCatalogTransport` and the plain value types it speaks. GymSync implements it
   as `SupabaseGymCatalogTransport`. Tests in GymData use a fake.
2. **Ids.** A shared or synced listing keeps the phone's id on the server (`share_listing(p_listing_id, …)`), so a retry
   after a lost response finds the same row. A cached listing from someone else uses the server's id as its local id. So
   for listings `remoteId == id` once the row is on the server. Gyms differ: a Maps gym has a local id and a server id
   (`remoteId`), because two phones can pick the same place. A synced private gym keeps the phone's id on the server.
3. **Visibility options.** A private gym offers "This phone only" and "Synced to my account". A Maps gym offers "This
   phone only" and "Shared at this gym". The SQL still allows a private listing on a public gym; the app doesn't offer it
   yet because the rows would mix two sync paths at one gym for little benefit.
4. **Syncing a listing syncs its gym.** Choosing "Synced to my account" marks the private gym `synced` too. A `device`
   listing at a synced gym stays on the phone.
5. **Item reconciliation.** `share_listing` may store a branded listing under an existing item with a different id from
   the phone's. On the next refresh of the gym, the listing's `itemId` is repointed to the server's item. An unreferenced
   local item row stays; it's a few bytes and `catalogueItems` only counts items with listings.
6. **Thumbnails.** The server holds one image per listing (at most 1 MB). The phone downloads it once, saves it through
   `GymPhotoStore` and makes the thumbnail locally. Storage image transforms aren't used, so the cloud project doesn't
   need a paid feature.
7. **Who owns an outbox row.** Each row records the user who queued it. The outbox runs only rows of the signed-in user,
   so one person's queued share can't be uploaded under another account after a sign-out. A wipe removes all rows.
8. **Local links stay local.** A workout's link to a `device` gym is never sent. A pull that brings back `gym_id = null`
   doesn't clear a local link: the server can't know about it.
9. **Signing out keeps what only this phone has.** `resetAccountData()` (used by sign-out and the account switch) keeps
   `device` gyms, listings and their photos, and removes `synced` rows and cached `shared` rows, with their photo files,
   because those are safe on the server. It clears `catalogRefreshedAt`, so the next open downloads again. A Maps gym with
   a `device` listing stays. A gym left with no listings and only ever known from the server goes. Queued outbox rows of
   that user are dropped and their listings go back to `device`, `.local`: nothing is lost, the share just didn't happen.
   `resetAll()` (Erase All, Delete Account) still removes everything.
10. **Photo names carry no user.** Each upload gets a new `<uuid>.jpg`, with no folder, in either bucket. A folder per user
    would give every reader of a public URL the uploader's id. The name is stored in `remotePhotoPath` as soon as the
    upload succeeds, so a retry skips the upload: once a listing uses a name, the bucket refuses that name again.
11. **Private text stays out of the catalogue.** A synced listing sends its kind's generic item id and keeps brand and
    model in `private_brand` and `private_model`. Clients can't create catalogue items directly; only `share_listing`
    does. So a brand typed for a private listing can never become public.
12. **The phone shows the name Apple Maps gave.** The first person to share at a place sets the server's name, so a
    refresh never overwrites a Maps gym's local name, address or coordinates. Only its `remoteId` comes from the server.
13. **One bad row never breaks a gym.** Transports decode rows one at a time. A row that can't be read is skipped and
    logged; a row with an unknown `loads` shape comes back with `loads == nil`.
14. **A listing with no photo can borrow one from the catalogue.** `public_equipment_items` returns `photo_path` and
    `photo_listing_id`, worked out from the item's active public listings, so moderation needs no clean-up. The phone caches
    both on `EquipmentItemRecord` and loads the picture by URL through the photo loader; it isn't saved through
    `GymPhotoStore` and never reaches `photoFile` or `remotePhotoPath`, so it's never uploaded again and `share_listing`'s
    "the caller's own, unused photo" rule is untouched. Order on screen: own photo, this, plan 20's stock photo, placeholder.

---

## File map

| File | Does |
|---|---|
| `supabase/migrations/20261030000001…06` | Tables, functions, buckets, seed, workout links, moderation (written, tested) |
| `ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift` | Gym limits, moved from `GymRepository` |
| `ios/Packages/GymData/Sources/GymData/Gym/GymCatalogTransport.swift` | Protocol and values |
| `ios/Packages/GymData/Sources/GymData/Gym/GymCatalogClient.swift` | Lookup, cache, refresh |
| `ios/Packages/GymData/Sources/GymData/Gym/ShareOutbox.swift` | Persisted queue and runner |
| `ios/Packages/GymData/Sources/GymData/Records/ShareOutboxRecord.swift` | The queue's row |
| `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+Gyms.swift` | Dirty rows, tombstones, `applyRemote` |
| `ios/Packages/GymSync/Sources/GymSync/SupabaseGymCatalogTransport.swift` | Views, functions, Storage |
| `ios/Packages/GymSync/Sources/GymSync/DTO/GymDTO.swift`, `GymListingDTO.swift` | Private rows |
| `ios/GymRollins/App/AppEnvironment+GymCatalog.swift` | Wiring, triggers, share and confirm actions |
| `ios/GymRollins/Features/Gyms/GymVisibilityPicker.swift`, `ShareStatusRow.swift`, `SignInForSharingSheet.swift` | UI |
| `scripts/test-gym-e2e.sh`, `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/GymCatalogE2ETests.swift` | Two users plus anon |

---

### Task 1: Server side

The migrations and tests are written and pass (395 database tests, after a security review by an independent agent).
This task adds the limits and commits.

**Files:**
- Commit: `supabase/migrations/20261030000001`, `02`, `03`, `04`, `05`, `scripts/gen-equipment-seed.mjs` and its test,
  `supabase/tests/database/gyms.test.sql`, and the adjusted `security.test.sql` and `exercise_photos_bucket.test.sql`.
  `06` and `gym_moderation.test.sql` belong to plan 22, but `06` also holds `delete_my_account`; commit them here too so
  every migration has run together, and plan 22 starts from a tree with no uncommitted SQL.
- Modify: `DomainLimits.swift`, `supabase/functions/_shared/domain-limits.ts`, `GymRepository.swift`, `scripts/test-all.sh`

- [ ] **Step 1: Run `scripts/test-db.sh`.** Expected: `Result: PASS`, 395 tests.
- [ ] **Step 2: Move the limits.** Add to `DomainLimits` in Swift and to `domain-limits.ts` (the drift guard compares
  names, so use the same ones):
  ```swift
  // Gyms and equipment
  public static let gymNameMax = 120
  public static let gymAddressMax = 300
  public static let listingQuantity: ClosedRange<Int> = 1...50
  public static let listingNotesMax = 280
  public static let itemBrandMax = 60
  public static let itemModelMax = 80
  public static let listingStackKg: ClosedRange<Double> = 0.25...1_000
  public static let listingStepKg: ClosedRange<Double> = 0.25...50
  public static let listingFixedWeightsMax = 60
  public static let listingFixedKg: ClosedRange<Double> = 0.25...500
  public static let privateGymsMax = 100
  public static let privateListingsMax = 1_000
  // Daily limits per user, enforced by the server functions
  public static let dailyGymCreations = 10
  public static let dailyShares = 30
  public static let dailyConfirmations = 100
  public static let dailyPhotoUploads = 60
  ```
  `GymRepository` reads these instead of its own constants. Compare each number with
  `20261030000001_gyms.sql` and `20261030000002_gym_functions.sql` by reading them; if one differs, the SQL wins and the
  difference goes in your report. The pgTAP suites already assert the SQL's bounds through behaviour, so no new ones are needed
  there.
- [ ] **Step 3: Pin the generic item ids.** Add `GymRepositoryTests.genericItemIdMatchesTheServerSeed`: the generic item
  for `dumbbells` has id `cdd9d434-9eca-5d33-8406-2bdea6b4c561`, the value in `20261030000004_equipment_seed.sql`.
- [ ] **Step 4: Add to `scripts/test-all.sh`**, after the existing node suites:
  ```bash
  echo "==> Equipment seed generator (node test, drift against the migration)"
  node --test "$ROOT/scripts/gen-equipment-seed.test.mjs"
  node "$ROOT/scripts/gen-equipment-seed.mjs" --check
  ```
- [ ] **Step 5: Verify and commit.** Run `scripts/test-db.sh`, the deno `_shared` tests, `swift test` in GymCore and
  GymData. Commit: `feat(db): shared gym catalogue tables, functions, buckets and seed`.

---

### Task 2: `GymCatalogTransport` and `GymCatalogClient`

**Files:**
- Create: `GymData/Gym/GymCatalogTransport.swift`, `GymData/Gym/GymCatalogClient.swift`, `GymDataTests/FakeGymCatalogTransport.swift`, `GymDataTests/GymCatalogClientTests.swift`
- Modify: `Records/GymRecords.swift`, `Values/GymValues.swift`, `Repositories/GymRepository.swift`

- [ ] **Step 1: Add the fields.** All optional or defaulted, so the store migrates lightly.
  - `GymRecord`: `catalogRefreshedAt: Date?`.
  - `GymListingRecord`: `remotePhotoPath: String?`, `confirmedByMe: Bool = false`, `duplicatesData: Data?`.
  - `UploadState` gains `.waitingForChoice`, meaning `share_listing` returned duplicates.
- [ ] **Step 2: Define the protocol exactly:**
  ```swift
  /// The server side of the shared catalogue. Reads work with no account; writes need a signed-in user.
  public protocol GymCatalogTransport: Sendable {
      func publicGym(mapsPlaceId: String) async throws -> RemoteGym?
      func publicListings(gymId: UUID) async throws -> [RemoteListing]
      func publicItems(kindId: String) async throws -> [RemoteItem]
      func findOrCreateGym(mapsPlaceId: String, name: String, address: String?, latitude: Double?,
                           longitude: Double?) async throws -> UUID
      func share(_ request: ShareRequest) async throws -> ShareResult
      func confirm(listingId: UUID) async throws -> Int
      /// Uploads to `gym-photos/<name>`. A photo the caller already uploaded under that name counts as uploaded.
      func uploadSharedPhoto(_ data: Data, name: String) async throws -> String
      func publicPhotoURL(path: String) -> URL?
  }

  public struct RemoteGym: Sendable, Equatable { public let id: UUID, name: String, address: String?, latitude: Double?, longitude: Double?, mapsPlaceId: String? }
  public struct RemoteItem: Sendable, Equatable { public let id: UUID, kindId: String, brand: String?, model: String?, gymCount: Int, photoPath: String?, photoListingId: UUID? }
  public struct RemoteListing: Sendable, Equatable {
      public let id: UUID, gymId: UUID, itemId: UUID, kindId: String, brand: String?, model: String?
      public let photoPath: String?, loads: ListingLoads?, quantity: Int, notes: String?
      public let status: String, confirmCount: Int, isMine: Bool, confirmedByMe: Bool
  }
  public struct ShareRequest: Sendable, Equatable {
      public let listingId: UUID, gymId: UUID, kindId: String, brand: String?, model: String?
      public let loads: ListingLoads, quantity: Int, notes: String?, photoPath: String?, forceNew: Bool
  }
  public enum ShareResult: Sendable, Equatable { case created(UUID), duplicates([RemoteListing]) }
  public enum GymCatalogError: Error, Equatable { case signedOut, dailyLimit, offline, gymNotShareable, photoMissing, rejected(String) }
  ```
  `loads` is optional because a newer app version may store a shape this one can't read.
- [ ] **Step 3: Write the failing tests** in `GymCatalogClientTests` against a fake transport:
  - `refreshCachesPublicListingsAsLocalRows`: a Maps gym with `remoteId` nil finds its server gym, sets `remoteId`, and
    stores two listings with `visibility == .shared`, `isOwn` from `isMine`, `id == remoteId`.
  - `aDeviceListingAtTheGymIsLeftAlone`.
  - `aListingGoneFromTheServerIsRemovedLocallyAndItsPhotoReturned`: only `.shared` rows that aren't queued.
  - `aListingWithAnUnreadableLoadsShapeIsKeptButNotUsable`: stored with status `unsupported`, and left out of
    `inventory(gymId:)`.
  - `anUnknownKindIsLeftOutOfTheInventory`: `RemoteListing.kindId` not in the kinds catalogue.
  - `aPrivateGymNeverCallsTheServer`: `mapsPlaceId` nil and visibility not synced means zero transport calls.
  - `refreshSkipsWithinSixHoursUnlessForced`, with an injected clock.
  - `aGymNotOnTheServerStaysLocal`: `publicGym` returns nil, no error, `catalogRefreshedAt` set.
  - `theItemIdIsRepointedToTheServersItem`: decision 5.
  - `aRefreshKeepsTheNameAppleMapsGave`: decision 12. The server's name, address and coordinates differ, and the local
    ones stay.
  - `offlineLeavesTheCacheAlone`: the transport throws `.offline`, rows unchanged, no throw to the UI.
- [ ] **Step 4: Run them.** Expected: compile failure, then failures once stubbed.
- [ ] **Step 5: Implement `GymCatalogClient`:**
  ```swift
  @MainActor public final class GymCatalogClient {
      public init(repository: GymRepository, transport: GymCatalogTransport, knownKinds: Set<String>, now: @escaping () -> Date)
      /// Returns the photo paths to download and the local files to delete.
      public func refresh(gymId: UUID, force: Bool) async throws -> CatalogRefresh
      public func items(kindId: String) async -> [CatalogueItem]
  }
  public struct CatalogRefresh: Sendable, Equatable { public let photosToFetch: [PhotoFetch], filesToDelete: [String] }
  ```
  `items(kindId:)` merges `publicItems` with local `catalogueItems`, using the local list alone when offline.
- [ ] **Step 6: Run the tests and all of GymData.** Commit: `feat(data): cache a gym's shared listings`.

---

### Task 3: `ShareOutbox` and the "stays on the phone" guard

**Files:**
- Create: `Records/ShareOutboxRecord.swift`, `Gym/ShareOutbox.swift`, `GymDataTests/ShareOutboxTests.swift`, `GymDataTests/StaysOnThePhoneTests.swift`
- Modify: `GymStore.models`, `SyncStore.resetAll`

- [ ] **Step 1: Write the failing tests:**
  - `sharingCreatesTheGymThenUploadsThePhotoThenCallsTheFunction`: asserts the order of fake transport calls, a name of a
    fresh lowercase uuid plus `.jpg` with no folder and no user id, and that the listing ends `.shared`, `.uploaded`, with
    `remotePhotoPath` set.
  - `aRetryAfterALostResponseDoesNotShareTwice`: the fake throws after storing, the next run skips the upload because
    `remotePhotoPath` is set, gets `.created` for the same id, and the outbox empties.
  - `aMissingPhotoOnTheServerIsUploadedAgain`: `.photoMissing` clears `remotePhotoPath`, so the next run uploads under a
    new name.
  - `aGymUnderReviewShowsAMessage`: `.gymNotShareable` leaves the listing `.device`, `.failed`, with "This gym is under
    review. Try again later."; the row leaves the queue.
  - `offlineKeepsTheItemQueued`: state stays `.queued`, the error isn't shown as a failure.
  - `dailyLimitLeavesItLocalWithTheMessage`: the listing goes back to `.device`, `.failed`, with
    "You've shared a lot today. Try again tomorrow."; the row leaves the queue.
  - `duplicatesWaitForTheUsersChoice`: `.waitingForChoice`, with the listings stored in `duplicatesData`.
  - `keepingTheExistingOneConfirmsItAndRemovesMine`: the local row goes, its photo file is returned for deletion and the
    confirm is queued.
  - `sharingAnywaySendsForceNew`.
  - `aRowOfAnotherUserIsLeftAlone`: decision 7.
  - `confirmIsIdempotentAndUpdatesTheCount`: set from the server's answer.
  - `retryRequeuesAFailedItem`.
  - `aPrivateGymCanNeverBeShared`: `enqueueShare` throws, and no row is written.
  - `resetAllRemovesTheQueue`.
- [ ] **Step 2: Run them.** Expected: compile failure.
- [ ] **Step 3: Implement:**
  ```swift
  @Model public final class ShareOutboxRecord {
      @Attribute(.unique) public var id: UUID
      public var kindRaw: String      // "share", "confirm" (plan 22 adds "report", "block")
      public var targetId: UUID       // the local listing id
      public var ownerId: UUID
      public var forceNew: Bool
      public var createdAt: Date
  }

  @MainActor public final class ShareOutbox {
      public init(repository: GymRepository, transport: GymCatalogTransport, photoData: @escaping (String) -> Data?, now: @escaping () -> Date)
      public func enqueueShare(listingId: UUID, ownerId: UUID, forceNew: Bool = false) throws
      public func enqueueConfirm(listingId: UUID, ownerId: UUID) throws
      /// Runs the signed-in user's rows oldest first. Stops at the first offline error; other errors are per row.
      public func run(userId: UUID?) async
      public func retry(listingId: UUID, ownerId: UUID) throws
      public func keepExisting(listingId: UUID, existingId: UUID, ownerId: UUID) throws -> String?
      public var pendingCount: Int { get }
  }
  ```
  `run(userId: nil)` does nothing. A re-entrant `run` returns at once, so two triggers can't send a row twice.
- [ ] **Step 4: Write `StaysOnThePhoneTests` (criterion 6).** A fake transport that records every call, and a `device`
  Maps gym and a `device` private gym, each with listings and photos:
  - browsing with `refresh` on the private gym makes no calls;
  - `refresh` on the Maps gym makes only `publicGym` and `publicListings` calls, which carry the place id, never a row of
    the user's;
  - signed in, `run` with an empty queue makes no calls;
  - `SyncStore.dirtyGyms()` and `dirtyGymListings()` (Task 5 adds them; keep this test here and extend it there) return
    nothing for `device` rows.
- [ ] **Step 5: Run the tests and all of GymData.** Commit: `feat(data): a persisted outbox for sharing and confirming`.

---

### Task 4: `SupabaseGymCatalogTransport`

**Files:**
- Create: `GymSync/SupabaseGymCatalogTransport.swift`, `GymSyncTests/GymCatalogDTOTests.swift`, `GymSyncIntegrationTests/GymCatalogIntegrationTests.swift`

- [ ] **Step 1: Write failing decoding tests** in `GymCatalogDTOTests`: a `public_gym_equipment` row JSON decodes to
  `RemoteListing`, with all four load shapes and an unknown one (`loads == nil`); **a response with one unreadable row
  returns the other rows** (decision 13); a `share_listing` response decodes to each `ShareResult`; a PostgREST error with
  `daily_limit` maps to `.dailyLimit`, `gym_not_shareable` to `.gymNotShareable`, `photo_missing` to `.photoMissing`, a
  network error (`AuthFailure.isNetwork`) to `.offline`, and an auth error to `.signedOut`.
- [ ] **Step 2: Write failing integration tests** against the local stack, following `IntegrationSupport.swift`. Add them
  to the filter in `scripts/test-sync-integration.sh`:
  - signed in, share with a photo, then read it back through an anon client, including `is_mine == false` and the public
    photo URL returning 200 with `image/jpeg`;
  - a second share of the kind returns `.duplicates`, and `forceNew` creates it;
  - uploading the same photo twice succeeds;
  - after a listing uses a name, deleting and uploading that name again is refused;
  - a photo URL contains no user id;
  - sharing another user's uploaded photo is refused.
- [ ] **Step 3: Implement.** Reuse `SupabaseTransport`'s `mappingRejections` and `SyncJSON` date handling where they fit.
  Lowercase every UUID in Storage paths and function arguments, because the policies and `share_listing` compare against
  lowercase text. Read views only with an explicit `select` list. Storage answers HTTP 400 for both a duplicate and a
  policy refusal. The body tells them apart (`"statusCode":"409","error":"Duplicate"`), and only the duplicate counts as
  already uploaded. Decode rows one at a time, per decision 13. Checked against the local stack on 2026-10-30: `owner_id`
  is set when the insert policy runs, and PostgREST upserts on `gyms` and `gym_equipment` work with the column grants.
- [ ] **Step 4: Run** `swift test --filter GymCatalogDTOTests` and `scripts/test-sync-integration.sh`. Commit:
  `feat(sync): the Supabase side of the gym catalogue`.

---

### Task 5: Sync private gyms and listings

**Files:**
- Create: `GymData/Sync/SyncStore+Gyms.swift`, `GymSync/DTO/GymDTO.swift`, `GymSync/DTO/GymListingDTO.swift`, tests beside the existing DTO and engine tests
- Modify: `SyncEntity`, `GymRecords.swift`, `GymRepository.swift`, `SyncTransport.swift`, `SupabaseTransport.swift`, `SyncEngine+Rounds.swift`, `SyncEngine.swift`

- [ ] **Step 1: Read `SyncStore+Preferences.swift`, `SyncStore+Workouts.swift` and `DTO/RoutineDTO.swift`** and follow them.
- [ ] **Step 2: Add the sync fields** to `GymRecord` and `GymListingRecord`: conform to `SyncTracked`, adding whatever
  it needs (`dirty`, `serverUpdatedAt`, `deletedAt`).
- [ ] **Step 3: Write the failing tests:**
  - `dirtyGyms` and `dirtyGymListings` only return rows with `visibility == .synced`; a `device` row, and a `shared` row
    (written only through the outbox), never appear;
  - deleting a synced gym or listing leaves a tombstone until it's pushed and then removes it; deleting a `device` row
    removes it at once, as now;
  - `applyRemote` inserts, updates through `remoteWins`, and removes on `deleted_at`, returning the photo file to delete;
  - `applyRemote` never touches a row with `visibility` of `device` or `shared`;
  - making a private gym synced marks it and its `synced` listings dirty, and leaves its `device` listings alone;
  - a Maps gym can't be made synced (decision 3);
  - decision 9, through `resetAccountData()`: `device` rows and photo files stay; `synced` and cached `shared` rows and
    their photo files go; a queued share's listing returns to `device`, `.local` and its outbox row goes;
  - engine test: push order is gyms, then listings, before workouts, and pull order is the same;
  - engine test: a synced listing with a photo uploads to `gym-photos-private/<new uuid>.jpg` first and sends that
    `photo_path`; a failed upload leaves the row dirty and the rest of the round continues;
  - a synced listing with a brand sends the generic item id and `private_brand`, and comes back with the same brand;
  - engine test: a pulled listing with a `photo_path` and no local file downloads it; a failed download doesn't fail the
    round and is retried at the next pull.
- [ ] **Step 4: Run them.** Expected: compile failure.
- [ ] **Step 5: Implement.** Add `.gyms, .gymListings` to `SyncEntity` after `muscleTargets` and before `bodyweight`.
  The transport gets `push(gyms:)`, `push(gymListings:)`, `pullGyms(since:)`, `pullGymListings(since:)`, with no-op
  defaults in the `extension SyncTransport` so older test doubles compile. It also gets:
  ```swift
  func uploadPrivatePhoto(_ data: Data, name: String) async throws -> String
  func downloadPrivatePhoto(path: String) async throws -> Data
  ```
  `pullGymListings` selects `*,equipment_items(kind_id)` with `visibility=eq.private`. RLS limits private rows to the
  owner, and `owner_id` isn't readable, so don't filter on it; cached public rows never come through here. Per decision 11,
  a pushed listing sends `GymRepository`'s generic item id for its kind, plus `private_brand` and `private_model`. A pulled
  one finds or creates the local item with that kind, brand and model.
  The engine gets an optional `GymPhotoFiles` port (`data(file:)`, `save(_:file:)`), default nil, so existing tests
  compile. With nil, the engine sends the row without a photo and logs it.
- [ ] **Step 6: Extend the integration suite:** a private gym, listing and photo pushed by one client reach a second
  signed-in client of the same user; another user and anon see nothing, and the private photo's path returns an error.
- [ ] **Step 7: Run** GymData and GymSync tests, then `scripts/test-sync-integration.sh`, then extend
  `StaysOnThePhoneTests`. Commit: `feat(sync): private gyms and listings sync to the account`.

---

### Task 6: Workout links

**Files:**
- Modify: `Workout` and `WorkoutEntry` values in GymCore, their records and mapping in GymData, `DTO/WorkoutDTO.swift`, `SyncStore+Workouts.swift`, `SessionPlanner.swift`, `AppEnvironment+Gyms.swift`

- [ ] **Step 1: Write the failing tests:**
  - a workout started at the current gym stores `gymId`; each entry whose exercise has a load listing stores
    `gymListingId` (the same listing Today showed);
  - with no current gym, both are nil, and old records read back as nil;
  - `dirtyWorkouts` sends `gym_id` only when the gym has a `remoteId` and isn't `device`, and `gym_equipment_id` only when
    the listing is `shared` or `synced` with a `remoteId`. The server already accepts these (`20261030000005`) and turns a
    link the caller can't see into null;
  - **decision 8:** after a push that left the link out, a pull of the same workout with `gym_id = null` keeps the local
    `gymId`;
  - a pulled non-null `gym_id` resolves to the local gym with that `remoteId`, and stays nil when there's none;
  - a deleted gym leaves the workout readable, and the exercise still shows, with no crash on the dangling id.
- [ ] **Step 2: Run them.** Expected: compile failure.
- [ ] **Step 3: Implement.** `WorkoutDTO` encodes `gym_id` and `gym_equipment_id` only when present. Keep the fields
  optional in every initializer with a nil default, so existing call sites stay as they are.
- [ ] **Step 4: Run** GymCore, GymData, GymSync, and the app suites that touch sessions (`SessionPlannerTests`,
  `GymEnvironmentTests`), then `scripts/test-sync-integration.sh`. Commit: `feat(sync): workouts link their gym and equipment`.

---

### Task 7: The app

Screens are specified by behaviour, copy and identifiers. Identifiers are requirements.

**Files:**
- Create: `App/AppEnvironment+GymCatalog.swift`, `Features/Gyms/GymVisibilityPicker.swift`, `ShareStatusRow.swift`, `SignInForSharingSheet.swift`, `GymPhotoCache.swift`
- Modify: `AddEquipmentModel.swift`, `AddEquipmentDetailSteps.swift`, `AddEquipmentSteps.swift`, `GymEquipmentModel.swift`, `GymEquipmentView.swift`, `ListingDetailView.swift`, `GymPickerView.swift`, `LaunchOptions`

**Wiring.** `AppEnvironment` builds `GymCatalogClient` and `ShareOutbox` with a `SupabaseGymCatalogTransport`. In UI tests
a launch flag `-fakeGymCatalog` swaps in an in-memory fake with fixed listings, compiled out of Release like the others.

- `gymCatalogRefresh(gymId:force:)` calls the client, then downloads `photosToFetch` one at a time through `GymPhotoCache`
  (accepts only JPEG up to 1 MB, saves through `GymPhotoStore`, makes the 400 px thumbnail) and deletes `filesToDelete`.
- Triggers for `outbox.run`: after an enqueue, on app foreground, and on sign-in.
- Triggers for refresh: opening the equipment screen and choosing a gym, at most every 6 hours; pull to refresh forces it.
  Offline stays silent; the cached rows stay on screen.
- After a refresh, `gymsChanged` runs, so Today re-adapts to the new listings.

**Sign-in.** `SignInForSharingSheet` reuses the existing Sign in with Apple flow. Copy: title "Sign in to share", body
"Your gym's equipment stays yours until you share it. Nothing else leaves your phone." After success the original action
continues. Cancelling queues nothing.

**Add equipment, step 4.** `GymVisibilityPicker` (`add.visibility.device`, `add.visibility.shared`,
`add.visibility.synced`) shows the two options for the gym's type, with "This phone only" selected. Save with "Shared at
this gym" asks for sign-in if needed, saves the listing as `device` and `.queued`, enqueues the share and finishes the
flow. Save with "Synced to my account" asks for sign-in if needed and marks the listing and gym synced.

**Add equipment, step 3.** Other people's cached listings of the kind appear first, with photo and `✓ N`, each with
"Yes, that's it (+1 confirm)" (`add.confirm.<id>`). Your own listing shows "Already added" instead of the button.
Confirming asks for sign-in if needed, enqueues the confirm and closes the flow. Catalogue items from
`GymCatalogClient.items` appear next, with "N gyms", then "Generic", then "No, it's a different one".

**Equipment screen and listing detail.**
- Badges on tiles: `✓ N` for shared listings with confirmations, `Only me` for `device`, `Synced` for `synced`,
  `Waiting to upload` for `.queued`, and `Couldn't upload` for `.failed`.
- Listing detail shows `ShareStatusRow` (`listing.shareStatus`): the state in words, the failure reason with Retry
  (`listing.retry`), "Share with this gym" (`listing.share`) for a `device` listing at a Maps gym, and "+1 confirm"
  (`listing.confirm`) for someone else's that you haven't confirmed. Confirmed shows "You confirmed this".
- A listing in `.waitingForChoice` shows "This gym may already have it" and opens the step 3 list, with "Yes, that's it
  (+1 confirm)" and "No, it's a different one" (`listing.shareAnyway`).
- A row with status `unsupported` shows "Update the app to use this item", and isn't used by the rules.
- Removing someone else's shared listing isn't offered. Removing your own shared listing isn't offered either until plan
  22 adds moderation paths, so it says "Report a problem" there later; for now the menu leaves it out. Deleting a gym that
  has shared listings removes only the local rows and files, not the server rows.
- Pull to refresh on the screen.
- A listing with no photo of its own whose item has a catalogue photo (decision 14) shows it through `ListingPhotoView`, with
  the capsule "Other gym" (`listing.catalogPhoto`) and, in detail, "Photo from another gym. Add yours to show the real
  one here." (`listing.catalogPhotoNote`). Take Photo and Add a photo stay. Offline or on a failed load it falls through to
  the stock photo.

**Picker.** Badges on My gyms: `Only me`, `Synced`, or `Shared` when the gym has a `remoteId`. Private gyms get a "Sync to
my account" action in the gym's menu (`picker.sync.<id>`).

- [ ] **Step 1: Write failing unit tests** for the models: visibility options per gym type; a signed-out share asks for
  sign-in and queues nothing; a signed-in share queues and finishes; step 3 ordering; `Already added`; the badge for each
  state; `GymPhotoCache` rejects non-JPEG and files over 1 MB.
- [ ] **Step 2: Write failing XCUITests** with `-fakeGymCatalog`:
  `GymSharingUITests.testBrowsingWithNoAccountShowsSharedEquipment`, `testAListingWithoutAPhotoBorrowsTheCataloguePhoto`
  (adding one replaces it, also after reopening), `testShareAsksForSignIn` (cancel leaves it `Only
  me`), `testConfirmAsksForSignIn`, `testDuplicatesShowTheExistingListings`, `testAFailedShareOffersRetry`.
- [ ] **Step 3: Implement.** Keep files under 400 lines.
- [ ] **Step 4: Extend the audits.** Add the new states to `AccessibilityAuditUITests` and `DynamicTypeUITests`, with no
  exclusions.
- [ ] **Step 5: Run the unit and UI suites for gyms.** Commit: `feat(gyms): share, confirm and sync from the app`.

---

### Task 8: Two users and an anonymous client

**Files:**
- Create: `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/GymCatalogE2ETests.swift`, `scripts/test-gym-e2e.sh`
- Modify: `scripts/test-all.sh`

- [ ] **Step 1: Write the tests.** Real transports against the local stack, with the rules from GymCore:
  - **Criterion 2:** user A creates a gym by place id and shares 5 listings. User B and an anon client each run
    `GymCatalogClient.refresh`, get those listings, and `WorkoutBuilder` builds a chest workout from them with neither
    adding anything; every equipment exercise links one of A's listings.
  - **Criterion 4:** user B's share of a kind the gym has returns `.duplicates`; B keeps the existing one, and A's listing
    shows `confirm_count` 1.
  - **Borrowed photo:** user A shares a listing with a photo. User B's listing of the same item, with no photo, gets A's
    `photoPath` and `photoListingId` through `items`, and the public URL returns 200 with `image/jpeg`. When A's listing is
    flagged, the next refresh returns nil for both. B's `share_listing` with no photo stores `photo_path = null`.
  - **Criterion 6:** with real transports, a `device` gym with a marker name and a `device` listing with a marker note
    stay out of every table: query `gyms` and `gym_equipment` through the script's `psql_local` for the markers and expect
    zero rows.
- [ ] **Step 2: Write `scripts/test-gym-e2e.sh`**, copying the guard from `test-sync-integration.sh`: refuses a non-local
  `API_URL`, removes `gym-%@test.local` users before and after, and exits non-zero on failure.
- [ ] **Step 3: Add to `scripts/test-all.sh`:**
  ```bash
  # Gyms shared between two users and an anonymous client, against the local stack (needs Docker): opt in with GYM_E2E=1.
  if [[ "${GYM_E2E:-0}" == "1" ]]; then
    echo "==> Shared gym catalogue E2E (local Supabase)"
    "$ROOT/scripts/test-gym-e2e.sh"
  fi
  ```
- [ ] **Step 4: Run it twice** to prove the cleanup. Commit: `test: two users and an anonymous client share a gym`.

---

### Task 9: Finish

- [ ] **Step 1:** Run everything: GymCore with the coverage gate, GymData, GymSync, `scripts/test-db.sh`, deno, the node
  suites, `scripts/test-sync-integration.sh`, `scripts/test-gym-e2e.sh`, and the app suite with
  `DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2'`.
- [ ] **Step 2:** Open the app on the simulator against the local stack and walk through: browse signed out, sign in,
  share a listing with a photo, watch it reach a second account. Screenshots go in the scratchpad, not the repo.
- [ ] **Step 3:** Update `README.md` and the spec for the decisions above. Tick the boxes and add `## Outcome` with real
  numbers. Commit: `docs: plan 21 outcome`.
