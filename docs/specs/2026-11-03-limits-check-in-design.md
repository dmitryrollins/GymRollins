# Injury note check-in: design spec

Date: 2026-11-03 · Status: approved in brainstorming, waiting for the owner's review of this file.
Builds on: the unmerged branch `feat-shared-workout` (plan 23), which sits on plans 19 to 22.

## 1. Goal

An injury note can have an end date. When that date comes, Today asks whether it's the right time to continue. If it is,
the note goes and any paused routine can come back at lighter weights, so training restarts light.

It came from the owner's knee note, "Knee: no leg loading until ~26 Oct 2026", still showing on 1 November. The app never
reads a date in the note, and the note can only be set in first-time setup, so it can't be removed either.

### Acceptance criteria

1. **Edit and clear.** In Settings, Injuries / limits, the owner can change the note, set or clear an Until date, and clear
   the note. Clearing the note clears its date. Today's reminder follows at once.
2. **Before the date.** With "Knee: no leg loading" until 26 Oct, Today's reminder reads "Knee: no leg loading · until 26 Oct", in
   the same place as now.
3. **On the date.** On 26 Oct or later, Today shows the check-in card in place of the reminder, every time Today is open,
   until it's answered. It never shows while a workout is running.
4. **Not yet.** The card offers a new date, two weeks from today, which can be changed. Save puts the reminder back with the
   new date, and the card comes back on that date.
5. **Yes.** The note and its date are cleared. The reminder goes, the muscle map stops dimming legs, and Strength stops
   showing squat and deadlift as paused.
6. **Resume at 60%.** Legs is paused, and the app would suggest squat 135 lb and leg press 170 lb. After Yes, Resume at 60%
   unpauses Legs, and its plan reads squat 80 lb and leg press 100 lb (60%, rounded down to the plates). After a session
   at those weights, normal progression carries on from what was logged.
7. **Another phone.** Answering on one signed-in phone removes the card on another after it syncs.

### Out of scope

Notifications, injuries as body parts, choosing a percentage, putting the resumed routine on a weekday, Claude setting the
note or date, and reading a date out of the note's text.

## 2. Decisions (settled in brainstorming, 2026-11-02 and 2026-11-03)

| Question | Decision |
|---|---|
| What Yes does to a paused routine | Offers **Resume at 60%**. The owner chose this over resuming at the saved weights, or only clearing the note. |
| Notification on the date | None. The card on Today only, because the owner opens Today to train. Nothing to schedule or cancel. |
| Where the date lives | On the profile next to the note, synced with the account, and readable by Claude. |
| Which paused routines are offered | Every paused routine, each with its own button. The owner may have paused one for another reason, so it's an offer. |
| The sample data | `-seedOwner` keeps its note with no date, so existing tests see no card. A separate launch flag sets a past date. |

## 3. Architecture

```
GymCore
  LimitsCheckIn          isDue(note:until:now:calendar:), the Not yet date and the allowed range (pure Swift)
  ReturnWeights          60% of a suggested weight, rounded down on a LoadRounder, never below its smallest load
GymData
  Profile.limitsUntil    Date?, a calendar day like goalDate; ProfileRecord, ProfileRepository, SyncStore+Profile
GymSync
  ProfileDTO             limits_until, read with decodeIfPresent
supabase/
  migrations/            profiles.limits_until date, null by default
  functions/mcp          get_profile returns limits_until
App
  Features/Limits/
    LimitsEditor         note and optional Until date, used by Settings and first-time setup
    LimitsSettingsView   the Settings screen, opened from LimitsSettingsRow ("Injuries / limits" in Training)
    LimitsReminder       on Today: the reminder before the date, the card on or after it
    LimitsCheckInCard    the card: question, Not yet, Yes, then the paused routines
    LimitsCheckInModel   which step the card is on, and the text it shows
  App/AppEnvironment+Limits.swift  postpone, clear, resume a routine at 60%
```

`LimitsCheckIn` and `ReturnWeights` don't know about screens or storage. The card asks `AppEnvironment` for the three
actions, so its steps can be tested without a database.

## 4. Key behaviours

### The date
- `limitsUntil` is a calendar day, stored and synced the way `goalDate` is (`SyncDay`).
- A date only counts with a note. The editor turns the date off while the note is empty, and clearing the note clears it.
  A date that reaches the phone with an empty note is ignored.
- It's due when today's local day is on or after it.

### Not yet
- The date picker starts two weeks from today and allows tomorrow to one year ahead. Save writes the new date. Cancel closes
  the picker and leaves the card.

### Yes
- One profile save clears the note and the date. If it fails, the card stays and says so, and nothing else changes.
- Then the card lists each paused routine with its own button, **Resume Legs at 60%**, and **Not now**. With no paused routine the card closes.
- Not now closes the card and leaves the routines paused. They can still be resumed by hand in My Plan.

