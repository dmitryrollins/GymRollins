# Fitbod alias review

Curated decisions behind `ios/GymRollins/Resources/fitbod-aliases.json`, built from the owner's Fitbod export.
Only exercise **names** and **set counts** appear here: no dates, weights, reps or notes.

- Distinct names: **120** (2606 sets)
- Mapped to a library exercise: **79**; custom on import (`null`): **41**
- The matcher alone (exact, or unambiguous fuzzy >= 0.6) already agreed with the curated id for 37 names; the
  table overrides 13 confident-but-wrong matcher results and settles every tie and no-match by hand.

Regenerate the raw matcher view locally (never commit the CSV):

```sh
node scripts/fitbod-alias-report.mjs "<path to WorkoutExport.csv>"                                   # stdout only
node scripts/fitbod-alias-report.mjs "<path to WorkoutExport.csv>" --out /tmp/fitbod-alias-report.md  # names + counts only
```

## Rules applied

1. Prefer the library exercise whose **equipment and grip** match the Fitbod name. Fitbod names without an equipment
   prefix use Fitbod's default equipment (barbell for Deadlift, Romanian Deadlift, Preacher Curl, Upright Row;
   dumbbell for Goblet Squat, Concentration Curl, Hammer Curls).
2. Never merge two exercises whose loads are not comparable (45° sled vs seated leg press, paused vs regular squat,
   kettlebell vs barbell upright row). The odd one out becomes `null` (custom) so PRs and progression stay honest.
3. **Handle Band** movements are all custom (plan decision): the loads Fitbod logs for them are not comparable to the
   library band or cable entries.
4. `null` = create a custom exercise on first import. Its mode is `cardio` when any of its sets carries a duration
   or distance and no reps (Swimming, High Knee), otherwise `reps`.
5. Two Fitbod names may share one library id (Dumbbell Back Fly and Dumbbell Bent Over Reverse Fly).
6. Library-mapped timed movements (Plank, Walking, Running, Single Leg Glute Bridge, Jumping Jack) keep their
   duration/distance on the imported sets regardless of the library exercise's default mode.

## Decisions (by set count)

