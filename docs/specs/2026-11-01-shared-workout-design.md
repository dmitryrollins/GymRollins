# Shared workouts: design spec

Date: 2026-11-01 · Status: approved in brainstorming, waiting for the owner's review of this file.
Builds on: `docs/specs/2026-10-30-gym-equipment-design.md` and the unmerged branch `feat-gym-moderation`, because it
reuses Build workout and today's plan from those plans. Where they disagree, this file wins for shared workouts only.

## 1. Goal

Two people do the same workout on one day, each on their own phone, and each keeps their own weights. One person sends
the workout by QR code or link. The other opens it, sees it with their own weights, and uses it as today's plan.

This is the first version: same workout, separate phones, no live connection. Live progress may be added on top later.

### Acceptance criteria

1. **Own weights.** A has benched 140 lb and B has benched 95 lb. A shares a workout with bench press. B's sheet and Today
   show B's suggested weight, worked out from B's history. Nothing in the link or on B's phone says 140.
2. **New exercise.** B has never done an exercise in the link. B's sheet says "Set on first set", and the first set starts
   with no weight.
3. **No account, no signal.** Both phones are signed out and in airplane mode. A shows a QR code. B opens the link, taps
   Use for today and logs the workout. Nothing is sent over the network.
4. **Today only.** B's normal plan is back the next day, and B's routines are unchanged.
5. **Own history.** B's finished workout is in B's history only. A's phone doesn't change.
6. **Bad links.** A damaged link changes nothing and shows "This link doesn't work. Ask for a new one."
7. **Never loses a workout.** With a workout running on B's phone, opening a link changes nothing and asks B to finish first.

### Out of scope

Live progress, shared rest timers, turn-taking, one phone logging for two people, saving a shared workout as a routine,
sharing custom exercises, accounts, a scanner inside the app, and anything stored on a server.

## 2. Decisions (settled in brainstorming, 2026-11-01)

| Question | Decision |
|---|---|
| What "together" means | Same workout, separate phones, no live connection. The owner weighed live progress and chose to start without it. |
| Kind of link | A real web link, plus a QR code. The owner will buy a domain soon. Until then the app uses a temporary `gymrollins://` link. |
| What the partner taps | **Use for today** or **Not now**. It doesn't start straight away, so the partner can edit it first. |
| Custom exercises | Left out, and the sender is told. |
| Text in the link | None. See section 8. |
| A different gym | The partner's weights fit their gym's equipment, and the exercises stay as sent. The partner can swap one by hand. |

## 3. Architecture

```
GymCore
  SharedWorkout            contents, link text in and out, limits (pure Swift)
App
  Features/SharedWorkout/
    ShareWorkoutSheet      QR code, Send link, what was left out
    ShareWorkoutModel      makes the SharedWorkout from Today, Build or the running workout
    IncomingWorkoutSheet   the partner's view: exercises, own weights, Use for today / Not now
    IncomingWorkoutScreen  what the sheet shows, for each outcome in section 7
    IncomingWorkoutCoordinator  holds a link until onboarding ends, opens the sheet over whatever is on screen
    WorkoutLink            builds the URL from SHARE_LINK_HOST, reads an incoming URL
  Features/Today/TodayPlan TodayPlan.shared(items:day:)
web/share/                 landing page and Apple's domain file, published once the domain exists
```

`SharedWorkout` is the only code that knows how the link is written, and it depends only on the exercise library. Nothing in this feature talks to the network, the database or `GymSync`.

## 4. The link

```
https://<SHARE_LINK_HOST>/w#1.0001_3_8-10.1512_3_10_g1.0201_3_12_g1.0300_1_s600
gymrollins://w#1.0001_3_8-10.1512_3_10_g1.0201_3_12_g1.0300_1_s600
```

**Which one the app makes.** `SHARE_LINK_HOST` in `ios/Config/Base.xcconfig` is empty until the domain exists, so the app
makes `gymrollins://` links. Once it's set, the app makes `https://` links. The app keeps reading both, so links sent
before the change still work.

**What it accepts.** `gymrollins` with host `w`, and `https` with host equal to `SHARE_LINK_HOST` and path `/w` or `/w/`.

**The payload** is everything after the `#`. It uses only letters, digits and `_ - .`, so chat apps keep it in the link.

| Part | Format | Meaning |
|---|---|---|
| Version | `1` | The first field. A higher number means the link is from a newer app. |
| Exercise | `<id>_<sets>_<target>[_g<n>]` | Exercises are joined by `.`, in order. |
| `<id>` | 1 to 8 letters or digits | A library exercise id. |
| `<sets>` | number | Working sets. |
| `<target>` | `10`, `8-10` or `s600` | Reps, a rep range (`repsMin-reps`), or seconds. |
| `g<n>` | `g1` | A superset number, renumbered from 1 in order of appearance. Never the sender's own label. |

