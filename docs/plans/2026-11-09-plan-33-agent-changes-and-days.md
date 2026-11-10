# Plan 33: agents change the plan, and Today shows later days

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the owner has turned on "Apply changes without asking", agents say their plan changes are made, not just proposed. Today can also show later days: swipe left for the next day, or tap the date and pick one.

**Architecture:** Part A changes wording only. The app already applies an agent's pending proposals by itself when `mcp_auto_apply` is on (`ProposalService.autoApplyPending`, run on every sync pull). However, the server's MCP instructions, the `propose_plan_changes` description and its result all tell agents the owner reviews every change. The server will now read the switch and say which way a change lands. The app's copyable coach prompt stops saying everything waits for review.

Part B adds a read-only preview of a later day to Today. It uses the plan Today would show on that day (an agent's one-day change from `PlannedSwitchStore`, else the week schedule), adapted to the current gym, with today's suggested sets. The preview never consumes the planned switch and never touches today's stored edits.

**Tech Stack:** Cloudflare Worker + Hono MCP server (TypeScript, Vitest in the workers pool); SwiftUI app (iOS 26), Swift Testing unit tests, XCUITest.

---

## Decisions (owner, 2026-11-09)

1. **Agent changes use the existing switch.**
   - When "Apply changes without asking" is on, agents are told their changes are made. The app applies them the next time it opens or syncs, and the owner can undo for 7 days.
   - When the switch is off, nothing changes: agents propose and the owner reviews.
   - The server does not write the plan directly. That would lose the 7-day undo, and one-day (`today`) changes live only on the phone.
2. **A later day is view-only.**
   - Today shows that day's workout and suggested sets. A "Back to today" button replaces Start and Build.
   - Rows open the exercise (Video & Instructions, Exercise History). There is no Switch, no Add Exercise, no editing and no Share.
3. **Future days only.** Today is the earliest reachable day; past workouts stay in Log/History.

Diagnosis (why agents said "I can only propose"):
- `server/src/mcp/instructions.ts` opens with "You read their training and propose plan changes; the owner reviews them in the app." and says "tell the owner they review it in the app".
- `propose_plan_changes` says "Proposals never change anything by themselves".
- Its result is always `applies: 'when the owner reviews it in the app (or automatically if auto-apply is on)'`.
- The app's coach prompt says "Every change to my plan goes to GymRollins as a proposal, so I can review it."
- `get_profile` does return `permissions.auto_apply`, but nothing tells the agent what it means.

Out of scope:
- Renaming the `propose_plan_changes` tool, because prompts and the onboarding text name it.
- Editing or switching a future day.
- Past days.
- Push notifications to make the phone apply sooner.

## File map

Server (Part A):
- Modify `server/src/mcp/d1-db.ts`: `Permissions.autoApply` and `autoApply()`.
- Modify `server/src/mcp/db.ts`: the `autoApply()` method on the `Db` interface.
- Modify `server/test/mcp/fake-db.ts`: `autoApply()`.
- Modify `server/src/mcp/tools/write.ts`: `appliesNote`, the result field `auto_apply`, and `get_proposal`'s `applies`.
- Modify `server/src/mcp/tools/register.ts`: the `propose_plan_changes` description.
- Modify `server/src/mcp/instructions.ts`: lines 1 and 5.
- Tests: `server/test/mcp/tools/write.test.ts`, `server/test/mcp/d1-db.test.ts`, `server/test/mcp/instructions.test.ts` and `server/test/mcp/agent-wording.test.ts`.

App wording (Part A):
- Modify `ios/GymRollins/Features/Claude/ClaudePrompts.swift`.
- Modify `ios/GymRollinsTests/ClaudePromptsTests.swift`.
- Modify `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift`: the permissions footer.
- Modify `README.md`: line 28.

Today days (Part B):
- Create `ios/GymRollins/Features/Today/TodayDay.swift`: `TodayDay` (offset, date, title) and `DayPreview` (plan + model).
- Create `ios/GymRollins/App/AppEnvironment+DayPreview.swift`: `previewPlan(on:)`.
- Create `ios/GymRollins/Features/Today/TodayDayPreviewView.swift`: the preview content and `TodayGymNote`.
- Create `ios/GymRollins/Features/Today/TodayDatePickerSheet.swift`.
- Modify `ios/GymRollins/Features/Today/TodayExerciseRow.swift`: an `openHint` parameter.
- Modify `ios/GymRollins/Features/Today/TodayView.swift`: day state, swipe, date button, preview, bottom bar and resets.
- Tests: `ios/GymRollinsTests/TodayDayTests.swift`, `ios/GymRollinsTests/DayPreviewEnvironmentTests.swift` and `ios/GymRollinsUITests/TodayDaysUITests.swift`.

Commands:
- Server: `cd server && npx vitest run && npx tsc --noEmit`
- One iOS test class: `scripts/ios-test.sh -only-testing:GymRollinsTests/TodayDayTests`. The script passes extra args to `xcodebuild test`.
- Full iOS suite: `scripts/ios-test.sh`. The xcresult lands in `ios/build/`; read failures with `xcrun xcresulttool get test-results summary --path <bundle>`.

Rules for every task:
- Commit messages are conventional (`feat:`, `fix:`, `test:`, `docs:`). Never add Co-Authored-By, "Generated with" or Claude-Session lines.
- Never deploy, never `wrangler login`, never push, never install on a device.
- Never print or commit `server/.dev.vars` or `ios/Config/Local.xcconfig`.
- Test data is synthetic.

---

### Task 1: The server says how a change lands

**Files:** `server/src/mcp/d1-db.ts`, `server/src/mcp/db.ts`, `server/test/mcp/fake-db.ts`, `server/src/mcp/tools/write.ts`, `server/src/mcp/tools/register.ts`, `server/src/mcp/instructions.ts`, and the tests listed in the file map.

- [ ] **Step 1: Write the failing tests**

In `server/test/mcp/tools/write.test.ts`, update the existing valid-proposal test's last assertion. Then add a test with the switch on. `fixtureDb()` builds a `FakeDb` from `testdata/owner.json`, whose profile has `mcp_auto_apply: false`; read `fake-db.ts` to see how the test sets the profile, as `agent-wording.test.ts` does with `data.profile = { ...data.profile!, … }`.

```ts
  // in "the fixture's valid proposal is inserted once…", replacing the `applies` assertion:
  assertEquals(out.auto_apply, false)
  assert(String(out.applies).includes('Tell them to review it there'), String(out.applies))

test('propose_plan_changes: with "Apply changes without asking" on, the agent is told the change is made', async () => {
  const db = fixtureDb()
  db.data.profile = { ...db.data.profile!, mcp_auto_apply: true } // adapt to how FakeDb exposes its data
  const valid = fixture.cases.find((c) => c.name === 'valid knee-break proposal')!
  const out = json(await proposePlanChanges({ db, now: NOW }, valid.proposal))
  assertEquals(out.auto_apply, true)
  assertEquals(out.applies, APPLIES_AUTOMATICALLY)
  assert(String(out.applies).includes('Tell the owner the change is made'))
})

test('get_proposal: a pending proposal says how it will land', async () => {
  // Insert via proposePlanChanges, then call getProposal with the returned id, once with the switch off and once
  // on; expect applies === APPLIES_AFTER_REVIEW and APPLIES_AUTOMATICALLY. A resolved proposal has no `applies`.
})
```

(If `FakeDb.proposal(id)` can't return inserted proposals, give the third test a fake that returns `{ status: 'pending', … }` the way the existing `getProposal` tests do. Read them first.)

In `server/test/mcp/d1-db.test.ts`, next to the existing `readPermissions` and profile tests, add:

```ts
it('autoApply is off without a profile and follows mcp_auto_apply', async () => {
  // a user with no profile row → false; after writing a profile with mcp_auto_apply = 1 → true
})
```

Copy the user/profile setup from the neighbouring tests in that file.

In `server/test/mcp/instructions.test.ts`, add:

```ts
test('instructions say how auto_apply changes what the agent tells the owner', () => {
  assert(SERVER_INSTRUCTIONS.includes('auto_apply'), 'names the permission')
  assert(SERVER_INSTRUCTIONS.includes("say they're made"), 'switch on: changes are made')
  assert(!SERVER_INSTRUCTIONS.includes('the owner reviews them in the app.'), 'no longer review-only')
})
```

In `server/test/mcp/agent-wording.test.ts`, inside `names agents in every description, never Claude`, add:

```ts
    expect(byName.propose_plan_changes).toContain('permissions.auto_apply')
    expect(byName.propose_plan_changes).not.toContain('never change anything by themselves')
```

- [ ] **Step 2: Run the tests to see them fail**

Run: `cd server && npx vitest run test/mcp`
Expected: FAIL. The new tests fail because `APPLIES_AUTOMATICALLY`, `auto_apply` and `autoApply` don't exist yet, and the wording differs.

- [ ] **Step 3: Implement**

`server/src/mcp/d1-db.ts`:
- In `Permissions`, add after `propose`: `/** "Apply changes without asking": off by default, so off without a profile too. */ autoApply: boolean`.
- In `allowed()`, select `mcp_auto_apply` too and add `autoApply: p ? bool(p.mcp_auto_apply) : false,`.
- Add, next to `readPermissions()`:

```ts
  /** "Apply changes without asking", answered even when "Read your plan and profile" hides the profile. */
  async autoApply(): Promise<boolean> {
    return (await this.allowed()).autoApply
  }
```

`server/src/mcp/db.ts`: add `autoApply(): Promise<boolean>` to `Db`, with the same doc comment.

`server/test/mcp/fake-db.ts`: add, next to `readPermissions()`:

```ts
  /** Like D1Db: the stored flag, off when no profile was saved. */
  autoApply(): Promise<boolean> {
    return Promise.resolve(this.data.profile?.mcp_auto_apply ?? false)
  }
```

`server/src/mcp/tools/write.ts`:
- Fix the header comment: "Nothing here changes the plan: proposals are stored as `pending` and only the app applies them, after the owner's review or by itself when the owner turned on auto-apply."
- Replace `APPLIES_NOTE` with:

```ts
/** What a saved proposal's result tells the agent to say (owner, 2026-11-09: with "Apply changes without asking" on,
 *  an agent's changes are made, not proposed; the app applies them when it next syncs). */
export const APPLIES_AUTOMATICALLY =
  'Saved, and the owner turned on "Apply changes without asking": the GymRollins app applies it by itself the next ' +
  'time it opens or syncs, without a review. Tell the owner the change is made; they can undo it in the app for 7 days.'
export const APPLIES_AFTER_REVIEW =
  'Saved for review: the owner applies it in the GymRollins app. Tell them to review it there. To let agents ' +
  'change the plan without a review, they can turn on "Apply changes without asking" in Settings › AI agents.'

export function appliesNote(autoApply: boolean): string {
  return autoApply ? APPLIES_AUTOMATICALLY : APPLIES_AFTER_REVIEW
}
```

- In `proposePlanChanges`, after `insertProposal`:

```ts
  const autoApply = await db.autoApply()
  …
  return ok({
    proposal_id: row.id,
    status: 'pending',
    auto_apply: autoApply,
    changes: args.changes.length,
    applies: appliesNote(autoApply),
    ...(warnings.length ? { warnings } : {}),
  })
```

- In `getProposal`, add `...(p.status === 'pending' ? { applies: appliesNote(await db.autoApply()) } : {}),` after `resolved_at`.
- `grep -rn APPLIES_NOTE server/` must come back empty afterwards.

`server/src/mcp/tools/register.ts`: replace the first two sentences of `propose_plan_changes`' description, "Propose changes to the owner's plan. Proposals never change anything by themselves: the owner reviews them in the app and applies them change by change (or they auto-apply if the owner enabled that).", with:

```ts
      "Change the owner's plan. How a proposal lands depends on the owner's \"Apply changes without asking\" " +
      'setting (get_profile → permissions.auto_apply): when it is on, the app applies the changes by itself the ' +
      'next time it opens, with no review, and the owner can undo them for 7 days; when it is off, the owner ' +
      "reviews them in the app and applies them change by change. The result's `applies` says which to tell the " +
      'owner. ' +
```

Keep the rest of the description as it is ("The whole proposal is validated…").

`server/src/mcp/instructions.ts`: keep 9 lines and the same 8 tool names. Replace line 1 and line 5 (the "Change the plan only…" line):

```ts
  "GymRollins is the owner's gym tracker. You read their training and change their plan with " +
  'propose_plan_changes.',
  …
  '- Change the plan only with propose_plan_changes. If get_profile says auto_apply is on, the app applies your ' +
  "changes by itself and the owner can undo them for 7 days: say they're made, don't ask for a review. If it's " +
  'off, tell the owner to review them in the app. Keep changes small and give each a reason.',
```

Also update the file's top comment: it says the coach prompt "repeats the key ones", which stays true.

- [ ] **Step 4: Run the tests to see them pass**

Run: `cd server && npx vitest run && npx tsc --noEmit`
Expected: all pass with 0 type errors. `app.test.ts` compares `instructions` to the constant, so it passes unchanged.

- [ ] **Step 5: Commit**

```bash
git add server
git commit -m "feat(server): agents are told a change is made when the owner turned on Apply changes without asking"
```

### Task 2: The app's wording follows the switch

**Files:** `ios/GymRollins/Features/Claude/ClaudePrompts.swift`, `ios/GymRollinsTests/ClaudePromptsTests.swift`, `ios/GymRollins/Features/Claude/ClaudeConnectionView.swift` and `README.md`.

- [ ] **Step 1: Update the test first**

In `ClaudePromptsTests.swift`, replace the two expectations:

```swift
        #expect(ClaudePrompts.coach.contains("Plan it for that day only."))
        #expect(ClaudePrompts.coach.contains("My profile says whether they apply straight away or wait for my review"))
        #expect(!ClaudePrompts.coach.contains("as a proposal"))
```

Keep the no-digits and no-unit checks.

- [ ] **Step 2: Run it to see it fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/ClaudePromptsTests`
Expected: FAIL.

- [ ] **Step 3: Implement**

The prompt is pasted once into a Claude Project and the switch can change later. So the prompt tells the agent to read the profile; it never states the switch.

`ClaudePrompts.coach`, lines 3–4 become:

```
        - When I ask for a workout, build it from my plan, history and the equipment where I train. Plan it for that day only.
        - Make plan changes in GymRollins. My profile says whether they apply straight away or wait for my review, so tell me which.
```

Add one sentence to the doc comment: "It never states whether changes are reviewed, because the owner can change that switch after copying; the profile says."

`ClaudeConnectionView.permissionsSection` footer: replace `Text("Applied changes can be undone for 7 days.")` with:

```swift
                Text("With \u{201C}Apply changes without asking\u{201D} on, an agent's plan changes are applied the "
                     + "next time GymRollins opens, without a review. Applied changes can be undone for 7 days.")
                    .accessibilityIdentifier("agents.autoApplyNote")
```

`README.md` line 28: "Claude never edits your plan directly; you review each proposal" becomes "Claude never edits your plan directly: you review each proposal in the app and apply it with one tap, or turn on auto-apply and the app applies Claude's changes for you." Rewrap lines 28–29 to fit.

- [ ] **Step 4: Run it to see it pass**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/ClaudePromptsTests -only-testing:GymRollinsUITests/ClaudePromptsUITests -only-testing:GymRollinsUITests/AgentsUITests`
Expected: PASS. If a UI test matched the old footer or prompt text, update it to the new text.

- [ ] **Step 5: Commit**

```bash
git add ios README.md
git commit -m "feat(ios): the coach prompt and AI agents footer say changes can apply without a review"
```

### Task 3: Which later day, and what it trains

**Files:**
- Create `ios/GymRollins/Features/Today/TodayDay.swift`.
- Create `ios/GymRollins/App/AppEnvironment+DayPreview.swift`.
- Create the tests `ios/GymRollinsTests/TodayDayTests.swift` and `ios/GymRollinsTests/DayPreviewEnvironmentTests.swift`.

New files are picked up by xcodegen; `ios-test.sh` regenerates the project.

- [ ] **Step 1: Write the failing tests**

`ios/GymRollinsTests/TodayDayTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymRollins

@Suite struct TodayDayTests {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }()
    private let locale = Locale(identifier: "en_GB")
    /// Saturday 26 Sep 2026, 09:00 London.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 9))! }

    @Test func offsetsNeverGoBeforeToday() {
        #expect(TodayDay.today.previous == .today)
        #expect(TodayDay(offset: -3) == .today)
        #expect(TodayDay.today.next.offset == 1)
        #expect(TodayDay.today.next.previous == .today)
    }

    @Test func aDateMapsToItsDayFromToday() {
        let tuesday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 23))!
        #expect(TodayDay(date: tuesday, now: now, calendar: calendar).offset == 3)
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 12))!
        #expect(TodayDay(date: yesterday, now: now, calendar: calendar) == .today)
    }

    @Test func theDayKeepsItsCalendarDayAcrossTheClockChange() {
        // UK clocks go back on Sun 25 Oct 2026; 30 days from 26 Sep is Mon 26 Oct.
        let day = TodayDay(offset: 30).date(now: now, calendar: calendar)
        #expect(TodayPlan.dayKey(day, calendar: calendar) == "2026-10-26")
    }

    @Test func titles() {
        #expect(TodayDay.today.title(now: now, calendar: calendar, locale: locale) == "Today")
        #expect(TodayDay(offset: 1).title(now: now, calendar: calendar, locale: locale) == "Tomorrow")
        #expect(TodayDay(offset: 2).title(now: now, calendar: calendar, locale: locale) == "Monday")
        #expect(TodayDay(offset: 6).title(now: now, calendar: calendar, locale: locale) == "Friday")
        #expect(TodayDay(offset: 7).title(now: now, calendar: calendar, locale: locale) == "3 Oct")
    }

    // MARK: DayPreview.plan

    private let push = Routine(name: "Push", exercises: [])
    private let pull = Routine(name: "Pull", exercises: [])
    private let paused = Routine(name: "Legs", paused: true, exercises: [])

    @Test func aRestDayWithNothingPlannedIsNil() {
        #expect(DayPreview.plan(day: "2026-09-27", scheduled: nil, routines: [push], planned: nil) == nil)
    }

    @Test func theScheduledRoutineShows() {
        let plan = DayPreview.plan(day: "2026-09-28", scheduled: push, routines: [push, pull], planned: nil)
        #expect(plan?.kind == .scheduled)
        #expect(plan?.base?.id == push.id)
    }

    @Test func anAgentsOneDayChangeWins() {
        let plan = DayPreview.plan(day: "2026-09-28", scheduled: push, routines: [push, pull], planned: pull.id)
        #expect(plan?.kind == .switched)
        #expect(plan?.base?.id == pull.id)
        let onRest = DayPreview.plan(day: "2026-09-27", scheduled: nil, routines: [push, pull], planned: pull.id)
        #expect(onRest?.base?.id == pull.id)
    }

    @Test func aPlannedChangeTodayWouldIgnoreIsIgnored() {
        // Paused, deleted, or the scheduled routine itself: the same rules as takePlannedSwitch.
        #expect(DayPreview.plan(day: "d", scheduled: push, routines: [push, paused], planned: paused.id)?.kind == .scheduled)
        #expect(DayPreview.plan(day: "d", scheduled: push, routines: [push], planned: UUID())?.kind == .scheduled)
        #expect(DayPreview.plan(day: "d", scheduled: push, routines: [push], planned: push.id)?.kind == .scheduled)
        #expect(DayPreview.plan(day: "d", scheduled: nil, routines: [paused], planned: paused.id) == nil)
    }

    @Test func aRestDayModelSaysRest() {
        let model = DayPreview.model(plan: nil, profile: Profile(), library: ExerciseLibrary(exercises: []),
                                     history: { _ in [] }, gym: nil)
        #expect(model.title == "Rest day")
        #expect(model.summary == "Recover and eat well")
        #expect(model.rows.isEmpty)
    }
}
```

Fit `Profile()`, `ExerciseLibrary(exercises:)` and `Routine(name:paused:exercises:)` to the real initialisers; see `TodayModel` tests or `ExerciseSuggestionsTests` for how they're built.

`ios/GymRollinsTests/DayPreviewEnvironmentTests.swift`. Build the environment like `ClaudeEnvironmentTests.makeEnv()`: `-uiTesting` seeds the owner's split (Push + Arms on Mon and Sat, Pull on Wed, Upper on Fri). Add `"-fixedNow", "2026-09-26T09:00:00Z"` so `env.now()` is Saturday.

```swift
@MainActor
@Suite struct DayPreviewEnvironmentTests {
    private func makeEnv() throws -> AppEnvironment {
        let defaults = try #require(UserDefaults(suiteName: "DayPreviewEnvironmentTests.\(UUID())"))
        return try AppEnvironment(options: LaunchOptions(arguments: ["-uiTesting", "-fixedNow", "2026-09-26T09:00:00Z"]),
                                  defaults: defaults)
    }

    private func day(_ offset: Int, _ env: AppEnvironment) -> Date { TodayDay(offset: offset).date(now: env.now()) }

    @Test func tomorrowIsRestAndMondayIsPush() throws {
        let env = try makeEnv()
        #expect(try env.previewPlan(on: day(1, env)) == nil)
        #expect(try env.previewPlan(on: day(2, env))?.title == "Push + Arms")
    }

    @Test func previewingAnAgentsPlannedDayLeavesItForThatDay() throws {
        let env = try makeEnv()
        let pull = try #require(try env.routines.all().first { $0.name.hasPrefix("Pull") })
        let monday = TodayPlan.dayKey(day(2, env))
        PlannedSwitchStore(defaults: env.defaults).set(pull.id, on: monday)
        #expect(try env.previewPlan(on: day(2, env))?.base?.id == pull.id)
        #expect(try env.previewPlan(on: day(2, env))?.base?.id == pull.id) // still there: preview doesn't take it
        #expect(PlannedSwitchStore(defaults: env.defaults).all()[monday] == pull.id)
        #expect(try env.todaysPlan().plan.base?.title != pull.name) // today's plan is untouched
    }
}
```

`TodayPlan.title` and `env.defaults` may be named differently; check `TodayPlan` and `AppEnvironment`, and adjust. (`defaults` is used by `AppEnvironment+TodayRoutine.swift`, so it is reachable from tests via `@testable`.)

- [ ] **Step 2: Run them to see them fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsTests/TodayDayTests -only-testing:GymRollinsTests/DayPreviewEnvironmentTests`
Expected: build failure, because `TodayDay`, `DayPreview` and `previewPlan` don't exist yet.

- [ ] **Step 3: Implement**

`ios/GymRollins/Features/Today/TodayDay.swift`:

```swift
import Foundation
import GymCore
import GymData

/// The day Today shows (owner, 2026-11-09): today, or a later day previewed read-only. Swiping and the date picker
/// move it; a day before today can't be reached, so past workouts stay in Log.
struct TodayDay: Equatable {
    /// Days after today: 0 is today.
    let offset: Int

    static let today = TodayDay(offset: 0)

    init(offset: Int) { self.offset = max(0, offset) }

    /// The day `date` falls on, counted from `now`'s day; a date before today is today.
    init(date: Date, now: Date, calendar: Calendar = .current) {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        self.init(offset: days)
    }

    var isToday: Bool { offset == 0 }
    var next: TodayDay { TodayDay(offset: offset + 1) }
    var previous: TodayDay { TodayDay(offset: offset - 1) }

    /// Midday of the day, so a clock change can't move it to the day before.
    func date(now: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: offset, to: start) ?? start
        return calendar.date(byAdding: .hour, value: 12, to: day) ?? day
    }

    /// "Today", "Tomorrow", a weekday in the coming week ("Wednesday"), then a date ("3 Oct").
    func title(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return date(now: now, calendar: calendar).formatted(style.weekday(.wide))
        default: return date(now: now, calendar: calendar).formatted(style.day().month(.abbreviated))
        }
    }
}

