# Plan 19: Gym rules and equipment data (GymCore)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the curated equipment data (46 kinds, requirements for 1,107 library exercises) and the pure-Swift
rules that use it: which listings an exercise needs at a gym, fitting weights to a gym's loads, adapting today's
routine to a gym, and building a workout from a gym's equipment.

**Architecture:** Data first: `equipment-kinds.json` is hand-curated, `equipment-requirements.json` is generated
by a Node script with a review file, like the existing photo and alias mappings. The rules live in GymCore under
`Sources/GymCore/Gym/`: value types, no I/O, Swift Testing. `InventoryMatcher` answers availability;
`AvailableLoads` fits weights; `GymAdapter` and `WorkoutBuilder` use the matcher together with the existing
`ExerciseRanking`, `MuscleTaxonomy` and `RoutineExercise.defaults`. The Swap sheet's candidate order moves into
GymCore (`SwapOrdering`) so the adapter and the sheet share it. Nothing in the app uses the new rules yet; plan 20
wires them into Today and the gym screens.

**Tech Stack:** Swift 6.2, Swift Testing, Foundation, CryptoKit (via the existing `StableUUID`); Node 22
(`node --test`, no dependencies).

**Spec:** `docs/specs/2026-10-30-gym-equipment-design.md` (sections 4 and 5; milestone 1 in section 10).

**Roadmap (each plan is written just before it runs):** 19 rules and data (this plan) · 20 gyms and equipment on
the phone with no account (SwiftData models, gym picker, equipment screen, add flow, photo processing, Today
adaptation, Build workout) · 21 shared catalogue (migration, access rules, functions, buckets, outbox, two-user
suite) · 22 moderation and Claude (report, block, admin list, account deletion, MCP tools).

**Verified:** every code block below was compiled and run on a copy of GymCore on 2026-10-30: 48 new tests pass,
the full suite (429 tests) passes, and GymCore line coverage is 90.96%. The mapping script first mapped 1,191 of 1,324
exercises; review tightened it to 1,107 (118 need no equipment), see Task 2.

**Conventions for every task**
- Work on branch `feat-gym-rules`, created in Task 1 from `docs/gym-equipment-spec` (which holds the spec and
  this plan).
- Commit after each task with a conventional message. No `Co-Authored-By` or "Generated with" lines (the owner's
  rule).
- GymCore tests: `cd ios/Packages/GymCore && swift test --filter <SuiteName>`. All new Swift tests use Swift
  Testing (`import Testing`, `@Suite`, `@Test`, `#expect`).
- Style: value types with `let` properties, `///` doc comments on public API, lines under 120 characters where the
  surrounding code does (SwiftLint warns at 140).

## File structure