Seconds mean a timed exercise, or a cardio one if the library says that exercise is cardio. Reps mean a rep exercise.

**Limits.** At most 1024 characters, read before anything else is parsed. At most `DomainLimits.routineExercisesMax` (20)
exercises. Values use `PlanChangeLimits`: sets 1...10, reps 1...100, seconds 5...3600. `repsMin` is at most `reps`.

**Sending.** Values outside those limits are clamped when the link is made, so a sender can always share. With more than
20 exercises, the first 20 go.

**Reading.** Any broken syntax or value outside the limits makes the whole link damaged. An exercise id that isn't in this
phone's library is only dropped and counted, because a newer app can have exercises an older one lacks. If no exercise is
left, the link is damaged.

## 5. Key behaviours

### Sharing
The Share button is on Today, on the Build result and in the running workout, so a partner can join after the start. All
three make the same thing:
- **Today:** `plan.exercises` as shown. An exercise with edited sets uses the number of working sets and the first working
  set's reps or seconds.
- **Build result:** `built.items`.
- **Running workout:** the entries, with the same rule as edited sets. Warm-ups don't count.

The sender's custom exercises (`custom-*`) are left out and named on the share screen. If nothing is left, the screen
explains why instead of showing a code. The button is hidden when there are no exercises.

Sharing changes nothing on the sender's phone. The sender starts their own workout as usual.

### Opening
1. The app receives the URL through `onOpenURL` (`gymrollins://`) or `onContinueUserActivity` (`https://`). No URL is opened
   without the person tapping or scanning it.
2. If onboarding isn't finished, the link waits in memory and the sheet opens when onboarding ends. If the app is quit in
   between, the link is gone and the person taps it again.
3. The sheet opens over whatever is on screen. If that isn't possible because a system sheet is open, it opens as soon as
   that closes. A second link replaces the first.

### The partner's sheet
- Title "Shared workout", the number of exercises, then one row per exercise.
- The rows are `TodayModel` rows, built by `TodayModel.make` from the plan the button would apply, so they always match what
  Today then shows, in the partner's language and units.
- A row whose exercise takes weight and has no suggestion also says "Set on first set". A bodyweight exercise shows only its
  sets and reps.
- If today's plan has edits, or isn't the normal scheduled plan, the sheet says "This replaces today's plan."
- **Use for today** applies the plan and closes the sheet on Today. **Not now** closes it and stores nothing.

### Today's plan
`TodayPlan.shared(items:day:)` is a `.built` plan named "Shared workout", with every item in `gymPinned`:
- `GymAdapter` can't swap a pinned item, so the exercises stay as sent.
- Editing, Start Workout, Resume and the Watch's "Start today's workout" work as they do for a Build workout.
- Items carry no `weightKg` and no `weightSetAt`, so `SessionPlanner` takes weights from the partner's history and fits them
  to the current gym. Warm-ups and rest follow the partner's own settings.
- It lasts until Start is tapped or the day ends, as a Build workout does. After Start, Today goes back to the normal plan.
- The workout has no `routineId`, so it doesn't count as a routine done. Its sets count towards progression by exercise, in
  that person's history only.

## 6. UI

**Share screen.** A sheet with the QR code, "Send link" (system share sheet) and one line: "Your partner sees this workout
with their own weights." Left-out exercises are listed under it, and a line appears if only the first 20 went.

**QR code.** Generated with Core Image's built-in `CIQRCodeGenerator`, correction level M, dark on white with its quiet zone,
even in dark mode. Its VoiceOver label is "QR code for this workout", and "Send link" is the alternative to it.

**The app has no scanner.** The iPhone camera opens the link. Control Center's code scanner does too.

**Style.** The sheets follow the existing style: `.glass` buttons, a prominent button for Use for today, and accessibility
identifiers starting `share.` and `incoming.`.

**Privacy screen.** One added sentence: "Sharing a workout link sends only its exercises, sets and reps: no weights, name
or history."

**Web page (`web/share/`).** Static: the app's name, "Open in GymRollins" and "Get the app". The App Store button stays hidden
until `APP_STORE_URL` is set in the page. "Open in GymRollins" is for browsers inside other apps, which don't always hand a
link to the app. A few lines of script add the address's `#` part to a `gymrollins://w` link and nothing else. The page has no
analytics, and its content security policy has `connect-src 'none'`, so it can't send anything.

## 7. Error handling

| Situation | What the person sees | What changes |
|---|---|---|
| Damaged, too long or fake link | "This link doesn't work. Ask for a new one." | Nothing |
| Version higher than this app reads | "Update GymRollins to open this workout." | Nothing |
| Some exercises not in this phone's library | The rest, and "2 exercises aren't in your version of the app." | Nothing until Use for today |
| A workout is running | "Finish your current workout first." and a Resume button | Nothing |
| A workout starts while the sheet is open (the Watch) | The same message when Use for today is tapped | Nothing |
| A link from another `https` host | iOS doesn't send it to the app. If one arrives anyway, the damaged-link message | Nothing |
| The workout has only custom exercises (sender) | "These are your own exercises, so they can't go in a link." and no code | Nothing |

