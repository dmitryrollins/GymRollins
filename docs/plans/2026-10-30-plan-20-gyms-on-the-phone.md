# Plan 20: Gyms and equipment on the phone (no account)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Everything a user can do with gyms without an account: pick or add a gym, photograph and catalogue its
equipment, have today's routine adapted to it for the session, and build a workout from it. Nothing leaves the phone.

**Architecture:** GymData gets three SwiftData records and `GymRepository`. The app gets `Features/Gyms/` and
`AppEnvironment+Gyms`. The rules from plan 19 run through one seam: `AppEnvironment.todaysPlan()` returns the plan
adapted to the current gym, so Today, the plan-mode exercise screen, Start and the watch all see the same list.
`TodayPlan` remembers what each swapped item really is (`gymSwaps`), so a swap is never saved into a routine.

**Tech Stack:** Swift 6, SwiftUI (iOS 26), SwiftData, ImageIO, Vision, Core Image, MapKit, Core Location, Swift Testing,
XCUITest.

**Spec:** `docs/specs/2026-10-30-gym-equipment-design.md` (sections 3–7; milestone 2 in section 10).

**Roadmap:** 19 rules and data (done) · 20 this plan · 21 shared catalogue · 22 moderation and Claude.

**Branch:** `feat-gym-phone`, stacked on `feat-gym-rules`. Commit per task, no attribution trailers, no push.

**How to read the tasks.** Logic that is easy to get subtly wrong (the `TodayPlan` changes, repository rules, photo
pipeline) is given as code or exact rules. SwiftUI screens are given as behaviour, exact copy and accessibility
identifiers, because they follow the existing design system and a line-by-line transcription adds nothing. Tests are
written first in every task; test names below are required, and implementers add more where they find gaps.

**Decisions made while planning (additions to the spec):**
1. **Pinned items.** The spec didn't say what happens when the user wants the planned exercise anyway, or hand-picks an
   exercise the catalogue says isn't here. Without an answer, the next reload swaps it again, and an incomplete
   catalogue would block the user. `TodayPlan.gymPinned` holds items the user chose by hand; the adapter leaves them
   alone. A swapped row's menu offers "Use <planned> anyway".
2. **Location prompt.** Today only asks for a fix when permission is already granted. The first permission prompt comes
   when the user opens the gym picker, where the reason is obvious. The rest of the spec's rule is unchanged.
3. **Visibility in this plan.** Only "This phone only" is offered; the other two options arrive with plan 21. The
   records already carry `visibility`, `uploadState` and `remoteId`.
4. **Wipes.** Sign-out-and-remove, account deletion, account switch and Erase All also remove gyms and their photos,
   like every other local row. Plain sign-out keeps them.
5. **Workout links.** `workouts.gym_id` and `workout_entries.gym_equipment_id` arrive with plan 21, because they only
   matter on the server.

---

## File map

| File | Responsibility |
|---|---|
| `ios/Packages/GymData/Sources/GymData/Records/GymRecords.swift` | `GymRecord`, `EquipmentItemRecord`, `GymListingRecord` |
| `.../GymData/Values/GymValues.swift` | `GymVisibility`, `UploadState`, `ListingStatus`, `Gym`, `EquipmentItem`, `GymListing`, `NewListing`, `CatalogueItem` |
| `.../GymData/Repositories/GymRepository.swift` | Gyms, items and listings: validation, queries, `inventory(gymId:)` |
| `ios/GymRollins/App/AppEnvironment+Gyms.swift` | Current gym, matcher, adapter, loads lookup, `buildWorkout` |
| `ios/GymRollins/App/DebugGymSeed.swift` | `-seedGym`, DEBUG only |
| `ios/GymRollins/Features/Media/GymPhotoProcessor.swift` | Downscale, blur faces, strip metadata, thumbnail |
| `ios/GymRollins/Features/Media/GymPhotoStore.swift` | Photo files in Application Support |
| `ios/GymRollins/Features/Gyms/GymEquipmentCatalog.swift` | Bundled kinds and requirements, tiles, kind search |
| `.../Gyms/ListingLoadsText.swift` | Loads as text in the user's unit |
| `.../Gyms/GymPhotoView.swift` | Local photo or thumbnail with a placeholder |
| `.../Gyms/GymChip.swift`, `GymPickerView.swift`, `AddPrivateGymSheet.swift` | Chip and picker |
| `.../Gyms/GymLocator.swift`, `NearbyGymRule.swift`, `GymPlaceSearch.swift` | One-shot location, the 150 m and 30 minute rules, Maps search |
| `.../Gyms/GymEquipmentView.swift`, `GymEquipmentModel.swift`, `ListingDetailView.swift` | Equipment screen |
| `.../Gyms/AddEquipmentFlow.swift`, `AddEquipmentModel.swift`, `AddEquipmentSteps.swift`, `CameraPicker.swift` | The 4 steps |
| `.../Gyms/BuildWorkoutSheet.swift`, `BuildResultView.swift`, `BuildResultModel.swift` | Build workout |
| `ios/GymRollins/Features/Today/TodayPlan.swift` | `gymSwaps`, `gymPinned`, `builtName`, `adapted(by:)` |
| `ios/GymRollins/Features/Today/TodayModel.swift`, `TodayExerciseRow.swift`, `TodayView.swift` | Marks, chip, Build button |
| `ios/GymRollins/Features/Workout/SessionPlanner.swift` | Optional `loads` |
| `ios/Packages/GymCore/Sources/GymCore/Gym/*` | `GymAdapter.adapt(_:pinned:)`, `Suggestion.fitted(to:)`, `WorkoutBuilder.itemCount(for:asOf:)` |
| `ios/project.yml` | Camera, location and photo-library usage strings |

---

### Task 1: GymData records and repository

**Files:** create `Records/GymRecords.swift`, `Values/GymValues.swift`, `Repositories/GymRepository.swift`; modify
`Store/GymStore.swift`, `Sync/SyncStore.swift` (`resetAll`); test `Tests/GymDataTests/GymRepositoryTests.swift`.