| File | Responsibility |
|---|---|
| `ios/GymRollins/Resources/equipment-kinds.json` | The 46 curated kinds (hand-written) |
| `scripts/map-equipment-requirements.mjs` (+ `.test.mjs`) | Generates the requirements JSON and the review file |
| `ios/GymRollins/Resources/equipment-requirements.json` | Generated: exercise id → requirement groups |
| `docs/import/equipment-requirements-review.md` | Generated: machine mappings and unmapped exercises for the owner |
| `GymCore/Gym/EquipmentKind.swift` | `EquipmentKind`, `EquipmentCategory`, `EquipmentLoadType`, JSON decoding |
| `GymCore/Gym/ExerciseRequirements.swift` | Requirement groups per exercise, JSON decoding |
| `GymCore/Gym/GymInventory.swift` | `ListingLoads` (Codable, the `loads` JSON shape), `InventoryListing`, `GymInventory` |
| `GymCore/Gym/AvailableLoads.swift` | Fits a weight and rep target to a listing's loads |
| `GymCore/Gym/InventoryMatcher.swift` | `InventoryMatch`, `Availability`, `InventoryMatcher` |
| `GymCore/Model/Exercise+Loading.swift` | `Exercise.isBarbellLoaded` (moved from the app's `LoadRounding`) |
| `GymCore/Preferences/SwapOrdering.swift` | Swap candidate order (moved from the app's `ExerciseSuggestions`) |
| `GymCore/Gym/GymAdapter.swift` | `AdaptedItem`, `GymAdapter` |
| `GymCore/Gym/BuildOptions.swift` | `BuildMuscle`, `BuildLength`, `BuildRequest` |
| `GymCore/Gym/StableHash.swift` | FNV-1a and the UTC day, for reproducible tie-breaks |
| `GymCore/Gym/WorkoutBuilder.swift` | Output types and `WorkoutBuilder.build` |
| `GymCore/Gym/WorkoutBuilder+Pool.swift` | Candidates per chip: filtering, ranking, recent exercises |
| `GymCore/Gym/SlotPicker.swift` | Slot-by-slot picking: once per exercise, machine cap, repeats |
| `GymCoreTests/Gym/*.swift`, `GymCoreTests/SwapOrderingTests.swift` | Tests, with `GymFixtures` as the shared library and gyms |

(`GymCore/` = `ios/Packages/GymCore/Sources/GymCore/`, `GymCoreTests/` = `ios/Packages/GymCore/Tests/GymCoreTests/`.)

---

### Task 1: Branch, equipment kinds and `EquipmentKind`

**Files:**
- Create: `ios/GymRollins/Resources/equipment-kinds.json`
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/EquipmentKind.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/EquipmentDataTests.swift`

- [x] **Step 1: Create the branch**

```bash
git switch docs/gym-equipment-spec && git switch -c feat-gym-rules
```

- [x] **Step 2: Write the kinds file**

`ios/GymRollins/Resources/equipment-kinds.json`:

```json
{
  "version": 1,
  "kinds": [
    { "id": "dumbbells", "name": "Dumbbells", "category": "free-weight", "load": "fixed-set" },
    { "id": "kettlebells", "name": "Kettlebells", "category": "free-weight", "load": "fixed-set" },
    { "id": "barbell", "name": "Barbell and plates", "category": "free-weight", "load": "plate-loaded" },
    { "id": "ez-bar", "name": "EZ curl bar", "category": "free-weight", "load": "plate-loaded" },
    { "id": "trap-bar", "name": "Trap bar", "category": "free-weight", "load": "plate-loaded" },
    { "id": "medicine-ball", "name": "Medicine ball", "category": "free-weight", "load": "fixed-set" },
    { "id": "flat-bench", "name": "Flat bench", "category": "bench", "load": "none" },
    { "id": "adjustable-bench", "name": "Adjustable bench", "category": "bench", "load": "none" },
    { "id": "incline-bench", "name": "Incline bench", "category": "bench", "load": "none" },
    { "id": "decline-bench", "name": "Decline bench", "category": "bench", "load": "none" },
    { "id": "preacher-bench", "name": "Preacher bench", "category": "bench", "load": "none" },
    { "id": "power-rack", "name": "Power or squat rack", "category": "rack", "load": "none" },
    { "id": "bench-press-station", "name": "Bench press station", "category": "rack", "load": "none" },
    { "id": "smith-machine", "name": "Smith machine", "category": "rack", "load": "plate-loaded" },
    { "id": "pull-up-bar", "name": "Pull-up bar", "category": "rack", "load": "bodyweight" },
    { "id": "dip-station", "name": "Dip station", "category": "rack", "load": "bodyweight" },
    { "id": "cable-station", "name": "Cable station", "category": "cable", "load": "stack" },
    { "id": "lat-pulldown", "name": "Lat pulldown", "category": "cable", "load": "stack" },
    { "id": "seated-cable-row", "name": "Seated cable row", "category": "cable", "load": "stack" },
    { "id": "chest-press-machine", "name": "Chest press machine", "category": "machine", "load": "stack" },
    { "id": "shoulder-press-machine", "name": "Shoulder press machine", "category": "machine", "load": "stack" },
    { "id": "pec-deck", "name": "Pec deck / rear delt fly", "category": "machine", "load": "stack" },
    { "id": "lateral-raise-machine", "name": "Lateral raise machine", "category": "machine", "load": "stack" },
    { "id": "seated-row-machine", "name": "Row machine", "category": "machine", "load": "stack" },
    { "id": "t-bar-row", "name": "T-bar row", "category": "machine", "load": "plate-loaded" },
    { "id": "assisted-pullup-dip", "name": "Assisted pull-up / dip machine", "category": "machine", "load": "stack" },
    { "id": "preacher-curl-machine", "name": "Biceps curl machine", "category": "machine", "load": "stack" },
    { "id": "triceps-machine", "name": "Triceps machine", "category": "machine", "load": "stack" },
    { "id": "ab-crunch-machine", "name": "Ab crunch machine", "category": "machine", "load": "stack" },
    { "id": "back-extension", "name": "Back extension bench", "category": "machine", "load": "bodyweight" },
    { "id": "leg-press", "name": "Leg press", "category": "machine", "load": "plate-loaded" },
    { "id": "hack-squat", "name": "Hack squat", "category": "machine", "load": "plate-loaded" },
    { "id": "leg-extension", "name": "Leg extension", "category": "machine", "load": "stack" },
    { "id": "leg-curl", "name": "Leg curl", "category": "machine", "load": "stack" },
    { "id": "calf-raise-machine", "name": "Calf raise machine", "category": "machine", "load": "stack" },
    { "id": "hip-abductor-adductor", "name": "Hip abductor / adductor", "category": "machine", "load": "stack" },
    { "id": "resistance-bands", "name": "Resistance bands", "category": "accessory", "load": "none" },
    { "id": "stability-ball", "name": "Stability ball", "category": "accessory", "load": "none" },
    { "id": "bosu-ball", "name": "BOSU ball", "category": "accessory", "load": "none" },
    { "id": "ab-wheel", "name": "Ab wheel", "category": "accessory", "load": "none" },
    { "id": "treadmill", "name": "Treadmill", "category": "cardio", "load": "none" },
    { "id": "stationary-bike", "name": "Stationary bike", "category": "cardio", "load": "none" },
    { "id": "elliptical", "name": "Elliptical", "category": "cardio", "load": "none" },
    { "id": "stepmill", "name": "Stepmill", "category": "cardio", "load": "none" },
    { "id": "skierg", "name": "SkiErg", "category": "cardio", "load": "none" },
    { "id": "upper-body-ergometer", "name": "Upper body ergometer", "category": "cardio", "load": "none" }
  ]
}
```

- [x] **Step 3: Write the failing test**

`ios/Packages/GymCore/Tests/GymCoreTests/Gym/EquipmentDataTests.swift` (Task 3 adds a second test to this suite):

```swift
import Foundation
import Testing
@testable import GymCore

/// The bundled equipment data (`ios/GymRollins/Resources/equipment-*.json`) decodes and fits the exercise library.
@Suite struct EquipmentDataTests {
    private static let resources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("GymRollins/Resources")

    private func load(_ name: String) throws -> Data {
        try Data(contentsOf: Self.resources.appendingPathComponent(name))
    }

    @Test func kindsDecodeWithUniqueIds() throws {
        let kinds = try EquipmentKind.decodeList(load("equipment-kinds.json"))
        #expect(kinds.count >= 40)
        #expect(Set(kinds.map(\.id)).count == kinds.count)
        #expect(kinds.first { $0.id == "kettlebells" }?.load == .fixedSet)
        #expect(kinds.first { $0.id == "leg-press" }?.isMachine == true)
        #expect(kinds.first { $0.id == "dumbbells" }?.isMachine == false)
    }
}
```

- [x] **Step 4: Run it and see it fail**

Run: `cd ios/Packages/GymCore && swift test --filter EquipmentDataTests`
Expected: build error `cannot find 'EquipmentKind' in scope`.

- [x] **Step 5: Implement `EquipmentKind`**

`ios/Packages/GymCore/Sources/GymCore/Gym/EquipmentKind.swift`:

```swift
import Foundation

/// How a kind of equipment is grouped in the app (docs/specs/2026-10-30-gym-equipment-design.md §4).
public enum EquipmentCategory: String, Codable, Sendable, CaseIterable {
    case machine, cable
    case freeWeight = "free-weight"
    case bench, rack, cardio, accessory
}

/// How a kind carries load: a weight stack, plates, a fixed set of weights (dumbbells, kettlebells), the user's
/// bodyweight, or nothing (benches, balls).
public enum EquipmentLoadType: String, Codable, Sendable, CaseIterable {
    case stack
    case plateLoaded = "plate-loaded"
    case fixedSet = "fixed-set"
    case bodyweight, none

    /// The listing of such a kind decides an exercise's weight (`InventoryMatch.loadListingId`).
    public var bearsLoad: Bool { self == .stack || self == .plateLoaded || self == .fixedSet }
}

/// A curated kind of equipment from the bundled `equipment-kinds.json`. Users pick one when they add equipment;
/// exercises name kinds in their requirements (`ExerciseRequirements`).
public struct EquipmentKind: Codable, Sendable, Identifiable, Hashable {
    public let id: String
    public let name: String
    public let category: EquipmentCategory
    public let load: EquipmentLoadType

    public init(id: String, name: String, category: EquipmentCategory, load: EquipmentLoadType) {
        self.id = id
        self.name = name
        self.category = category
        self.load = load
    }

    /// A machine for the builder's spread rule (at most 2 exercises each): it bears load and isn't a free weight, so
    /// weight stacks, cables, plate-loaded machines and the Smith machine, but not dumbbells or a barbell.
    public var isMachine: Bool { category != .freeWeight && (load == .stack || load == .plateLoaded) }

    /// Decodes `equipment-kinds.json`: `{"version": 1, "kinds": [...]}`.
    public static func decodeList(_ data: Data) throws -> [EquipmentKind] {
        try JSONDecoder().decode(KindsFile.self, from: data).kinds
    }

    private struct KindsFile: Decodable {
        let version: Int
        let kinds: [EquipmentKind]
    }
}
```

- [x] **Step 6: Run it and see it pass**

Run: `cd ios/Packages/GymCore && swift test --filter EquipmentDataTests`
Expected: `Test run with 1 test in 1 suite passed`.

- [x] **Step 7: Commit**

```bash
git add ios/GymRollins/Resources/equipment-kinds.json ios/Packages/GymCore/Sources/GymCore/Gym/EquipmentKind.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/Gym/EquipmentDataTests.swift
git commit -m "feat(core): curated equipment kinds"
```

---

### Task 2: The requirements mapping script

> **Changed after review (2026-10-30):** a review found about 50 exercises marked as needing less equipment than
> they do, and bodyweight fills that were really stretches or elite skills. The code below is the first version. The
> committed `scripts/map-equipment-requirements.mjs` and its tests are authoritative, and the expected counts are now
> `Mapped 1107 / 1324`, `no equipment: 118`, `Unmapped: 217`.

**Files:**
- Create: `scripts/map-equipment-requirements.mjs`
- Test: `scripts/map-equipment-requirements.test.mjs`
- Generated: `ios/GymRollins/Resources/equipment-requirements.json`, `docs/import/equipment-requirements-review.md`

The rules are conservative: a wrong requirement makes the app suggest an exercise the gym can't do, so unclear
names stay unmapped and land in the review file. Rule notes the tests pin down:
- Free weights need their load kind plus the bench the name implies (`incline`, `decline`, `bench`, `lying`, and for
  free weights only `fly`, `pullover`, `skull`). A ball in the name replaces the bench.
- Barbell presses need a bench and a rack, or a station that is both; barbell squats, lunges and good mornings
  need a rack.
- Leverage and sled machines go through `MACHINE_RULES` (first match wins, `null` = deliberately unmapped).
- Bodyweight exercises need a bar, dip station, bench, ball or back-extension bench only when the name says so;
  names that need rings, towels, ropes, boxes, steps and the like are unmapped.
- Stretches, `weighted`, `assisted` (partner), `rope`, `roller`, `hammer` and `tire` are unmapped.

- [x] **Step 1: Write the failing tests**

`scripts/map-equipment-requirements.test.mjs`:

```js
// Unit tests for the equipment-requirements mapper: node --test scripts/map-equipment-requirements.test.mjs
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { test } from 'node:test'
import {
  DECLINE_BENCH, FLAT_BENCH, INCLINE_BENCH, benchFor, buildRequirements, requirementsFor, review,
} from './map-equipment-requirements.mjs'

const ex = (n, eq, id = '0001') => ({ id, n, eq })
const groups = (n, eq) => requirementsFor(ex(n, eq)).groups
const unmapped = (n, eq) => requirementsFor(ex(n, eq)).unmapped

test('free weights need their load and the bench the name implies', () => {
  assert.deepEqual(groups('dumbbell curl', 'dumbbell'), [['dumbbells']])
  assert.deepEqual(groups('dumbbell incline fly', 'dumbbell'), [['dumbbells'], INCLINE_BENCH])
  assert.deepEqual(groups('dumbbell decline bench press', 'dumbbell'), [['dumbbells'], DECLINE_BENCH])
  assert.deepEqual(groups('dumbbell fly', 'dumbbell'), [['dumbbells'], FLAT_BENCH])
  assert.deepEqual(groups('kettlebell one arm row', 'kettlebell'), [['kettlebells']])
  assert.deepEqual(groups('ez barbell preacher curl', 'ez barbell'), [['ez-bar'], ['preacher-bench']])
  assert.deepEqual(groups('dumbbell incline fly on exercise ball', 'dumbbell'), [['dumbbells'], ['stability-ball']])
})

test('barbell presses need a bench and a rack, or a station that is both; squats need a rack', () => {
  assert.deepEqual(groups('barbell bench press', 'barbell'),
    [['barbell'], ['flat-bench', 'adjustable-bench', 'bench-press-station'], ['power-rack', 'bench-press-station']])
  assert.deepEqual(groups('barbell incline bench press', 'barbell'),
    [['barbell'], INCLINE_BENCH, ['power-rack', 'incline-bench']])
  assert.deepEqual(groups('barbell decline bench press', 'barbell'),
    [['barbell'], DECLINE_BENCH, ['power-rack', 'decline-bench']])
  assert.deepEqual(groups('barbell full squat', 'barbell'), [['barbell'], ['power-rack']])
  assert.deepEqual(groups('barbell curl', 'barbell'), [['barbell']])
  assert.deepEqual(groups('barbell lying triceps extension', 'barbell'), [['barbell'], FLAT_BENCH])
})

test('machines map to one specific kind, or stay unmapped', () => {
  assert.deepEqual(groups('lever chest press', 'leverage machine'), [['chest-press-machine']])
  assert.deepEqual(groups('lever seated squat calf raise on leg press machine', 'leverage machine'), [['leg-press']])
  assert.deepEqual(groups('lever standing calf raise', 'leverage machine'), [['calf-raise-machine']])
  assert.deepEqual(groups('hack calf raise', 'sled machine'), [['hack-squat']])
  assert.deepEqual(groups('sled 45° leg wide press', 'sled machine'), [['leg-press']])
  assert.deepEqual(groups('lever one arm lateral wide pulldown', 'leverage machine'), [['lat-pulldown']])
  assert.deepEqual(groups('lever one arm lateral high row', 'leverage machine'), [['seated-row-machine']])
  assert.deepEqual(groups('lever t bar row', 'leverage machine'), [['t-bar-row']])
  assert.deepEqual(groups('assisted pull-up', 'leverage machine'), [['assisted-pullup-dip']])
  assert.deepEqual(groups('lever overhand triceps dip', 'leverage machine'), [['triceps-machine']])
  assert.deepEqual(groups('walking on incline treadmill', 'leverage machine'), [['treadmill']])
  assert.equal(unmapped('lever shrug', 'leverage machine'), 'machine not identified')
  assert.equal(unmapped('lever bent-over row with v-bar', 'leverage machine'), 'machine not identified')
  assert.equal(unmapped('lever reverse hyperextension', 'leverage machine'), 'machine not identified')
})

test('cables use a pulldown or row station when the name says so, and a bench only when named', () => {
  assert.deepEqual(groups('cable pulldown', 'cable'), [['lat-pulldown', 'cable-station']])
  assert.deepEqual(groups('cable seated row', 'cable'), [['seated-cable-row', 'cable-station']])
  assert.deepEqual(groups('cable middle fly', 'cable'), [['cable-station']], 'a standing cable fly needs no bench')
  assert.deepEqual(groups('cable incline fly', 'cable'), [['cable-station'], INCLINE_BENCH])
  assert.deepEqual(groups('smith bench press', 'smith machine'), [['smith-machine'], FLAT_BENCH])
})

test('bodyweight needs a bar, dip station, bench or ball only when named', () => {
  assert.deepEqual(groups('pull-up', 'body weight'), [['pull-up-bar', 'power-rack']])
  assert.deepEqual(groups('hanging leg raise', 'body weight'), [['pull-up-bar', 'power-rack']])
  assert.deepEqual(groups('chest dip', 'body weight'), [['dip-station', 'assisted-pullup-dip']])
  assert.deepEqual(groups('chest dip (on dip-pull-up cage)', 'body weight'), [['dip-station', 'assisted-pullup-dip']])
  assert.deepEqual(groups('triceps dip (between benches)', 'body weight'), [FLAT_BENCH])
  assert.deepEqual(groups('triceps dips floor', 'body weight'), [])
  assert.deepEqual(groups('inverted row', 'body weight'), [['power-rack', 'smith-machine']])
  assert.deepEqual(groups('hyperextension', 'body weight'), [['back-extension']])
  assert.deepEqual(groups('incline push-up', 'body weight'), [FLAT_BENCH])
  assert.deepEqual(groups('push-up', 'body weight'), [])
  assert.equal(unmapped('ring dips', 'body weight'), 'needs equipment that has no kind')
  assert.equal(unmapped('incline push-up (on box)', 'body weight'), 'needs equipment that has no kind')
})

test('stretches, partner-assisted and kind-less equipment are unmapped', () => {
  assert.equal(unmapped('assisted lying glutes stretch', 'assisted'), 'stretch')
  assert.equal(unmapped('calf stretch with rope', 'rope'), 'stretch')
  assert.equal(unmapped('assisted sit-up', 'assisted'), 'no kind for "assisted"')
  assert.equal(unmapped('weighted pull-up', 'weighted'), 'no kind for "weighted"')
  assert.equal(unmapped('battling ropes', 'rope'), 'no kind for "rope"')
  assert.equal(unmapped('mystery move', 'hoverboard'), 'unknown equipment "hoverboard"')
})

test('benchFor: a ball replaces the bench, and only free weights read "fly" as lying on a bench', () => {
  assert.deepEqual(benchFor('cable incline fly (on stability ball)', { fly: false }), [['stability-ball']])
  assert.deepEqual(benchFor('dumbbell fly', { fly: true }), [FLAT_BENCH])
  assert.deepEqual(benchFor('cable middle fly', { fly: false }), [])
})

test('buildRequirements rejects kinds that are not in equipment-kinds.json', () => {
  assert.throws(() => buildRequirements([ex('dumbbell curl', 'dumbbell')], ['barbell']), /unknown kind "dumbbells"/)
})

test('the real library maps with known kinds, and the review lists machines and unmapped exercises', () => {
  const root = resolve(import.meta.dirname, '..')
  const library = JSON.parse(readFileSync(resolve(root, 'ios/GymRollins/Resources/exercises.json'), 'utf8'))
  const kinds = JSON.parse(readFileSync(resolve(root, 'ios/GymRollins/Resources/equipment-kinds.json'), 'utf8')).kinds
  const result = buildRequirements(library, kinds.map(k => k.id))
  const mapped = Object.keys(result.requirements).length
  assert.equal(mapped + result.unmapped.length, library.length)
  assert.ok(mapped >= 1_150, `expected most exercises mapped, got ${mapped}`)
  const text = review(library, result)
  assert.match(text, /## Machines \(check these\)/)
  assert.match(text, /\| lever chest press \| chest-press-machine \|/)
  assert.match(text, /\| stretch \| /)
})
```

- [x] **Step 2: Run them and see them fail**

Run: `node --test scripts/map-equipment-requirements.test.mjs`
Expected: FAIL with `Cannot find module '.../scripts/map-equipment-requirements.mjs'`.

- [x] **Step 3: Write the script**

`scripts/map-equipment-requirements.mjs`:

```js
#!/usr/bin/env node
// Maps every library exercise to the equipment kinds it needs (docs/specs/2026-10-30-gym-equipment-design.md §4).
// Each exercise gets requirement groups that ALL have to be present, any one kind per group:
//   [["barbell"], ["flat-bench", "adjustable-bench", "bench-press-station"], ["power-rack", "bench-press-station"]]
// `[]` = no equipment. An exercise missing from the output is unmapped: the app still logs it but never picks it.
// Conservative on purpose (a wrong requirement suggests an exercise the gym can't do): unclear names stay unmapped
// and are listed in the review file.
//
// Usage: node scripts/map-equipment-requirements.mjs
//   Reads ios/GymRollins/Resources/exercises.json and equipment-kinds.json, writes
//   ios/GymRollins/Resources/equipment-requirements.json and docs/import/equipment-requirements-review.md.
// Tests: node --test scripts/map-equipment-requirements.test.mjs
import { readFileSync, writeFileSync } from 'node:fs'
import { resolve } from 'node:path'

const ROOT = resolve(import.meta.dirname, '..')
const LIBRARY = resolve(ROOT, 'ios/GymRollins/Resources/exercises.json')
const KINDS = resolve(ROOT, 'ios/GymRollins/Resources/equipment-kinds.json')
const OUT_JSON = resolve(ROOT, 'ios/GymRollins/Resources/equipment-requirements.json')
const OUT_REVIEW = resolve(ROOT, 'docs/import/equipment-requirements-review.md')

export const FLAT_BENCH = ['flat-bench', 'adjustable-bench']
export const INCLINE_BENCH = ['adjustable-bench', 'incline-bench']
export const DECLINE_BENCH = ['adjustable-bench', 'decline-bench']
const BALL = /stability ball|exercise ball|swiss ball/

/** Free weights: the library's `eq` -> the kind that carries the load. */
const FREE_WEIGHTS = {
  dumbbell: 'dumbbells', kettlebell: 'kettlebells', barbell: 'barbell', 'olympic barbell': 'barbell',
  'ez barbell': 'ez-bar', 'trap bar': 'trap-bar', 'medicine ball': 'medicine-ball',
}
/** Equipment that maps one to one to a kind. */
const DIRECT = {
  band: 'resistance-bands', 'resistance band': 'resistance-bands', 'stability ball': 'stability-ball',
  'bosu ball': 'bosu-ball', 'wheel roller': 'ab-wheel', 'stationary bike': 'stationary-bike',
  'elliptical machine': 'elliptical', 'stepmill machine': 'stepmill', 'skierg machine': 'skierg',
  'upper body ergometer': 'upper-body-ergometer',
}
/** Equipment with no kind, or partner-assisted ("assisted"): always unmapped. */
const NO_KIND = new Set(['weighted', 'assisted', 'rope', 'roller', 'hammer', 'tire'])
/** Bodyweight exercises that need something the kinds list doesn't have. */
const NEEDS_OTHER = /\brings?\b|towel|rope|\bbox\b|stool|chair|\bstep\b|platform|sled/

/** Leverage and sled machines, first match wins; `null` = deliberately unmapped. */
export const MACHINE_RULES = [
  [/hack.*calf/, ['hack-squat']],
  [/on leg press|^sled .*calf/, ['leg-press']],
  [/calf/, ['calf-raise-machine']],
  [/hack squat/, ['hack-squat']],
  [/leg (wide )?press/, ['leg-press']],
  [/assisted/, ['assisted-pullup-dip']],
  [/leg extension/, ['leg-extension']],
  [/leg curl/, ['leg-curl']],
  [/hip (abduction|adduction)/, ['hip-abductor-adductor']],
  [/chest press/, ['chest-press-machine']],
  [/shoulder press|military press/, ['shoulder-press-machine']],
  [/lateral raise/, ['lateral-raise-machine']],
  [/seated (reverse )?fly/, ['pec-deck']],
  [/pulldown/, ['lat-pulldown']],
  [/\bt[- ]?bar\b/, ['t-bar-row']],
  [/bent-over/, null],
  [/\brow\b/, ['seated-row-machine']],
  [/preacher curl|bicep curl/, ['preacher-curl-machine']],
  [/triceps (extension|dip)|seated dip/, ['triceps-machine']],
  [/crunch|kneeling twist/, ['ab-crunch-machine']],
  [/reverse hyperextension/, null],
  [/back extension|hyperextension/, ['back-extension']],
  [/treadmill/, ['treadmill']],
  [/stationary bike/, ['stationary-bike']],
  [/cross trainer/, ['elliptical']],
]

/** The bench an exercise needs, as zero or one requirement group. A ball replaces the bench; only free weights
 *  read "fly", "pullover" and "skull" as lying on a bench (cable flies are standing). */
export function benchFor(name, { fly }) {
  if (BALL.test(name)) return [['stability-ball']]
  if (/preacher/.test(name)) return [['preacher-bench']]
  if (/\bincline\b/.test(name)) return [INCLINE_BENCH]
  if (/\bdecline\b/.test(name)) return [DECLINE_BENCH]
  if (/\bbench\b|\blying\b/.test(name) || (fly && /\bfly\b|pullover|skull/.test(name))) return [FLAT_BENCH]
  return []
}

/** Barbell presses from uprights: a bench plus a rack, or one station that is both. */
function barbellPress(name) {
  if (/\bincline\b/.test(name)) return [INCLINE_BENCH, ['power-rack', 'incline-bench']]
  if (/\bdecline\b/.test(name)) return [DECLINE_BENCH, ['power-rack', 'decline-bench']]
  return [[...FLAT_BENCH, 'bench-press-station'], ['power-rack', 'bench-press-station']]
}

function freeWeight(name, eq) {
  const load = [FREE_WEIGHTS[eq]]
  if (load[0] !== 'barbell') return { groups: [load, ...benchFor(name, { fly: true })] }
  if (/bench press|(incline|decline).*press/.test(name)) return { groups: [load, ...barbellPress(name)] }
  if (/squat|lunge|good morning/.test(name)) {
    return { groups: [load, ['power-rack'], ...benchFor(name, { fly: true })] }
  }
  return { groups: [load, ...benchFor(name, { fly: true })] }
}

function cable(name) {
  const base = /pulldown|pull-down|pull down/.test(name) ? ['lat-pulldown', 'cable-station']
    : /seated.*row|low row|floor seated/.test(name) ? ['seated-cable-row', 'cable-station']
      : ['cable-station']
  return { groups: [base, ...benchFor(name, { fly: false })] }
}

function machine(name) {
  const rule = MACHINE_RULES.find(([re]) => re.test(name))
  return rule?.[1] ? { groups: [rule[1]] } : { unmapped: 'machine not identified' }
}

/** Bodyweight exercises need a bar, dip station, bench, ball or back-extension bench only when the name says so. */
export function bodyweight(name) {
  if (NEEDS_OTHER.test(name)) return { unmapped: 'needs equipment that has no kind' }
  if (/\bdips?\b/.test(name)) {
    if (/floor/.test(name)) return { groups: [] }
    if (/\bbench(es)?\b/.test(name)) return { groups: [FLAT_BENCH] }
    return { groups: [['dip-station', 'assisted-pullup-dip']] }
  }
  if (/pull-?up|chin-?up|muscle[- ]?up|hanging|\bhang\b/.test(name)) return { groups: [['pull-up-bar', 'power-rack']] }
  if (/inverted row/.test(name)) return { groups: [['power-rack', 'smith-machine']] }
  if (BALL.test(name)) return { groups: [['stability-ball']] }
  if (/back extension|hyperextension/.test(name)) return { groups: [['back-extension']] }
  if (/\bbench\b|incline push|decline push/.test(name)) return { groups: [FLAT_BENCH] }
  return { groups: [] }
}

/** Requirement groups for one library exercise (`{ groups }`), or `{ unmapped: reason }`. */
export function requirementsFor({ n, eq }) {
  const name = n.toLowerCase()
  if (/stretch/.test(name)) return { unmapped: 'stretch' }
  if (NO_KIND.has(eq)) return { unmapped: `no kind for "${eq}"` }
  if (eq === 'leverage machine' || eq === 'sled machine') return machine(name)
  if (eq === 'cable') return cable(name)
  if (eq === 'smith machine') return { groups: [['smith-machine'], ...benchFor(name, { fly: false })] }
  if (eq === 'body weight') return bodyweight(name)
  if (FREE_WEIGHTS[eq]) return freeWeight(name, eq)
  if (DIRECT[eq]) return { groups: [[DIRECT[eq]]] }
  return { unmapped: `unknown equipment "${eq}"` }
}

/** Maps the whole library. Throws when a rule names a kind that isn't in equipment-kinds.json. */
export function buildRequirements(library, kindIds) {
  const known = new Set(kindIds)
  const requirements = {}
  const unmapped = []
  for (const ex of library) {
    const result = requirementsFor(ex)
    if (result.unmapped) {
      unmapped.push({ id: ex.id, n: ex.n, eq: ex.eq, reason: result.unmapped })
      continue
    }
    const unknown = result.groups.flat().find(kind => !known.has(kind))
    if (unknown) throw new Error(`${ex.id} ${ex.n}: unknown kind "${unknown}"`)
    requirements[ex.id] = result.groups
  }
  return { requirements, unmapped }
}

/** The owner's review file: counts, every machine mapping, every unmapped exercise. */
export function review(library, { requirements, unmapped }) {
  const cell = s => String(s).replaceAll('|', '\\|')
  const needs = groups => groups.map(g => g.join(' or ')).join(' + ')
  const none = Object.values(requirements).filter(g => g.length === 0).length
  const machines = library.filter(e => (e.eq === 'leverage machine' || e.eq === 'sled machine') && requirements[e.id])
  const sortedUnmapped = [...unmapped].sort((a, b) => a.reason.localeCompare(b.reason) || a.id.localeCompare(b.id))
  return [
    '# Equipment requirements review',
    '',
    'Generated by `node scripts/map-equipment-requirements.mjs`; do not edit by hand. Check the machine table and the',
    'unmapped list. To fix a row, change the rules in the script and run it again.',
    '',
    `- Library exercises: ${library.length}`,
    `- Mapped: ${Object.keys(requirements).length} (no equipment: ${none})`,
    `- Unmapped: ${unmapped.length}`,
    '',
    '## Machines (check these)',
    '',
    '| Id | Library name | Needs |',
    '|---|---|---|',
    ...machines.map(e => `| ${e.id} | ${cell(e.n)} | ${needs(requirements[e.id])} |`),
    '',
    '## Unmapped',
    '',
    '| Reason | Id | Library name | Equipment |',
    '|---|---|---|---|',
    ...sortedUnmapped.map(u => `| ${cell(u.reason)} | ${u.id} | ${cell(u.n)} | ${u.eq} |`),
    '',
  ].join('\n')
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const library = JSON.parse(readFileSync(LIBRARY, 'utf8'))
  const kinds = JSON.parse(readFileSync(KINDS, 'utf8')).kinds
  const result = buildRequirements(library, kinds.map(k => k.id))
  const sorted = Object.fromEntries(Object.entries(result.requirements).sort((a, b) => a[0].localeCompare(b[0])))
  writeFileSync(OUT_JSON, `${JSON.stringify({ version: 1, requirements: sorted })}\n`)
  writeFileSync(OUT_REVIEW, review(library, result))
  console.log(`Mapped ${Object.keys(sorted).length} / ${library.length} exercises -> ${OUT_JSON}`)
}
```

- [x] **Step 4: Run the tests and see them pass**

Run: `node --test scripts/map-equipment-requirements.test.mjs`
Expected: `# pass 9`, `# fail 0`.

- [x] **Step 5: Generate the data and the review file**

Run: `node scripts/map-equipment-requirements.mjs`
Expected: `Mapped 1191 / 1324 exercises -> .../ios/GymRollins/Resources/equipment-requirements.json`.
Then open `docs/import/equipment-requirements-review.md` and check that the summary reads
`Mapped: 1191 (no equipment: 220)` and `Unmapped: 133`.

- [x] **Step 6: Commit**

```bash
git add scripts/map-equipment-requirements.mjs scripts/map-equipment-requirements.test.mjs \
  ios/GymRollins/Resources/equipment-requirements.json docs/import/equipment-requirements-review.md
git commit -m "feat(data): map library exercises to equipment requirements"
```

---

### Task 3: `ExerciseRequirements`

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/ExerciseRequirements.swift`
- Modify: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/EquipmentDataTests.swift` (add one test)

- [x] **Step 1: Write the failing test**

Add to `EquipmentDataTests`, after `kindsDecodeWithUniqueIds`:

```swift
    @Test func requirementsNameKnownKindsAndLibraryExercises() throws {
        let kinds = Set(try EquipmentKind.decodeList(load("equipment-kinds.json")).map(\.id))
        let requirements = try ExerciseRequirements.decode(load("equipment-requirements.json"))
        let library = Set(try JSONDecoder().decode([Exercise].self, from: load("exercises.json")).map(\.id))
        #expect(requirements.groups.count >= 1_000)
        #expect(Set(requirements.groups.flatMap { $0.value.flatMap { $0 } }).isSubset(of: kinds))
        #expect(Set(requirements.groups.keys).isSubset(of: library))
        #expect(requirements.groups.values.allSatisfy { $0.allSatisfy { !$0.isEmpty } })
    }
```

- [x] **Step 2: Run it and see it fail**

Run: `cd ios/Packages/GymCore && swift test --filter EquipmentDataTests`
Expected: build error `cannot find 'ExerciseRequirements' in scope`.

- [x] **Step 3: Implement**

`ios/Packages/GymCore/Sources/GymCore/Gym/ExerciseRequirements.swift`:

```swift
import Foundation

/// The equipment each library exercise needs: requirement groups that must all be present, any one kind per group,
/// e.g. `[["dumbbells"], ["flat-bench", "adjustable-bench"]]`. An empty list means no equipment. An exercise that
/// isn't listed is unmapped: it can still be logged and swapped in by hand, but the adapter and the builder never
/// pick it. Generated by `scripts/map-equipment-requirements.mjs` into the bundled `equipment-requirements.json`.
public struct ExerciseRequirements: Sendable, Equatable {
    public let groups: [String: [[String]]]

    public init(groups: [String: [[String]]]) {
        self.groups = groups
    }

    /// The requirement groups for an exercise; nil when it's unmapped.
    public func requirement(for exerciseId: String) -> [[String]]? { groups[exerciseId] }

    /// Decodes `equipment-requirements.json`: `{"version": 1, "requirements": {"<exerciseId>": [[...]]}}`.
    public static func decode(_ data: Data) throws -> ExerciseRequirements {
        ExerciseRequirements(groups: try JSONDecoder().decode(RequirementsFile.self, from: data).requirements)
    }

    private struct RequirementsFile: Decodable {
        let version: Int
        let requirements: [String: [[String]]]
    }
}
```

- [x] **Step 4: Run it and see it pass**

Run: `cd ios/Packages/GymCore && swift test --filter EquipmentDataTests`
Expected: `Test run with 2 tests in 1 suite passed`.

- [x] **Step 5: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Gym/ExerciseRequirements.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/Gym/EquipmentDataTests.swift
git commit -m "feat(core): decode exercise equipment requirements"
```

---

### Task 4: Listings, loads and the gym inventory

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/GymInventory.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymInventoryTests.swift`

`ListingLoads` encodes to the exact JSON the server will store in `gym_equipment.loads` (spec §4).

- [x] **Step 1: Write the failing tests**

`ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymInventoryTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct GymInventoryTests {
    @Test(arguments: [
        (#"{"type":"stack","maxKg":113.4,"stepKg":4.5}"#, ListingLoads.stack(maxKg: 113.4, stepKg: 4.5)),
        (#"{"type":"stack","maxKg":90}"#, ListingLoads.stack(maxKg: 90, stepKg: nil)),
        (#"{"type":"fixed","kg":[20,24]}"#, ListingLoads.fixed(kg: [20, 24])),
        (#"{"type":"plates"}"#, ListingLoads.plates),
        (#"{"type":"none"}"#, ListingLoads.none),
    ])
    func loadsDecodeAndRoundTrip(json: String, expected: ListingLoads) throws {
        let decoded = try JSONDecoder().decode(ListingLoads.self, from: Data(json.utf8))
        #expect(decoded == expected)
        let again = try JSONDecoder().decode(ListingLoads.self, from: JSONEncoder().encode(decoded))
        #expect(again == expected)
    }

    @Test func unknownLoadsTypeThrows() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ListingLoads.self, from: Data(#"{"type":"magic"}"#.utf8))
        }
    }

    @Test func ownListingsScoreOneMoreConfirmation() {
        #expect(InventoryListing(id: UUID(), kindId: "x", confirmCount: 3, isOwn: true).score == 4)
        #expect(InventoryListing(id: UUID(), kindId: "x", confirmCount: 3).score == 3)
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run: `cd ios/Packages/GymCore && swift test --filter GymInventoryTests`
Expected: build error `cannot find 'ListingLoads' in scope`.

- [x] **Step 3: Implement**

`ios/Packages/GymCore/Sources/GymCore/Gym/GymInventory.swift`:

```swift
import Foundation

/// The loads a listing offers, stored as `gym_equipment.loads` (weights in kg).
public enum ListingLoads: Sendable, Hashable, Codable {
    /// A weight stack up to `maxKg`, in `stepKg` increments when known.
    case stack(maxKg: Double, stepKg: Double?)
    /// A fixed set of weights, e.g. kettlebells of 20 and 24 kg.
    case fixed(kg: [Double])
    /// Plates: rounding follows the profile's plate inventory, as it does today.
    case plates
    case none

    private enum CodingKeys: String, CodingKey { case type, maxKg, stepKg, kg }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "stack":
            self = .stack(maxKg: try c.decode(Double.self, forKey: .maxKg),
                          stepKg: try c.decodeIfPresent(Double.self, forKey: .stepKg))
        case "fixed": self = .fixed(kg: try c.decode([Double].self, forKey: .kg))
        case "plates": self = .plates
        case "none": self = .none
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown loads type \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .stack(maxKg, stepKg):
            try c.encode("stack", forKey: .type)
            try c.encode(maxKg, forKey: .maxKg)
            try c.encodeIfPresent(stepKg, forKey: .stepKg)
        case let .fixed(kg):
            try c.encode("fixed", forKey: .type)
            try c.encode(kg, forKey: .kg)
        case .plates: try c.encode("plates", forKey: .type)
        case .none: try c.encode("none", forKey: .type)
        }
    }
}

/// One active listing at a gym, as the rules see it. The caller passes only active listings: the gym's shared ones
/// plus the user's own (synced or "This phone only").
public struct InventoryListing: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let kindId: String
    public let loads: ListingLoads
    public let confirmCount: Int
    /// Added by this user; the matcher prefers these and the builder ranks them like one more confirmation.
    public let isOwn: Bool

    public init(id: UUID, kindId: String, loads: ListingLoads = .none, confirmCount: Int = 0, isOwn: Bool = false) {
        self.id = id
        self.kindId = kindId
        self.loads = loads
        self.confirmCount = confirmCount
        self.isOwn = isOwn
    }

    /// The builder's ranking score: confirmations, plus one for the user's own listing.
    var score: Int { confirmCount + (isOwn ? 1 : 0) }
}