/// What a later day trains, as Today previews it: an agent's one-day change for that date (`PlannedSwitchStore`) wins
/// over the week schedule, under the rules Today applies on the day (`takePlannedSwitch`). Nil is a rest day.
enum DayPreview {
    static func plan(day: String, scheduled: Routine?, routines: [Routine], planned: UUID?) -> TodayPlan? {
        let base = TodayPlan.make(scheduled: scheduled, routines: [], lastDone: [:], day: day)
        if let planned, let routine = routines.first(where: { $0.id == planned }), !routine.paused,
           routine.id != scheduled?.id {
            return base.switched(to: routine)
        }
        return scheduled == nil ? nil : base
    }

    /// The preview's rows: today's suggestions for that day's exercises; an agent's change is said in the summary.
    static func model(plan: TodayPlan?, profile: Profile, library: ExerciseLibrary,
                      history: (String) -> [SessionResult], gym: TodayGymContext?) -> TodayModel {
        guard let plan else {
            return TodayModel(routineId: nil, title: "Rest day", summary: "Recover and eat well", rows: [])
        }
        let model = TodayModel.make(plan: plan, profile: profile, library: library, history: history, gym: gym,
                                    loads: { gym?.loads(for: $0) })
        guard plan.kind == .switched else { return model }
        return TodayModel(routineId: model.routineId, title: model.title,
                          summary: "\(model.summary) \u{00B7} changed for this day", rows: model.rows,
                          gymNote: model.gymNote)
    }
}
```

Add a test for the "changed for this day" summary if it's cheap; the UI test in Task 4 doesn't cover it.

`ios/GymRollins/App/AppEnvironment+DayPreview.swift`:

```swift
import Foundation
import GymCore
import GymData

