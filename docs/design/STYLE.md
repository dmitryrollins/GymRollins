# GymRollins iOS mockups: artboard spec (read fully before writing)

You write iPhone mockup artboards (`.dc.html` files) for a design canvas. The REFERENCE artboard is
`<root>/project/Main.dc.html`. Read it first and copy its structure, head, helmet and patterns EXACTLY. Its colours and
fonts predate native design stage 1 (plan 40): take those from "Visual language" below, which follows the app's `Theme`.
`<root>` = <scratchpad>/design (a local working folder, not in the repo)

## File format rules (each violation fails silently)
- Whole file shape as Main.dc.html: `<!doctype html>`, `<head>` with `<meta charset>`, a unique `<title>`, and EXACTLY `<script src="./support.js"></script>`; body holds `<x-dc>` with a `<helmet>` (same style block as Main, without its Google Fonts link: the type is the system's SF Pro), then ONE root `<div>` of fixed `width: 390px; height: 844px; box-sizing: border-box; position: relative; overflow: hidden`, then after `</x-dc>` the same `<script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":390,"height":844}}'>` block with `class Component extends DCLogic { renderVals() { return {}; } }`.
- Close every non-void element; quote every attribute; ALL styling is inline `style="…"` (only the helmet's body/a rules are allowed in `<style>`).
- Static mockups: no JS logic, no `{{holes}}`, no innerHTML. Links between screens: `<a href="Other.dc.html">` styled as the button itself (never a button inside an a).
- Real `<button type="button">`, `<a href>`, `<input>` with a `<label>` (visually hidden label span via `position: absolute; left: -9999px` is fine). `aria-label` on icon-only buttons.
- Icons: inline stroke SVG (`fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"`), never emoji.
- No fake status bar: leave the top 54px empty (content starts at `padding-top: 58px`).
- No lorem ipsum. Use the real data below; anything unknown is a bracketed placeholder like `[exercise GIF]`.

## Visual language: Apple Fitness dark + iOS 26 Liquid Glass
Native design stage 1 (plan 40). The source of truth is `ios/GymRollins/DesignSystem/` (`Theme.swift`, `Glass.swift`,
`MetricStyle.swift`, `DetailSection.swift`, `DetailTopBar.swift`); the app is dark only.

Tokens:
- Page background `#000000` (Fitness' page). Text white `#FFFFFF`; secondary `rgba(235,235,245,0.6)` (Apple's
  `secondaryLabel`, 5.9:1 on the card); tertiary/captions `#8E8E93` (system gray: `tertiaryLabel`'s 30 % is under 4.5:1).
- CONTENT layer (lists, cards, charts, tables) stays SOLID for legibility, on Apple's dark greys: card `#1C1C1E`, radius
  24px, padding 16px; inner thumbnail/placeholder `#2C2C2E`; dividers `#38383A`.
- CONTROL/NAVIGATION layer is LIQUID GLASS (every button, chip, segmented control, toolbar, nav button, tab bar, floating CTA, sheet, timer bar, overlay). The glass itself is unchanged by stage 1: only its tint changes.
  - Glass: `background: rgba(40,40,52,0.55); backdrop-filter: blur(20px) saturate(170%); -webkit-backdrop-filter: blur(20px) saturate(170%); border: 1px solid rgba(255,255,255,0.12); box-shadow: inset 0 1px 0 rgba(255,255,255,0.22), 0 8px 24px rgba(0,0,0,0.45)`.
  - Prominent glass (primary action, ONE per screen; `prominentGlass()`, `PrimaryGlassButton`): the same glass tinted the red action colour the app had before stage 1 (`primaryButtonFill` `#A82431` in the app), `background: rgba(214,58,70,0.78)` + same blur + `border: 1px solid rgba(255,170,175,0.35); box-shadow: inset 0 1px 0 rgba(255,255,255,0.35), 0 10px 26px rgba(200,50,62,0.35)`; WHITE bold text (`onAccent`: white is 7.1:1 on `#A82431`, still above 5:1 with the glass' lightening).
  - Selected state inside a glass group (tab pill, segmented selection): `background: rgba(255,255,255,0.12); box-shadow: inset 0 1px 0 rgba(255,255,255,0.18)`.
  - Sheets / modals: glass panel `background: rgba(30,30,40,0.72); backdrop-filter: blur(30px) saturate(170%)`, top radius 34px, the same inset highlight, a 40×5 grabber `rgba(255,255,255,0.3)`. Behind a sheet, show the underlying screen content dimmed (a few solid cards under `rgba(0,0,0,0.45)` overlay) so the glass has something to blur.
  - Shapes: capsules (radius = height/2) for buttons and chips; circles 44×44 for icon buttons. Touch targets ≥ 44px.
  - Float controls OVER content where it makes sense (content continues underneath) so the glass reads.
- Action colour: red, as the app had before stage 1 (the owner's amendment of 17 Nov 2026).
  - Accent coral `#FF6B72` (`Theme.accent`): links, toggles, the selected tab, accent text and icons on the page, cards
    and glass (7.6:1 on the page, 6.2:1 on the card, 5.0:1 on `#2C2C2E`). Never a fill behind text: white on it is only
    2.8:1.
  - A solid fill behind a label (a chosen chip or weight) is `#C22F3B` (`primaryFill`); the prominent glass tint is
    `#A82431` (`primaryButtonFill`). Anything drawn ON them (a prominent button's label, a chosen chip's text) is WHITE
    (`onAccent`): 5.6:1 and 7.1:1.
  - Fitness' green-yellow `#B6F23A` is a data colour only (`Theme.Metric.workout`), never an action.
- Success `#4FD1A5` (done sets, increases; badge bg `#14342A`). Records/warm-up/warnings amber `#F5B75A` (badge bg
  `rgba(245,183,90,0.14)`). Destructive text and symbols: the system red, `#FF4245` in dark on iOS 26 (5.0:1 on the
  card). A solid destructive fill behind a WHITE label (a set's swipe Delete) is `#C22F3B` (`destructiveFill`, 5.6:1).
- Measured values keep Fitness' metric colours (`Theme.Metric`, each 4.5:1 or more on the card): workout `#B6F23A`, time
  `#F6E23B`, calories `#FF4F6D`, heart rate `#FF6961`, distance `#40A8F5`, cadence `#5EE0E6`, steps `#A98BFF`, exercise
  `#A6F23A`, stand `#3FE6EF`. Data colours keep their meaning whatever the action colour: the recovery map's fatigue is
  coral `#FF6B72` (`RecoveryPalette.fatigued`, its own token though it matches the accent).
- Type: SF Pro and SF Rounded (CSS `font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif`;
  numbers `ui-rounded, 'SF Pro Rounded', -apple-system, sans-serif`). No Barlow and no italics.
  - Titles (`Theme.display(_:)`, `DisplayTitle`): SF Pro bold at a Dynamic Type style: screen titles 34px (large title),
    sheet titles 28px (title), smaller titles 22px (title2).
  - Big numbers (stat tiles, weights, clocks; `Theme.number(_:heavy:)`): SF Rounded semibold at the same sizes, bold for
    the active set or a chosen chip. A measured value is its metric colour with its unit uppercase and smaller right
    after it (`412` + `KCAL`), a plain label above.
  - Body SF Pro 17px regular. Section labels (`SectionLabel`): sentence case as written, 15px semibold (subheadline),
    secondary text colour, no letter-spacing.
- Screens in Fitness' layout (stage 1: the workout detail; the outside-workout detail shares the bar):
  - `DetailTopBar`: a glass Back circle on the left and the screen's own glass circles on the right (Share, "•••"),
    pinned at the top; content that scrolls under it and the status bar is hidden (a hard scroll edge), not faded.
  - `DetailSection`: the section's title in bold 20px (title3) white ABOVE a solid card, not inside it, with an optional
    glass circle at the header's end (the estimate's ⓘ). In the card, metrics sit two to a row (one to a row at
    accessibility text sizes).
- Tab screens (Today, Body, Library, Log) carry the floating glass tab bar exactly as in Main.dc.html (copy the whole `<nav>`; move the selected-pill style to the active tab; active tab label color `#FF6B72`, others `#D7D7DE`). Give scrolling content `padding-bottom: 108px` or let it run under the bar. Non-tab screens (pushed/modal) have NO tab bar; they have a glass back/close circle button top-left.
- Units: user loads lb plates; show lb first, kg in brackets, e.g. `160 lb (72.6 kg)`.

## Sample data to use
- Sample user (fictional values for mockups): initial "R", man, 30, 178 cm. Bodyweight 76.0 kg rising 0.2 kg a week to 76.8 kg; goal 80 kg by 15 Dec. Injury note "Ankle sprain: no leg loading until ~9 Nov 2026", which pauses leg training.
- Today (Sat 26 Sep), Push + Arms: Bench 3×8 @160 lb; Incline DB Press 3×8–10 @50 lb; Incline DB Fly 3×12 @32.5 lb; Cable Crossover 3×12 @30 lb; Rope Overhead Ext 3×8–10 @50 lb; Hammer Curls 3×10 @25 lb; Preacher Curl 3×10 @65 lb.
- History: Tue 22 Sep Pull + Shoulders + Triceps (Lat Pulldown 3×10 @135 lb; Cable Row 3×12 @110 lb; Kettlebell Row 10,10,12 @35 lb; Face Pull 3×12 @40 lb; Machine Shoulder Press 8,10,8 @75 lb; Rope Overhead 3×10 @45 lb; Pushdown 3×10 @60 lb). Sat 19 Sep Push + Biceps (Bench 3×10 @150 lb = rep record, e1RM 90.7 kg up from 81.6; Incline DB 3×10 @45; Preacher 12,15,12 @60). Wed 16 Sep Pull (Barbell Row 5×6 @145 lb). Mon 14 Sep Legs (Leg Press 4×8 @195 lb).
- Bench history: 12 Sep 3×6 @150 lb; 19 Sep 3×10 @150 lb. Older history unknown → placeholder.
- Split: Push + Arms / Pull + Shoulders + Triceps / Upper weak points (Legs paused). Progression: double progression (hit top of rep range on all sets → +5 lb); miss twice → drop 5%.
- CSV import: a Fitbod-style CSV export, columns Date, Exercise, Reps, Weight(kg), Duration(s), Distance(m), Incline, Resistance, isWarmup, Note, multiplier. Use placeholders for counts you don't know, e.g. `[N] workouts`.
- Claude: connects via a custom connector URL `https://api.gymrollins.com/mcp`, signs in by OAuth, approved in the app with the code its sign-in page shows (Settings › Claude › Approve a connection). Claude's plan edits arrive as PROPOSALS the user applies or dismisses, each a before → after change with a reason.
- Exercise library: 1,324 exercises, filters by body part and equipment.

## Screen names (link targets that exist on the canvas)
Welcome, ProfileSetup, ImportCSV, ImportResult, ConnectClaude, Main (Today), Plan, RoutineEdit, Proposal, WorkoutOverview, Logging, RestSettings, Plates, HowTo, Swap, ExerciseOptions, AddExercise, FinishConfirm, Summary, Log, WorkoutDetail, ExerciseHistory, Body, AddWeighIn, Library, CustomExercise, Settings, Claude, SyncStates, Flow. File = `<Name>.dc.html`.

## Your deliverable
Write ONLY the files you are assigned, into `<root>/project/`, with the Write tool (no shell scripts generating files).
Do NOT publish, render, screenshot, or open anything. Do NOT touch canvas.json or files not assigned to you.
When done, reply with: the list of files written, one line per file describing what's on it, and any placeholder or assumption.