Decoding never throws to the UI as raw text: it returns one of `valid`, `damaged` or `tooNew`.

## 8. Security and privacy

- **The link is untrusted input,** so it's checked in `SharedWorkout` before anything else sees it. It can't change anything
  until the person taps Use for today, and it can't touch a running workout, routines or history.
- **No free text.** The link holds ids and numbers only, and everything on screen comes from the partner's own library. A link
  can't put a stranger's words in the app, in the workout's name or in front of Claude. Workouts and their names reach Claude
  through MCP once synced, so this matters. It's also why custom exercises are left out.
- **Nothing personal.** No weights, name, history, gym or account. What a link reveals is a list of exercises.
- **No server.** The app makes no request for this feature. The part after the `#` isn't sent to the web host, and the page
  only passes it to the app.
- **Temporary scheme.** Another app could register `gymrollins://` and receive such a link. That's accepted, because a link
  holds nothing private.
- **Moderation.** None is needed: nothing is published, and a link only reaches people it's sent to.

## 9. Testing

**GymCore (pure, part of the coverage gate):**
- Round trips for reps, rep ranges, seconds, cardio and supersets, keeping the order.
- Every limit, on and just past it, both when sending (clamped) and reading (damaged).
- Unknown ids dropped and counted; all ids unknown is damaged; a higher version is `tooNew`.
- Superset labels renumbered, with the sender's own label never in the text.
- Custom exercises and warm-ups never in the text, and no weight anywhere in it, checked on a workout that has them.
- Random and malformed strings never crash, including very long ones, non-ASCII and empty fields.

**App unit tests:**
- `WorkoutLink` builds `gymrollins://` with an empty host and `https://` with one set, and reads both. It refuses another host,
  another path and another scheme.
- `TodayPlan.shared` pins every item, and `adapted(by:)` leaves them alone at a gym that doesn't list them.
- Two different histories give each person their own weight from the same link (criterion 1).
- A generated QR code at the maximum link length reads back with Vision's barcode detector, to the same text.

**UI tests** (`XCUIApplication.open(_:)` with a real `gymrollins://` URL):
- Share from Today, the Build result and the running workout shows the code and Send link.
- A link opens the sheet; Use for today makes it Today's plan, and Start Workout logs it.
- Not now leaves Today unchanged. Each row of section 7 shows its message.
- A link during onboarding opens after it, and a link during a workout changes nothing.
- Accessibility audits and Dynamic Type on both sheets, with the app's existing suites.

**A walk on the simulator:** two signed-out simulators with different histories, a link from one opened on the other through
`simctl openurl`, and the workout logged on both. Screenshots of each step.

**Can't be tested until later:** the `https://` link opening the app needs the domain, the signed entitlement and a real
device. A camera scan needs a real iPhone.

## 10. Milestones

One implementation plan, plan 23, on branch `feat-shared-workout`:

1. `SharedWorkout` in GymCore.
2. `WorkoutLink` and `SHARE_LINK_HOST`, with the `gymrollins` URL scheme in `project.yml`.
3. Share screen, on Today, the Build result and the running workout.
4. `TodayPlan.shared`, the incoming sheet and link handling.
5. Web page and privacy sentence, walk and final run.

### When the domain is bought
1. Set `SHARE_LINK_HOST` in `ios/Config/Base.xcconfig`.
2. Add `com.apple.developer.associated-domains: [applinks:<domain>]` to `project.yml`. It needs a paid Apple Developer team
   in `ios/Config/Local.xcconfig`, and can't go in earlier because it names the domain.
3. Publish `web/share/` on any static host, with `/.well-known/apple-app-site-association` served as `application/json`, with
   no redirect, naming the team id, bundle id `com.rollins.gymrollins` and the path `/w`.
4. On a real iPhone, scan a QR code and tap a link from a chat app, with the app installed and without it.

The same host can serve the OAuth consent page, the hosted privacy policy and the contact address the launch list needs.

## 11. Risks

| Risk | Mitigation |
|---|---|
| Some chat apps won't make `gymrollins://` tappable, until the domain exists | The QR code works, and the main case is two people together. This goes away with the `https://` link. |
| A partner without the app gets nothing from a `gymrollins://` link | The same. The web page solves it, and the App Store button appears at release. |
| Sets with different reps are flattened | Accepted for this version: the link keeps one target per exercise, and the partner can edit it on Today. |
| The partner's gym doesn't have an exercise | They can swap it by hand. Weights still fit what the gym lists. |
| A first-time exercise has no suggested weight | "Set on first set", and the partner's history takes over next time. |
| Depends on four unmerged plans (19 to 22) | Plan 23 stacks on `feat-gym-moderation`. It can't be merged before them. |