extension AppEnvironment {
    /// A later day's plan for Today's preview, at the current gym (like `todaysPlan(at:)`). Read-only: an agent's
    /// planned switch stays in `PlannedSwitchStore` until its day, and today's stored plan is never read or written.
    func previewPlan(on date: Date) throws -> TodayPlan? {
        let all = try routines.all()
        let scheduled = try routines.schedule().routineId(on: date).flatMap { id in all.first { $0.id == id } }
        let day = TodayPlan.dayKey(date)
        return DayPreview.plan(day: day, scheduled: scheduled?.paused == true ? nil : scheduled, routines: all,
                               planned: PlannedSwitchStore(defaults: defaults).all()[day])?
            .adapted(by: gymAdapter())
    }
}
```

- [ ] **Step 4: Run them to see them pass**

Run: the same command as Step 2.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add ios
git commit -m "feat(ios): Today can work out what a later day trains, without taking an agent's planned switch"
```

### Task 4: Today swipes to later days and has a calendar

**Files:**
- Create `ios/GymRollins/Features/Today/TodayDayPreviewView.swift`.
- Create `ios/GymRollins/Features/Today/TodayDatePickerSheet.swift`.
- Modify `ios/GymRollins/Features/Today/TodayExerciseRow.swift` and `ios/GymRollins/Features/Today/TodayView.swift`.
- Create the test `ios/GymRollinsUITests/TodayDaysUITests.swift`.

