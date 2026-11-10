# Plan 22: Gym moderation and Claude

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Shared gym data is safe to publish: anyone can report or block, three reports hide content until an admin
decides, deleting an account removes the user's photos, and Claude can read gym data when the user allows it.

**Architecture:** The server functions were committed with plan 21 (`20261030000006`, 57 tests). `ShareOutbox` gains report and block rows. The
admin list reads `moderation_queue()`. MCP gets two read-only tools behind a new `mcp_flag('gyms')`.

**Tech stack:** Postgres, pgTAP, Supabase Storage, Deno, Swift 6.2, SwiftUI, Swift Testing, XCUITest.

**Spec:** `docs/specs/2026-10-30-gym-equipment-design.md`, sections 5 ("Moderation UI", "Account deletion", "Claude
(MCP)"), 7, 8, 9.

**Branch:** `feat-gym-moderation`, stacked on `feat-gym-shared`. No push. Supabase stays local.

---

## Decisions this plan makes

1. **Items aren't a target.** Only gyms and listings can be reported or blocked. Everything visible about an item comes
   through a listing. Flagging an item would hide every gym's listing of it, which is more than one report should do.
2. **A reporter can't report the same target again after a restore.** The spec's unique constraint already says so. It
   stops one person re-flagging something an admin has cleared.
3. **A removed or flagged gym hides its listings,** in the access rules themselves, and keeps their photos.
4. **Remove can be undone in the database, but the photo can't.** `moderate_content` clears the listing's `photo_path` and
   returns it, and the app deletes the object through Storage. SQL can't delete Storage objects.
5. **Account deletion removes photos first.** The app calls `my_gym_photos()`, deletes each through Storage, then calls
   `delete_my_account`. If the photo step fails, the account stays and the user sees the error and can retry. That's
   better than an account gone with photos left behind that nobody can ever remove.
6. **Disconnect turns the gyms flag off,** alongside the existing flags.
7. **Reports and blocks go through the outbox.** The spec's table says so, and no signal is normal in a gym. Hiding is
   immediate on the phone: a reported or blocked listing leaves the cached rows at once. A borrowed catalogue photo (plan
   21, decision 14) reports its source, `photo_listing_id`, not the listing it's showing on. The cached item's photo is
   cleared and that picture stays off this phone, while the listing under it stays. A refresh can bring another listing's
   picture. A block can be undone in Settings, which also cancels any block still queued. A report can't be undone.
8. **Strangers' free text doesn't reach Claude.** `get_gym_equipment` returns kind ids, loads rebuilt from known keys,
   quantity, confirm count and visibility. Brand and model appear only on the user's own listings; notes never do. A
   public gym's name is labelled `name_unverified`.
9. **A contact address for complaints needs the owner.** The About screen shows `GymConstants.contentContactEmail`. It's
   set to the address already used in `PrivacyPolicyView`, if there is one. If not, the task stops and reports
   NEEDS_CONTEXT instead of inventing an address.

---

## File map

| File | Does |
|---|---|
| `supabase/functions/mcp/tools/gyms.ts`, `gyms_test.ts` | `list_gyms`, `get_gym_equipment` |
| `supabase/functions/mcp/db.ts`, `tools/fake_db.ts`, `tools/register.ts`, `tools/schemas.ts` | Queries, fake, registration |
| `ios/Packages/GymData/Sources/GymData/Gym/ShareOutbox.swift` | Report and block rows |
| `ios/Packages/GymSync/Sources/GymSync/SupabaseGymCatalogTransport.swift` | The new calls and deleting photos |
| `ios/GymRollins/Features/Gyms/ReportContentSheet.swift` | Reason list and note |
| `ios/GymRollins/Features/Settings/ModerationView.swift`, `ModerationModel.swift` | The admin list |
| `ios/GymRollins/Features/Settings/SettingsView.swift`, `PrivacyPolicyView.swift`, `CreditsView.swift` | Unblock, Moderation, contact |
| `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift` | The flag and what Claude can't see |

---

### Task 1: Server functions

- [x] **Step 1:** Add to `DomainLimits` and `domain-limits.ts`: `dailyReports = 20`, `reportNoteMax = 280`.
- [x] **Step 2:** Run `scripts/test-db.sh` and the deno `_shared` tests. Expected: `Result: PASS`.
- [x] **Step 3:** Commit: `feat(core): limits for reports`.

---

### Task 2: Report and block on the phone

**Files:**
- Modify: `GymCatalogTransport.swift`, `FakeGymCatalogTransport.swift`, `ShareOutbox.swift`, `ShareOutboxTests.swift`, `SupabaseGymCatalogTransport.swift`, `GymCatalogDTOTests.swift`, `GymCatalogIntegrationTests.swift`, `ListingDetailView.swift`, `GymEquipmentModel.swift`
- Create: `ReportContentSheet.swift`

- [x] **Step 1: Extend the protocol:**
  ```swift
  func report(targetType: GymTargetType, targetId: UUID, reason: ReportReason, note: String?) async throws
  func blockAuthor(targetType: GymTargetType, targetId: UUID) async throws
  func unblockAll() async throws -> Int
  ```
  ```swift
  public enum GymTargetType: String, Sendable, Codable { case gym, listing }
  public enum ReportReason: String, Sendable, Codable, CaseIterable {
      case wrongInfo = "wrong-info", notHereAnymore = "not-here-anymore", duplicate
      case inappropriatePhoto = "inappropriate-photo", personInPhoto = "person-in-photo", spam, other
  }
  ```
- [x] **Step 2: Write the failing tests** in `ShareOutboxTests`:
  - `reportingQueuesAndHidesTheListingAtOnce`: the row leaves `inventory(gymId:)` before `run`.
  - `aReportSurvivesOfflineAndIsSentLater`.
  - `blockingHidesEveryListingFromThatAuthor`: the phone doesn't know the author, so block hides this listing at once and
    the next refresh drops the rest, because the server stops returning them.
  - `aRefreshDoesNotBringBackAReportedListingWhileItsReportIsQueued`.
  - `theDailyLimitOnReportsShowsTheMessageAndDropsTheRow`.
  - `unblockAllForcesARefresh`.
  - `aDeviceListingCannotBeReported`: throws, and no row is written.
  - `reportingYourOwnListingIsNotOffered`: the server answers `own`, which the outbox treats as done, with nothing hidden.
  - `aGymReportHidesNothingLocally`: the gym stays in My gyms if it's the user's.
- [x] **Step 3: Run them.** Expected: compile failure.
- [x] **Step 4: Implement** the transport and outbox. Add a `hiddenLocally: Bool` field to `GymListingRecord`, which
  `inventory(gymId:)` and the listing queries skip.
- [x] **Step 5: Write the UI.** `ReportContentSheet` (`report.reason.<raw>`, `report.note`, `report.send`) shows these
  reasons in this order: "Wrong information", "Not here anymore", "Duplicate", "Inappropriate photo", "Person in the
  photo", "Spam", "Something else". Note is optional, 280 characters. After sending: "Thanks. We'll take a look."
  - The listing detail menu shows Report (`listing.report`) for any shared listing that isn't yours, and "Hide everything
    from this user" (`listing.block`) with an inline confirmation card, as in the picker. Signed out, both ask for
    sign-in first.
  - The equipment screen's menu shows "Report this gym" for a public gym (`gym.report`).
  - A listing showing a borrowed catalogue photo offers "Report this photo" (`listing.reportCatalogPhoto`), even on your own
    `device` listing, with the two photo reasons first. It reports `photo_listing_id` and clears the cached photo. Test:
    `reportingABorrowedPhotoRemovesItAndKeepsTheListing`.
  - Your own flagged listing shows "Under review".
- [x] **Step 6: Tests and commit.** Run GymData, GymSync, `scripts/test-sync-integration.sh`, and the gym UI suites, with
  a new `GymSharingUITests.testReportingHidesTheListing`. Commit: `feat(gyms): report and block`.

---

### Task 3: Admin list

**Files:**
- Create: `ModerationModel.swift`, `ModerationView.swift`, `ModerationModelTests.swift`
- Modify: `SettingsView.swift`, `GymCatalogTransport.swift`, `SupabaseGymCatalogTransport.swift`, `LaunchOptions`

- [x] **Step 1: Extend the protocol:**
  ```swift
  func isAdmin() async throws -> Bool
  func moderationQueue() async throws -> [ModerationEntry]
  /// Returns the photo to delete, if any.
  func moderate(targetType: GymTargetType, targetId: UUID, action: ModerationAction) async throws -> String?
  func deleteSharedPhoto(path: String) async throws
  ```
- [x] **Step 2: Write the failing tests** for `ModerationModel`:
  - it loads the queue, showing reasons by count and notes;
  - `remove` deletes the returned photo, then drops the row;
  - a photo delete failure shows "Removed, but the photo couldn't be deleted. Try again from Storage." and still drops
    the row, since the listing is already hidden and has no path;
  - `restore` drops the row;
  - a failed `moderate` keeps the row and shows the error.
- [x] **Step 3: Implement.** Settings shows a Moderation row (`settings.moderation`) only when `isAdmin()` returned
  true. Checked once per sign-in, and hidden when it fails or the user is offline. Each row shows the photo, the title,
  count, reasons and notes, plus Restore (`moderation.restore.<id>`) and Remove (`moderation.remove.<id>`, with an inline
  confirmation card).
- [x] **Step 4: Add an integration test:** an admin (added by the script through `psql_local`) removes another user's
  listing with a photo; the public URL then returns 400 or 404.
- [x] **Step 5: Add a UI test** with `-fakeGymCatalog -fakeGymAdmin`: Restore and Remove empty the list. Add the screen to
  both audits. Commit: `feat(gyms): moderation list for admins`.

---

### Task 4: Unblock, contact, account deletion

**Files:**
- Modify: `SettingsView.swift`, the About screen (`CreditsView.swift` or `PrivacyPolicyView.swift`; read them and pick the one that holds About), `AuthService.swift`, `AuthServiceTests`, `scripts/test-sync-integration.sh`

- [x] **Step 1: Write the failing tests:**
  - `deleteAccountRemovesPhotosFirst`: the port is called before the RPC, and when it throws, the RPC isn't called and
    the error reaches the caller;
  - integration: a user with a shared and a private photo deletes the account. Both objects are gone, `photo_path` is null
    on the shared listing, `added_by` is null, and private rows are gone;
  - extend the `left=` query in `scripts/test-sync-integration.sh` with `gyms` (`owner_id`), `gym_equipment` (`owner_id`),
    `equipment_confirmations`, `reports` (`reporter_id`: these rows stay but lose the id), `user_blocks` (`blocker_id`),
    and `storage.objects` in both buckets by `owner_id`.
- [x] **Step 2: Implement.** `AuthService.deleteAccount` takes an optional `removePhotos: (@Sendable (UUID) async throws
  -> Void)?` port with a nil default, so existing callers compile. `SupabaseGymCatalogTransport.deleteAllPhotos()` calls
  `my_gym_photos()` and removes each object through Storage.
  **The server refuses too:** `delete_my_account` raises `photos_remain` while the caller still owns objects in either gym
  bucket, so a custom or older client can't leave them behind. pgTAP for it, and `deleteAccountRemovesPhotosFirst` covers the
  app's order.
- [x] **Step 3: Write the UI.**
  - Settings → "Unblock everyone" (`settings.unblockAll`), signed in only, with a confirmation dialog, then
    "Unblocked N people."
  - About shows "Report a content problem: <address>" (`about.contentContact`). See decision 9.
- [x] **Step 4: Tests and commit.** Commit: `feat(gyms): unblock, contact address, photos go with the account`.

---

### Task 5: Claude

**Files:**
- Create: `supabase/functions/mcp/tools/gyms.ts`, `gyms_test.ts`
- Modify: `db.ts`, `tools/fake_db.ts`, `tools/register.ts`, `tools/schemas.ts`, `ClaudeConnectionView.swift`, the disconnect path, `ProfileDTO.swift` and its profile value, `supabase/tests/database/mcp_hardening.test.sql`

- [x] **Step 1: Write the failing deno tests**, following `read_test.ts`:
  - `list_gyms` returns the user's private gyms, plus public gyms the user trained at or shared to, and no other public
    gyms;
  - it never returns a user id, `created_by`, `added_by` or `owner_id`;
  - `get_gym_equipment` returns active listings visible to the user (decision 8) and the exercise ids available there;
  - a stranger's listing with a brand and note returns neither, and an unexpected key in `loads` is dropped;
  - an exercise needing a kind the gym lacks isn't in the list, and a no-equipment exercise is (same rule as
    `InventoryMatcher`: every requirement group needs a listing of one of its kinds);
  - a listing with `status` other than active doesn't count;
  - flag off: both tools answer the existing "turned off" error;
  - a gym the user can't see answers "not found", the same as one that doesn't exist.