/// The equipment the rules may use at one gym.
public struct GymInventory: Sendable, Hashable {
    public let gymName: String
    public let listings: [InventoryListing]

    public init(gymName: String, listings: [InventoryListing]) {
        self.gymName = gymName
        self.listings = listings
    }
}
```

- [x] **Step 4: Run them and see them pass**

Run: `cd ios/Packages/GymCore && swift test --filter GymInventoryTests`
Expected: `Test run with 3 tests in 1 suite passed` (a parameterized test counts once).

- [x] **Step 5: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Gym/GymInventory.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymInventoryTests.swift
git commit -m "feat(core): gym inventory and listing loads"
```

---

### Task 5: `AvailableLoads`

> **Changed after review (2026-10-30):** the committed code also guards a stack with no positive maximum and never
> returns a weight above the maximum. The code below is the first version.

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/AvailableLoads.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/AvailableLoadsTests.swift`

- [x] **Step 1: Write the failing tests**

`ios/Packages/GymCore/Tests/GymCoreTests/Gym/AvailableLoadsTests.swift`:

```swift
import Testing
@testable import GymCore

@Suite struct AvailableLoadsTests {
    private let bells = ListingLoads.fixed(kg: [24, 20])

    @Test func fixedSetPicksTheNearestWeight() {
        #expect(AvailableLoads.fit(weightKg: 21, reps: 10, to: bells) == FittedLoad(weightKg: 20, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 23, reps: 10, to: bells) == FittedLoad(weightKg: 24, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 10, reps: 10, to: bells) == FittedLoad(weightKg: 20, reps: 10))
    }

    @Test func fixedSetTiesGoToTheLighterWeight() {
        #expect(AvailableLoads.fit(weightKg: 22, reps: 8, to: bells) == FittedLoad(weightKg: 20, reps: 8))
    }