- [ ] **Step 1: Write the failing UI test**

`ios/GymRollinsUITests/TodayDaysUITests.swift`. The default `-fixedNow` is Saturday 26 Sep 2026, a Push day. Sunday is rest, Monday is Push + Arms, and Wednesday 30 Sep is Pull + Shoulders + Triceps.

```swift
import XCTest

/// Today shows later days read-only: swipe left for the next day, tap the date for a calendar, Back to today returns.
final class TodayDaysUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func title(_ app: XCUIApplication) -> XCUIElement { app.staticTexts["today.title"] }

    private func waitForLabel(_ element: XCUIElement, _ text: String, contains: Bool = false,
                              file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: contains ? "label CONTAINS %@" : "label == %@", text)
        let result = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5)
        XCTAssertEqual(result, .completed, "label was '\(element.label)'", file: file, line: line)
    }

    func testSwipingShowsLaterDaysAndBackToTodayReturns() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        waitForLabel(title(app), "Today")
        app.scrollViews.firstMatch.swipeLeft()
        waitForLabel(title(app), "Tomorrow")
        waitForLabel(app.staticTexts["today.summary"], "Rest day", contains: true)
        XCTAssertFalse(app.buttons["today.start"].exists, "a later day can't be started")
        XCTAssertFalse(app.buttons["today.switch"].exists)

        app.scrollViews.firstMatch.swipeLeft()
        waitForLabel(title(app), "Monday")
        waitForLabel(app.staticTexts["today.summary"], "Push + Arms", contains: true)

        app.scrollViews.firstMatch.swipeRight()
        waitForLabel(title(app), "Tomorrow")
        app.buttons["today.backToToday"].tapCenter()
        waitForLabel(title(app), "Today")
        XCTAssertTrue(app.buttons["today.start"].waitForExistence(timeout: 5))

        app.scrollViews.firstMatch.swipeRight()
        waitForLabel(title(app), "Today") // nothing before today
    }

    func testTheCalendarPicksADayAndTodayComesBack() {
        let app = XCUIApplication.launchReady { $0.buttons["today.start"] }
        app.buttons["today.date"].tap()
        let picker = app.datePickers["today.datePicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        // The graphical picker's day buttons are labelled like "Wednesday 30 September"; match on the day and month.
        let wednesday = picker.buttons.matching(NSPredicate(format: "label CONTAINS '30' AND label CONTAINS 'September'"))
            .firstMatch
        XCTAssertTrue(wednesday.waitForExistence(timeout: 5))
        wednesday.tap()
        waitForLabel(title(app), "Wednesday")
        waitForLabel(app.staticTexts["today.summary"], "Pull", contains: true)

        app.buttons["today.date"].tap()
        app.buttons["today.datePicker.today"].tap()
        waitForLabel(title(app), "Today")
    }
}
```