| Fitbod name | Sets | Curated | Matcher alone | Why |
|---|---:|---|---|---|
| Barbell Bench Press | 125 | `0025` barbell bench press | 0025 (exact 1.00) | Exact name match. |
| Dumbbell Row | 87 | `0292` dumbbell one arm bent-over row | tie at 0.67 | Fitbod's Dumbbell Row is a single-arm row; the matcher tied incline row vs upright row (both wrong). Chose the one-arm bent-over row. |
| Dumbbell Bicep Curl | 83 | `0294` dumbbell biceps curl | 0294 (fuzzy 1.00) | Plural/singular only. |
| Leg Extension | 81 | `0585` lever leg extension | 0585 (fuzzy 0.67) | Machine leg extension (the band version is a different tool). |
| Bent Over Barbell Row | 79 | `0027` barbell bent over row | 0027 (fuzzy 1.00) | Same words, different order. |
| Hammer Curls | 76 | `0313` dumbbell hammer curl | 0313 (fuzzy 0.67) | Fitbod default is dumbbell. |
| Leg Press | 75 | `0739` sled 45° leg press | 0760 (fuzzy 0.67) | Fitbod's Leg Press is the 45° plate-loaded sled, not the Smith leg press the fuzzy match suggested. |
| Back Squat | 72 | `0043` barbell full squat | none | Barbell back squat = barbell full squat (the "(back pov)" entries are camera-angle duplicates). |
| Dumbbell Incline Bench Press | 59 | `0314` dumbbell incline bench press | 0314 (exact 1.00) | Exact name match. |
| Dumbbell Incline Fly | 56 | `0319` dumbbell incline fly | 0319 (exact 1.00) | Exact name match. |
| Dumbbell Shoulder Press | 56 | `0405` dumbbell seated shoulder press | 0405 (fuzzy 0.75) | Fitbod performs it seated, both arms. |
| Romanian Deadlift | 55 | `0085` barbell romanian deadlift | tie at 0.67 | Unprefixed Fitbod RDL is the barbell version (the dumbbell one has its own name below); matcher tie broken by equipment. |
| Cable Row | 53 | `0861` cable seated row | tie at 0.67 | Seated cable row; matcher tied with "cable upper row". |
| Walking | 52 | `3666` walking on incline treadmill | none | The library's only plain walking cardio entry. Imported as cardio (duration/distance), which is what matters for history. |
| Lat Pulldown | 50 | `0198` cable pulldown | none | Standard cable lat pulldown (plan guidance). |
| Seated Leg Curl | 49 | `0599` lever seated leg curl | 0599 (fuzzy 0.75) | Machine seated leg curl. |
| Dumbbell Bench Press | 47 | `0289` dumbbell bench press | 0289 (exact 1.00) | Exact name match. |
| Handle Band Row | 45 | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Cable Tricep Pushdown | 44 | `0201` cable pushdown | 0201 (fuzzy 0.67) | Straight-bar cable pushdown. |
| Handle Band Tricep Extension | 44 | **custom** | 0998 (fuzzy 0.60) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Dumbbell Lateral Raise | 43 | `0334` dumbbell lateral raise | 0334 (exact 1.00) | Exact name match. |
| Handle Band Shoulder Press | 43 | **custom** | 0997 (fuzzy 0.75) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Handle Band Pec Fly | 42 | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Dumbbell Front Raise | 41 | `0310` dumbbell front raise | 0310 (exact 1.00) | Exact name match. |
| Bench Dip | 39 | `0814` triceps dip | tie at 0.67 | Library "triceps dip" is the bench dip (hands on a bench edge, feet on floor); the fuzzy tie offered three-bench / weighted variants. |
| Handle Band Bicep Curl | 38 | **custom** | 0968 (fuzzy 0.60) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Kettlebell Row | 38 | `0541` kettlebell one arm row | 0522 (fuzzy 0.67) | Fitbod's Kettlebell Row is one arm at a time (the alternating version has its own name below). |
| Seated Machine Calf Press | 36 | `2335` lever seated calf press | 2335 (fuzzy 0.60) | Seated calf press machine. |
| Ab Crunch Machine | 34 | `1452` lever seated crunch | none | Seated crunch machine (lever). |
| Handle Band Lateral Raise | 32 | **custom** | 0977 (fuzzy 0.60) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Dumbbell Skullcrusher | 31 | `0351` dumbbell lying triceps extension | none | A dumbbell skullcrusher is the lying dumbbell triceps extension. |
| Cable Crossover Fly | 30 | `0227` cable standing fly | none | Standing cable fly between two pulleys; the fuzzy candidates were decline/incline bench flies. |
| Lying Hamstrings Curl | 28 | `0586` lever lying leg curl | none | Machine lying leg curl; fuzzy candidates were biceps curls. |
| Single Leg Kickback | 27 | **custom** | none | Glute kickback on all fours; the library only has triceps kickbacks. |
| EZ-Bar Overhead Tricep Extension | 26 | `0453` ez barbell seated triceps extension | none | EZ-bar overhead triceps extension (equipment match; the barbell entries use a straight bar). |
| Machine Shoulder Press | 26 | `0603` lever shoulder press | none | Lever (machine) shoulder press (plan guidance). |
| Handle Band Reverse Curl | 25 | **custom** | 0994 (fuzzy 0.60) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Clam | 23 | **custom** | none | Clamshell hip exercise is not in the library. |
| Air Squats | 22 | **custom** | none | Bodyweight squat: the library has only jump / pistol / sissy / split variants, none equivalent. |
| Assisted Dip | 22 | `0019` assisted triceps dip (kneeling) | none | Machine-assisted dip (kneeling pad), triceps variant. |
| Concentration Curl | 21 | `0297` dumbbell concentration curl | tie at 0.67 | Fitbod's is dumbbell; matcher tied band vs cable. |
| Bicycle Crunch | 20 | `0262` cross body crunch | 0972 (fuzzy 0.67) | Cross-body (elbow to opposite knee) crunch; the only "bicycle" entry uses a band. |
| Dumbbell Fly | 20 | `0308` dumbbell fly | 0308 (exact 1.00) | Exact name match. |
| Dumbbell Tricep Extension | 20 | `2188` dumbbell seated triceps extension | tie at 0.75 | Two-hand overhead dumbbell extension; matcher tied decline/incline lying versions. |
| Handle Band Rear Deltoid Fly | 20 | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Handle Band Upright Row | 20 | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Side Lunge | 20 | **custom** | none | Bodyweight lateral lunge; the only library lateral lunge is barbell-loaded. |
| Cable Face Pull | 19 | `0203` cable rear delt row (with rope) | none | Face pull = cable rear delt row with rope (plan guidance). |
| Handle Band Squat | 19 | **custom** | 1004 (fuzzy 0.67) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Handle Band Bent Over Row | 18 | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Handle Band Forward Raise | 18 | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Hip Thrust | 18 | **custom** | none | Bodyweight hip thrust (shoulders on bench); the library has only floor glute bridges and a kneeling band thrust. |
| Dumbbell Back Fly | 15 | `0383` dumbbell reverse fly | 0308 (fuzzy 0.67) | Bent-over dumbbell reverse fly (rear delts), not the chest fly the fuzzy match suggested. |
| Goblet Squat | 15 | `1760` dumbbell goblet squat | tie at 0.67 | Fitbod's Goblet Squat is dumbbell; matcher tied dumbbell vs kettlebell. |
| Preacher Curl | 15 | `0070` barbell preacher curl | tie at 0.67 | Fitbod default preacher curl is barbell; matcher tied barbell vs cable. |
| Push Up | 15 | `0662` push-up | 0662 (exact 1.00) | Exact after punctuation. |
| Cable Rope Overhead Triceps Extension | 14 | `0194` cable overhead triceps extension (rope attachment) | 0194 (fuzzy 0.83) | Overhead cable extension with rope. |
| Dumbbell Lunge | 14 | `0336` dumbbell lunge | 0336 (exact 1.00) | Exact name match. |
| Handle Band Straight-Arm Pulldown | 14 | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Seated Dumbbell Curl | 13 | `0391` dumbbell seated curl | 0391 (fuzzy 1.00) | Same words, different order. |
| Superman | 13 | **custom** | none | Prone back-extension hold; the library only has a superman push-up. |
| Cable Rope Tricep Extension | 12 | `0200` cable pushdown (with rope attachment) | 1725 (fuzzy 0.80) | Fitbod's rope tricep extension is the rope pushdown, not the incline bench version the fuzzy match suggested. |
| Handle Band Lat Pulldown | 12 | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Kettlebell Upright Row | 12 | **custom** | none | No kettlebell upright row; kept separate from barbell/dumbbell loads. |
| Russian Twist | 12 | `0687` russian twist | 0687 (exact 1.00) | Exact name match. |
| Barbell Hip Thrust | 11 | **custom** | none | Shoulders-on-bench barbell hip thrust; the library glute bridges are floor-based, loads not comparable. |
| Dumbbell Kickbacks | 11 | `0333` dumbbell kickback | 0333 (fuzzy 1.00) | Plural only. |
| Deadlift | 10 | `0032` barbell deadlift | none | Unprefixed Fitbod Deadlift is barbell; matcher tied barbell vs cable. |
| Dumbbell Bent Over Row | 10 | `0293` dumbbell bent over row | 0293 (exact 1.00) | Exact name match. |
| Kettlebell Halo | 10 | **custom** | none | Not in the library. |
| Calf Raise | 9 | `1373` bodyweight standing calf raise | tie at 0.67 | Unprefixed Fitbod Calf Raise is the standing bodyweight version; logged weight is recorded as added load. |
| Dead Bug | 8 | `0276` dead bug | 0276 (exact 1.00) | Exact name match. |
| Machine Leg Press | 8 | **custom** | none | Seated selectorized leg press: no two-leg lever leg press in the library, and its loads must not merge into the 45° sled (Leg Press) history. |
| Pike Push Up | 8 | **custom** | 0662 (fuzzy 0.67) | Floor pike push-up; library only has the stability-ball pike push-up. |
| Walkout to Push Up | 8 | **custom** | none | Inchworm plus a push-up; kept separate from plain Walkout. |
| Cobra Triceps Extension | 7 | **custom** | none | Prone bodyweight triceps extension; not in the library. |
| Dumbbell Shrug | 7 | `0406` dumbbell shrug | 0406 (exact 1.00) | Exact name match. |
| Dumbbell Squat | 7 | `0413` dumbbell squat | 0413 (exact 1.00) | Exact name match. |
| Handle Band Squat to Press | 6 | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Single Leg Glute Bridge | 6 | `3645` single leg bridge with outstretched leg | none | Single-leg bridge with the other leg extended. |
| Single-Leg Glute Bridge with External Rotation | 6 | **custom** | none | Distinct rehab variant; not in the library. |
| Dumbbell Bent Over Reverse Fly | 5 | `0383` dumbbell reverse fly | 0383 (fuzzy 0.60) | Same movement as Dumbbell Back Fly; both Fitbod names share one library id. |
| Dumbbell Romanian Deadlift | 5 | `1459` dumbbell romanian deadlift | 1459 (exact 1.00) | Exact name match. |
| Kettlebell Alternating Row | 5 | `0522` kettlebell alternating row | 0522 (exact 1.00) | Exact name match. |
| Prone T's | 5 | **custom** | none | Floor prone T raise (bodyweight); library T-raise is an incline dumbbell exercise. |
| Assisted Pull Up | 4 | `0017` assisted pull-up | 0017 (exact 1.00) | Exact after punctuation. |
| Barbell Curl | 4 | `0031` barbell curl | 0031 (exact 1.00) | Exact name match. |
| Barbell Front Raise | 4 | `0041` barbell front raise | 0041 (exact 1.00) | Exact name match. |
| Cable Underhand Tricep Pushdown | 4 | `0207` cable reverse-grip pushdown | none | Underhand = reverse-grip cable pushdown. |
| Dip | 4 | `0251` chest dip | none | Parallel-bar dip. |
| Floor Press | 4 | **custom** | none | Two-arm barbell floor press; the library only has one-arm barbell/kettlebell versions. |
| Glute Ham Raise | 4 | `3193` glute-ham raise | 3193 (exact 1.00) | Exact after punctuation (present in library, so not custom). |
| Machine Hip Abductor | 4 | `0597` lever seated hip abduction | none | Seated hip abduction machine. |
| Machine Hip Adductor | 4 | `0598` lever seated hip adduction | none | Seated hip adduction machine. |
| Mountain Climber | 4 | `0630` mountain climber | 0630 (exact 1.00) | Exact name match. |
| Pause Back Squat | 4 | **custom** | none | Paused variant with lower loads; kept separate so it does not drag Back Squat progression. |
| Side Leg Raises | 4 | `0710` side hip abduction | none | Side hip abduction (leg raised out to the side). |
| Single Arm Kettlebell Deadlift | 4 | **custom** | none | No kettlebell deadlift in the library. |
| Straight Leg Kickback | 4 | **custom** | none | Straight-leg glute kickback; library only has triceps kickbacks. |
| Walkout | 4 | `1471` inchworm | none | A walkout is the inchworm. |
| Cable Lateral Raise | 3 | `0178` cable lateral raise | 0178 (exact 1.00) | Exact name match. |
| Dumbbell Hang Snatch | 3 | `3888` dumbbell one arm snatch | none | Single-arm dumbbell snatch from the hang. |
| Hammerstrength High Row | 3 | `0581` lever high row | none | Hammer Strength is a plate-loaded lever machine: lever high row. |
| Hand Release Push Up | 3 | **custom** | 1311 (fuzzy 0.60) | Distinct push-up variant (chest to floor, hands lifted); "wide hand push up" is a different movement. |
| Incline Back Extension | 3 | `0489` hyperextension | none | 45° back extension bench = hyperextension (the lever entry is a seated machine). |
| Plank | 3 | `2135` weighted front plank | none | Front forearm plank; imported with zero added weight and its duration. |
| Prone Y's | 3 | **custom** | none | Floor prone Y raise (bodyweight); library Y-raise uses a band or incline dumbbells. |
| Reverse Barbell Curl | 3 | `0080` barbell reverse curl | 0080 (fuzzy 1.00) | Same words, different order. |
| Running | 3 | `0685` run | none | Run (cardio). |
| Smith Machine Stiff-Legged Deadlift | 3 | `0752` smith deadlift | none | Smith deadlift, the closest equipment match; stiff-leg is a form cue. |
| Toe Touchers | 3 | **custom** | none | Lying legs-up toe reach crunch; not in the library. |
| Upright Row | 3 | `0120` barbell upright row | tie at 0.67 | Unprefixed Fitbod Upright Row is barbell (all sets weighted); matcher tied barbell vs cable. |
| Barbell Incline Bench Press | 2 | `0047` barbell incline bench press | 0047 (exact 1.00) | Exact name match. |
| Behind the Back Cable Bicep Curl | 2 | **custom** | none | Cable curl facing away from the stack; not in the library. |
| Cycling - Stationary | 2 | `2138` stationary bike run v. 3 | none | Stationary bike (equipment match). |
| Handle Band Crunch | 2 | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| High Knee | 2 | **custom** | none | Running high knees in place; the library version is wall-supported. |
| Jumping Jack | 2 | `3224` jack jump (male) | none | Jack jump = jumping jack. |
| Scapular Pull Up | 2 | `0688` scapular pull-up | 0688 (exact 1.00) | Exact after punctuation. |
| Swimming | 1 | **custom** | none | Not in the library; becomes a custom cardio exercise. |