- [x] **Step 2: Write the failing pgTAP test** in `mcp_hardening.test.sql`: an MCP client with `mcp_read_gyms` off reads no
  private gym, and with it on reads only its own.
- [x] **Step 3: Run them.** Expected: failures.
- [x] **Step 4: Implement** the tools. Each result stays small: `get_gym_equipment` lists exercise ids only, since Claude
  has `search_exercises` for details.
- [x] **Step 5: Write the UI.** `ClaudeConnectionView` adds a "Gyms" toggle next to the existing flags, default on, plus a
  line: "Claude can read gyms you've synced or shared. "This phone only" gyms stay on your phone, so Claude can't see
  them." Disconnect turns it off with the others. Add `mcp_read_gyms` to `ProfileDTO` and the profile value, following
  the existing flags. Check that `pullProfile` on an old row reads as true.
- [x] **Step 6: Tests and commit.** Run deno `mcp/`, `scripts/test-mcp.sh`, `scripts/test-db.sh`, and the affected app
  tests. Commit: `feat(mcp): Claude can read synced and shared gyms`.

---

### Task 6: Finish

- [x] **Step 1:** Run everything, including `SYNC_E2E`, `MCP_E2E`, `GYM_E2E` and the coverage gate. The app suite uses
  `DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2'`.