`tapCenter()` is the helper in `UITestSupport.swift` for bottom-bar glass buttons. If the picker's day-button labels differ on the simulator, print `app.debugDescription` once, match what's there, and record the real format in the comment.

- [ ] **Step 2: Run it to see it fail**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/TodayDaysUITests`
Expected: FAIL, because there is no `today.title` and no `today.date`.

- [ ] **Step 3: Implement**

**`TodayExerciseRow.swift`.** Add `var openHint = "Opens today's sets"` after `onOpen`, and use it in `.accessibilityHint(openHint)`. Because the stored properties are memberwise, `openHint` must come after `onOpen` and before `menu`, with a default value, so that existing call sites still compile. If the trailing-closure `menu` makes the memberwise init awkward, add an explicit `init` with that parameter order.

**`TodayDayPreviewView.swift`:**

```swift
import GymCore
import SwiftUI

/// A later day on Today, read-only (owner, 2026-11-09): its title, what it trains and the sets suggested as of now, at
/// the current gym. Rows open the exercise; nothing here edits a plan or starts a workout.
struct TodayDayPreviewView: View {
    @Environment(AppEnvironment.self) private var env
    let day: TodayDay
    let onDetails: (String) -> Void
    let onHistory: (String) -> Void
    @State private var model: TodayModel?
    @State private var loadError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                DisplayTitle(text: day.title(now: env.now()), size: 48)
                    .lineLimit(1).minimumScaleFactor(0.6)
                    .accessibilityIdentifier("today.title")
                if let model {
                    Text("\(model.title) \u{00B7} \(model.summary)")
                        .foregroundStyle(Theme.textSecondary)
                        .accessibilityIdentifier("today.summary")
                }
            }
            if let loadError { Text(loadError).foregroundStyle(Theme.destructive) }
            if let note = model?.gymNote { TodayGymNote(text: note) }
            ForEach(model?.rows ?? []) { row in
                TodayExerciseRow(row: row, exercise: env.library.exercise(row.exerciseId),
                                 onOpen: { onDetails(row.exerciseId) }, openHint: "Opens the exercise") {
                    menu(row)
                }
            }
        }
        .task(id: ReloadKey(day: day, plan: env.planRevision, data: env.dataRevision)) { load() }
    }

    private struct ReloadKey: Equatable {
        let day: TodayDay
        let plan: Int
        let data: Int
    }

    private func menu(_ row: TodayModel.Row) -> some View {
        Menu {
            Button("Video & Instructions", systemImage: "play.rectangle") { onDetails(row.exerciseId) }
            Button("Exercise History", systemImage: "calendar") { onHistory(row.exerciseId) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.bold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("More for \(row.name)")
        .accessibilityIdentifier("today.row.menu.\(row.exerciseId)")
    }

    private func load() {
        do {
            let plan = try env.previewPlan(on: day.date(now: env.now()))
            let gym = env.todayGymContext()?.preferring(plan?.builtListings ?? [:])
            model = DayPreview.model(plan: plan, profile: env.profile, library: env.library,
                                     history: { (try? env.workouts.history(exerciseId: $0, limit: 5)) ?? [] },
                                     gym: gym)
            loadError = nil
        } catch {
            AppEnvironment.log.error("Day preview failed: \(error.localizedDescription, privacy: .public)")
            loadError = "Couldn't load this day's plan."
        }
    }
}

/// "1 exercise swapped for this gym. Your plan isn't changed.", on Today and on a later day.
struct TodayGymNote: View {
    let text: String

    var body: some View {
        Text(text).font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.record)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glassCapsule(tint: Theme.record.opacity(0.25), interactive: false)
            .accessibilityIdentifier("today.gymNote")
    }
}
```

Use the real types of `env.planRevision` and `env.dataRevision` in `ReloadKey`; they may not be `Int`. Replace TodayView's private `gymNote(_:)` with `TodayGymNote(text:)`.

**`TodayDatePickerSheet.swift`:**

```swift
import SwiftUI