    @Test func pastTheHeaviestWeightKeepsItAndAddsReps() {
        #expect(AvailableLoads.fit(weightKg: 26, reps: 10, to: bells)
            == FittedLoad(weightKg: 24, reps: 12, atHeaviest: true))
        #expect(AvailableLoads.fit(weightKg: 120, reps: 8, to: .stack(maxKg: 113, stepKg: 4.5))
            == FittedLoad(weightKg: 113, reps: 10, atHeaviest: true))
    }

    @Test func stackSnapsToItsStep() {
        #expect(AvailableLoads.fit(weightKg: 50, reps: 10, to: .stack(maxKg: 113, stepKg: 4.5))
            == FittedLoad(weightKg: 49.5, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 51, reps: 10, to: .stack(maxKg: 113, stepKg: nil))
            == FittedLoad(weightKg: 51, reps: 10))
        #expect(AvailableLoads.fit(weightKg: 1, reps: 10, to: .stack(maxKg: 113, stepKg: 4.5))
            == FittedLoad(weightKg: 4.5, reps: 10), "never below one plate of the stack")
    }

    @Test func platesNoneEmptySetsAndNoSuggestionChangeNothing() {
        #expect(AvailableLoads.fit(weightKg: 61.2, reps: 5, to: .plates) == FittedLoad(weightKg: 61.2, reps: 5))
        #expect(AvailableLoads.fit(weightKg: 61.2, reps: 5, to: .none) == FittedLoad(weightKg: 61.2, reps: 5))
        #expect(AvailableLoads.fit(weightKg: 30, reps: 5, to: .fixed(kg: [])) == FittedLoad(weightKg: 30, reps: 5))
        #expect(AvailableLoads.fit(weightKg: 0, reps: 10, to: bells) == FittedLoad(weightKg: 0, reps: 10))
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run: `cd ios/Packages/GymCore && swift test --filter AvailableLoadsTests`
Expected: build error `cannot find 'AvailableLoads' in scope`.

- [x] **Step 3: Implement**

`ios/Packages/GymCore/Sources/GymCore/Gym/AvailableLoads.swift`:

```swift
import Foundation

/// A suggested weight and rep target after fitting them to what a listing offers.
public struct FittedLoad: Sendable, Equatable {
    public let weightKg: Double
    public let reps: Int
    /// The suggestion was heavier than anything available: the heaviest weight is kept and the rep target raised.
    public let atHeaviest: Bool

    public init(weightKg: Double, reps: Int, atHeaviest: Bool = false) {
        self.weightKg = weightKg
        self.reps = reps
        self.atHeaviest = atHeaviest
    }
}

/// Fits a progression suggestion to a listing's loads (spec §5, Build workout step 8): a weight stack caps and
/// snaps to its step, a fixed set picks the nearest weight it has (ties go to the lighter one). Past the heaviest
/// weight the load stays there and the rep target goes up instead. Plates and no-load listings change nothing; the
/// existing plate rounding already applies to them.
public enum AvailableLoads {
    /// Reps added to the target when the suggestion is past the heaviest available weight.
    public static let extraRepsAtHeaviest = 2
    private static let toleranceKg = 0.01

    public static func fit(weightKg: Double, reps: Int, to loads: ListingLoads) -> FittedLoad {
        let unchanged = FittedLoad(weightKg: weightKg, reps: reps)
        guard weightKg > 0 else { return unchanged }
        switch loads {
        case let .stack(maxKg, stepKg):
            if weightKg > maxKg + toleranceKg { return heaviest(maxKg, reps: reps) }
            guard let stepKg, stepKg > 0 else { return unchanged }
            let snapped = min(maxKg, max(stepKg, (weightKg / stepKg).rounded() * stepKg))
            return FittedLoad(weightKg: snapped, reps: reps)
        case let .fixed(kg):
            let weights = kg.filter { $0 > 0 }.sorted()
            guard let top = weights.last else { return unchanged }
            if weightKg > top + toleranceKg { return heaviest(top, reps: reps) }
            let nearest = weights.min { abs($0 - weightKg) < abs($1 - weightKg) } ?? top
            return FittedLoad(weightKg: nearest, reps: reps)
        case .plates, .none:
            return unchanged
        }
    }

    private static func heaviest(_ kg: Double, reps: Int) -> FittedLoad {
        FittedLoad(weightKg: kg, reps: reps + extraRepsAtHeaviest, atHeaviest: true)
    }
}
```

- [x] **Step 4: Run them and see them pass**

Run: `cd ios/Packages/GymCore && swift test --filter AvailableLoadsTests`
Expected: `Test run with 5 tests in 1 suite passed`.

- [x] **Step 5: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Gym/AvailableLoads.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/Gym/AvailableLoadsTests.swift
git commit -m "feat(core): fit suggested weights to a listing's loads"
```

---

### Task 6: Test fixtures and `InventoryMatcher`

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/InventoryMatcher.swift`
- Create: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymFixtures.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/InventoryMatcherTests.swift`

`GymFixtures` is the shared test library for Tasks 6–11: 20 exercises with hand-written requirements (one
deliberately unmapped) and two gyms. Home is the owner's real setup: a flat bench and kettlebells of 20 and 24 kg.

- [x] **Step 1: Write the fixtures**

`ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymFixtures.swift`:

```swift
import Foundation
@testable import GymCore

/// A small library, its requirements and two gyms for the gym rules tests: Home (a flat bench and kettlebells of
/// 20 and 24 kg, the owner's real setup) and Iron (a commercial gym).
enum GymFixtures {
    static let kinds: [EquipmentKind] = [
        EquipmentKind(id: "dumbbells", name: "Dumbbells", category: .freeWeight, load: .fixedSet),
        EquipmentKind(id: "kettlebells", name: "Kettlebells", category: .freeWeight, load: .fixedSet),
        EquipmentKind(id: "barbell", name: "Barbell", category: .freeWeight, load: .plateLoaded),
        EquipmentKind(id: "flat-bench", name: "Flat bench", category: .bench, load: .none),
        EquipmentKind(id: "adjustable-bench", name: "Adjustable bench", category: .bench, load: .none),
        EquipmentKind(id: "incline-bench", name: "Incline bench", category: .bench, load: .none),
        EquipmentKind(id: "power-rack", name: "Power rack", category: .rack, load: .none),
        EquipmentKind(id: "bench-press-station", name: "Bench press station", category: .rack, load: .none),
        EquipmentKind(id: "pull-up-bar", name: "Pull-up bar", category: .rack, load: .bodyweight),
        EquipmentKind(id: "cable-station", name: "Cable station", category: .cable, load: .stack),
        EquipmentKind(id: "lat-pulldown", name: "Lat pulldown", category: .cable, load: .stack),
        EquipmentKind(id: "chest-press-machine", name: "Chest press", category: .machine, load: .stack),
        EquipmentKind(id: "pec-deck", name: "Pec deck", category: .machine, load: .stack),
        EquipmentKind(id: "leg-press", name: "Leg press", category: .machine, load: .plateLoaded),
    ]

    private static func ex(_ id: String, _ name: String, _ bodyPart: String, _ equipment: String, _ target: String,
                           _ secondary: [String] = []) -> Exercise {
        Exercise(id: id, name: name, bodyPart: bodyPart, equipment: equipment, target: target, secondary: secondary)
    }

    static let exercises: [Exercise] = [
        ex("c-bb-bench", "Barbell Bench Press", "chest", "barbell", "pectorals", ["triceps", "shoulders"]),
        ex("c-db-press", "Dumbbell Bench Press", "chest", "dumbbell", "pectorals", ["triceps", "shoulders"]),
        ex("c-db-incline", "Dumbbell Incline Press", "chest", "dumbbell", "pectorals", ["triceps", "shoulders"]),
        ex("c-machine-press", "Lever Chest Press", "chest", "leverage machine", "pectorals", ["triceps"]),
        ex("c-pec-deck", "Lever Seated Fly", "chest", "leverage machine", "pectorals"),
        ex("c-cable-fly", "Cable Middle Fly", "chest", "cable", "pectorals", ["shoulders"]),
        ex("c-cable-crossover", "Cable Crossover", "chest", "cable", "pectorals", ["shoulders"]),
        ex("c-cable-press", "Cable Standing Chest Press", "chest", "cable", "pectorals", ["triceps"]),
        ex("c-pushup", "Push-Up", "chest", "body weight", "pectorals", ["triceps"]),
        ex("b-pulldown", "Cable Pulldown", "back", "cable", "lats", ["biceps"]),
        ex("b-pullup", "Pull-Up", "back", "body weight", "lats", ["biceps"]),
        ex("b-db-row", "Dumbbell Row", "back", "dumbbell", "upper back", ["lats", "biceps"]),
        ex("b-kb-row", "Kettlebell One Arm Row", "back", "kettlebell", "upper back", ["lats", "biceps"]),
        ex("b-bb-row", "Barbell Row", "back", "barbell", "upper back", ["lats"]),
        ex("a-db-curl", "Dumbbell Curl", "upper arms", "dumbbell", "biceps", ["forearms"]),
        ex("a-kb-curl", "Kettlebell Hammer Curl", "upper arms", "kettlebell", "biceps", ["forearms"]),
        ex("a-cable-pushdown", "Cable Pushdown", "upper arms", "cable", "triceps"),
        ex("a-kb-skull", "Kettlebell Skull Crusher", "upper arms", "kettlebell", "triceps"),
        ex("l-leg-press", "Sled 45° Leg Press", "upper legs", "sled machine", "quads", ["glutes", "hamstrings"]),
        ex("x-shrug", "Lever Shrug", "back", "leverage machine", "traps"),
    ]

    static let requirements = ExerciseRequirements(groups: [
        "c-bb-bench": [["barbell"], ["flat-bench", "adjustable-bench", "bench-press-station"],
                       ["power-rack", "bench-press-station"]],
        "c-db-press": [["dumbbells"], ["flat-bench", "adjustable-bench"]],
        "c-db-incline": [["dumbbells"], ["adjustable-bench", "incline-bench"]],
        "c-machine-press": [["chest-press-machine"]],
        "c-pec-deck": [["pec-deck"]],
        "c-cable-fly": [["cable-station"]],
        "c-cable-crossover": [["cable-station"]],
        "c-cable-press": [["cable-station"]],
        "c-pushup": [],
        "b-pulldown": [["lat-pulldown", "cable-station"]],
        "b-pullup": [["pull-up-bar", "power-rack"]],
        "b-db-row": [["dumbbells"], ["flat-bench", "adjustable-bench"]],
        "b-kb-row": [["kettlebells"]],
        "b-bb-row": [["barbell"]],
        "a-db-curl": [["dumbbells"]],
        "a-kb-curl": [["kettlebells"]],
        "a-cable-pushdown": [["cable-station"]],
        "a-kb-skull": [["kettlebells"], ["flat-bench", "adjustable-bench"]],
        "l-leg-press": [["leg-press"]],
        // "x-shrug" is deliberately unmapped.
    ])

    static func id(_ n: Int) -> UUID { UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))! }

    static let homeKettlebells = InventoryListing(id: id(1), kindId: "kettlebells", loads: .fixed(kg: [20, 24]),
                                                  isOwn: true)
    static let homeBench = InventoryListing(id: id(2), kindId: "flat-bench", isOwn: true)
    static let home = GymInventory(gymName: "Home", listings: [homeKettlebells, homeBench])

    static let iron = GymInventory(gymName: "Iron Works Gym", listings: [
        InventoryListing(id: id(10), kindId: "barbell", loads: .plates, confirmCount: 9),
        InventoryListing(id: id(11), kindId: "bench-press-station", confirmCount: 6),
        InventoryListing(id: id(12), kindId: "power-rack", confirmCount: 4),
        InventoryListing(id: id(13), kindId: "dumbbells", loads: .fixed(kg: [5, 10, 15, 20, 25, 30]), confirmCount: 8),
        InventoryListing(id: id(14), kindId: "adjustable-bench", confirmCount: 5),
        InventoryListing(id: id(15), kindId: "cable-station", loads: .stack(maxKg: 90, stepKg: 4.5), confirmCount: 7),
        InventoryListing(id: id(16), kindId: "lat-pulldown", loads: .stack(maxKg: 136, stepKg: 4.5), confirmCount: 7),
        InventoryListing(id: id(17), kindId: "chest-press-machine", loads: .stack(maxKg: 113, stepKg: 4.5),
                         confirmCount: 3),
        InventoryListing(id: id(18), kindId: "pec-deck", loads: .stack(maxKg: 90, stepKg: 4.5), confirmCount: 2),
        InventoryListing(id: id(19), kindId: "leg-press", loads: .plates, confirmCount: 3),
    ])

    static func matcher(_ inventory: GymInventory) -> InventoryMatcher {
        InventoryMatcher(requirements: requirements, kinds: kinds, inventory: inventory)
    }

    /// A finished workout on `day` (days since 1970, noon UTC) with these exercises.
    static func workout(day: Int, _ exerciseIds: [String]) -> Workout {
        let start = Date(timeIntervalSince1970: Double(day) * 86_400 + 43_200)
        return Workout(startedAt: start, endedAt: start.addingTimeInterval(3_600), name: "Day \(day)",
                       entries: exerciseIds.map { WorkoutEntry(exerciseId: $0) })
    }

    static func date(day: Int) -> Date { Date(timeIntervalSince1970: Double(day) * 86_400 + 36_000) }
}
```

- [x] **Step 2: Write the failing tests**

`ios/Packages/GymCore/Tests/GymCoreTests/Gym/InventoryMatcherTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct InventoryMatcherTests {
    private let home = GymFixtures.matcher(GymFixtures.home)
    private let iron = GymFixtures.matcher(GymFixtures.iron)

    @Test func availableExerciseUsesOneListingPerGroupAndNamesTheLoadListing() {
        #expect(home.availability(of: "a-kb-skull") == .available(InventoryMatch(
            listingIds: [GymFixtures.id(1), GymFixtures.id(2)], loadListingId: GymFixtures.id(1))))
    }

    @Test func oneListingCanCoverSeveralGroups() {
        // The bench press station is both the bench and the rack.
        #expect(iron.availability(of: "c-bb-bench") == .available(InventoryMatch(
            listingIds: [GymFixtures.id(10), GymFixtures.id(11)], loadListingId: GymFixtures.id(10))))
    }

    @Test func missingReportsTheFirstUncoveredGroup() {
        #expect(home.availability(of: "c-bb-bench") == .missing(["barbell"]))
        #expect(home.availability(of: "c-db-incline") == .missing(["dumbbells"]))
        #expect(iron.availability(of: "b-pullup") == .available(InventoryMatch(
            listingIds: [GymFixtures.id(12)], loadListingId: nil)), "a power rack has a pull-up bar")
    }

    @Test func noEquipmentAndUnmapped() {
        #expect(home.availability(of: "c-pushup") == .available(.noEquipment))
        #expect(home.needsNoEquipment("c-pushup"))
        #expect(!home.needsNoEquipment("b-kb-row"))
        #expect(home.availability(of: "x-shrug") == .unmapped)
        #expect(home.availability(of: "no-such-exercise") == .unmapped)
    }

    @Test func prefersOwnListingsThenMoreConfirmations() {
        let shared = InventoryListing(id: GymFixtures.id(30), kindId: "dumbbells", confirmCount: 12)
        let mine = InventoryListing(id: GymFixtures.id(31), kindId: "dumbbells", confirmCount: 0, isOwn: true)
        let weaker = InventoryListing(id: GymFixtures.id(32), kindId: "dumbbells", confirmCount: 2)
        let both = GymFixtures.matcher(GymInventory(gymName: "G", listings: [weaker, shared, mine]))
        #expect(both.availability(of: "a-db-curl")
            == .available(InventoryMatch(listingIds: [mine.id], loadListingId: mine.id)))
        let sharedOnly = GymFixtures.matcher(GymInventory(gymName: "G", listings: [weaker, shared]))
        #expect(sharedOnly.availability(of: "a-db-curl")
            == .available(InventoryMatch(listingIds: [shared.id], loadListingId: shared.id)))
    }

    @Test func listingsOfUnknownKindsAreIgnored() {
        let future = InventoryListing(id: GymFixtures.id(40), kindId: "hover-bench", confirmCount: 99)
        let matcher = GymFixtures.matcher(GymInventory(gymName: "G", listings: [future]))
        #expect(matcher.listing(future.id) == nil)
        #expect(matcher.availability(of: "c-db-press") == .missing(["dumbbells"]))
    }
}
```

- [x] **Step 3: Run them and see them fail**

Run: `cd ios/Packages/GymCore && swift test --filter InventoryMatcherTests`
Expected: build error `cannot find 'InventoryMatcher' in scope`.

- [x] **Step 4: Implement**

`ios/Packages/GymCore/Sources/GymCore/Gym/InventoryMatcher.swift`:

```swift
import Foundation