- [x] **Step 2:** Walk the flow on the simulator against the local stack: three accounts report a listing, it disappears,
  and an admin restores it.
- [x] **Step 3:** Update `README.md` and the spec. Tick the boxes and add `## Outcome` with real numbers. Commit:
  `docs: plan 22 outcome`.

---

## Outcome

Done on 2026-10-31, branch `feat-gym-moderation`, stacked on `feat-gym-shared`, not pushed. Supabase stays local. Final run at `1afe73a`:

| Suite | Result |
|---|---|
| App, unit and UI, iPhone 17 Pro Max, iOS 26.2, `PerformanceUITests` excluded | 1000 tests: 985 passed, 0 failed, 15 skipped |
| `scripts/ios-test-sync.sh`, the app against the real local stack | 5 tests, all passed (5 of the 15 skips above) |
| `scripts/test-photo-hosting.sh`, the exercise-photos bucket next to the new trigger | 1 test, passed (1 of the 15 skips above) |
| GymCore (`scripts/coverage-gymcore.sh`) | 96.25% line coverage, threshold 90% |
| GymData | 352 tests in 48 suites |
| GymSync | 181 tests in 31 suites |
| `scripts/test-db.sh` | 570 assertions in 17 files |
| `scripts/test-sync-integration.sh` | 39 tests in 11 suites, "Account deletion verified: 56 deleted users, 0 rows left; 0 test users remain" |
| `scripts/test-gym-e2e.sh` | 5 tests, photo upload rules, "stays on the phone" and cleanup verified |
| `scripts/test-mcp.sh` | 154 deno tests, 18 consent tests |
| `node --test scripts/*.test.mjs` | 148 tests |