/// Today's calendar: pick today or a later day to see what it trains. Picking a day closes the sheet.
struct TodayDatePickerSheet: View {
    let now: Date
    let onPick: (TodayDay) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var date: Date

    init(selected: TodayDay, now: Date, onPick: @escaping (TodayDay) -> Void) {
        self.now = now
        self.onPick = onPick
        _date = State(initialValue: selected.date(now: now))
    }

    var body: some View {
        NavigationStack {
            DatePicker("Day", selection: $date, in: Calendar.current.startOfDay(for: now)...,
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .tint(Theme.primaryFill)
                .padding(.horizontal, Theme.gutter)
                .accessibilityIdentifier("today.datePicker")
                .frame(maxHeight: .infinity, alignment: .top)
                .navigationTitle("Pick a day")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Today") { pick(.today) }.accessibilityIdentifier("today.datePicker.today")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .onChange(of: date) { _, new in pick(TodayDay(date: new, now: now)) }
    }

    private func pick(_ day: TodayDay) {
        onPick(day)
        dismiss()
    }
}
```

**`TodayView.swift`.** Keep every existing behaviour for today.

1. Add state:

```swift
    /// The day shown: today, or a later day previewed read-only (`TodayDayPreviewView`).
    @State private var day = TodayDay.today
    /// Whether the last move went to a later day, for the slide's direction.
    @State private var forward = true
    @State private var showDatePicker = false
```

2. Move the content now inside the `VStack` after `header` (from the title `HStack` down to the Share button) into `@ViewBuilder private var todayContent: some View`. Give the "Today" `DisplayTitle` `.accessibilityIdentifier("today.title")`. In the `VStack`, show:

```swift
                    header
                    Group {
                        if day.isToday {
                            todayContent
                        } else {
                            TodayDayPreviewView(day: day, onDetails: { detailExercise = $0 },
                                                onHistory: { historyExercise = $0 })
                        }
                    }
                    .id(day.offset)
                    .transition(.push(from: forward ? .trailing : .leading))
```

3. In `header`, replace the date `Text` with a button for the shown day:

```swift
            Button { showDatePicker = true } label: {
                Label(day.date(now: env.now()).formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)),
                      systemImage: "calendar")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.glass)
            .disabled(env.session != nil)
            .accessibilityHint("Pick a day to see its workout")
            .accessibilityIdentifier("today.date")
            .accessibilityAction(named: "Next day") { show(day.next) }
            .accessibilityAction(named: "Previous day") { show(day.previous) }
