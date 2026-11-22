# Fitbod alias review

Curated decisions behind `ios/GymRollins/Resources/fitbod-aliases.json`, built from a Fitbod export.
Only exercise **names** appear here: no dates, weights, reps, notes or counts.

- Distinct names: **120**
- Mapped to a library exercise: **79**; custom on import (`null`): **41**
- The matcher alone (exact, or unambiguous fuzzy >= 0.6) already agreed with the curated id for 37 names; the
  table overrides 13 confident-but-wrong matcher results and settles every tie and no-match by hand.

Regenerate the raw matcher view locally (never commit the CSV):

```sh
node scripts/fitbod-alias-report.mjs "<path to the Fitbod export CSV>"                                   # stdout only
node scripts/fitbod-alias-report.mjs "<path to the Fitbod export CSV>" --out /tmp/fitbod-alias-report.md  # names + counts only
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

## Decisions

| Fitbod name | Curated | Matcher alone | Why |
|---|---|---|---|
| Barbell Bench Press | `0025` barbell bench press | 0025 (exact 1.00) | Exact name match. |
| Dumbbell Row | `0292` dumbbell one arm bent-over row | tie at 0.67 | Fitbod's Dumbbell Row is a single-arm row; the matcher tied incline row vs upright row (both wrong). Chose the one-arm bent-over row. |
| Dumbbell Bicep Curl | `0294` dumbbell biceps curl | 0294 (fuzzy 1.00) | Plural/singular only. |
| Leg Extension | `0585` lever leg extension | 0585 (fuzzy 0.67) | Machine leg extension (the band version is a different tool). |
| Bent Over Barbell Row | `0027` barbell bent over row | 0027 (fuzzy 1.00) | Same words, different order. |
| Hammer Curls | `0313` dumbbell hammer curl | 0313 (fuzzy 0.67) | Fitbod default is dumbbell. |
| Leg Press | `0739` sled 45° leg press | 0760 (fuzzy 0.67) | Fitbod's Leg Press is the 45° plate-loaded sled, not the Smith leg press the fuzzy match suggested. |
| Back Squat | `0043` barbell full squat | none | Barbell back squat = barbell full squat (the "(back pov)" entries are camera-angle duplicates). |
| Dumbbell Incline Bench Press | `0314` dumbbell incline bench press | 0314 (exact 1.00) | Exact name match. |
| Dumbbell Incline Fly | `0319` dumbbell incline fly | 0319 (exact 1.00) | Exact name match. |
| Dumbbell Shoulder Press | `0405` dumbbell seated shoulder press | 0405 (fuzzy 0.75) | Fitbod performs it seated, both arms. |
| Romanian Deadlift | `0085` barbell romanian deadlift | tie at 0.67 | Unprefixed Fitbod RDL is the barbell version (the dumbbell one has its own name below); matcher tie broken by equipment. |
| Cable Row | `0861` cable seated row | tie at 0.67 | Seated cable row; matcher tied with "cable upper row". |
| Walking | `3666` walking on incline treadmill | none | The library's only plain walking cardio entry. Imported as cardio (duration/distance), which is what matters for history. |
| Lat Pulldown | `0198` cable pulldown | none | Standard cable lat pulldown (plan guidance). |
| Seated Leg Curl | `0599` lever seated leg curl | 0599 (fuzzy 0.75) | Machine seated leg curl. |
| Dumbbell Bench Press | `0289` dumbbell bench press | 0289 (exact 1.00) | Exact name match. |
| Handle Band Row | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Cable Tricep Pushdown | `0201` cable pushdown | 0201 (fuzzy 0.67) | Straight-bar cable pushdown. |
| Handle Band Tricep Extension | **custom** | 0998 (fuzzy 0.60) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Dumbbell Lateral Raise | `0334` dumbbell lateral raise | 0334 (exact 1.00) | Exact name match. |
| Handle Band Shoulder Press | **custom** | 0997 (fuzzy 0.75) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Handle Band Pec Fly | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Dumbbell Front Raise | `0310` dumbbell front raise | 0310 (exact 1.00) | Exact name match. |
| Bench Dip | `0814` triceps dip | tie at 0.67 | Library "triceps dip" is the bench dip (hands on a bench edge, feet on floor); the fuzzy tie offered three-bench / weighted variants. |
| Handle Band Bicep Curl | **custom** | 0968 (fuzzy 0.60) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Kettlebell Row | `0541` kettlebell one arm row | 0522 (fuzzy 0.67) | Fitbod's Kettlebell Row is one arm at a time (the alternating version has its own name below). |
| Seated Machine Calf Press | `2335` lever seated calf press | 2335 (fuzzy 0.60) | Seated calf press machine. |
| Ab Crunch Machine | `1452` lever seated crunch | none | Seated crunch machine (lever). |
| Handle Band Lateral Raise | **custom** | 0977 (fuzzy 0.60) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Dumbbell Skullcrusher | `0351` dumbbell lying triceps extension | none | A dumbbell skullcrusher is the lying dumbbell triceps extension. |
| Cable Crossover Fly | `0227` cable standing fly | none | Standing cable fly between two pulleys; the fuzzy candidates were decline/incline bench flies. |
| Lying Hamstrings Curl | `0586` lever lying leg curl | none | Machine lying leg curl; fuzzy candidates were biceps curls. |
| Single Leg Kickback | **custom** | none | Glute kickback on all fours; the library only has triceps kickbacks. |
| EZ-Bar Overhead Tricep Extension | `0453` ez barbell seated triceps extension | none | EZ-bar overhead triceps extension (equipment match; the barbell entries use a straight bar). |
| Machine Shoulder Press | `0603` lever shoulder press | none | Lever (machine) shoulder press (plan guidance). |
| Handle Band Reverse Curl | **custom** | 0994 (fuzzy 0.60) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Clam | **custom** | none | Clamshell hip exercise is not in the library. |
| Air Squats | **custom** | none | Bodyweight squat: the library has only jump / pistol / sissy / split variants, none equivalent. |
| Assisted Dip | `0019` assisted triceps dip (kneeling) | none | Machine-assisted dip (kneeling pad), triceps variant. |
| Concentration Curl | `0297` dumbbell concentration curl | tie at 0.67 | Fitbod's is dumbbell; matcher tied band vs cable. |
| Bicycle Crunch | `0262` cross body crunch | 0972 (fuzzy 0.67) | Cross-body (elbow to opposite knee) crunch; the only "bicycle" entry uses a band. |
| Dumbbell Fly | `0308` dumbbell fly | 0308 (exact 1.00) | Exact name match. |
| Dumbbell Tricep Extension | `2188` dumbbell seated triceps extension | tie at 0.75 | Two-hand overhead dumbbell extension; matcher tied decline/incline lying versions. |
| Handle Band Rear Deltoid Fly | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Handle Band Upright Row | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Side Lunge | **custom** | none | Bodyweight lateral lunge; the only library lateral lunge is barbell-loaded. |
| Cable Face Pull | `0203` cable rear delt row (with rope) | none | Face pull = cable rear delt row with rope (plan guidance). |
| Handle Band Squat | **custom** | 1004 (fuzzy 0.67) | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Handle Band Bent Over Row | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Handle Band Forward Raise | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Hip Thrust | **custom** | none | Bodyweight hip thrust (shoulders on bench); the library has only floor glute bridges and a kneeling band thrust. |
| Dumbbell Back Fly | `0383` dumbbell reverse fly | 0308 (fuzzy 0.67) | Bent-over dumbbell reverse fly (rear delts), not the chest fly the fuzzy match suggested. |
| Goblet Squat | `1760` dumbbell goblet squat | tie at 0.67 | Fitbod's Goblet Squat is dumbbell; matcher tied dumbbell vs kettlebell. |
| Preacher Curl | `0070` barbell preacher curl | tie at 0.67 | Fitbod default preacher curl is barbell; matcher tied barbell vs cable. |
| Push Up | `0662` push-up | 0662 (exact 1.00) | Exact after punctuation. |
| Cable Rope Overhead Triceps Extension | `0194` cable overhead triceps extension (rope attachment) | 0194 (fuzzy 0.83) | Overhead cable extension with rope. |
| Dumbbell Lunge | `0336` dumbbell lunge | 0336 (exact 1.00) | Exact name match. |
| Handle Band Straight-Arm Pulldown | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Seated Dumbbell Curl | `0391` dumbbell seated curl | 0391 (fuzzy 1.00) | Same words, different order. |
| Superman | **custom** | none | Prone back-extension hold; the library only has a superman push-up. |
| Cable Rope Tricep Extension | `0200` cable pushdown (with rope attachment) | 1725 (fuzzy 0.80) | Fitbod's rope tricep extension is the rope pushdown, not the incline bench version the fuzzy match suggested. |
| Handle Band Lat Pulldown | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Kettlebell Upright Row | **custom** | none | No kettlebell upright row; kept separate from barbell/dumbbell loads. |
| Russian Twist | `0687` russian twist | 0687 (exact 1.00) | Exact name match. |
| Barbell Hip Thrust | **custom** | none | Shoulders-on-bench barbell hip thrust; the library glute bridges are floor-based, loads not comparable. |
| Dumbbell Kickbacks | `0333` dumbbell kickback | 0333 (fuzzy 1.00) | Plural only. |
| Deadlift | `0032` barbell deadlift | none | Unprefixed Fitbod Deadlift is barbell; matcher tied barbell vs cable. |
| Dumbbell Bent Over Row | `0293` dumbbell bent over row | 0293 (exact 1.00) | Exact name match. |
| Kettlebell Halo | **custom** | none | Not in the library. |
| Calf Raise | `1373` bodyweight standing calf raise | tie at 0.67 | Unprefixed Fitbod Calf Raise is the standing bodyweight version; logged weight is recorded as added load. |
| Dead Bug | `0276` dead bug | 0276 (exact 1.00) | Exact name match. |
| Machine Leg Press | **custom** | none | Seated selectorized leg press: no two-leg lever leg press in the library, and its loads must not merge into the 45° sled (Leg Press) history. |
| Pike Push Up | **custom** | 0662 (fuzzy 0.67) | Floor pike push-up; library only has the stability-ball pike push-up. |
| Walkout to Push Up | **custom** | none | Inchworm plus a push-up; kept separate from plain Walkout. |
| Cobra Triceps Extension | **custom** | none | Prone bodyweight triceps extension; not in the library. |
| Dumbbell Shrug | `0406` dumbbell shrug | 0406 (exact 1.00) | Exact name match. |
| Dumbbell Squat | `0413` dumbbell squat | 0413 (exact 1.00) | Exact name match. |
| Handle Band Squat to Press | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| Single Leg Glute Bridge | `3645` single leg bridge with outstretched leg | none | Single-leg bridge with the other leg extended. |
| Single-Leg Glute Bridge with External Rotation | **custom** | none | Distinct rehab variant; not in the library. |
| Dumbbell Bent Over Reverse Fly | `0383` dumbbell reverse fly | 0383 (fuzzy 0.60) | Same movement as Dumbbell Back Fly; both Fitbod names share one library id. |
| Dumbbell Romanian Deadlift | `1459` dumbbell romanian deadlift | 1459 (exact 1.00) | Exact name match. |
| Kettlebell Alternating Row | `0522` kettlebell alternating row | 0522 (exact 1.00) | Exact name match. |
| Prone T's | **custom** | none | Floor prone T raise (bodyweight); library T-raise is an incline dumbbell exercise. |
| Assisted Pull Up | `0017` assisted pull-up | 0017 (exact 1.00) | Exact after punctuation. |
| Barbell Curl | `0031` barbell curl | 0031 (exact 1.00) | Exact name match. |
| Barbell Front Raise | `0041` barbell front raise | 0041 (exact 1.00) | Exact name match. |
| Cable Underhand Tricep Pushdown | `0207` cable reverse-grip pushdown | none | Underhand = reverse-grip cable pushdown. |
| Dip | `0251` chest dip | none | Parallel-bar dip. |
| Floor Press | **custom** | none | Two-arm barbell floor press; the library only has one-arm barbell/kettlebell versions. |
| Glute Ham Raise | `3193` glute-ham raise | 3193 (exact 1.00) | Exact after punctuation (present in library, so not custom). |
| Machine Hip Abductor | `0597` lever seated hip abduction | none | Seated hip abduction machine. |
| Machine Hip Adductor | `0598` lever seated hip adduction | none | Seated hip adduction machine. |
| Mountain Climber | `0630` mountain climber | 0630 (exact 1.00) | Exact name match. |
| Pause Back Squat | **custom** | none | Paused variant with lower loads; kept separate so it does not drag Back Squat progression. |
| Side Leg Raises | `0710` side hip abduction | none | Side hip abduction (leg raised out to the side). |
| Single Arm Kettlebell Deadlift | **custom** | none | No kettlebell deadlift in the library. |
| Straight Leg Kickback | **custom** | none | Straight-leg glute kickback; library only has triceps kickbacks. |
| Walkout | `1471` inchworm | none | A walkout is the inchworm. |
| Cable Lateral Raise | `0178` cable lateral raise | 0178 (exact 1.00) | Exact name match. |
| Dumbbell Hang Snatch | `3888` dumbbell one arm snatch | none | Single-arm dumbbell snatch from the hang. |
| Hammerstrength High Row | `0581` lever high row | none | Hammer Strength is a plate-loaded lever machine: lever high row. |
| Hand Release Push Up | **custom** | 1311 (fuzzy 0.60) | Distinct push-up variant (chest to floor, hands lifted); "wide hand push up" is a different movement. |
| Incline Back Extension | `0489` hyperextension | none | 45° back extension bench = hyperextension (the lever entry is a seated machine). |
| Plank | `2135` weighted front plank | none | Front forearm plank; imported with zero added weight and its duration. |
| Prone Y's | **custom** | none | Floor prone Y raise (bodyweight); library Y-raise uses a band or incline dumbbells. |
| Reverse Barbell Curl | `0080` barbell reverse curl | 0080 (fuzzy 1.00) | Same words, different order. |
| Running | `0685` run | none | Run (cardio). |
| Smith Machine Stiff-Legged Deadlift | `0752` smith deadlift | none | Smith deadlift, the closest equipment match; stiff-leg is a form cue. |
| Toe Touchers | **custom** | none | Lying legs-up toe reach crunch; not in the library. |
| Upright Row | `0120` barbell upright row | tie at 0.67 | Unprefixed Fitbod Upright Row is barbell (all sets weighted); matcher tied barbell vs cable. |
| Barbell Incline Bench Press | `0047` barbell incline bench press | 0047 (exact 1.00) | Exact name match. |
| Behind the Back Cable Bicep Curl | **custom** | none | Cable curl facing away from the stack; not in the library. |
| Cycling - Stationary | `2138` stationary bike run v. 3 | none | Stationary bike (equipment match). |
| Handle Band Crunch | **custom** | none | Handle Band (tube band with handles) movement: kept as its own custom exercise, as the plan specifies, so band "weights" never mix into library band/cable history. |
| High Knee | **custom** | none | Running high knees in place; the library version is wall-supported. |
| Jumping Jack | `3224` jack jump (male) | none | Jack jump = jumping jack. |
| Scapular Pull Up | `0688` scapular pull-up | 0688 (exact 1.00) | Exact after punctuation. |
| Swimming | **custom** | none | Not in the library; becomes a custom cardio exercise. |