/// The listings an exercise uses at a gym: one per requirement group in group order, without duplicates (one
/// listing, such as a bench press station, can cover several groups).
public struct InventoryMatch: Sendable, Hashable {
    public let listingIds: [UUID]
    /// The listing that decides the weight: the first chosen listing whose kind bears load. Nil for bodyweight.
    public let loadListingId: UUID?

    public init(listingIds: [UUID], loadListingId: UUID?) {
        self.listingIds = listingIds
        self.loadListingId = loadListingId
    }

    public static let noEquipment = InventoryMatch(listingIds: [], loadListingId: nil)
}

/// Whether an exercise can be done at a gym.
public enum Availability: Sendable, Hashable {
    case available(InventoryMatch)
    /// The first requirement group that no listing covers (its kind ids).
    case missing([String])
    /// The exercise isn't in the requirements data.
    case unmapped
}

/// "Can this exercise be done at this gym, and on which listings?" (spec §5). Listings whose kind this app version
/// doesn't know are ignored.
public struct InventoryMatcher: Sendable {
    public let inventory: GymInventory
    private let requirements: ExerciseRequirements
    private let kinds: [String: EquipmentKind]
    /// Listings per kind id, best first (`better`).
    private let byKind: [String: [InventoryListing]]
    private let byId: [UUID: InventoryListing]