**Skips left:** `ReadmeScreenshotsUITests` (8) only runs when regenerating the README's screenshots. `RealExportImportTests` (1) needs the owner's export file.

**The walk.** The real app, on the simulator against the local stack with real accounts, on `a64a294`. It took several attempts, so the record is a mix of runs, not one unbroken pass.
- Three accounts reported a listing. `status` read `active`, `active`, then `flagged`. An anonymous REST read and a signed-out browse no longer showed it.
- An admin saw "Hidden, 3 reports" with the reasons and notes and restored it. The reports resolved, and it came back for everyone.
- One report put a listing on the admin's list with "1 report". Remove set `status` to `removed`, cleared `photo_path` and deleted the Storage object, and the old URL returned 400.
- A block hid all the author's listings. Unblock everyone brought them back.
- Deleting an account with a photo removed the user and the Storage object, and the old URL returned 400. The listing stayed public with no photo, notes, author or owner. The app went back to signed out with its gym data erased.
- "Deleting your account..." went by too fast to catch on screen, and no UI test covers that row.

**What the walk changed,** in `1afe73a`:
- A listing's row in the moderation list now names its gym. It only gave an address, which doesn't identify a listing.
- Unblock everyone uses a system dialog instead of the inline card from Task 4.
- The report sheet's keyboard can be dismissed by scrolling.
- The privacy screen said photos stay on the phone and that deletion removes everything, both false once sharing exists. It and the delete confirmation now say what happens. A hosted privacy policy will need the same wording.