### Resume at 60%
- For each exercise in the routine, the base is what the app would suggest now: `SessionPlanner.suggestion` from the
  person's history, with no gym fitting. The new planned weight is 60% of that, rounded down on that exercise's rounder,
  and never below the empty bar or the smallest step.
- The new weight is saved with `weightSetAt` set to now. The engine already prefers a weight planned after the last session,
  in either direction, so the first session comes in light and later ones progress from what's logged.
- Left alone: exercises with no weight (body weight), timed and cardio exercises, and exercises whose progression is Off,
  because Off means the person sets the weight and the engine ignores a planned one.
- Also left alone (added after review): an exercise with a fixed weight, and one where the light weight isn't below the
  suggestion, or lands on the last logged weight after the floor. The engine ignores a planned weight equal to the last
  one, so the card would claim a change that never happens.
- The routine is saved once, with `paused` false and the new weights together, so a failure leaves it as it was.
- The card then says "Legs is back, with 6 exercises at 60%. Pick its day in My Plan." and offers **Open My Plan**. When
  nothing was lowered it says "Legs is back. Pick its day in My Plan."

## 5. UI

- **Settings, Training:** a row "Injuries / limits" showing the note, or "None". Its screen has the note field, an
  "Until" toggle with a date picker, and **Clear note**. The note keeps its 500-character limit.
- **First-time setup:** the same editor in place of the single field. The placeholder becomes "e.g. knee — no leg loading",
  because the date has its own field now.
- **Today, before the date:** the reminder reads "<note> · until 26 Oct". With no date it reads as it does now.
- **Today, on the date:** the card, in the app's card style, where the reminder was:
  - "<note>"
  - "You planned this until 26 Oct. Is it the right time to continue?"
  - **Yes, continue** and **Not yet**.
- Every control has an accessibility identifier under `limits.` and works with VoiceOver and the largest text sizes.

## 6. Error handling

| Case | What happens |
|---|---|
| The profile save fails | The card or the Settings screen shows "Couldn't save. Try again." and keeps what was typed. |
| The routine save fails | The card says "Couldn't bring Legs back. Try again." The note stays cleared, and the routine is unchanged. |
| The routine was deleted or unpaused elsewhere | It isn't listed. A button for one that's gone does nothing and removes its row. |
| A sync brings an older profile | Sync already takes the newer profile. The date follows the note, so they can't disagree. |

## 7. Security and privacy

The date goes where the note already goes: the phone, the account, the JSON export, and Claude's `get_profile` when the
plan permission is on. The privacy text needs no change, because it already covers the note. Nothing new is sent anywhere.

## 8. Testing

**GymCore (pure, part of the coverage gate):**
- `isDue` before, on and after the date, at midnight, and in another time zone.
- The default next date, and its range.
- `ReturnWeights` on barbell, dumbbell and machine rounders, at the empty bar, at 0 and on a grid with an offset.

**Data and server:**
- `ProfileRecord` and `ProfileRepository` round-trip the date. An old store opens with it empty.
- `ProfileDTO` round-trips `limits_until`, and a row without it reads as no date.
- A pgTAP test for the column, and the sync integration suite writing and reading it.
- `get_profile` returns it.

**App:**
- `LimitsCheckInModel`: each step and each message, Not yet's dates, Yes with zero, one and two paused routines.
- Resume at 60% on the seeded Legs routine gives squat 80 lb and leg press 100 lb, leaves body weight, timed and Off alone,
  and the next suggestion after a logged session progresses from 80 lb (criterion 6).
- UI tests: edit and clear in Settings, Not yet, Yes then Resume then Open My Plan, and no card during a workout.
- Accessibility audits and Dynamic Type on the card and the Settings screen.

## 9. Milestones

One implementation plan, plan 24, on branch `feat-limits-checkin`, stacked on `feat-shared-workout`. Supabase stays local.

1. `LimitsCheckIn` and `ReturnWeights` in GymCore.
2. `limitsUntil` in GymData, GymSync, the migration and `get_profile`.
3. The editor in Settings and first-time setup.
4. The card on Today, Not yet and Yes.
5. Resume at 60%, then accessibility, a walk on the simulator and the final run.

## 10. Risks

| Risk | Mitigation |
|---|---|
| 60% is too light or too heavy for someone | It's one session: progression takes over from what's logged, and the plan can be edited. |
| An exercise with progression Off keeps its old weight | The card counts only the exercises it lowered, so it never claims more. |
| The resumed routine has no weekday | The card says to pick its day and opens My Plan. Switch on Today can also start it. |
| A schema change on a branch that isn't merged | The column is nullable and new, so plans 19 to 23 can merge first without it. |
| Depends on five unmerged plans (19 to 23) | Plan 24 stacks on `feat-shared-workout` and can't be merged before them. |
| The app or Claude's server goes out before the migration | The new column must exist first: a profile push or `get_profile` naming `limits_until` fails without it. Ship the migration first. |
| Today fits a weight to the gym's equipment | At a gym with coarse steps, Today may round the 60% weight up to the nearest load it has. |
