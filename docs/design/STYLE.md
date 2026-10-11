# GymRollins iOS mockups: artboard spec (read fully before writing)

You write iPhone mockup artboards (`.dc.html` files) for a design canvas. The REFERENCE artboard is
`<root>/project/Main.dc.html`. Read it first and copy its structure, head, helmet, tokens and patterns EXACTLY.
`<root>` = <scratchpad>/design (a local working folder, not in the repo)

## File format rules (each violation fails silently)
- Whole file shape as Main.dc.html: `<!doctype html>`, `<head>` with `<meta charset>`, a unique `<title>`, and EXACTLY `<script src="./support.js"></script>`; body holds `<x-dc>` with a `<helmet>` (same Google Fonts link + same style block as Main), then ONE root `<div>` of fixed `width: 390px; height: 844px; box-sizing: border-box; position: relative; overflow: hidden`, then after `</x-dc>` the same `<script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":390,"height":844}}'>` block with `class Component extends DCLogic { renderVals() { return {}; } }`.
- Close every non-void element; quote every attribute; ALL styling is inline `style="…"` (only the helmet's body/a rules are allowed in `<style>`).
- Static mockups: no JS logic, no `{{holes}}`, no innerHTML. Links between screens: `<a href="Other.dc.html">` styled as the button itself (never a button inside an a).
- Real `<button type="button">`, `<a href>`, `<input>` with a `<label>` (visually hidden label span via `position: absolute; left: -9999px` is fine). `aria-label` on icon-only buttons.
- Icons: inline stroke SVG (`fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"`), never emoji.
- No fake status bar: leave the top 54px empty (content starts at `padding-top: 58px`).
- No lorem ipsum. Use the real data below; anything unknown is a bracketed placeholder like `[exercise GIF]`.

## Visual language: dark athletic + iOS 26 Liquid Glass
Tokens:
- Page background `#0B0B10`. Text `#F2F2F5`, secondary `#A9A9B5`, tertiary/captions `#8E8E9A`.
- CONTENT layer (lists, cards, charts, tables) stays SOLID for legibility: card `#17171E`, radius 18px; inner thumbnail/placeholder `#262631`; dividers `#25252E`.
- CONTROL/NAVIGATION layer is LIQUID GLASS (every button, chip, segmented control, toolbar, nav button, tab bar, floating CTA, sheet, timer bar, overlay):
  - Glass: `background: rgba(40,40,52,0.55); backdrop-filter: blur(20px) saturate(170%); -webkit-backdrop-filter: blur(20px) saturate(170%); border: 1px solid rgba(255,255,255,0.12); box-shadow: inset 0 1px 0 rgba(255,255,255,0.22), 0 8px 24px rgba(0,0,0,0.45)`.
  - Prominent glass (primary action, ONE per screen): `background: rgba(214,58,70,0.78)` + same blur + `border: 1px solid rgba(255,170,175,0.35); box-shadow: inset 0 1px 0 rgba(255,255,255,0.35), 0 10px 26px rgba(200,50,62,0.35)`; white bold text.
  - Selected state inside a glass group (tab pill, segmented selection): `background: rgba(255,255,255,0.12); box-shadow: inset 0 1px 0 rgba(255,255,255,0.18)`.
  - Sheets / modals: glass panel `background: rgba(30,30,40,0.72); backdrop-filter: blur(30px) saturate(170%)`, top radius 34px, the same inset highlight, a 40×5 grabber `rgba(255,255,255,0.3)`. Behind a sheet, show the underlying screen content dimmed (a few solid cards under `rgba(0,0,0,0.45)` overlay) so the glass has something to blur.
  - Shapes: capsules (radius = height/2) for buttons and chips; circles 44×44 for icon buttons. Touch targets ≥ 44px.
  - Float controls OVER content where it makes sense (content continues underneath) so the glass reads.
- Accent text/icons `#FF6B72`. Success `#4FD1A5` (done sets, increases; badge bg `#14342A`). Records/warm-up/warnings amber `#F5B75A` (badge bg `rgba(245,183,90,0.14)`). Destructive text `#FF8A8F`.
- Type: headings `'Barlow Condensed'` italic 800 (screen titles 40–48px, sheet titles 28px); body `Barlow` 400–700; small caps labels 12–13px, 700, letter-spacing .08em, color `#8E8E9A`.
- Tab screens (Today, Body, Library, Log) carry the floating glass tab bar exactly as in Main.dc.html (copy the whole `<nav>`; move the selected-pill style to the active tab; active tab label color `#FF6B72`, others `#D7D7DE`). Give scrolling content `padding-bottom: 108px` or let it run under the bar. Non-tab screens (pushed/modal) have NO tab bar; they have a glass back/close circle button top-left.
- Units: user loads lb plates; show lb first, kg in brackets, e.g. `140 lb (63.5 kg)`.

## Real data to use
- Sample user (fictional values for mockups): initial "R", a bodyweight goal, and an injury note that pauses leg training for a few weeks.
- Today (Sat 26 Sep), Push + Arms: Bench 3×8 @140 lb; Incline DB Press 3×8–10 @45 lb; Incline DB Fly 3×12 @27.5 lb; Cable Crossover 3×12 @25 lb; Rope Overhead Ext 3×8–10 @40 lb; Hammer Curls 3×10 @22.5 lb; Preacher Curl 3×10 @55 lb.
- History: Tue 22 Sep Pull + Shoulders + Triceps (Lat Pulldown 3×10 @120 lb; Cable Row 3×12 @120 lb; Kettlebell Row 10,10,12 @44 lb; Face Pull 3×12 @30 lb; Machine Shoulder Press 8,10,8 @70 lb; Rope Overhead 3×10 @35 lb; Pushdown 3×10 @50 lb). Sat 19 Sep Push + Biceps (Bench 3×10 @130 lb = rep record, e1RM 78.6 kg up from 70.8; Incline DB 3×10 @40; Preacher 12,15,12 @50). Wed 16 Sep Pull (Barbell Row 5×6 @130 lb). Mon 14 Sep Legs (Leg Press 4×8 @165 lb).
- Bench history: 12 Sep 3×6 @130 lb; 19 Sep 3×10 @130 lb. Best Nov 2025 era unknown → placeholder.
- Split: Push + Arms / Pull + Shoulders + Triceps / Upper weak points (Legs paused). Progression: double progression (hit top of rep range on all sets → +5 lb); miss twice → drop 5%.
- CSV import: file "WorkoutExport.csv", 2,605 rows, Aug 2025 → Sep 2026, columns Date, Exercise, Reps, Weight(kg), Duration(s), Distance(m), Incline, Resistance, isWarmup, Note, multiplier. Use placeholders for counts you don't know, e.g. `[N] workouts`.
- Claude: connects via a custom connector URL `https://[project].supabase.co/functions/v1/mcp`, signs in with OAuth ("Allow Claude to access GymRollins"). Claude's plan edits arrive as PROPOSALS the user applies or dismisses, each a before → after change with a reason.
- Exercise library: 1,324 exercises, filters by body part and equipment.

## Screen names (link targets that exist on the canvas)
Welcome, ProfileSetup, ImportCSV, ImportResult, ConnectClaude, Main (Today), Plan, RoutineEdit, Proposal, WorkoutOverview, Logging, RestSettings, Plates, HowTo, Swap, ExerciseOptions, AddExercise, FinishConfirm, Summary, Log, WorkoutDetail, ExerciseHistory, Body, AddWeighIn, Library, CustomExercise, Settings, Claude, SyncStates, Flow. File = `<Name>.dc.html`.

## Your deliverable
Write ONLY the files you are assigned, into `<root>/project/`, with the Write tool (no shell scripts generating files).
Do NOT publish, render, screenshot, or open anything. Do NOT touch canvas.json or files not assigned to you.
When done, reply with: the list of files written, one line per file describing what's on it, and any placeholder or assumption.