**Changed from the decisions above**
- Decision 5: the order is detach, remove, delete, not photos first. The server forgets the names, then Storage deletes the objects, then the account goes. A failure after detaching leaves no listing naming a missing photo. A synced listing with a local copy uploads it again at the next sync.
- Decision 9: no address exists anywhere in the app, so `GymConstants.contentContactEmail` is nil and the About row is hidden. **The owner must set one before release.** The App Store's rules for user-generated content ask for it.

**Added after this plan's reviews**
- A refused report brings the listing back and tells the user. A rejected note sends again without the note.
- Sign-out offers to send queued reports and blocks first, waits for a run already going, and counts what's left.
- A failed account deletion restarts sync and leaves the phone's data alone.
- The moderation list keeps a removed row until its photo is gone ("Removed, but the photo couldn't be deleted. Tap Remove to try again.").
- Limits on blocks. Photos over 4096 px are refused by reading the JPEG's frame header before decoding.
- `reports.note` is checked the way `clean_text` cleans it, and counted in code points.

**Decisions**
- After a report is sent the listing stays hidden on that phone while it's cached. A report can't be undone. A block can, in Settings.
- Sign-in is asked at Send. A gym report leaves out the photo reasons. Send is never disabled.
- One report puts a listing on the admin's list. Three hide it.
- Flagged keeps workout links; removed and blocked drop them.
- `get_gym_equipment` refuses a public gym the user hasn't used.
- `reportedPhotoListingId` holds one listing per item, so a second report on another picture overwrites the first. Accepted.

**Not tested:** the camera, real location, Apple Maps search, `PhotosPicker` and real Sign in with Apple, all of which need a device.

**Known and left:** the "Moderation" section header and its row read the same, as Apple Health's do. The thanks text doesn't say the item hides. The launch list is in the spec's risks table. **First on it: an OAuth token Claude holds can set a password through `PUT /auth/v1/user` and get a full session.** It predates this plan and has to be fixed on the hosted project.