- [ ] **Step 1: Write the failing tests** (in-memory `GymStore.container(inMemory: true)`, as `ExercisePreferenceTests` does):

  `addPrivateGymTrimsAndValidates` (empty name throws `GymDataError.invalidInput`, 121 characters throws, address over 300 throws, whitespace trimmed, blank address becomes nil, visibility `.device`, `mapsPlaceId` nil) · `addMapsGymIsIdempotentPerPlace` · `gymsAreSortedByName` · `addListingStoresEverythingOnThePhone` (visibility `.device`, uploadState `.local`, `isOwn`, status `.active`, confirmCount 0, remoteId nil) · `addListingValidates` (quantity 0 and 51; note over 280; brand over 60; model over 80; stack `maxKg` 0, negative, or over 1000; step over max or ≤ 0; fixed empty, over 60 weights, or a weight ≤ 0 or over 500; unknown gym) · `genericItemIsStablePerKind` (same id on every call, no duplicate row, nil brand and model) · `sameBrandAndModelReuseTheItem` (case-insensitive) · `catalogueItemsCountGyms` (item used at 2 gyms reports 2; the generic item isn't included; other kinds aren't included) · `listingsOnlyReturnActiveOnesInOrder` (flagged and removed excluded; oldest first) · `inventoryMapsActiveListings` (id, kind, loads, confirmCount, isOwn; `gymName`) · `updateListingChangesLoadsQuantityAndNote` · `removeListingReturnsItsPhoto` · `deleteGymRemovesItsListingsAndReturnsTheirPhotos` (the gym's items stay when another gym uses them) · `itemCountsPerGym` · `resetAllRemovesGymRows` (in `SyncStoreTests`).

- [ ] **Step 2: Run and watch them fail.** From `ios/Packages/GymData`: `swift test --filter GymRepositoryTests`. Expected: build error, `GymRepository` not found.

- [ ] **Step 3: Implement.** Records follow `ExercisePreferenceRecord`'s style.

```swift
// Values/GymValues.swift
/// Who a gym or listing is visible to (spec §5). Only `device` exists until plan 21.
public enum GymVisibility: String, Codable, Sendable, CaseIterable { case device, synced, shared }
public enum UploadState: String, Codable, Sendable { case local, queued, uploaded, failed }
public enum ListingStatus: String, Codable, Sendable { case active, flagged, removed }

public struct Gym: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let address: String?
    public let latitude: Double?
    public let longitude: Double?
    /// `MKMapItem.identifier`; nil for a private gym, which can never be shared.
    public let mapsPlaceId: String?
    public let visibility: GymVisibility
    public let remoteId: UUID?
    public var isPrivate: Bool { mapsPlaceId == nil }
}
public struct EquipmentItem: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kindId: String
    public let brand: String?
    public let model: String?
    public var isGeneric: Bool { brand == nil && model == nil }
}
public struct GymListing: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let gymId: UUID
    public let item: EquipmentItem
    public let loads: ListingLoads
    public let quantity: Int
    public let notes: String?
    /// File name inside `GymPhotoStore`; nil when the user skipped the photo.
    public let photoFile: String?
    public let visibility: GymVisibility
    public let uploadState: UploadState
    public let uploadError: String?
    public let status: ListingStatus
    public let confirmCount: Int
    public let isOwn: Bool
    public let remoteId: UUID?
    public let createdAt: Date
}
public struct NewListing: Sendable {
    public let gymId: UUID
    public let kindId: String
    public let brand: String?
    public let model: String?
    public let loads: ListingLoads
    public let quantity: Int
    public let notes: String?
    public let photoFile: String?
    public init(gymId: UUID, kindId: String, brand: String? = nil, model: String? = nil, loads: ListingLoads = .none,
                quantity: Int = 1, notes: String? = nil, photoFile: String? = nil) { /* assign */ }
}
/// A known item of a kind and how many of My gyms list it (Step 3 of adding equipment).
public struct CatalogueItem: Sendable, Hashable, Identifiable {
    public let item: EquipmentItem
    public let gymCount: Int
    public var id: UUID { item.id }
}
```

  `GymListingRecord` stores `loads` as JSON `Data` (`JSONEncoder` over `ListingLoads`), `kindId` and `itemId`, and every field above. A listing whose stored loads fail to decode reads as `.none` (never crash on a newer app's data). `GymRecord` has `createdAt`/`updatedAt`. Hard delete only; soft removal is for server rows in plan 21 (`status` is still stored).

  `GymRepository` is `@MainActor`, `init(context:now:)`, public API: `gyms()`, `gym(_:)`, `addPrivateGym(name:address:)`, `addMapsGym(placeId:name:address:latitude:longitude:)`, `updateGym(_:name:address:)` (private gyms only), `deleteGym(_:) -> [String]` (photo files), `listings(gymId:)`, `listing(_:)`, `addListing(_:) -> GymListing`, `updateListing(_:loads:quantity:notes:)`, `removeListing(_:) -> String?`, `catalogueItems(kindId:) -> [CatalogueItem]`, `inventory(gymId:) -> GymInventory`, `itemCounts() -> [UUID: Int]`. Limits are `public static let` constants on the repository. The generic item id is `StableUUID.make(namespace: <new constant>, name: kindId)`.

  Add the three records to `GymStore.models` and `resetAll`. SwiftData migrates by itself because only new models are added.

- [ ] **Step 4: Run and watch them pass.** `swift test --filter GymRepositoryTests`, then all of `swift test` in GymData.

- [ ] **Step 5: Commit.** `git commit -m "feat(data): gyms, equipment items and listings on the phone"`

---

### Task 2: The small GymCore additions

**Files:** modify `Gym/GymAdapter.swift`, `Gym/AvailableLoads.swift`, `Gym/WorkoutBuilder.swift`; tests in the matching suites.

- [ ] **Step 1: Failing tests.**
  - `GymAdapterTests.pinnedItemsStayAsPlannedAndBlockDuplicates`: a pinned, missing exercise comes back `.unmapped(item)`, and no other item's replacement is that exercise.
  - `AvailableLoadsTests.suggestionFittedToFixedSet` (30 kg, 8 reps on `[20, 24]` → 24 kg, 10 reps), `suggestionFittedKeepsSecAndReason` (a timed suggestion keeps reps and `sec`).
  - `WorkoutBuilderFallbackTests.itemCountMatchesTheThinNotice`: `itemCount(for:asOf:)` equals `ThinInventoryNotice.itemCount` for the same gym and muscle, and counts each listing once.

- [ ] **Step 2: Implement.**

```swift
// GymAdapter
/// `pinned` items were chosen by hand for today. They stay as planned (`.unmapped`) and still count as used, so nothing
/// else is swapped to them.
public func adapt(_ items: [RoutineExercise], pinned: Set<UUID> = []) -> [AdaptedItem] {
    let start = (out: [AdaptedItem](), used: Set(items.map(\.exerciseId)))
    return items.reduce(into: start) { state, item in
        let adapted = pinned.contains(item.id) ? AdaptedItem.unmapped(item) : adapt(item, excluding: state.used)
        state.used.insert(adapted.item.exerciseId)
        state.out.append(adapted)
    }.out
}

// AvailableLoads.swift
public extension Suggestion {
    /// The suggestion on a listing's loads. A timed exercise has no rep target to raise.
    func fitted(to loads: ListingLoads) -> Suggestion {
        let fitted = AvailableLoads.fit(weightKg: weightKg, reps: reps, to: loads)
        return Suggestion(weightKg: fitted.weightKg, reps: sec == nil ? fitted.reps : reps, sec: sec, reason: reason)
    }
}

// WorkoutBuilder
/// How many listings at the gym could serve an equipment exercise for this chip (the coverage badge and thin notice).
public func itemCount(for muscle: BuildMuscle, asOf date: Date) -> Int { /* same Set as build() uses; share one helper */ }
```

- [ ] **Step 3: Run** `swift test` and `scripts/coverage-gymcore.sh` (≥ 90%).

- [ ] **Step 4: Commit.** `git commit -m "feat(core): pinned items, fitted suggestions and a chip's item count"`

---

### Task 3: Photo processor and store

**Files:** create `Features/Media/GymPhotoProcessor.swift`, `Features/Media/GymPhotoStore.swift`; test `ios/GymRollinsTests/GymPhotoProcessorTests.swift`, `GymPhotoStoreTests.swift`.

The fixture with a real face is the bundled `OwnPhotos/own-0453-0.jpg` (Vision finds one face at about x 0.48, y 0.73, w 0.054, h 0.081, origin bottom-left).

- [ ] **Step 1: Failing tests.** Run app tests with `DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4'` and `-only-testing:GymRollinsTests/GymPhotoProcessorTests` (the 26.2 runtime hangs on this Mac):
  - `downscalesToTheLongEdge`: a 4000×3000 generated image comes out with long edge exactly 1600, thumbnail long edge exactly 400, and never upscales a 300×200 one.
  - `staysUnderOneMegabyte`: a noisy 4000×3000 image comes out under 1 MB, or throws `.tooBig`, never above.
  - `rejectsWhatStaysTooBig`: with `maxBytes: 1_000`, throws `.tooBig`.
  - `stripsAllMetadata`: input JPEG written with EXIF, GPS and TIFF dictionaries; output `CGImageSourceCopyPropertiesAtIndex` has no `kCGImagePropertyExifDictionary` (or only what the encoder itself adds, with no original values), no GPS, no TIFF.
  - `respectsOrientation`: a landscape bitmap tagged orientation 6 comes out portrait.
  - `blursEachFaceRegion`: with a stub detector returning a known rect over a high-contrast checkerboard, pixels inside the padded rect lose their contrast, pixels well outside are unchanged.
  - `detectorFailureRejectsThePhoto`: a throwing detector gives `.faceDetectionFailed`, and no output exists (spec: no unblurred fallback).
  - `notAnImageThrows`: random bytes give `.notAnImage`.
  - `findsTheFaceInTheFixture`: the real `VisionFaceDetector` on the bundled photo finds at least one face. If Vision can't run on the simulator (its error names the inference context), skip with `withKnownIssue` and report it; do not fake a pass.
  - `GymPhotoStoreTests`: saves and reads back, thumbnail file exists, delete removes both, `removeAll` empties the folder, a file name containing `/` or `..` is refused, and a missing file is not an error on delete.

- [ ] **Step 2: Implement.**

```swift
enum GymPhotoError: Error, Equatable { case notAnImage, tooBig, faceDetectionFailed }

struct ProcessedGymPhoto: Sendable { let jpeg: Data; let thumbnail: Data }

protocol FaceDetecting: Sendable {
    /// Face rectangles, normalized, Vision's bottom-left origin.
    func faces(in image: CGImage) throws -> [CGRect]
}
struct VisionFaceDetector: FaceDetecting { /* VNDetectFaceRectanglesRequest; rethrow errors */ }

struct GymPhotoProcessor: Sendable {
    static let maxLongEdge = 1600, thumbnailLongEdge = 400, maxBytes = 1_000_000
    static let quality = 0.7, retryQuality = 0.5
    /// Added around each face rect on every side, as a fraction of its size.
    static let facePadding = 0.35
    init(detector: any FaceDetecting = VisionFaceDetector(), maxBytes: Int = Self.maxBytes)
    /// Spec §5 "Photos". Throws rather than ever returning an unblurred image.
    func process(_ data: Data) throws -> ProcessedGymPhoto
}
```

  Order: decode with `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceCreateThumbnailWithTransform`, `kCGImageSourceThumbnailMaxPixelSize` 1600), detect on that downscaled, upright image, blur with Core Image (`CIGaussianBlur` with radius scaled to the face, clamped to extent, cropped to the padded rect, composited over the original), then encode with `CGImageDestination` passing only `kCGImageDestinationLossyCompressionQuality` so no source properties are copied. The thumbnail is cut from the blurred image, never the original. `process` runs off the main actor at its call site (`Task.detached`).

  `GymPhotoStore` is a `Sendable` struct over `Application Support/GymPhotos`: `save(_:) throws -> String` (`<uuid>.jpg`, `<uuid>-thumb.jpg`), `url(_:)`, `thumbnailURL(_:)`, `delete(_:)`, `removeAll()`.

- [ ] **Step 3: Run and pass.**

- [ ] **Step 4: Commit.** `git commit -m "feat(app): clean gym photos on the phone before saving them"`

---

### Task 4: TodayPlan knows about gym swaps

**Files:** modify `Features/Today/TodayPlan.swift`, `Features/Today/TodayPlanEditor.swift`; test `ios/GymRollinsTests/TodayPlanGymTests.swift`.

This is the seam that keeps "your plan isn't changed" true. `exercises` holds what the session will do; `gymSwaps` holds what the plan really says for swapped items.

- [ ] **Step 1: Failing tests.**
  - `adaptedSwapsWithoutMarkingEdited`: a swap appears in `exercises`, `edited == false`, `canSaveToRoutine == false`, `hasTodayChanges == false`, `plannedExercises` equals the routine's.
  - `routineToStartUsesTheSwap`, with the same item id and `entryId(for:in:)` still resolving.
  - `adaptedIsIdempotent`: applying twice gives an equal plan.
  - `adaptedWithNoGymUndoesEverySwap`.
  - `changingGymsReDecides`: swap at gym A, none at gym B, a different swap at gym C.
  - `saveChangesNeverWritesASwap`: a real edit elsewhere plus a swap; `routineWithEdits` has the planned exercise, its sets and weight unchanged.
  - `savedToRoutineKeepsTheSwapShowing`.
  - `setEditsOnASwappedItemAreNotSavedToTheRoutine`: `canSaveToRoutine` stays false, the override is kept and started.
  - `setEditsOnASwappedItemSurviveReload`: store → `load` (the `rebased` path) → `adapted`, the override is still there when the same replacement is chosen.
  - `setEditsAreDroppedWhenTheExerciseChanges`: another gym picks another replacement; the override goes, because it belongs to the old exercise.
  - `replacingPinsAndClearsTheSwap`, `addingPins`, `deletingClearsBoth`.
  - `pinnedSurvivesReload`: pinned planned exercise, not edited, is stored (`hasTodayChanges` true) and not swapped after reload.
  - `usePlannedAnywayRestoresAndPins`: exercises match the base again, `edited == false`, pinned.
  - `rebasedKeepsSwapsOfItemsStillThere` and drops them when the item's planned exercise changed in My Plan.
  - `builtPlan`: `title == builtName`, `routineToStart.name == builtName`, `canSaveToRoutine == false`, kind `.built`, Codable round trip.
  - `plansStoredBeforeThisStillDecode`: JSON without the new keys decodes with empty swaps and pins.

- [ ] **Step 2: Implement.** Add to `TodayPlan` (with `init` defaults, `CodingKeys`, `decodeIfPresent`):

```swift
enum Kind { ...; /// Built by Build workout for today.
    case built }
/// Items swapped for the current gym: item id → what the plan really has there. `exercises` holds the replacement.
/// Never saved to a routine, recomputed on every load.
let gymSwaps: [UUID: RoutineExercise]
/// Items chosen by hand for today: the gym never swaps them.
let gymPinned: Set<UUID>
/// A built workout's title ("Back + Arms").
let builtName: String?

var plannedExercises: [RoutineExercise] { exercises.map { gymSwaps[$0.id] ?? $0 } }
var title: String { builtName ?? base?.name ?? "Empty workout" }
var hasTodayChanges: Bool { kind != .scheduled || edited || !setOverrides.isEmpty || restSec != nil || !gymPinned.isEmpty }
var routineToStart: Routine? {
    if let base { return base.with(exercises: exercises) }
    return exercises.isEmpty ? nil : Routine(name: builtName ?? "Workout", exercises: exercises)
}
var exercisesMatchBase: Bool { base?.exercises == plannedExercises }
```

  Rules for the rest:
  - `routineWithEdits`: a swapped item writes its planned exercise, untouched; others as today.
  - `changed(...)`: `exercisesDiffer` compares `base.exercises` with `new` after reverting swaps; carries `gymSwaps`, `gymPinned`, `builtName`, and takes optional replacements for them.
  - `replacing`: removes the swap, pins the id. `adding`: pins the new ids. `deleting`: removes from both.
  - `editingSets`: a swapped item's edit is stored in `setOverrides` but not added to `unsavedSetEdits` (nothing to save back).
  - `switched(to:)`, `make(...)`: no swaps, no pins.
  - `savedToRoutine`: swapped items keep showing their replacement; `gymSwaps` stays.
  - `rebased(on:)`: compares against `plannedExercises`. Keeps overrides, pins and swaps of items whose planned exercise is unchanged; a kept swap's planned item is the routine's current version; `exercises` shows the replacement for kept swaps.
  - New `usingPlanned(_ itemId:)`: restores the planned item, removes the swap and its override, pins it.
  - New `static func built(name:items:day:) -> TodayPlan`: kind `.built`, `base` nil, `edited` true (like a hand-picked list, which keeps `changed`'s rule). Its items aren't pinned: `adapted` keeps whatever is available, and re-decides only if the user changes gym.
  - New `adapted(by adapter: GymAdapter?) -> TodayPlan`:

```swift
/// This plan at the current gym: swaps are re-decided from the planned exercises every time, so this is idempotent and
/// moving gyms (or leaving them) can't accumulate anything. Set edits survive only while the item's exercise does.
func adapted(by adapter: GymAdapter?) -> TodayPlan {
    let planned = plannedExercises
    let results = adapter?.adapt(planned, pinned: gymPinned) ?? planned.map { AdaptedItem.unmapped($0) }
    let swaps = results.reduce(into: [UUID: RoutineExercise]()) { swaps, result in
        if case let .swapped(plannedItem, _, _, _) = result { swaps[plannedItem.id] = plannedItem }
    }
    let new = results.map(\.item)
    let before = Dictionary(exercises.map { ($0.id, $0.exerciseId) }, uniquingKeysWith: { first, _ in first })
    let kept = setOverrides.filter { id, _ in new.contains { $0.id == id && $0.exerciseId == before[id] } }
    let unsaved = unsavedSetEdits.intersection(kept.keys)
    return TodayPlan(day: day, kind: kind, base: base, exercises: new,
                     edited: (base.map { $0.exercises != planned } ?? !planned.isEmpty) || !unsaved.isEmpty,
                     setOverrides: kept, restSec: restSec, unsavedSetEdits: unsaved,
                     gymSwaps: swaps, gymPinned: gymPinned, builtName: builtName)
}
```

  `TodayPlanEditor`: add `usePlanned(_ itemId:)` (forget + apply). `replace` and `delete` already go through `TodayPlan`. `TodayPlanStore.save` stores whatever has `hasTodayChanges`, swaps included; that's safe because they're re-decided on load. Also clear a stale store: if `hasTodayChanges` is false it clears, as today.

- [ ] **Step 3: Run** `-only-testing:GymRollinsTests/TodayPlanGymTests` plus every existing `TodayPlan*` and `TodayModel*` suite. Existing tests must pass unchanged.

- [ ] **Step 4: Commit.** `git commit -m "feat(today): today's plan keeps gym swaps apart from the routine"`

---

### Task 5: Environment, catalog and SessionPlanner wiring

**Files:** create `Features/Gyms/GymEquipmentCatalog.swift`, `Features/Gyms/ListingLoadsText.swift`, `App/AppEnvironment+Gyms.swift`, `App/DebugGymSeed.swift`; modify `App/AppEnvironment.swift`, `App/AppEnvironment+Watch.swift` (`todaysPlan(at:)`), `App/LaunchOptions.swift`, `Features/Workout/SessionPlanner.swift`, `Features/Today/TodayModel.swift`, `Features/Today/TodayView.swift` (`reload`, `refreshModel`, `choose`); tests `GymEnvironmentTests.swift`, `SessionPlannerTests` additions, `TodayModelGymTests.swift`, `GymEquipmentCatalogTests.swift`, `ListingLoadsTextTests.swift`.

- [ ] **Step 1: Failing tests.**
  - `GymEquipmentCatalogTests`: `loadsBundledFiles` (46 kinds, 1,107 requirements), `commonTilesAreRealKinds`, `searchMatchesNameAndIgnoresCase`, `groupsKeepCommonFirst`.
  - `ListingLoadsTextTests`: lb user `.stack(113.4, nil)` → "to 250 lb"; kg user → "to 113 kg"; `.fixed([20, 24])` lb user → "44 · 53 lb"; `.plates` → "plate-loaded"; `.none` → nil.
  - `SessionPlannerTests.loadsFitTheSuggestion`: `entry(..., loads: .fixed(kg: [20, 24]))` with history at 30 kg gives 24 kg and reps + 2; `nil` loads are unchanged (existing tests still pass); warm-ups use the fitted weight.
  - `GymEnvironmentTests` (a real `AppEnvironment` with `LaunchOptions(arguments: ["-uiTesting"])` and a throwaway `UserDefaults` suite):
    - `noCurrentGymChangesNothing`: `todaysPlan()` equals the plain plan, no swaps.
    - `currentGymPersists` per device; `deletingTheCurrentGymClearsIt`; a current id for a missing gym reads as nil.
    - `todaysPlanIsAdapted`: the owner's seeded routine at a kettlebell-and-bench gym swaps what it can't do, never edits the routine (`env.routines.routine(id)` unchanged after Save-to-routine isn't offered).
    - `startSessionUsesSwapsAndFittedWeights`: `startTodaysWorkout()` (the watch path) starts the swapped exercises at listed weights.
    - `everyAdaptedExerciseIsBackedByListings` (criterion 5 at app level): for each row, requirements are covered, or it's unmapped, or it's marked unavailable.
    - `buildWorkoutUsesTheCurrentGym`, `loggedCountsAndPreferencesReachTheBuilder`, `rebuildAvoidListGrows`.
    - `eraseAllRemovesGymsAndPhotos`, `localResetRemovesGymsAndPhotos`, `plainSignOutKeepsThem`.
  - `TodayModelGymTests`: a swapped row has `gymMark == .swapped(planned: "Preacher Curl", missingKind: "preacher bench")`, a `swappedNote` of "1 exercise swapped for this gym. Your plan isn't changed." (and the plural), an unavailable row has `.unavailable`, a kept row has its listing's `photoFile`, and with no gym nothing differs from today's model.

- [ ] **Step 2: Implement.**

  `LaunchOptions` (DEBUG only, `false`/nil in Release): `-seedGym` (private "Home" gym, kettlebells `.fixed(kg: [20, 24])`, flat bench, set as current, no photos), `-gymPhotoFixture` (the Library button uses a generated image), `-fakeLocation <lat>,<lng>`, `-fakeGymPlaces` (Maps search returns "Iron Works Gym" and "Test Fitness", ids `fake-iron-works`, `fake-test-fitness`, 50 m and 2 km from the fake location).

  `AppEnvironment` gains stored `let gyms: GymRepository`, `let gymCatalog: GymEquipmentCatalog`, `let gymPhotos: GymPhotoStore`, `private(set) var gymRevision = 0`, and calls `gymPhotos.removeAll()` and clears the current gym in `eraseAllLocalData` and `onLocalDataReset`. A catalog that fails to load logs the error and makes the matcher nil (no adaptation) rather than failing launch.

```swift
// AppEnvironment+Gyms.swift
extension AppEnvironment {
    static let currentGymKey = "gymrollins.currentGymId"
    var currentGym: Gym? // reads the id from `defaults`, then `gyms.gym(id)`; nil when missing
    func setCurrentGym(_ id: UUID?) // writes, bumps gymRevision, planRevision so Today reloads, todayPlanChanged() for the watch
    func gymsChanged() // equipment was added, edited or removed: bumps gymRevision and reloads Today the same way
    func gymMatcher(gymId: UUID? = nil) -> InventoryMatcher? // nil with no gym
    func gymAdapter() -> GymAdapter?
    func gymLoggedCounts() -> [String: Int] // the same 200-workout count SwapSheet uses; SwapSheet moves to this
    func gymLoads(_ exerciseId: String) -> ListingLoads? // the load listing's loads, nil when no gym or no load listing
    func buildWorkout(muscles: [BuildMuscle], length: BuildLength, avoid: [String]) -> BuiltWorkout?
}
```

  `todaysPlan(at:)` ends with `return (plan.adapted(by: gymAdapter()), scheduled)`. `startSession` passes `loads:` from `gymLoads`. `SessionPlanner.suggestion`, `entry` and `start` take `loads` (default nil) and use `suggestion.fitted(to:)`. Remove `SessionPlanner.barbellEquipment` in favour of `Exercise.barbellLoadedEquipment` (plan 19's follow-up).

  `TodayModel.Row` gains `gymMark: GymMark?` and `photoFile: String?`; `TodayModel` gains `gymNote: String?`.

```swift
struct TodayGymContext {
    let matcher: InventoryMatcher
    /// Listing id → its photo file.
    let photo: (UUID) -> String?
}
enum GymMark: Equatable { case swapped(planned: String, missingKind: String); case unavailable(missingKind: String) }
```

  `TodayModel.make(plan:profile:library:history:gym: TodayGymContext? = nil, loads: (String) -> ListingLoads? = { _ in nil })`. Display name for a missing group: the first kind's lowercased name. `TodayView.reload` and `refreshModel` pass the context; `choose` applies `current.switched(to: routine).adapted(by: env.gymAdapter())`; Add and Replace go through `plan.adding`/`replacing`, which pin. `TodayPlanEditor.configure`'s `suggest` closure passes `loads`.

- [ ] **Step 3: Run** the new suites, the existing `SessionPlanner*`, `Today*`, `Watch*` suites, then the whole unit target.

- [ ] **Step 4: Commit.** `git commit -m "feat(app): adapt today's plan to the current gym"`

---

### Task 6: Gym chip, picker and locator

**Files:** create `Features/Gyms/GymChip.swift`, `GymPickerView.swift`, `AddPrivateGymSheet.swift`, `GymLocator.swift`, `NearbyGymRule.swift`, `GymPlaceSearch.swift`, `GymPhotoView.swift`; modify `TodayView.swift`, `ios/project.yml`; tests `NearbyGymRuleTests.swift`, `ios/GymRollinsUITests/GymPickerUITests.swift`.

- [ ] **Step 1: Failing tests.**
  - `NearbyGymRuleTests`: `findsTheNearestWithin150m`, `ignoresTheCurrentGym`, `ignoresGymsWithoutCoordinates`, `prefersMyGymsOverMapsPlacesAtTheSameDistance`, `matchesAMapsPlaceAlreadyInMyGymsOnce`, `throttlesTo30Minutes`, `nothingFarAway`.
  - `GymPickerUITests`: `testAddAPrivateGymAndPickIt`, `testPickerIsReachableAndCancelable`, `testPickAMapsGymWithFakePlaces` (`-fakeLocation -fakeGymPlaces`: search "Iron", tap, chip shows the name, and it's listed under My gyms on reopening), `testNearbySuggestionOffersTrainHere`, `testNoGymGoesBackToThePlainPlan`.

- [ ] **Step 2: Implement.**

  **`project.yml`:** `NSCameraUsageDescription` "GymRollins uses the camera to photograph gym equipment. Faces are blurred before the photo is saved.", `NSLocationWhenInUseUsageDescription` "GymRollins uses your location once to suggest the gym you're at. It isn't stored or sent anywhere.", `NSPhotoLibraryUsageDescription` isn't needed (`PhotosPicker` runs out of process). Run `xcodegen generate`.

  **Chip** (under the summary on Today, `session == nil` only): glass capsule, `mappin.and.ellipse`, gym name or "Choose gym", `chevron.down`. Identifier `today.gymChip`, label "Gym: <name>", hint "Opens the gym picker".

  **"You're at X?"** below the chip (`today.gymSuggestion`, button `today.gymSuggestion.accept`, close `today.gymSuggestion.dismiss`). `GymLocator` protocol-injected: `CoreLocationGymLocator` uses `CLLocationManager.requestLocation()`; on Today it only runs when status is `.authorizedWhenInUse` and the last check is over 30 minutes old (`gymrollins.gymLocationCheckedAt` in defaults); under `-uiTesting` only with `-fakeLocation`. It never changes the gym by itself.

  **Picker** (sheet, `.large`, title "Where are you training?", `gymPicker.close`): the first time it opens, ask for When In Use. Sections:
  1. `NEARBY`, when one is found: name, address, distance in the user's unit, "Train here" (`gymPicker.nearby.train`).
  2. Search field "Search gyms on Apple Maps" (`gymPicker.search`), debounced 300 ms with `.task(id: query)`. Results `gymPicker.place.<placeId>`. Offline or failed search: the line "Maps isn't available right now. You can still add a private gym." and no error dialog.
  3. `MY GYMS`: `gymPicker.gym.<name>`, with photo thumbnail placeholder, "<n> items", badge `THIS PHONE ONLY`, a checkmark on the current one, swipe to delete with a confirmation (`gymPicker.delete.confirm`) that names the number of items and says photos go too. The header's current gym name opens its equipment screen (`gymPicker.currentEquipment`).
  4. `+ Add a private gym` (`gymPicker.addPrivate`) → `AddPrivateGymSheet`: name (required), address (optional), Save (`privateGym.save`, disabled while the name is blank). Validation errors from the repository show inline.
  5. `No gym` (`gymPicker.none`), "Use my plan as written".

  `GymPlaceSearch` protocol: `search(query:near:) async throws -> [GymPlace]`, `nearby(_:) async throws -> [GymPlace]`; `MapKitGymPlaceSearch` uses `MKLocalSearch` with `MKPointOfInterestFilter(including: [.fitnessCenter])` and `MKLocalPointsOfInterestRequest(center:radius: 150)`, reading `mapItem.identifier?.rawValue`, skipping items without one. `FakeGymPlaceSearch` for `-fakeGymPlaces`.

  Picking a Maps place calls `gyms.addMapsGym` (a local row, `.device`), then `setCurrentGym`.

- [ ] **Step 3: Run** `-only-testing:GymRollinsTests/NearbyGymRuleTests -only-testing:GymRollinsUITests/GymPickerUITests`, then `TodayFlexUITests` and `TodayPlanScreenUITests`.

- [ ] **Step 4: Commit.** `git commit -m "feat(gyms): gym chip, picker and a one-shot nearby suggestion"`

---

### Task 7: Gym equipment screen

**Files:** create `GymEquipmentView.swift`, `GymEquipmentModel.swift`, `ListingDetailView.swift`; tests `GymEquipmentModelTests.swift`, UI in `GymEquipmentUITests.swift`.

- [ ] **Step 1: Failing tests.** `GymEquipmentModelTests`: `groupsByCategoryInOrder` (Machines, Cables, Free weights, Benches, Racks, Cardio, Accessories; empty ones left out), `coverageIsAmberBelowThree`, `coverageCountsOnlyServingListings` (a treadmill counts for nothing), `headerCountsAndAddress` ("Home · 3 items"), `unknownKindShowsUpdateTheApp` (a listing with a kind this app doesn't know: title "Update the app to use this item", ignored by the rules), `badgeForEachState` (`Only me` for device, `✓ N` for confirmations; `Flagged` and `Under review` are in the model now, used by plan 22).

- [ ] **Step 2: Implement.**
  - Reached from the picker. Title (`DisplayTitle`), address, item count; coverage badges for the 6 chips (`gymEquipment.coverage.<muscle>`; amber `Theme.record` when under 3), computed once per load with `WorkoutBuilder.itemCount`, off the main thread if it takes over 16 ms on the real library; photo tiles (`gymEquipment.listing.<kindId>`), grouped by category, with kind name (brand and model if any), loads text, badge, `×N` when quantity is over 1. Floating `+ Add equipment` (`gymEquipment.add`, primary glass). Empty state: "Nothing here yet. Add the first piece of equipment." Pull to refresh does nothing until plan 21, so it isn't offered yet.
  - Tile → `ListingDetailView`: full photo, kind, editable loads (the same control as Step 4), quantity, note, Save (`listing.save`), Delete with a confirmation (`listing.delete`, `listing.delete.confirm`), which removes the row and its photo files. A listing with no photo offers "Add a photo" (the camera or library, processed the same way).
  - Changes call `env.gymsChanged()`.

- [ ] **Step 3: Run** the suites.

- [ ] **Step 4: Commit.** `git commit -m "feat(gyms): the gym's equipment screen"`

---

### Task 8: Add equipment in 4 steps

**Files:** create `AddEquipmentFlow.swift`, `AddEquipmentModel.swift`, `AddEquipmentSteps.swift`, `CameraPicker.swift`; tests `AddEquipmentModelTests.swift`, UI `AddEquipmentUITests.swift`.

- [ ] **Step 1: Failing tests.** `AddEquipmentModelTests`:
  `skippingPhotoGoesToKind` · `kindWithNoListingSkipsTheDuplicateStep` · `kindAlreadyListedShowsTheDuplicateStep` · `yesThatsItCreatesNothing` (own listing at a phone-only gym: "Yes, that's it" ends the flow with no new row) · `pickingACatalogueItemCarriesBrandAndModel` · `differentOneGoesToDetails` · `stackDefaultsAndStepsInTheUserUnit` (lb: 250 lb, steps of 5 lb; kg: 110 kg, steps of 2.5 kg; stored in kg; can't go below one step or above 1000 kg) · `plateLoadedAndBodyweightHaveNoLoadInput` (`.plates`, `.none`) · `fixedSetRequiresAWeight` (Save disabled until one chip is on) · `fixedChipsMatchTheKind` (kettlebells offer 20 kg, shown "44 lb (20 kg)" to an lb user, and 44 and 53 lb chips store 20 and 24 kg; dumbbells offer 5 to 100 lb by 5, or 2 to 50 kg by 2; `All` selects every chip) · `saveStoresPhoneOnly` (`.device`, photo file set when there's a photo, nil when skipped) · `processorFailureOffersRetryOrSkip` (Vision failure message: "We couldn't check this photo for faces, so it wasn't saved. Try again or skip the photo."; too big: "This photo couldn't be made small enough. Try another one.") · `failedSaveDeletesTheJustSavedPhoto` (no orphan file).

  `AddEquipmentUITests` with `-gymPhotoFixture -seedGym`: `testAddWithPhoto`, `testSkipPhoto`, `testDuplicateStepAppears`, `testFixedSetChipsSaveAndShowOnTheScreen`, `testCancelLeavesNothing`.

- [ ] **Step 2: Implement.** A sheet with its own `NavigationStack`, reachable from `gymEquipment.add` and from Build's `+ Add equipment`.
  1. **Photo** (`addEquipment.photo`): reminder "Photograph the equipment, not people. Faces are blurred automatically." Camera opens at once when available (`UIImagePickerController` via `CameraPicker`, `fullScreenCover`; on the simulator it isn't available, so the step's buttons remain). Buttons: Take Photo (`addEquipment.camera`), Library (`addEquipment.library`, `PhotosPicker`; with `-gymPhotoFixture` it uses a generated image), Skip (`addEquipment.skip`). Processing shows a spinner and runs detached; the original image data is dropped right after.
  2. **Kind** (`addEquipment.kind`): "STEP 2 OF 4 · What is it?". Tiles `addEquipment.kind.<id>`. Common first in two groups: Machines (lat-pulldown, leg-press, chest-press-machine, pec-deck, seated-row-machine, leg-curl), Free weights · benches · racks (dumbbells, kettlebells, barbell, adjustable-bench, power-rack, cable-station), then the rest by category. Search field (`addEquipment.kindSearch`) filters all 46. Footer "Each kind already knows its exercises and muscles. You never tag muscles."
  3. **Already here?** (`addEquipment.duplicate`): existing listings of the kind at this gym with photo and loads, each "Yes, that's it" (`addEquipment.same.<listingId>`; the "+1 confirm" wording and server call are plan 21's); "Or a known model" from `catalogueItems(kindId:)` with "listed at N gyms"; Generic; "No, it's a different one" (`addEquipment.different`), which also offers optional Brand and Model fields on the next step.
  4. **Weights** (`addEquipment.details`): stack stepper (`addEquipment.stackMinus`, `addEquipment.stackPlus`, showing "250 lb (113 kg)"), or fixed-weight chips (`addEquipment.weight.<kg>`, `addEquipment.weightsAll`), or nothing. Who sees it: fixed "This phone only" text. Note (optional, 280). Save (`addEquipment.save`). Save shows errors inline and calls `env.gymsChanged()`.

- [ ] **Step 3: Run** the suites.

- [ ] **Step 4: Commit.** `git commit -m "feat(gyms): add equipment in 4 steps"`

---

### Task 9: Build workout

**Files:** create `BuildWorkoutSheet.swift`, `BuildResultView.swift`, `BuildResultModel.swift`; modify `TodayView.swift`, `TodayExerciseRow.swift`, `DesignSystem/ExerciseRow.swift`; tests `BuildResultModelTests.swift`, `BuildWorkoutScenarioTests.swift`, `BuildWorkoutUITests.swift`, additions to `AccessibilityAuditUITests` and `DynamicTypeUITests`.

- [ ] **Step 1: Failing tests.**
  - `BuildResultModelTests`: `titleJoinsChips` ("Back + Arms"), `subtitleCountsAndMinutes` ("Home · 4 exercises · ~45 min"), `rowShowsSetsRepsAndFittedLoad` ("3 × 10 · 53 lb (24 kg)"), `rowNamesItsListing`, `repeatRowHasBadgeAndReason` ("also Tuesday · no other Back option here"), `bodyweightFillIsMarked` ("no equipment"), `thinNoticeWords` ("Only 3 Back items catalogued at Home so far. Add a photo to unlock more variety."), `thinNoticeWithNoItems` ("No Back equipment catalogued at Home yet. Add a photo to unlock more variety."), `skippedChipsAreReported` ("No room for Core at 30 min"), `shortWorkoutSaysSo` ("4 of 6 exercises. That's all this gym has for these muscles right now.").
  - `BuildWorkoutScenarioTests` (criterion 1 and 3 at app level with the real library, a real `AppEnvironment`, and fake photos): `newGymFiveListingsBuildChest` (every equipment exercise links a listing with a photo; every kind is listed; fills are marked), `fourDaysInARow` (build, complete, next day; each of workouts 2 to 4 changes at least half, when the gym offers at least twice as many as the workout needs), `rebuildAlwaysChangesWhileThereIsMore`, `startBecomesTodaysPlan` (`TodayPlan.kind == .built`, title, the routine is unchanged, Start uses it; after `planStore.clear()` Today is back to the schedule).
  - `BuildWorkoutUITests`: `testBuildAtHomeShowsBannerAndStarts` (`-seedGym`), `testBuildWithNoGymOpensThePickerFirst`, `testRebuildChangesTheList`, `testSwappedBadgeOnToday` (a seeded routine with `-seedGym` shows `today.row.swapped.<id>`, the note, and "Your plan isn't changed"), `testUsePlannedAnyway`.
  - Add the gym picker, equipment screen, add flow and Build screens to `AccessibilityAuditUITests` and `DynamicTypeUITests`.

- [ ] **Step 2: Implement.**
  - **Today bottom bar:** `Build workout` (`today.build`, secondary glass) next to `Start Workout`; `ViewThatFits(in: .horizontal)` stacks them at large Dynamic Type. Shown whenever no session runs, including rest days and an empty plan. With no gym, it opens the picker and continues to the sheet after a gym is chosen.
  - **Row marks:** `TodayExerciseRow`: `.swapped` shows `Badge("SWAPPED", .record)` and a note line "for <planned> · no <kind> here" (identifier `today.row.swapped.<exerciseId>`); `.unavailable` shows `Badge("NOT HERE", .neutral)` and "not available here". `ExerciseRow` gains `note: String?` and `photoFile: String?`; with a photo, `GymPhotoView` replaces `ExerciseThumbnail`. The note above the rows is `today.gymNote` (glass, amber). The row's menu adds "Use <planned> anyway" (`today.menu.usePlanned`) for swapped rows.
  - **Sheet** (`build.sheet`, `.large`): "Build workout", "at <gym> · <n> items"; 6 large chips (`build.chip.<muscle>`, multi-select in tap order, `.isSelected` trait); segmented 30 / 45 / 60 min (`build.length.<minutes>`, default 45); Build (`build.go`, disabled with no chips). Chips and length are remembered per device (`gymrollins.buildSetup`).
  - **Result** (pushed; `build.result`): title and subtitle; banners (thin, with `+ Add equipment` `build.addEquipment`; skipped; short); rows `build.row.<exerciseId>` with `GymPhotoView` of the load listing, or the exercise thumbnail, subtitle, badges (`REPEAT`, `no equipment`); `Rebuild` (`build.rebuild`) appends the result to `avoid` in order; `Start` (`build.start`). A workout with no exercises says "Nothing fits yet" with the add link and no Start. After adding equipment it builds again with the same request and resets `avoid`.
  - **Start:** `TodayView` applies `TodayPlan.built(name:items:day:)` and starts as usual. If a session started meanwhile, it shows that one (the same rule as `start(from:)`).

- [ ] **Step 3: Run** the new suites and the whole app test target, UI tests included except `PerformanceUITests`, with the 26.4 `DEST`:

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4' scripts/ios-test.sh
```

- [ ] **Step 4: Commit.** `git commit -m "feat(gyms): build a workout from the gym's equipment"`

---

### Task 10: Documentation and outcome

**Files:** `README.md`, this plan, `docs/specs/2026-10-30-gym-equipment-design.md` (only where behaviour was decided differently: pinned items, location prompt).

- [ ] **Step 1:** Add the feature to the README in the existing voice.
- [ ] **Step 2:** Look at the app: launch on the simulator with `-seedGym -seedOwner`, walk the picker, add flow and Build, and check screenshots against the wireframes.
- [ ] **Step 3:** Tick the boxes and append `## Outcome` with real numbers.
- [ ] **Step 4: Commit.** `git commit -m "docs: plan 20 outcome"`

## Spec coverage (milestone 2)

| Spec item | Task |
|---|---|
| §4 on the phone: records, visibility, upload state, remote id, current gym per device | 1, 5 |
| §5 visibility levels (device only for now), no account | 1, 8 |
| §5 picker and location | 6 |
| §5 adding equipment | 8 |
| §5 photos | 3 |
| §5 plan adaptation | 2, 4, 5, 9 |
| §5 Build workout, including `AvailableLoads`, Rebuild, skipped, thin | 2, 5, 9 |
| §6 UI (Today chip, equipment screen, Build sheet, gym-floor rules) | 6, 7, 8, 9 |
| §7 errors: no signal, photo too big, Vision fails, location denied, Maps offline, unknown kind | 3, 6, 7, 8 |
| §1 criteria 1, 3, 5 at app level | 5, 9 |
| §1 criterion 6: no network path exists yet; guarded by a test in plan 21 | 21 |