    public init(requirements: ExerciseRequirements, kinds: [EquipmentKind], inventory: GymInventory) {
        let kindsById = Dictionary(kinds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = inventory.listings.filter { kindsById[$0.kindId] != nil }
        self.inventory = inventory
        self.requirements = requirements
        self.kinds = kindsById
        self.byKind = Dictionary(grouping: known, by: \.kindId).mapValues { $0.sorted(by: Self.better) }
        self.byId = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func availability(of exerciseId: String) -> Availability {
        guard let groups = requirements.requirement(for: exerciseId) else { return .unmapped }
        var chosen: [InventoryListing] = []
        for group in groups where !chosen.contains(where: { group.contains($0.kindId) }) {
            guard let best = group.compactMap({ byKind[$0]?.first }).min(by: Self.better) else {
                return .missing(group)
            }
            chosen.append(best)
        }
        let load = chosen.first { kinds[$0.kindId]?.load.bearsLoad == true }
        return .available(InventoryMatch(listingIds: chosen.map(\.id), loadListingId: load?.id))
    }

    public func listing(_ id: UUID) -> InventoryListing? { byId[id] }

    public func kind(_ id: String) -> EquipmentKind? { kinds[id] }

    /// Whether a requirement exists for the exercise and is empty (a no-equipment exercise).
    public func needsNoEquipment(_ exerciseId: String) -> Bool {
        requirements.requirement(for: exerciseId)?.isEmpty == true
    }

    /// The user's own listings first, then more confirmations, then the id (stable across runs).
    static func better(_ a: InventoryListing, _ b: InventoryListing) -> Bool {
        if a.isOwn != b.isOwn { return a.isOwn }
        if a.confirmCount != b.confirmCount { return a.confirmCount > b.confirmCount }
        return a.id.uuidString < b.id.uuidString
    }
}
```

- [x] **Step 5: Run them and see them pass**

Run: `cd ios/Packages/GymCore && swift test --filter InventoryMatcherTests`
Expected: `Test run with 6 tests in 1 suite passed`.

- [x] **Step 6: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Gym/InventoryMatcher.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymFixtures.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/Gym/InventoryMatcherTests.swift
git commit -m "feat(core): match exercise requirements to a gym's listings"
```

---

### Task 7: Move swap ordering and barbell loading into GymCore

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Preferences/SwapOrdering.swift`
- Create: `ios/Packages/GymCore/Sources/GymCore/Model/Exercise+Loading.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/SwapOrderingTests.swift`
- Modify: `ios/GymRollins/Features/Library/ExerciseSuggestions.swift:8-22`
- Modify: `ios/GymRollins/Features/Plan/LoadRounding.swift:8-13`

`GymAdapter` (Task 8) has to offer swaps in the same order as the Swap sheet and needs the barbell check for
increments. Both live in the app target today, so they move into GymCore and the app calls them. Behavior doesn't
change; the existing `ExerciseSuggestionsTests` guard that.

- [x] **Step 1: Write the failing tests**

`ios/Packages/GymCore/Tests/GymCoreTests/SwapOrderingTests.swift`:

```swift
import Testing
@testable import GymCore

@Suite struct SwapOrderingTests {
    private func ex(_ id: String, _ name: String, target: String, bodyPart: String = "chest",
                    equipment: String = "dumbbell") -> Exercise {
        Exercise(id: id, name: name, bodyPart: bodyPart, equipment: equipment, target: target)
    }

    @Test func sameTargetFirstThenSameBodyPartEachByLoggedCountThenName() {
        let current = ex("cur", "Current", target: "pectorals")
        let list = [current, ex("t2", "B Press", target: "pectorals"), ex("t1", "A Press", target: "pectorals"),
                    ex("b1", "Serratus Punch", target: "serratus anterior"),
                    ex("o1", "Curl", target: "biceps", bodyPart: "upper arms")]
        let ordered = SwapOrdering.candidates(for: current, in: list, loggedCounts: ["t2": 4, "b1": 1])
        #expect(ordered.map(\.id) == ["t2", "t1", "b1"])
    }

    @Test func barbellLoadedEquipment() {
        #expect(ex("a", "A", target: "x", equipment: "ez barbell").isBarbellLoaded)
        #expect(ex("b", "B", target: "x", equipment: "smith machine").isBarbellLoaded)
        #expect(!ex("c", "C", target: "x", equipment: "dumbbell").isBarbellLoaded)
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run: `cd ios/Packages/GymCore && swift test --filter SwapOrderingTests`
Expected: build error `cannot find 'SwapOrdering' in scope`.

- [x] **Step 3: Implement both**

`ios/Packages/GymCore/Sources/GymCore/Preferences/SwapOrdering.swift`:

```swift
/// The order Replace/Swap candidates are offered in: exercises with the same target, then with the same body part
/// (the current exercise excluded), each group by how often it was logged and then by name. `ExerciseRanking` applies
/// the owner's preferences on top. Shared by the Swap sheet (`ExerciseSuggestions.swap`) and `GymAdapter`.
public enum SwapOrdering {
    public static func candidates(for current: Exercise, in exercises: [Exercise],
                                  loggedCounts: [String: Int]) -> [Exercise] {
        func sorted(_ list: [Exercise]) -> [Exercise] {
            list.sorted { l, r in
                let lc = loggedCounts[l.id, default: 0], rc = loggedCounts[r.id, default: 0]
                return lc != rc ? lc > rc : l.name < r.name
            }
        }
        let sameTarget = exercises.filter { $0.id != current.id && $0.target == current.target }
        let sameBodyPart = exercises.filter {
            $0.id != current.id && $0.target != current.target && $0.bodyPart == current.bodyPart
        }
        return sorted(sameTarget) + sorted(sameBodyPart)
    }
}
```

`ios/Packages/GymCore/Sources/GymCore/Model/Exercise+Loading.swift`:

```swift
public extension Exercise {
    /// Equipment that's loaded as a fixed bar plus plates, so it only moves in barbell increments.
    static let barbellLoadedEquipment: Set<String> = [
        "barbell", "olympic barbell", "ez barbell", "smith machine", "trap bar",
    ]

    /// True for barbell-type equipment (barbell increments and rounding); false for dumbbells, machines, cables,
    /// bodyweight and the rest.
    var isBarbellLoaded: Bool { Self.barbellLoadedEquipment.contains(equipment) }
}
```

- [x] **Step 4: Run them and see them pass**

Run: `cd ios/Packages/GymCore && swift test --filter SwapOrderingTests`
Expected: `Test run with 2 tests in 1 suite passed`.

- [x] **Step 5: Point the app at the shared code**

In `ios/GymRollins/Features/Library/ExerciseSuggestions.swift`, replace the doc comment and the start of `swap`
(everything from `/// Replace/Swap candidates:` down to and including `let candidates = sorted(sameTarget) +
sorted(sameBodyPart)`) with:

```swift
    /// Replace/Swap candidates in `SwapOrdering`'s order (same target, then same body part, each by how often it
    /// was logged and then by name), then ranked by preference.
    static func swap(current: Exercise, library: ExerciseLibrary, loggedCounts: [String: Int],
                     preferences: [String: ExercisePreference], query: String) -> [Exercise] {
        let candidates = SwapOrdering.candidates(for: current, in: library.exercises, loggedCounts: loggedCounts)
```

The rest of the function (the `words` query filter and both `ExerciseRanking` calls) stays as it is.

In `ios/GymRollins/Features/Plan/LoadRounding.swift`, replace

```swift
    /// Equipment that's loaded as a fixed bar plus plates, so it only moves in barbell increments.
    private static let barbellEquipment: Set<String> = [
        "barbell", "olympic barbell", "ez barbell", "smith machine", "trap bar"
    ]

    static func isBarbellType(_ equipment: String) -> Bool { barbellEquipment.contains(equipment) }
```

with

```swift
    static func isBarbellType(_ equipment: String) -> Bool { Exercise.barbellLoadedEquipment.contains(equipment) }
```

- [x] **Step 6: Run the app's suggestion tests**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/ExerciseSuggestionsTests`
Expected: `** TEST SUCCEEDED **`.

- [x] **Step 7: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Preferences/SwapOrdering.swift \
  ios/Packages/GymCore/Sources/GymCore/Model/Exercise+Loading.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/SwapOrderingTests.swift \
  ios/GymRollins/Features/Library/ExerciseSuggestions.swift ios/GymRollins/Features/Plan/LoadRounding.swift
git commit -m "refactor(core): share swap ordering and barbell loading with GymCore"
```

---

### Task 8: `GymAdapter`

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/GymAdapter.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymAdapterTests.swift`

- [x] **Step 1: Write the failing tests**

`ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymAdapterTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct GymAdapterTests {
    private func planned(_ exerciseId: String, n: Int, sets: Int = 4, reps: Int = 8) -> RoutineExercise {
        RoutineExercise(id: GymFixtures.id(100 + n), exerciseId: exerciseId, sets: sets, reps: reps, repsMin: 6,
                        weightKg: 60, incKg: 2.27, supersetGroup: n == 2 ? "A" : nil, weightSetAt: .distantPast)
    }

    private func adapter(_ inventory: GymInventory, preferences: [String: ExercisePreference] = [:],
                         logged: [String: Int] = [:]) -> GymAdapter {
        GymAdapter(matcher: GymFixtures.matcher(inventory), exercises: GymFixtures.exercises, loggedCounts: logged,
                   preferences: preferences)
    }

    @Test func availableExercisesAreKeptAndLinked() {
        let result = adapter(GymFixtures.home).adapt([planned("b-kb-row", n: 1)])
        #expect(result == [.kept(planned("b-kb-row", n: 1), InventoryMatch(
            listingIds: [GymFixtures.id(1)], loadListingId: GymFixtures.id(1)))])
    }

    @Test func missingEquipmentSwapsToTheBestAvailableExerciseForTheSameTarget() {
        let result = adapter(GymFixtures.home).adapt([planned("a-db-curl", n: 1)])
        guard case let .swapped(plannedItem, replacement, match, missing) = result.first else {
            Issue.record("expected a swap, got \(result)")
            return
        }
        #expect(plannedItem.exerciseId == "a-db-curl")
        #expect(missing == ["dumbbells"])
        #expect(replacement.exerciseId == "a-kb-curl")
        #expect(match.loadListingId == GymFixtures.id(1))
    }

    @Test func replacementKeepsTheItemAndTargetsButNotThePlannedWeight() {
        guard case let .swapped(_, replacement, _, _) = adapter(GymFixtures.home).adapt([planned("a-db-curl", n: 2)]).first
        else {
            Issue.record("expected a swap")
            return
        }
        #expect(replacement.id == GymFixtures.id(102))
        #expect(replacement.sets == 4 && replacement.reps == 8 && replacement.repsMin == 6)
        #expect(replacement.supersetGroup == "A")
        #expect(replacement.weightKg == nil && replacement.weightSetAt == nil)
        #expect(replacement.incKg == RoutineExercise.defaults(exerciseId: "a-kb-curl", mode: .reps, barbell: false).incKg)
    }

    @Test func nothingSimilarAvailableIsUnavailable() {
        #expect(adapter(GymFixtures.home).adapt([planned("l-leg-press", n: 1)])
            == [.unavailable(planned("l-leg-press", n: 1), missing: ["leg-press"])])
    }

    @Test func unmappedExercisesStayAsPlanned() {
        #expect(adapter(GymFixtures.home).adapt([planned("x-shrug", n: 1)]) == [.unmapped(planned("x-shrug", n: 1))])
    }

    @Test func aReplacementIsNeverAlreadyInTheListSoItFallsBackToTheSameBodyPart() {
        // The kettlebell curl is already planned, so the dumbbell curl's swap moves on to the same body part.
        let result = adapter(GymFixtures.home).adapt([planned("a-kb-curl", n: 1), planned("a-db-curl", n: 2)])
        #expect(result.map(\.item.exerciseId) == ["a-kb-curl", "a-kb-skull"])
    }

    @Test func neverPreferencesAreNotUsedAsReplacements() {
        let never: [String: ExercisePreference] = ["a-kb-curl": .never, "a-kb-skull": .never]
        let result = adapter(GymFixtures.home, preferences: never).adapt([planned("a-db-curl", n: 1)])
        #expect(result == [.unavailable(planned("a-db-curl", n: 1), missing: ["dumbbells"])])
    }

    @Test func benchPressAtHomeFallsBackToABodyweightPushUp() {
        let result = adapter(GymFixtures.home).adapt([planned("c-bb-bench", n: 1)])
        #expect(result.first?.item.exerciseId == "c-pushup")
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run: `cd ios/Packages/GymCore && swift test --filter GymAdapterTests`
Expected: build error `cannot find 'GymAdapter' in scope`.

- [x] **Step 3: Implement**

`ios/Packages/GymCore/Sources/GymCore/Gym/GymAdapter.swift`:

```swift
import Foundation

/// One planned exercise after adapting today's routine to the current gym.
public enum AdaptedItem: Sendable, Hashable {
    /// Doable here, linked to the listings it uses.
    case kept(RoutineExercise, InventoryMatch)
    /// Not doable here; `replacement` (same item id) is the best available alternative. `missing` is the first
    /// requirement group of the planned exercise that the gym lacks.
    case swapped(planned: RoutineExercise, replacement: RoutineExercise, match: InventoryMatch, missing: [String])
    /// Not doable here and no similar exercise is.
    case unavailable(RoutineExercise, missing: [String])
    /// No requirements data: left as planned, unmarked.
    case unmapped(RoutineExercise)

    /// The exercise the session uses.
    public var item: RoutineExercise {
        switch self {
        case let .kept(item, _), let .unavailable(item, _), let .unmapped(item): item
        case let .swapped(_, replacement, _, _): replacement
        }
    }
}

/// Adapts a routine's exercises to the current gym for one session (spec §5). The routine itself is never edited:
/// the result only feeds today's list.
public struct GymAdapter: Sendable {
    private let matcher: InventoryMatcher
    private let exercises: [Exercise]
    private let byId: [String: Exercise]
    private let loggedCounts: [String: Int]
    private let preferences: [String: ExercisePreference]

    public init(matcher: InventoryMatcher, exercises: [Exercise], loggedCounts: [String: Int] = [:],
                preferences: [String: ExercisePreference] = [:]) {
        self.matcher = matcher
        self.exercises = exercises
        self.byId = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.loggedCounts = loggedCounts
        self.preferences = preferences
    }

    /// Adapts the items in order. A replacement is never an exercise already in the list or chosen for an earlier
    /// item.
    public func adapt(_ items: [RoutineExercise]) -> [AdaptedItem] {
        let start = (out: [AdaptedItem](), used: Set(items.map(\.exerciseId)))
        return items.reduce(into: start) { state, item in
            let adapted = adapt(item, excluding: state.used)
            state.used.insert(adapted.item.exerciseId)
            state.out.append(adapted)
        }.out
    }

    private func adapt(_ item: RoutineExercise, excluding used: Set<String>) -> AdaptedItem {
        switch matcher.availability(of: item.exerciseId) {
        case .unmapped: return .unmapped(item)
        case let .available(match): return .kept(item, match)
        case let .missing(kinds):
            guard let current = byId[item.exerciseId] else { return .unavailable(item, missing: kinds) }
            let ordered = ExerciseRanking.suggestions(
                SwapOrdering.candidates(for: current, in: exercises, loggedCounts: loggedCounts),
                preferences: preferences, id: \.id)
            for candidate in ordered where !used.contains(candidate.id) {
                if case let .available(match) = matcher.availability(of: candidate.id) {
                    return .swapped(planned: item, replacement: Self.replacement(for: item, with: candidate),
                                    match: match, missing: kinds)
                }
            }
            return .unavailable(item, missing: kinds)
        }
    }

    /// The planned item with another exercise: same id, sets, reps, rest-relevant targets and superset; no planned
    /// weight, so progression starts from the new exercise's own history. The increment follows the new equipment.
    /// Across modes the targets come from `RoutineExercise.defaults`.
    static func replacement(for item: RoutineExercise, with exercise: Exercise) -> RoutineExercise {
        let defaults = RoutineExercise.defaults(exerciseId: exercise.id, mode: exercise.mode,
                                                barbell: exercise.isBarbellLoaded)
        guard exercise.mode == item.mode else {
            return RoutineExercise(id: item.id, exerciseId: exercise.id, sets: defaults.sets, reps: defaults.reps,
                                   repsMin: defaults.repsMin, sec: defaults.sec, mode: defaults.mode,
                                   policy: defaults.policy, incKg: defaults.incKg, supersetGroup: item.supersetGroup)
        }
        return RoutineExercise(id: item.id, exerciseId: exercise.id, sets: item.sets, reps: item.reps,
                               repsMin: item.repsMin, sec: item.sec, mode: item.mode, policy: item.policy,
                               incKg: defaults.incKg, supersetGroup: item.supersetGroup)
    }
}
```

- [x] **Step 4: Run them and see them pass**

Run: `cd ios/Packages/GymCore && swift test --filter GymAdapterTests`
Expected: `Test run with 8 tests in 1 suite passed`.

- [x] **Step 5: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Gym/GymAdapter.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymAdapterTests.swift
git commit -m "feat(core): adapt today's routine to the current gym"
```

---

### Task 9: Build options and the stable hash

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/BuildOptions.swift`
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/StableHash.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/BuildOptionsTests.swift`

`StableHash` exists because Swift's `Hasher` is seeded per process: tie-breaks built on it would change between
runs.

- [x] **Step 1: Write the failing tests**

`ios/Packages/GymCore/Tests/GymCoreTests/Gym/BuildOptionsTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct BuildOptionsTests {
    @Test(arguments: [
        (BuildLength.short, 1, 3), (.short, 3, 3), (.medium, 1, 4), (.medium, 2, 5), (.long, 1, 6), (.long, 4, 6),
    ])
    func slotsPerLength(length: BuildLength, muscles: Int, slots: Int) {
        #expect(length.slots(muscleCount: muscles) == slots)
    }

    @Test func chipsCoverEveryMuscleGroupExactlyOnce() {
        let all = BuildMuscle.allCases.flatMap(\.groups)
        #expect(all.count == MuscleGroup.allCases.count)
        #expect(Set(all) == Set(MuscleGroup.allCases))
    }

    @Test func requestDropsDuplicateChipsAndKeepsTheirOrder() {
        let request = BuildRequest(muscles: [.back, .arms, .back], length: .medium, date: .distantPast)
        #expect(request.muscles == [.back, .arms])
    }

    @Test func stableHashIsFnv1aAndDaysAreUtc() {
        #expect(StableHash.fnv1a("") == 0xcbf2_9ce4_8422_2325)
        #expect(StableHash.fnv1a("a") == 0xaf63_dc4c_8601_ec8c)
        #expect(StableHash.day(of: Date(timeIntervalSince1970: 86_400 * 3 + 86_399)) == 3)
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run: `cd ios/Packages/GymCore && swift test --filter BuildOptionsTests`
Expected: build error `cannot find 'BuildLength' in scope`.

- [x] **Step 3: Implement both**

`ios/Packages/GymCore/Sources/GymCore/Gym/BuildOptions.swift`:

```swift
import Foundation

/// The muscle chips on the Build workout sheet, each a set of `MuscleGroup`s.
public enum BuildMuscle: String, CaseIterable, Codable, Sendable, Identifiable {
    case chest, back, shoulders, arms, legs, core

    public var id: String { rawValue }

    public var groups: Set<MuscleGroup> {
        switch self {
        case .chest: [.chest]
        case .back: [.upperBack, .lats, .lowerBack, .traps]
        case .shoulders: [.shoulders]
        case .arms: [.biceps, .triceps, .forearms]
        case .legs: [.quads, .hamstrings, .glutes, .calves, .adductors, .abductors]
        case .core: [.abs]
        }
    }
}

/// The Build workout lengths, in minutes.
public enum BuildLength: Int, CaseIterable, Codable, Sendable {
    case short = 30, medium = 45, long = 60

    /// Exercises for this length: 30 min → 3; 45 min → 4, or 5 with two or more chips; 60 min → 6.
    public func slots(muscleCount: Int) -> Int {
        switch self {
        case .short: 3
        case .medium: muscleCount >= 2 ? 5 : 4
        case .long: 6
        }
    }
}

/// What the user asked Build workout for.
public struct BuildRequest: Sendable, Hashable {
    /// Muscle chips in the order the user picked them, without duplicates.
    public let muscles: [BuildMuscle]
    public let length: BuildLength
    /// The day being built for. It seeds tie-breaks, so the same day and input give the same workout.
    public let date: Date
    /// Exercises to avoid when anything else fits: Rebuild passes the current result's exercises. Unlike recent
    /// exercises, using one of these anyway isn't marked as a repeat.
    public let avoid: Set<String>

    public init(muscles: [BuildMuscle], length: BuildLength, date: Date, avoid: Set<String> = []) {
        self.muscles = muscles.reduce(into: []) { unique, muscle in
            if !unique.contains(muscle) { unique.append(muscle) }
        }
        self.length = length
        self.date = date
        self.avoid = avoid
    }
}
```

`ios/Packages/GymCore/Sources/GymCore/Gym/StableHash.swift`:

```swift
import Foundation

/// FNV-1a (64-bit) over a string's UTF-8 bytes. Unlike `Hasher`, it is the same on every run and device, so the
/// builder's tie-breaks are reproducible.
enum StableHash {
    static func fnv1a(_ text: String) -> UInt64 {
        text.utf8.reduce(0xcbf2_9ce4_8422_2325 as UInt64) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
    }

    /// Whole days since 1970 (UTC) for `date`: the builder's seed.
    static func day(of date: Date) -> Int { Int((date.timeIntervalSince1970 / 86_400).rounded(.down)) }
}
```

- [x] **Step 4: Run them and see them pass**

Run: `cd ios/Packages/GymCore && swift test --filter BuildOptionsTests`
Expected: `Test run with 4 tests in 1 suite passed` (a parameterized test counts once).

- [x] **Step 5: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Gym/BuildOptions.swift \
  ios/Packages/GymCore/Sources/GymCore/Gym/StableHash.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/Gym/BuildOptionsTests.swift
git commit -m "feat(core): build workout options and a stable hash"
```

---

### Task 10: `WorkoutBuilder`

> **Changed after review (2026-10-30):** review against the real library found the rules broke at real gyms, see the
> Outcome section. The code below is the first version; the committed sources and `WorkoutBuilderFallbackTests` and
> `GymRealDataTests` are authoritative.

**Files:**
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/WorkoutBuilder.swift`
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/WorkoutBuilder+Pool.swift`
- Create: `ios/Packages/GymCore/Sources/GymCore/Gym/SlotPicker.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/WorkoutBuilderTests.swift`
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/WorkoutBuilderVarietyTests.swift`

How it works (spec §5, "Build workout"):
1. `pool(for:day:)` collects each chip's candidates: rep exercises whose primary muscle is in the chip, available at
   the gym, not `never`. They're ranked by preference, then the load listing's score, then how often they were
   logged, then a hash seeded by the day. Equipment and no-equipment candidates are kept apart. The pool also
   holds the chip's recent exercises (from its last 3 workouts).
2. `build` fills the slots round-robin across the chips with equipment candidates (`SlotPicker`). It counts the
   slots nothing fit, issues thin-inventory notices for those chips, and then fills those slots with no-equipment
   exercises.
3. `SlotPicker.pick` takes a fresh candidate first (not recent, not avoided), then an avoided one (Rebuild), then
   the least recently done recent one, which is marked as a repeat. It skips exercises already chosen and machine
   listings that already have 2 exercises.
4. The output lists compound exercises first, then the rest, then fills.

- [x] **Step 1: Write the failing tests**

`ios/Packages/GymCore/Tests/GymCoreTests/Gym/WorkoutBuilderTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

@Suite struct WorkoutBuilderTests {
    private let day = 20_400

    private func builder(_ inventory: GymInventory, history: [Workout] = [],
                         preferences: [String: ExercisePreference] = [:],
                         logged: [String: Int] = [:]) -> WorkoutBuilder {
        WorkoutBuilder(matcher: GymFixtures.matcher(inventory), exercises: GymFixtures.exercises, history: history,
                       loggedCounts: logged, preferences: preferences)
    }

    private func request(_ muscles: [BuildMuscle], _ length: BuildLength, avoid: Set<String> = []) -> BuildRequest {
        BuildRequest(muscles: muscles, length: length, date: GymFixtures.date(day: day), avoid: avoid)
    }

    @Test func homeBackAndArmsIsShortWithAThinNoticeForBack() {
        let built = builder(GymFixtures.home).build(request([.back, .arms], .medium))
        #expect(built.requestedSlots == 5)
        #expect(built.items.map(\.exercise.exerciseId).sorted() == ["a-kb-curl", "a-kb-skull", "b-kb-row"])
        #expect(built.thin == [ThinInventoryNotice(muscle: .back, itemCount: 1)])
        #expect(built.items.allSatisfy { !$0.isBodyweightFill && $0.repeatOf == nil })
    }

    @Test func itemsUseDefaultTargetsAndNoPlannedWeight() throws {
        let item = try #require(builder(GymFixtures.home).build(request([.back], .short)).items.first)
        let defaults = RoutineExercise.defaults(exerciseId: "b-kb-row", mode: .reps, barbell: false)
        #expect(item.exercise.exerciseId == "b-kb-row")
        #expect(item.exercise.sets == defaults.sets && item.exercise.reps == defaults.reps)
        #expect(item.exercise.repsMin == defaults.repsMin && item.exercise.incKg == defaults.incKg)
        #expect(item.exercise.weightKg == nil)
        #expect(item.muscle == .back)
        #expect(item.match.loadListingId == GymFixtures.homeKettlebells.id)
    }

    @Test func atMostTwoExercisesPerMachineThenBodyweightFills() {
        let cablesOnly = GymInventory(gymName: "Cables", listings: [
            InventoryListing(id: GymFixtures.id(50), kindId: "cable-station", loads: .stack(maxKg: 90, stepKg: 4.5)),
        ])
        let built = builder(cablesOnly).build(request([.chest], .medium))
        let ids = built.items.map(\.exercise.exerciseId)
        #expect(ids.filter { $0.hasPrefix("c-cable") }.count == 2)
        #expect(ids.last == "c-pushup")
        #expect(built.items.last?.isBodyweightFill == true)
        #expect(built.items.count == 3, "4 slots, but only 2 cable exercises and 1 push-up fit")
        #expect(built.thin == [ThinInventoryNotice(muscle: .chest, itemCount: 1)])
    }

    @Test func freeWeightsAreNotCappedLikeMachines() {
        let built = builder(GymFixtures.home).build(request([.arms], .medium))
        #expect(built.items.count == 2, "only two arm exercises exist for kettlebells")
        #expect(built.items.allSatisfy { $0.match.loadListingId == GymFixtures.homeKettlebells.id })
    }

    @Test func preferencesRankMoreFirstAndDropNever() {
        let built = builder(GymFixtures.iron, preferences: ["c-pec-deck": .more, "c-bb-bench": .never])
            .build(request([.chest], .short))
        let ids = built.items.map(\.exercise.exerciseId)
        #expect(ids.contains("c-pec-deck"))
        #expect(!ids.contains("c-bb-bench"))
    }

    @Test func moreConfirmedListingsRankFirst() {
        // Back at Iron: barbell (9 confirmations), dumbbells (8), the cable station behind the pulldown (7), and
        // the power rack for pull-ups (4) last.
        let built = builder(GymFixtures.iron).build(request([.back], .short))
        #expect(built.items.map(\.exercise.exerciseId) == ["b-bb-row", "b-db-row", "b-pulldown"])
    }

    @Test func compoundExercisesComeFirst() {
        let built = builder(GymFixtures.iron).build(request([.chest], .long))
        let compound = built.items.map { MuscleTaxonomy.contributions(for: exercise($0)).count >= 2 }
        #expect(compound == compound.sorted { $0 && !$1 })
    }

    @Test func sameInputGivesTheSameWorkout() {
        let a = builder(GymFixtures.iron).build(request([.chest, .back], .long))
        let b = builder(GymFixtures.iron).build(request([.chest, .back], .long))
        #expect(a == b)
    }

    @Test func noChipsBuildsNothing() {
        #expect(builder(GymFixtures.iron).build(request([], .long))
            == BuiltWorkout(items: [], thin: [], requestedSlots: 0))
    }

    private func exercise(_ item: BuiltItem) -> Exercise {
        GymFixtures.exercises.first { $0.id == item.exercise.exerciseId }!
    }
}
```

`ios/Packages/GymCore/Tests/GymCoreTests/Gym/WorkoutBuilderVarietyTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

/// Variety: recent exercises are skipped, repeats are explained, Rebuild avoids the current result.
@Suite struct WorkoutBuilderVarietyTests {
    private let day = 20_400

    private func build(_ inventory: GymInventory, _ muscles: [BuildMuscle], _ length: BuildLength,
                       history: [Workout] = [], avoid: Set<String> = []) -> BuiltWorkout {
        WorkoutBuilder(matcher: GymFixtures.matcher(inventory), exercises: GymFixtures.exercises, history: history)
            .build(BuildRequest(muscles: muscles, length: length, date: GymFixtures.date(day: day), avoid: avoid))
    }

    @Test func exercisesFromRecentWorkoutsForTheMuscleAreSkipped() {
        let fresh = build(GymFixtures.iron, [.chest], .short)
        let history = [GymFixtures.workout(day: day - 1, fresh.items.map(\.exercise.exerciseId))]
        let next = build(GymFixtures.iron, [.chest], .short, history: history)
        #expect(Set(next.items.map(\.exercise.exerciseId)).isDisjoint(with: fresh.items.map(\.exercise.exerciseId)))
        #expect(next.items.allSatisfy { $0.repeatOf == nil })
    }

    @Test func onlyTheLastThreeWorkoutsForTheMuscleCount() {
        let machines = GymInventory(gymName: "Machines", listings: [
            InventoryListing(id: GymFixtures.id(70), kindId: "pec-deck", confirmCount: 5),
            InventoryListing(id: GymFixtures.id(71), kindId: "chest-press-machine", confirmCount: 4),
            InventoryListing(id: GymFixtures.id(72), kindId: "cable-station", confirmCount: 3),
        ])
        let old = GymFixtures.workout(day: day - 9, ["c-pec-deck"])
        let recent = (1...3).map { GymFixtures.workout(day: day - $0, ["c-machine-press"]) }
        let built = build(machines, [.chest], .short, history: [old] + recent)
        let ids = built.items.map(\.exercise.exerciseId)
        #expect(ids.contains("c-pec-deck"), "the 4th-latest chest workout no longer counts")
        #expect(!ids.contains("c-machine-press"))
        #expect(built.items.allSatisfy { $0.repeatOf == nil })
    }

    @Test func workoutsForOtherMusclesDontCount() {
        // Three leg days don't push the chest day out of the last 3 chest workouts.
        let legDays = (1...3).map { GymFixtures.workout(day: day - $0, ["l-leg-press"]) }
        let chestDay = GymFixtures.workout(day: day - 4, ["c-machine-press"])
        let built = build(GymFixtures.iron, [.chest], .long, history: legDays + [chestDay])
        #expect(!built.items.map(\.exercise.exerciseId).contains("c-machine-press"))
    }

    @Test func aRepeatIsUsedWhenNothingElseFitsAndCarriesItsLastDay() throws {
        let history = [GymFixtures.workout(day: day - 2, ["b-kb-row"])]
        let built = build(GymFixtures.home, [.back], .short, history: history)
        let row = try #require(built.items.first { $0.exercise.exerciseId == "b-kb-row" })
        #expect(row.repeatOf == GymFixtures.workout(day: day - 2, []).startedAt)
    }

    @Test func repeatsPickTheLeastRecentlyDoneFirst() throws {
        // One arms slot (3 slots over 3 chips); both kettlebell arm exercises are recent, the skull crusher less so.
        let history = [GymFixtures.workout(day: day - 1, ["a-kb-curl"]), GymFixtures.workout(day: day - 2, ["a-kb-skull"])]
        let built = build(GymFixtures.home, [.arms, .back, .chest], .short, history: history)
        let arms = try #require(built.items.first { $0.muscle == .arms })
        #expect(arms.exercise.exerciseId == "a-kb-skull")
        #expect(arms.repeatOf == GymFixtures.workout(day: day - 2, []).startedAt)
    }

    @Test func rebuildAvoidsTheCurrentResultWithoutMarkingRepeats() {
        let first = build(GymFixtures.iron, [.chest], .short)
        let avoid = Set(first.items.map(\.exercise.exerciseId))
        let second = build(GymFixtures.iron, [.chest], .short, avoid: avoid)
        #expect(Set(second.items.map(\.exercise.exerciseId)).isDisjoint(with: avoid))
        let thin = build(GymFixtures.home, [.arms], .short, avoid: ["a-kb-curl", "a-kb-skull"])
        #expect(thin.items.count == 2, "with nothing else, Rebuild returns the same exercises")
        #expect(thin.items.allSatisfy { $0.repeatOf == nil })
    }
}
```

- [x] **Step 2: Run them and see them fail**

Run: `cd ios/Packages/GymCore && swift test --filter WorkoutBuilder`
Expected: build error `cannot find 'WorkoutBuilder' in scope`.

- [x] **Step 3: Implement the output types and `build`**

`ios/Packages/GymCore/Sources/GymCore/Gym/WorkoutBuilder.swift`:

```swift
import Foundation

/// One exercise of a built workout.
public struct BuiltItem: Sendable, Hashable {
    public let exercise: RoutineExercise
    public let match: InventoryMatch
    public let muscle: BuildMuscle
    /// Set when this repeats a recent exercise because nothing else fits: the day it was last done.
    public let repeatOf: Date?
    /// A no-equipment exercise that fills a slot after the equipment exercises ran out.
    public let isBodyweightFill: Bool
}

/// "Only N <muscle> items catalogued at <gym> so far."
public struct ThinInventoryNotice: Sendable, Hashable {
    public let muscle: BuildMuscle
    /// Active listings at the gym used by at least one equipment candidate for this muscle.
    public let itemCount: Int
}

/// The result of Build workout. It can be shorter than `requestedSlots`: slots that nothing fits are dropped, never
/// padded with equipment the gym doesn't have.
public struct BuiltWorkout: Sendable, Hashable {
    public let items: [BuiltItem]
    public let thin: [ThinInventoryNotice]
    public let requestedSlots: Int
}

/// Builds a workout for muscle chips from one gym's equipment (spec §5, "Build workout").
public struct WorkoutBuilder: Sendable {
    /// At most this many exercises on one machine listing (`EquipmentKind.isMachine`).
    public static let maxPerMachine = 2
    /// Exercises from this many of the latest workouts that trained a muscle are skipped for it.
    public static let recentWorkoutsPerMuscle = 3
    static let idNamespace = UUID(uuidString: "6A0F3C52-1B7E-4F0D-9C2A-3D5E7B9A1C40")!

    let matcher: InventoryMatcher
    let exercises: [Exercise]
    let byId: [String: Exercise]
    /// Newest first.
    let history: [Workout]
    let loggedCounts: [String: Int]
    let preferences: [String: ExercisePreference]

    public init(matcher: InventoryMatcher, exercises: [Exercise], history: [Workout],
                loggedCounts: [String: Int] = [:], preferences: [String: ExercisePreference] = [:]) {
        self.matcher = matcher
        self.exercises = exercises
        self.byId = Dictionary(exercises.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.history = history.sorted { $0.startedAt > $1.startedAt }
        self.loggedCounts = loggedCounts
        self.preferences = preferences
    }

    /// Fills the slots round-robin across the chips with equipment exercises, then fills what's left with
    /// no-equipment exercises. Thin-inventory notices are for chips that had slots no equipment exercise fit.
    public func build(_ request: BuildRequest) -> BuiltWorkout {
        guard !request.muscles.isEmpty else { return BuiltWorkout(items: [], thin: [], requestedSlots: 0) }
        let day = StableHash.day(of: request.date)
        let total = request.length.slots(muscleCount: request.muscles.count)
        let pools = Dictionary(uniqueKeysWithValues: request.muscles.map { ($0, pool(for: $0, day: day)) })
        var picker = SlotPicker(matcher: matcher, avoid: request.avoid)
        var unfilled: [BuildMuscle: Int] = [:]
        for slot in 0..<total {
            let muscle = request.muscles[slot % request.muscles.count]
            guard let pool = pools[muscle] else { continue }
            if !picker.pick(from: pool.equipment, recent: pool.recent, muscle: muscle, fill: false) {
                unfilled[muscle, default: 0] += 1
            }
        }
        let thin = request.muscles.compactMap { muscle -> ThinInventoryNotice? in
            guard unfilled[muscle, default: 0] > 0, let pool = pools[muscle] else { return nil }
            return ThinInventoryNotice(muscle: muscle, itemCount: Set(pool.equipment.flatMap(\.match.listingIds)).count)
        }
        for muscle in request.muscles {
            guard let pool = pools[muscle] else { continue }
            for _ in 0..<unfilled[muscle, default: 0] {
                _ = picker.pick(from: pool.bodyweight, recent: pool.recent, muscle: muscle, fill: true)
            }
        }
        let items = Self.ordered(picker.picked).map { item(from: $0, day: day) }
        return BuiltWorkout(items: items, thin: thin, requestedSlots: total)
    }

    /// Exercises that train two or more muscle groups first, then the rest, then bodyweight fills; otherwise the
    /// order they were picked in (round-robin across the chips).
    static func ordered(_ picks: [SlotPicker.Pick]) -> [SlotPicker.Pick] {
        func rank(_ pick: SlotPicker.Pick) -> Int { pick.isFill ? 2 : (pick.candidate.compound ? 0 : 1) }
        return picks.enumerated()
            .sorted { a, b in rank(a.element) != rank(b.element) ? rank(a.element) < rank(b.element) : a.offset < b.offset }
            .map(\.element)
    }

    /// The default sets and reps for the exercise's equipment, no planned weight (progression and `AvailableLoads`
    /// set it later), and an id that is the same for the same day and exercise.
    private func item(from pick: SlotPicker.Pick, day: Int) -> BuiltItem {
        let exercise = pick.candidate.exercise
        let defaults = RoutineExercise.defaults(exerciseId: exercise.id, mode: exercise.mode,
                                                barbell: exercise.isBarbellLoaded)
        let planned = RoutineExercise(id: StableUUID.make(namespace: Self.idNamespace, name: "\(day)|\(exercise.id)"),
                                      exerciseId: exercise.id, sets: defaults.sets, reps: defaults.reps,
                                      repsMin: defaults.repsMin, sec: defaults.sec, mode: defaults.mode,
                                      policy: defaults.policy, incKg: defaults.incKg)
        return BuiltItem(exercise: planned, match: pick.candidate.match, muscle: pick.muscle, repeatOf: pick.repeatOf,
                         isBodyweightFill: pick.isFill)
    }
}
```

- [x] **Step 4: Implement the candidate pools**

`ios/Packages/GymCore/Sources/GymCore/Gym/WorkoutBuilder+Pool.swift`:

```swift
import Foundation

/// An exercise the builder may use for a chip at this gym.
struct BuildCandidate: Sendable {
    let exercise: Exercise
    let match: InventoryMatch
    /// Trains two or more muscle groups (`MuscleTaxonomy.contributions`).
    let compound: Bool
}

/// A chip's candidates, ranked best first, plus the exercises recently done for it.
struct BuildPool: Sendable {
    let equipment: [BuildCandidate]
    let bodyweight: [BuildCandidate]
    /// Exercise id → the latest day it was done, from the last `recentWorkoutsPerMuscle` workouts for the chip.
    let recent: [String: Date]
}

extension WorkoutBuilder {
    /// Rep exercises whose primary muscle is in the chip, available at the gym and not marked `never`, ranked:
    /// `more` first and `less` last, then the listing with more confirmations (own listings count as one), then
    /// the more-logged exercise, then a tie-break seeded by the day.
    func pool(for muscle: BuildMuscle, day: Int) -> BuildPool {
        let ranked = exercises.compactMap { candidate($0, for: muscle) }.sorted { ranksBefore($0, $1, day: day) }
        return BuildPool(equipment: ranked.filter { !matcher.needsNoEquipment($0.exercise.id) },
                         bodyweight: ranked.filter { matcher.needsNoEquipment($0.exercise.id) },
                         recent: recent(for: muscle))
    }

    private func candidate(_ exercise: Exercise, for muscle: BuildMuscle) -> BuildCandidate? {
        guard exercise.mode == .reps, preferences[exercise.id] != .never else { return nil }
        let contributions = MuscleTaxonomy.contributions(for: exercise)
        guard contributions.contains(where: { $0.isPrimary && muscle.groups.contains($0.group) }),
              case let .available(match) = matcher.availability(of: exercise.id) else { return nil }
        return BuildCandidate(exercise: exercise, match: match, compound: contributions.count >= 2)
    }

    private func ranksBefore(_ a: BuildCandidate, _ b: BuildCandidate, day: Int) -> Bool {
        let pa = (preferences[a.exercise.id] ?? .normal).rank, pb = (preferences[b.exercise.id] ?? .normal).rank
        if pa != pb { return pa < pb }
        let sa = score(a.match), sb = score(b.match)
        if sa != sb { return sa > sb }
        let la = loggedCounts[a.exercise.id, default: 0], lb = loggedCounts[b.exercise.id, default: 0]
        if la != lb { return la > lb }
        return StableHash.fnv1a("\(day)|\(a.exercise.id)") < StableHash.fnv1a("\(day)|\(b.exercise.id)")
    }

    private func score(_ match: InventoryMatch) -> Int {
        (match.loadListingId ?? match.listingIds.first).flatMap { matcher.listing($0)?.score } ?? 0
    }

    /// The exercises of the latest `recentWorkoutsPerMuscle` workouts that trained the chip (any entry whose primary
    /// muscle is in it), each with the latest day it was done.
    private func recent(for muscle: BuildMuscle) -> [String: Date] {
        let trained = history.filter { workout in
            workout.entries.contains { entry in byId[entry.exerciseId].map { trains($0, muscle) } ?? false }
        }
        return trained.prefix(Self.recentWorkoutsPerMuscle).reduce(into: [:]) { dates, workout in
            for entry in workout.entries where dates[entry.exerciseId] == nil {
                dates[entry.exerciseId] = workout.startedAt
            }
        }
    }

    private func trains(_ exercise: Exercise, _ muscle: BuildMuscle) -> Bool {
        MuscleTaxonomy.contributions(for: exercise).contains { $0.isPrimary && muscle.groups.contains($0.group) }
    }
}
```

- [x] **Step 5: Implement the slot picker**

`ios/Packages/GymCore/Sources/GymCore/Gym/SlotPicker.swift`:

```swift
import Foundation

/// Picks the builder's exercises one slot at a time, keeping each exercise once and each machine listing to at most
/// `WorkoutBuilder.maxPerMachine` exercises.
struct SlotPicker {
    struct Pick: Sendable {
        let candidate: BuildCandidate
        let muscle: BuildMuscle
        let repeatOf: Date?
        let isFill: Bool
    }

    let matcher: InventoryMatcher
    let avoid: Set<String>
    private(set) var picked: [Pick] = []
    private var chosen: Set<String> = []
    private var machineUse: [UUID: Int] = [:]

    init(matcher: InventoryMatcher, avoid: Set<String>) {
        self.matcher = matcher
        self.avoid = avoid
    }

    /// Takes the best open candidate for one slot: a fresh one (not recent, not avoided) first, then an avoided one,
    /// then a recent one, least recently done first, which is marked as a repeat. Returns false when none is open.
    mutating func pick(from pool: [BuildCandidate], recent: [String: Date], muscle: BuildMuscle, fill: Bool) -> Bool {
        let open = pool.filter { !chosen.contains($0.exercise.id) && fitsMachineCap($0.match) }
        let notRecent = open.filter { recent[$0.exercise.id] == nil }
        let fresh = notRecent.first { !avoid.contains($0.exercise.id) } ?? notRecent.first
        let repeated = open.filter { recent[$0.exercise.id] != nil }
            .min { recent[$0.exercise.id] ?? .distantFuture < recent[$1.exercise.id] ?? .distantFuture }
        guard let candidate = fresh ?? repeated else { return false }
        let repeatOf = fresh == nil ? recent[candidate.exercise.id] : nil
        record(Pick(candidate: candidate, muscle: muscle, repeatOf: repeatOf, isFill: fill))
        return true
    }

    private mutating func record(_ pick: Pick) {
        picked.append(pick)
        chosen.insert(pick.candidate.exercise.id)
        if let id = machineListing(pick.candidate.match) { machineUse[id, default: 0] += 1 }
    }

    private func fitsMachineCap(_ match: InventoryMatch) -> Bool {
        guard let id = machineListing(match) else { return true }
        return machineUse[id, default: 0] < WorkoutBuilder.maxPerMachine
    }

    /// The match's load listing when its kind is a machine.
    private func machineListing(_ match: InventoryMatch) -> UUID? {
        guard let id = match.loadListingId, let listing = matcher.listing(id),
              matcher.kind(listing.kindId)?.isMachine == true else { return nil }
        return id
    }
}
```

- [x] **Step 6: Run them and see them pass**

Run: `cd ios/Packages/GymCore && swift test --filter WorkoutBuilder`
Expected: `Test run with 15 tests in 2 suites passed`.

- [x] **Step 7: Commit**

```bash
git add ios/Packages/GymCore/Sources/GymCore/Gym/WorkoutBuilder.swift \
  ios/Packages/GymCore/Sources/GymCore/Gym/WorkoutBuilder+Pool.swift \
  ios/Packages/GymCore/Sources/GymCore/Gym/SlotPicker.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/Gym/WorkoutBuilderTests.swift \
  ios/Packages/GymCore/Tests/GymCoreTests/Gym/WorkoutBuilderVarietyTests.swift
git commit -m "feat(core): build a workout from a gym's equipment"
```

---

### Task 11: Acceptance tests for spec criteria 1, 3 and 5

**Files:**
- Test: `ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymRulesAcceptanceTests.swift`

These check the finished rules against the spec's success criteria, so they're expected to pass on the first run.
If one fails, the bug is in Tasks 6–10: fix it there and don't loosen the test. Criterion 5 is a property test over
40 seeded random inventories, covering both the builder and the adapter.

- [x] **Step 1: Write the tests**

`ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymRulesAcceptanceTests.swift`:

```swift
import Foundation
import Testing
@testable import GymCore

/// The spec's success criteria 1, 3 and 5 (docs/specs/2026-10-30-gym-equipment-design.md §1).
@Suite struct GymRulesAcceptanceTests {
    /// Every requirement group of the exercise is covered by a listing of the match, and every listing is at the gym.
    private func covers(_ match: InventoryMatch, _ exerciseId: String, _ inventory: GymInventory) -> Bool {
        guard let groups = GymFixtures.requirements.requirement(for: exerciseId) else { return false }
        let byId = Dictionary(uniqueKeysWithValues: inventory.listings.map { ($0.id, $0) })
        let used = match.listingIds.compactMap { byId[$0] }
        return used.count == match.listingIds.count
            && groups.allSatisfy { group in used.contains { group.contains($0.kindId) } }
    }

    @Test func criterion1NewGymWithFiveListingsBuildsAChestWorkoutFromThem() {
        let gym = GymInventory(gymName: "New gym", listings: [
            InventoryListing(id: GymFixtures.id(60), kindId: "dumbbells", loads: .fixed(kg: [10, 15, 20]), isOwn: true),
            InventoryListing(id: GymFixtures.id(61), kindId: "adjustable-bench", isOwn: true),
            InventoryListing(id: GymFixtures.id(62), kindId: "cable-station", loads: .stack(maxKg: 80, stepKg: 5), isOwn: true),
            InventoryListing(id: GymFixtures.id(63), kindId: "chest-press-machine", loads: .stack(maxKg: 100, stepKg: 5), isOwn: true),
            InventoryListing(id: GymFixtures.id(64), kindId: "pec-deck", loads: .stack(maxKg: 80, stepKg: 5), isOwn: true),
        ])
        let built = WorkoutBuilder(matcher: GymFixtures.matcher(gym), exercises: GymFixtures.exercises, history: [])
            .build(BuildRequest(muscles: [.chest], length: .medium, date: GymFixtures.date(day: 20_400)))
        #expect(built.items.count == 4)
        #expect(built.thin.isEmpty)
        for item in built.items {
            #expect(!item.isBodyweightFill)
            #expect(!item.match.listingIds.isEmpty)
            #expect(covers(item.match, item.exercise.exerciseId, gym), "\(item.exercise.exerciseId)")
        }
    }

    @Test func criterion3SameMusclesFourDaysInARowChangeAtLeastHalfEachTime() {
        let start = 20_400
        let results = (0..<4).reduce(into: (history: [Workout](), ids: [[String]]())) { state, offset in
            let built = WorkoutBuilder(matcher: GymFixtures.matcher(GymFixtures.iron), exercises: GymFixtures.exercises,
                                       history: state.history)
                .build(BuildRequest(muscles: [.chest], length: .short, date: GymFixtures.date(day: start + offset)))
            let ids = built.items.map(\.exercise.exerciseId)
            state.ids.append(ids)
            state.history.append(GymFixtures.workout(day: start + offset, ids))
        }.ids
        #expect(results.allSatisfy { $0.count == 3 })
        for (previous, next) in zip(results, results.dropFirst()) {
            let changed = Set(next).subtracting(previous).count
            #expect(changed * 2 >= next.count, "\(previous) → \(next)")
        }
    }

    @Test(arguments: 0..<40)
    func criterion5NeverInventsEquipment(seed: Int) {
        var random = SplitMix64(seed: UInt64(seed))
        let inventory = randomInventory(&random)
        let matcher = GymFixtures.matcher(inventory)
        let muscles = BuildMuscle.allCases.filter { _ in Bool.random(using: &random) }
        let length = BuildLength.allCases.randomElement(using: &random) ?? .short
        let built = WorkoutBuilder(matcher: matcher, exercises: GymFixtures.exercises, history: [])
            .build(BuildRequest(muscles: muscles, length: length, date: GymFixtures.date(day: 20_400 + seed)))
        for item in built.items {
            #expect(covers(item.match, item.exercise.exerciseId, inventory), "\(item.exercise.exerciseId)")
        }
        let machineUse = Dictionary(grouping: built.items.compactMap { item -> UUID? in
            guard let id = item.match.loadListingId, let listing = matcher.listing(id) else { return nil }
            return matcher.kind(listing.kindId)?.isMachine == true ? id : nil
        }, by: { $0 }).mapValues(\.count)
        #expect(machineUse.values.allSatisfy { $0 <= WorkoutBuilder.maxPerMachine })

        let routine = GymFixtures.exercises.enumerated().map { index, exercise in
            RoutineExercise(id: GymFixtures.id(500 + index), exerciseId: exercise.id, sets: 3, reps: 10)
        }
        for adapted in GymAdapter(matcher: matcher, exercises: GymFixtures.exercises).adapt(routine) {
            switch adapted {
            case let .kept(item, match): #expect(covers(match, item.exerciseId, inventory))
            case let .swapped(_, item, match, _): #expect(covers(match, item.exerciseId, inventory))
            case let .unavailable(item, _): #expect(matcher.availability(of: item.exerciseId) != .unmapped)
            case let .unmapped(item): #expect(matcher.availability(of: item.exerciseId) == .unmapped)
            }
        }
    }

    /// Each fixture kind is present with probability 1/2, as one or two listings with random confirmations.
    private func randomInventory(_ random: inout SplitMix64) -> GymInventory {
        var next = 1_000
        let listings = GymFixtures.kinds.flatMap { kind -> [InventoryListing] in
            guard Bool.random(using: &random) else { return [] }
            return (0..<Int.random(in: 1...2, using: &random)).map { _ in
                next += 1
                return InventoryListing(id: GymFixtures.id(next), kindId: kind.id,
                                        confirmCount: Int.random(in: 0...9, using: &random),
                                        isOwn: Bool.random(using: &random))
            }
        }
        return GymInventory(gymName: "Random", listings: listings)
    }
}

/// A small seeded generator, so the property test's inventories are the same on every run.
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
```

- [x] **Step 2: Run them**

Run: `cd ios/Packages/GymCore && swift test --filter GymRulesAcceptanceTests`
Expected: `Test run with 3 tests in 1 suite passed` (criterion 5's 40 seeds count as one test).

- [x] **Step 3: Commit**

```bash
git add ios/Packages/GymCore/Tests/GymCoreTests/Gym/GymRulesAcceptanceTests.swift
git commit -m "test(core): gym rules acceptance criteria 1, 3 and 5"
```

---

### Task 12: Full verification and docs

**Files:**
- Modify: `README.md` (the Test table)
- Modify: `docs/plans/2026-10-30-plan-19-gym-rules.md` (this file: tick the boxes, add an Outcome section)

- [x] **Step 1: Run the whole GymCore suite with the coverage gate**

Run: `scripts/coverage-gymcore.sh`
Expected: every test passes and the script prints `Line coverage: 9x.xx% (threshold 90%)`, exiting 0. The
prototype measured 90.96%.

- [x] **Step 2: Run the mapping tests again and check the data is current**

Run: `node --test scripts/map-equipment-requirements.test.mjs && node scripts/map-equipment-requirements.mjs && git status --short`
Expected: `# fail 0`, and no changes listed (the committed JSON and review match a fresh run).

- [x] **Step 3: Run the app unit tests**

Run: `scripts/ios-test.sh -skip-testing:GymRollinsUITests`
Expected: `** TEST SUCCEEDED **`.

- [x] **Step 4: Document the new test command**

In `README.md`'s Test table, add this row after the `GymCore coverage (≥ 90%)` row:

```markdown
| Equipment requirements mapping (writes `equipment-requirements.json` and its review file) | `node --test scripts/map-equipment-requirements.test.mjs` |
```

- [x] **Step 5: Record the outcome**

Tick every box in this plan, then append:

```markdown
## Outcome

Done on <date>, branch `feat-gym-rules`. GymCore: <N> tests, line coverage <x>%. Mapping: <mapped> / 1,324
exercises (<none> need no equipment). Follow-ups for plan 20: wire `GymAdapter` into Today, `WorkoutBuilder` into
Build workout, and `AvailableLoads` into the suggestion pipeline.
```

- [x] **Step 6: Commit**

```bash
git add README.md docs/plans/2026-10-30-plan-19-gym-rules.md
git commit -m "docs: plan 19 outcome and the mapping test command"
```

## Spec coverage (milestone 1)

| Spec item | Task |
|---|---|
| §4 curated kinds, requirements JSON, mapping script, review file | 1, 2, 3 |
| §4 `loads` JSON shape | 4 |
| §5 "Can I do this exercise here?" (own first, then confirmations; unknown kinds ignored) | 6 |
| §5 Plan adaptation (kept, swapped, unavailable, unmapped; Swap order; no duplicates) | 7, 8 |
| §5 Build workout steps 1–9 (candidates, slots, variety, ranking, spread, thin notices, fills, weights, Rebuild) | 5, 9, 10 |
| §1 criteria 1, 3, 5 | 11, and `GymRealDataTests` for criterion 3 at the owner's home gym |
| §10 milestone 1 | all |

Not in this plan (by design): the seed migration and drift test for the server tables (plan 21), the app's use of
the rules (plan 20), and criteria 2, 4 and 6 (plans 20–21).

## Outcome

Done on 2026-10-30, branch `feat-gym-rules`. GymCore: 468 tests, line coverage 96.42%. App unit tests: 473 passed, 2
skipped (existing integration tests), 0 failed. Mapping: 1,107 / 1,324 exercises (118 need no equipment), 217 unmapped.

**Changed by review.** The code blocks above compiled and passed on a copy of GymCore, but small fixtures hid problems
that only showed up against the real library. The committed code differs from this plan's first version:
- **Mapping:** 151 exercises changed. They needed more equipment than the first rules said, or were stretches,
  holds and elite skills that shouldn't be picked.
- **Fallback order:** fresh equipment, then fresh no-equipment, then a repeat (least recently done first), then what
  Rebuild is avoiding (oldest shown first). `BuildRequest.avoid` became an ordered list.
- **Machine cap:** an exercise on a capped listing moves to the gym's next listing that fits.
- **Ranking:** an exercise ranks by the best listing that could serve its requirement group, so an own listing never
  lowers it. The tie-break gets a SplitMix64 finalizer.
- **Recent:** only hard sets up to the request date count.
- **New:** `BuiltWorkout.skipped` for chips with no slot.

**Follow-ups for plan 20.** Wire `GymAdapter` into Today, `WorkoutBuilder` into Build workout, and `AvailableLoads` into
the suggestion pipeline. Rebuild must append each result to `avoid`. Show `skipped` ("No room for Core at 30 min"). The
thin notice needs other words when N is 0. `SessionPlanner.barbellEquipment` still duplicates
`Exercise.barbellLoadedEquipment`.

**Open for the owner.** A chip with no candidates shortens the workout rather than giving its slots to other chips, and
an exercise moved off a capped listing keeps its rank. Both follow the spec as written.

**Environment.** `scripts/ios-test.sh` defaults to iOS 26.2, where the test runner failed to connect or hung on this
Mac. The app tests above ran on the iPhone 17 Pro with iOS 26.4 (`DEST='platform=iOS Simulator,name=iPhone 17 Pro,OS=26.4'`).