```

4. Add the swipe and the move:

```swift
    /// Swipe left for the next day, right for the one before (never before today). A mostly-vertical drag scrolls.
    private var daySwipe: some Gesture {
        DragGesture(minimumDistance: 30).onEnded { value in
            let dx = value.translation.width, dy = value.translation.height
            guard abs(dx) > 80, abs(dx) > abs(dy) * 2 else { return }
            show(dx < 0 ? day.next : day.previous)
        }
    }

    /// Shows `new` with a slide; a running workout keeps Today on today.
    private func show(_ new: TodayDay) {
        guard env.session == nil, new != day else { return }
        forward = new.offset > day.offset
        withAnimation(.snappy) { day = new }
    }
```

   Attach `.simultaneousGesture(daySwipe)` to the `ScrollView`, before `.background`.

5. In `bottomBar`, inside the `else` branch where there's no session, show `startAndBuild` only for today:

```swift
            } else if day.isToday {
                startAndBuild
            } else {
                SecondaryGlassButton(title: "Back to today", identifier: "today.backToToday", minHeight: 56) {
                    show(.today)
                }
            }
```

6. Add the sheet: `.sheet(isPresented: $showDatePicker) { TodayDatePickerSheet(selected: day, now: env.now()) { show($0) } }`.

7. Return to today:
   - In the existing `.onChange(of: env.session != nil)`, add `if running { day = .today }`.
   - In `.onReceive(.NSCalendarDayChanged)`, set `day = .today` before `reload()`. Do the same in `.todayPlanReplaced`: a workout link replaced today's plan, so show it.
   - In `.onChange(of: scenePhase)`, add `if newPhase == .background { day = .today }`, so reopening the app later shows today, while Control Center or a sheet doesn't reset it.

8. `.refreshable` still syncs, and the preview reloads through `env.planRevision`.

Check the file stays under 600 lines (it was 519).

- [ ] **Step 4: Run the tests to see them pass**

Run: `scripts/ios-test.sh -only-testing:GymRollinsUITests/TodayDaysUITests -only-testing:GymRollinsUITests/TodayFlexUITests -only-testing:GymRollinsUITests/TodayPlanScreenUITests -only-testing:GymRollinsUITests/AccessibilityAuditUITests -only-testing:GymRollinsUITests/DynamicTypeUITests`
Expected: PASS. The Today tests already in the suite must not change behaviour.

- [ ] **Step 5: Commit**

```bash
git add ios
git commit -m "feat(ios): Today swipes to later days and has a calendar, read-only with Back to today"
```

### Task 5: Whole-suite check, screenshots, outcome

- [ ] **Step 1:** Run `cd server && npx vitest run && npx tsc --noEmit`. Expected: all pass.
- [ ] **Step 2:** Run `scripts/ios-test.sh`, the full suite. Expected: 0 failures, compared with 1180 passed / 0 failed / 19 skipped at 4a29495, plus the new tests. If anything fails, check whether it also fails at `4a29495` before calling it pre-existing.
- [ ] **Step 3:** On the simulator with `-uiTesting -fixedNow 2026-09-26T09:00:00Z`, take screenshots of:
  - Today;
  - tomorrow (rest);
  - Monday (Push + Arms);
  - the date sheet;
  - Settings › AI agents' footer.

  Check light and dark mode at the default text size, and the title at the largest Dynamic Type size.
- [ ] **Step 4:** Append an "Outcome" section to this plan with:
  - commits;
  - test counts;
  - what wasn't verified;
  - that the server change needs a deploy (owner approval) and the app needs a phone install (owner approval, back up Library + Documents first).

  Commit with `docs: plan 33 outcome`.

## Self-review

- **Decision coverage:**
  - Decision 1 is covered by Tasks 1 and 2: server wording, results and prompt.
  - Decision 2 is covered by Task 4: the preview is read-only, Back to today, rows open the exercise.
  - Decision 3 is covered by Task 3's clamp, Task 4's swipe right on today, and the picker range starting today.
- **Types:**
  - `TodayDay` has `offset`, `next`, `previous`, `date(now:)` and `title(now:)`.
  - `DayPreview.plan` and `DayPreview.model` are used with the same signatures in Tasks 3 and 4.
  - `previewPlan(on:)` returns `TodayPlan?`.
  - `appliesNote` is used by both `proposePlanChanges` and `getProposal`.
- **Risks:**
  - The horizontal drag on a vertical `ScrollView`. It's simultaneous and needs a 2:1 horizontal drag of 80 pt, so vertical scrolling and row taps are unaffected; Task 4's existing Today UI tests check this.
  - Graphical `DatePicker` labels in XCUITest. Step 1 says to match what the simulator shows.
- **Not covered:**
  - A planned agent day in a UI test. It's covered by unit tests, since there is no launch seed for a future `today` change.
