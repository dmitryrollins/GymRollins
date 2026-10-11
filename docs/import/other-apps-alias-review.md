# Strong, Hevy and FitNotes alias review

Curated decisions behind `ios/GymRollins/Resources/{strong,hevy,fitnotes}-aliases.json`, built from each app's default exercise names (not from personal exports). Every common name is listed so the importer never has to fall back to fuzzy suggestions for it.

Regenerate: `node scripts/other-apps-alias-report.mjs --out docs/import/other-apps-alias-review.md`

## Strong

- Names in `strong-aliases.json`: **85**; mapped to a library exercise: **83**; custom on import (`null`): **2**
- The matcher alone (exact, or unambiguous fuzzy >= 0.6) already agrees with the curated id for 49 names; the table overrides 8 confident-but-wrong matcher results; 28 names would be unmatched or tied without the table.

| Exported name | Curated | Matcher alone | Why |
|---|---|---|---|
| Ab Wheel | `0857` wheel rollerout | none | Kneeling ab-wheel rollout. |
| Arnold Press (Dumbbell) | `2137` dumbbell arnold press | 2137 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bench Dip | `0814` triceps dip | tie at 0.67 | Library "triceps dip" is the bench dip (Fitbod decision); fuzzy tie offered three-bench / weighted. |
| Bench Press (Barbell) | `0025` barbell bench press | 0025 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bench Press (Dumbbell) | `0289` dumbbell bench press | 0289 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bench Press (Smith Machine) | `0748` smith bench press | 0748 (fuzzy 0.75) | Matcher agrees (fuzzy 0.75); movement and equipment match. |
| Bent Over One Arm Row (Dumbbell) | `0292` dumbbell one arm bent-over row | 0292 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bent Over Row (Barbell) | `0027` barbell bent over row | 0027 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bent Over Row (Dumbbell) | `0293` dumbbell bent over row | 0293 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bicep Curl (Barbell) | `0031` barbell curl | 0023 (fuzzy 0.75) | Straight-bar two-arm curl; the matcher preferred the alternating variant. |
| Bicep Curl (Cable) | `0868` cable curl | tie at 0.75 | Standing cable curl with a bar; matcher tied lying vs pulldown curls. |
| Bicep Curl (Dumbbell) | `0294` dumbbell biceps curl | 0294 (fuzzy 1.00) | Same words, different order (or plural only). |
| Box Squat (Barbell) | `0026` barbell bench squat | none | Squat to a box/bench = barbell bench squat; not merged into full squat (lighter, paused). |
| Bulgarian Split Squat | `0410` dumbbell single leg split squat | 2368 (fuzzy 0.67) | Rear-foot-elevated split squat with dumbbells (the library entry puts the back foot on a bench); the matcher suggested the bodyweight floor split squat. |
| Cable Crossover | `0227` cable standing fly | none | Standing cable fly between two pulleys (Fitbod "Cable Crossover Fly"). |
| Cable Crunch | `0175` cable kneeling crunch | tie at 0.67 | Kneeling rope crunch at the high pulley; matcher tied kneeling vs reverse crunch. |
| Chest Dip | `0251` chest dip | 0251 (exact 1.00) | Exact name match. |
| Chest Fly (Dumbbell) | `0308` dumbbell fly | 0308 (fuzzy 0.67) | Matcher agrees (fuzzy 0.67); movement and equipment match. |
| Chest Press (Machine) | `0577` lever chest press | 1301 (fuzzy 0.75) | Selectorized seated chest press = lever chest press (0576 is a duplicate entry); "machine inner chest press" is a squeeze variant. |
| Chin Up | `1326` chin-up | 1326 (exact 1.00) | Exact name match. |
| Concentration Curl (Dumbbell) | `0297` dumbbell concentration curl | 0297 (fuzzy 1.00) | Same words, different order (or plural only). |
| Crunch | `0274` crunch floor | none | Floor crunch. |
| Cycling (Indoor) | `2138` stationary bike run v. 3 | none | Stationary bike (Fitbod "Cycling - Stationary"). |
| Deadlift (Barbell) | `0032` barbell deadlift | 0032 (fuzzy 1.00) | Same words, different order (or plural only). |
| Deadlift (Dumbbell) | `0300` dumbbell deadlift | 0300 (fuzzy 1.00) | Same words, different order (or plural only). |
| Decline Bench Press (Barbell) | `0033` barbell decline bench press | 0033 (fuzzy 1.00) | Same words, different order (or plural only). |
| Elliptical Machine | `2141` walk elliptical cross trainer | none | Elliptical cross trainer (equipment match). |
| Face Pull (Cable) | `0203` cable rear delt row (with rope) | none | Face pull = cable rear delt row with rope (Fitbod decision). |
| Front Raise (Dumbbell) | `0310` dumbbell front raise | 0310 (fuzzy 1.00) | Same words, different order (or plural only). |
| Front Squat (Barbell) | `0042` barbell front squat | 0042 (fuzzy 1.00) | Same words, different order (or plural only). |
| Goblet Squat (Kettlebell) | `0534` kettlebell goblet squat | 0534 (fuzzy 1.00) | Same words, different order (or plural only). |
| Good Morning (Barbell) | `0044` barbell good morning | 0044 (fuzzy 1.00) | Same words, different order (or plural only). |
| Hack Squat | `0743` sled hack squat | tie at 0.67 | Strong's Hack Squat is the plate-loaded hack machine (sled), not the behind-the-legs barbell lift. |
| Hammer Curl (Dumbbell) | `0313` dumbbell hammer curl | 0313 (fuzzy 1.00) | Same words, different order (or plural only). |
| Hanging Leg Raise | `0472` hanging leg raise | 0472 (exact 1.00) | Exact name match. |
| Hip Abductor (Machine) | `0597` lever seated hip abduction | none | Seated hip abduction machine (Fitbod decision). |
| Hip Adductor (Machine) | `0598` lever seated hip adduction | none | Seated hip adduction machine (Fitbod decision). |
| Hip Thrust (Barbell) | **custom** | none | Shoulders-on-bench barbell hip thrust; the library glute bridges are floor-based, loads not comparable (same call as Fitbod "Barbell Hip Thrust"). |
| Incline Bench Press (Barbell) | `0047` barbell incline bench press | 0047 (fuzzy 1.00) | Same words, different order (or plural only). |
| Incline Bench Press (Dumbbell) | `0314` dumbbell incline bench press | 0314 (fuzzy 1.00) | Same words, different order (or plural only). |
| Incline Chest Fly (Dumbbell) | `0319` dumbbell incline fly | 0319 (fuzzy 0.75) | Matcher agrees (fuzzy 0.75); movement and equipment match. |
| Jump Rope | `2612` jump rope | 2612 (exact 1.00) | Exact name match. |
| Lat Pulldown (Cable) | `0198` cable pulldown | 0198 (fuzzy 0.67) | Matcher agrees (fuzzy 0.67); movement and equipment match. |
| Lat Pulldown (Machine) | `0579` lever front pulldown | 0673 (fuzzy 0.60) | Plate-loaded pulldown machine = lever front pulldown; kept apart from the cable pulldown (0198) because loads differ. |
| Lateral Raise (Cable) | `0178` cable lateral raise | 0178 (fuzzy 1.00) | Same words, different order (or plural only). |
| Lateral Raise (Dumbbell) | `0334` dumbbell lateral raise | 0334 (fuzzy 1.00) | Same words, different order (or plural only). |
| Leg Extension (Machine) | `0585` lever leg extension | none | Machine leg extension (Fitbod decision). |
| Leg Press | `0739` sled 45° leg press | 0760 (fuzzy 0.67) | The 45° plate-loaded sled (Fitbod decision), not the Smith leg press the fuzzy match suggested. |
| Lunge (Barbell) | `0054` barbell lunge | 0054 (fuzzy 1.00) | Same words, different order (or plural only). |
| Lunge (Dumbbell) | `0336` dumbbell lunge | 0336 (fuzzy 1.00) | Same words, different order (or plural only). |
| Lying Leg Curl (Machine) | `0586` lever lying leg curl | 0586 (fuzzy 0.60) | Matcher agrees (fuzzy 0.60); movement and equipment match. |
| Mountain Climber | `0630` mountain climber | 0630 (exact 1.00) | Exact name match. |
| Overhead Press (Barbell) | `1456` barbell standing close grip military press | 0091 (fuzzy 0.75) | Standing barbell overhead press at shoulder width = standing close-grip military press (no plain standing OHP entry); the matcher's seated press is a different, lighter lift. |
| Overhead Press (Dumbbell) | `0426` dumbbell standing overhead press | 0426 (fuzzy 0.75) | Matcher agrees (fuzzy 0.75); movement and equipment match. |
| Plank | `2135` weighted front plank | none | Front forearm plank; imported with zero added weight and its duration (Fitbod decision). |
| Preacher Curl (Barbell) | `0070` barbell preacher curl | 0070 (fuzzy 1.00) | Same words, different order (or plural only). |
| Preacher Curl (Dumbbell) | `0372` dumbbell preacher curl | 0372 (fuzzy 1.00) | Same words, different order (or plural only). |
| Pull Up | `0652` pull-up | 0652 (exact 1.00) | Exact name match. |
| Pull Up (Assisted) | `0017` assisted pull-up | 0017 (fuzzy 1.00) | Same words, different order (or plural only). |
| Push Up | `0662` push-up | 0662 (exact 1.00) | Exact name match. |
| Reverse Fly (Dumbbell) | `0383` dumbbell reverse fly | 0383 (fuzzy 1.00) | Same words, different order (or plural only). |
| Romanian Deadlift (Barbell) | `0085` barbell romanian deadlift | 0085 (fuzzy 1.00) | Same words, different order (or plural only). |
| Romanian Deadlift (Dumbbell) | `1459` dumbbell romanian deadlift | 1459 (fuzzy 1.00) | Same words, different order (or plural only). |
| Rowing (Machine) | **custom** | none | No rowing ergometer in the library (only a SkiErg); becomes a custom cardio exercise. |
| Running | `0685` run | none | Run (cardio), same id as Fitbod "Running". Treadmill and outdoor runs share it; "run (equipment)" (0684) is a duplicate with identical instructions. |
| Running (Treadmill) | `0685` run | none | Run (cardio), same id as Fitbod "Running". Treadmill and outdoor runs share it; "run (equipment)" (0684) is a duplicate with identical instructions. |
| Russian Twist | `0687` russian twist | 0687 (exact 1.00) | Exact name match. |
| Seated Calf Raise (Plate Loaded) | `0594` lever seated calf raise | none | Seated calf raise machine (knee pad, plate loaded); the matcher offered barbell versions. |
| Seated Leg Curl (Machine) | `0599` lever seated leg curl | 0599 (fuzzy 0.60) | Matcher agrees (fuzzy 0.60); movement and equipment match. |
| Seated Overhead Press (Dumbbell) | `0405` dumbbell seated shoulder press | tie at 0.60 | Seated two-arm dumbbell press (same id as Fitbod "Dumbbell Shoulder Press"). |
| Seated Row (Cable) | `0861` cable seated row | 0861 (fuzzy 1.00) | Same words, different order (or plural only). |
| Shrug (Barbell) | `0095` barbell shrug | 0095 (fuzzy 1.00) | Same words, different order (or plural only). |
| Shrug (Dumbbell) | `0406` dumbbell shrug | 0406 (fuzzy 1.00) | Same words, different order (or plural only). |
| Sit Up | `0735` sit-up v. 2 | tie at 0.67 | Plain floor sit-up; the tie offered assisted / decline variants. |
| Skullcrusher (Barbell) | `0060` barbell lying triceps extension skull crusher | none | Barbell skull crusher (lying extension to the forehead), not the reverse-grip version. |
| Squat (Barbell) | `0043` barbell full squat | tie at 0.67 | Barbell back squat = barbell full squat (Fitbod "Back Squat"). |
| Standing Calf Raise (Machine) | `0605` lever standing calf raise | tie at 0.60 | Standing calf raise machine (shoulder pads); matcher tied barbell vs bodyweight. |
| Sumo Deadlift (Barbell) | `0117` barbell sumo deadlift | 0117 (fuzzy 1.00) | Same words, different order (or plural only). |
| T Bar Row | `0606` lever t bar row | 0606 (fuzzy 0.75) | Matcher agrees (fuzzy 0.75); movement and equipment match. |
| Triceps Dip | `1767` weighted triceps dip on high parallel bars | 0814 (exact 1.00) | Upright parallel-bar dip. Library "triceps dip" (0814) is the bench dip (Fitbod decision), so the exact-name hit is overridden; imported with the logged added load (0 when bodyweight). |
| Triceps Extension (Cable) | `0194` cable overhead triceps extension (rope attachment) | tie at 0.75 | Strong's cable triceps extension is overhead with a rope; matcher tied alternate vs incline versions. |
| Triceps Extension (Dumbbell) | `2188` dumbbell seated triceps extension | tie at 0.75 | Two-hand overhead dumbbell extension (Fitbod decision). |
| Triceps Pushdown (Cable - Straight Bar) | `0201` cable pushdown | 0241 (fuzzy 0.67) | Straight-bar cable pushdown; the matcher picked the V-bar version. |
| Upright Row (Barbell) | `0120` barbell upright row | 0120 (fuzzy 1.00) | Same words, different order (or plural only). |
| Walking | `3666` walking on incline treadmill | none | The library's only plain walking cardio entry (Fitbod decision). |

### Common names left unmatched

- **Hip Thrust (Barbell)**: Shoulders-on-bench barbell hip thrust; the library glute bridges are floor-based, loads not comparable (same call as Fitbod "Barbell Hip Thrust").
- **Rowing (Machine)**: No rowing ergometer in the library (only a SkiErg); becomes a custom cardio exercise.

### Rules

Same curation policy as Fitbod ([fitbod-alias-review.md](fitbod-alias-review.md), "Rules applied"): equipment and grip must match the Strong name; non-comparable loads are never merged (the odd one out is `null`); two names may share one id; timed/cardio moves may map to library cardio entries and keep their duration and distance. Where the same movement exists in the Fitbod table, the same library id is reused.

## Hevy

- Names in `hevy-aliases.json`: **85**; mapped to a library exercise: **82**; custom on import (`null`): **3**
- The matcher alone (exact, or unambiguous fuzzy >= 0.6) already agrees with the curated id for 42 names; the table overrides 8 confident-but-wrong matcher results; 35 names would be unmatched or tied without the table.

| Exported name | Curated | Matcher alone | Why |
|---|---|---|---|
| Arnold Press (Dumbbell) | `2137` dumbbell arnold press | 2137 (fuzzy 1.00) | Same words, different order (or plural only). |
| Back Extension (Hyperextension) | `0489` hyperextension | none | 45° back extension bench = hyperextension (Fitbod decision); the lever entry is a seated machine. |
| Bench Press (Barbell) | `0025` barbell bench press | 0025 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bench Press (Dumbbell) | `0289` dumbbell bench press | 0289 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bent Over Row (Barbell) | `0027` barbell bent over row | 0027 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bent Over Row (Dumbbell) | `0293` dumbbell bent over row | 0293 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bicep Curl (Barbell) | `0031` barbell curl | 0023 (fuzzy 0.75) | Straight-bar two-arm curl; the matcher preferred the alternating variant. |
| Bicep Curl (Cable) | `0868` cable curl | tie at 0.75 | Standing cable curl with a bar; matcher tied lying vs pulldown curls. |
| Bicep Curl (Dumbbell) | `0294` dumbbell biceps curl | 0294 (fuzzy 1.00) | Same words, different order (or plural only). |
| Bulgarian Split Squat | `0410` dumbbell single leg split squat | 2368 (fuzzy 0.67) | Rear-foot-elevated split squat with dumbbells (the library entry puts the back foot on a bench); the matcher suggested the bodyweight floor split squat. |
| Cable Crunch | `0175` cable kneeling crunch | tie at 0.67 | Kneeling rope crunch at the high pulley; matcher tied kneeling vs reverse crunch. |
| Cable Fly Crossovers | `0227` cable standing fly | none | Standing cable fly between two pulleys (Fitbod "Cable Crossover Fly"). |
| Calf Press (Machine) | `2289` lever calf press | none | Calf press on a machine = lever calf press (not the seated calf press). |
| Chest Dip | `0251` chest dip | 0251 (exact 1.00) | Exact name match. |
| Chest Fly (Dumbbell) | `0308` dumbbell fly | 0308 (fuzzy 0.67) | Matcher agrees (fuzzy 0.67); movement and equipment match. |
| Chest Fly (Machine) | `0596` lever seated fly | none | Pec deck = lever seated fly. |
| Chest Press (Machine) | `0577` lever chest press | 1301 (fuzzy 0.75) | Selectorized seated chest press = lever chest press (0576 is a duplicate entry); "machine inner chest press" is a squeeze variant. |
| Chin Up | `1326` chin-up | 1326 (exact 1.00) | Exact name match. |
| Crunch | `0274` crunch floor | none | Floor crunch. |
| Cycling | `2138` stationary bike run v. 3 | none | The library's only cycling cardio entry (stationary bike); imported as cardio duration/distance. |
| Dead Bug | `0276` dead bug | 0276 (exact 1.00) | Exact name match. |
| Deadlift (Barbell) | `0032` barbell deadlift | 0032 (fuzzy 1.00) | Same words, different order (or plural only). |
| Decline Bench Press (Barbell) | `0033` barbell decline bench press | 0033 (fuzzy 1.00) | Same words, different order (or plural only). |
| Dumbbell Row | `0292` dumbbell one arm bent-over row | tie at 0.67 | Single-arm dumbbell row (Fitbod decision); matcher tied incline vs upright row. |
| Elliptical Trainer | `2141` walk elliptical cross trainer | none | Elliptical cross trainer (equipment match). |
| EZ Bar Biceps Curl | `0447` ez barbell curl | none | EZ-bar curl; the arm-blaster version is a different setup. |
| Face Pull | `0203` cable rear delt row (with rope) | none | Hevy's Face Pull is cable with rope = cable rear delt row (with rope) (Fitbod decision). |
| Front Raise (Dumbbell) | `0310` dumbbell front raise | 0310 (fuzzy 1.00) | Same words, different order (or plural only). |
| Front Squat | `0042` barbell front squat | tie at 0.67 | Hevy's Front Squat is barbell; matcher tied barbell vs kettlebell. |
| Goblet Squat | `1760` dumbbell goblet squat | tie at 0.67 | Hevy logs Goblet Squat with a dumbbell (Fitbod decision); matcher tied dumbbell vs kettlebell. |
| Good Morning (Barbell) | `0044` barbell good morning | 0044 (fuzzy 1.00) | Same words, different order (or plural only). |
| Hack Squat (Machine) | `0743` sled hack squat | none | Plate-loaded hack squat machine (sled), not the barbell hack squat. |
| Hammer Curl (Dumbbell) | `0313` dumbbell hammer curl | 0313 (fuzzy 1.00) | Same words, different order (or plural only). |
| Hanging Leg Raise | `0472` hanging leg raise | 0472 (exact 1.00) | Exact name match. |
| Hip Abduction (Machine) | `0597` lever seated hip abduction | none | Seated hip abduction machine (Fitbod decision). |
| Hip Adduction (Machine) | `0598` lever seated hip adduction | none | Seated hip adduction machine (Fitbod decision). |
| Hip Thrust (Barbell) | **custom** | none | Shoulders-on-bench barbell hip thrust; the library glute bridges are floor-based, loads not comparable (same call as Fitbod "Barbell Hip Thrust"). |
| Incline Bench Press (Barbell) | `0047` barbell incline bench press | 0047 (fuzzy 1.00) | Same words, different order (or plural only). |
| Incline Bench Press (Dumbbell) | `0314` dumbbell incline bench press | 0314 (fuzzy 1.00) | Same words, different order (or plural only). |
| Incline Chest Fly (Dumbbell) | `0319` dumbbell incline fly | 0319 (fuzzy 0.75) | Matcher agrees (fuzzy 0.75); movement and equipment match. |
| Jump Rope | `2612` jump rope | 2612 (exact 1.00) | Exact name match. |
| Lat Pulldown (Cable) | `0198` cable pulldown | 0198 (fuzzy 0.67) | Matcher agrees (fuzzy 0.67); movement and equipment match. |
| Lat Pulldown (Machine) | `0579` lever front pulldown | 0673 (fuzzy 0.60) | Plate-loaded pulldown machine = lever front pulldown; kept apart from the cable pulldown (0198) because loads differ. |
| Lateral Raise (Cable) | `0178` cable lateral raise | 0178 (fuzzy 1.00) | Same words, different order (or plural only). |
| Lateral Raise (Dumbbell) | `0334` dumbbell lateral raise | 0334 (fuzzy 1.00) | Same words, different order (or plural only). |
| Leg Extension (Machine) | `0585` lever leg extension | none | Machine leg extension (Fitbod decision). |
| Leg Press (Machine) | `0739` sled 45° leg press | none | Hevy's Leg Press (Machine) is the 45° sled (it has a separate "Leg Press Horizontal"). |
| Lunge (Dumbbell) | `0336` dumbbell lunge | 0336 (fuzzy 1.00) | Same words, different order (or plural only). |
| Lying Leg Curl (Machine) | `0586` lever lying leg curl | 0586 (fuzzy 0.60) | Matcher agrees (fuzzy 0.60); movement and equipment match. |
| Lying Leg Raise | `0620` lying leg raise flat bench | 0865 (fuzzy 0.75) | Lying leg raise on a flat bench/floor; not the leg-hip raise variant. |
| Mountain Climber | `0630` mountain climber | 0630 (exact 1.00) | Exact name match. |
| Overhead Press (Barbell) | `1456` barbell standing close grip military press | 0091 (fuzzy 0.75) | Standing barbell overhead press at shoulder width = standing close-grip military press (no plain standing OHP entry); the matcher's seated press is a different, lighter lift. |
| Overhead Triceps Extension (Cable) | `0194` cable overhead triceps extension (rope attachment) | tie at 0.67 | Overhead cable extension with rope (Fitbod "Cable Rope Overhead Triceps Extension"); matcher tied high-pulley vs rope. |
| Plank | `2135` weighted front plank | none | Front forearm plank; imported with zero added weight and its duration (Fitbod decision). |
| Preacher Curl (Barbell) | `0070` barbell preacher curl | 0070 (fuzzy 1.00) | Same words, different order (or plural only). |
| Pull Up | `0652` pull-up | 0652 (exact 1.00) | Exact name match. |
| Pull Up (Assisted) | `0017` assisted pull-up | 0017 (fuzzy 1.00) | Same words, different order (or plural only). |
| Push Up | `0662` push-up | 0662 (exact 1.00) | Exact name match. |
| Rear Delt Reverse Fly (Dumbbell) | `0383` dumbbell reverse fly | tie at 0.60 | Bent-over dumbbell reverse fly (Fitbod decision). |
| Romanian Deadlift (Barbell) | `0085` barbell romanian deadlift | 0085 (fuzzy 1.00) | Same words, different order (or plural only). |
| Romanian Deadlift (Dumbbell) | `1459` dumbbell romanian deadlift | 1459 (fuzzy 1.00) | Same words, different order (or plural only). |
| Rowing Machine | **custom** | none | No rowing ergometer in the library (only a SkiErg); becomes a custom cardio exercise. |
| Running | `0685` run | none | Run (cardio), same id as Fitbod "Running". Treadmill and outdoor runs share it; "run (equipment)" (0684) is a duplicate with identical instructions. |
| Russian Twist | `0687` russian twist | 0687 (exact 1.00) | Exact name match. |
| Seated Cable Row - V Grip (Cable) | `0861` cable seated row | 0218 (fuzzy 0.67) | Seated cable row with the V handle (Fitbod "Cable Row"), not wide grip. |
| Seated Calf Raise | `0594` lever seated calf raise | tie at 0.75 | Seated calf raise machine (knee pad, plate loaded); the matcher offered barbell versions. |
| Seated Leg Curl (Machine) | `0599` lever seated leg curl | 0599 (fuzzy 0.60) | Matcher agrees (fuzzy 0.60); movement and equipment match. |
| Seated Overhead Press (Barbell) | `0091` barbell seated overhead press | 0091 (fuzzy 1.00) | Same words, different order (or plural only). |
| Seated Row (Machine) | `1350` lever seated row | none | Plate/selectorized seated row machine = lever seated row; kept apart from cable row. |
| Shoulder Press (Dumbbell) | `0405` dumbbell seated shoulder press | 0405 (fuzzy 0.75) | Matcher agrees (fuzzy 0.75); movement and equipment match. |
| Shrug (Barbell) | `0095` barbell shrug | 0095 (fuzzy 1.00) | Same words, different order (or plural only). |
| Shrug (Dumbbell) | `0406` dumbbell shrug | 0406 (fuzzy 1.00) | Same words, different order (or plural only). |
| Skullcrusher (Barbell) | `0060` barbell lying triceps extension skull crusher | none | Barbell skull crusher (lying extension to the forehead), not the reverse-grip version. |
| Squat (Barbell) | `0043` barbell full squat | tie at 0.67 | Barbell back squat = barbell full squat (Fitbod "Back Squat"). |
| Standing Calf Raise (Machine) | `0605` lever standing calf raise | tie at 0.60 | Standing calf raise machine (shoulder pads); matcher tied barbell vs bodyweight. |
| T Bar Row | `0606` lever t bar row | 0606 (fuzzy 0.75) | Matcher agrees (fuzzy 0.75); movement and equipment match. |
| Treadmill | `0685` run | none | Hevy "Treadmill" is a treadmill run; shares the run id. Treadmill walks log under "Walking". |
| Triceps Dip | `1767` weighted triceps dip on high parallel bars | 0814 (exact 1.00) | Upright parallel-bar dip. Library "triceps dip" (0814) is the bench dip (Fitbod decision), so the exact-name hit is overridden; imported with the logged added load (0 when bodyweight). |
| Triceps Extension (Cable) | **custom** | tie at 0.75 | Ambiguous: Hevy lists a separate overhead variant and a pushdown, so this one stays custom rather than merging its loads into either history. |
| Triceps Kickback (Dumbbell) | `0333` dumbbell kickback | 0333 (fuzzy 0.67) | Matcher agrees (fuzzy 0.67); movement and equipment match. |
| Triceps Pushdown | `0201` cable pushdown | none | Hevy's default pushdown uses a straight bar = cable pushdown (Fitbod decision). |
| Triceps Rope Pushdown | `0200` cable pushdown (with rope attachment) | none | Rope pushdown (Fitbod "Cable Rope Tricep Extension"). |
| Upright Row (Barbell) | `0120` barbell upright row | 0120 (fuzzy 1.00) | Same words, different order (or plural only). |
| Walking | `3666` walking on incline treadmill | none | The library's only plain walking cardio entry (Fitbod decision). |
| Walking Lunge | `1460` walking lunge | 1460 (exact 1.00) | Exact name match. |

### Common names left unmatched

- **Hip Thrust (Barbell)**: Shoulders-on-bench barbell hip thrust; the library glute bridges are floor-based, loads not comparable (same call as Fitbod "Barbell Hip Thrust").
- **Rowing Machine**: No rowing ergometer in the library (only a SkiErg); becomes a custom cardio exercise.
- **Triceps Extension (Cable)**: Ambiguous: Hevy lists a separate overhead variant and a pushdown, so this one stays custom rather than merging its loads into either history.

### Rules

Same curation policy as Fitbod ([fitbod-alias-review.md](fitbod-alias-review.md), "Rules applied"): equipment and grip must match the Hevy name; non-comparable loads are never merged (the odd one out is `null`); two names may share one id; timed/cardio moves may map to library cardio entries and keep their duration and distance. Where the same movement exists in the Fitbod table, the same library id is reused.

## FitNotes

- Names in `fitnotes-aliases.json`: **54**; mapped to a library exercise: **52**; custom on import (`null`): **2**
- The matcher alone (exact, or unambiguous fuzzy >= 0.6) already agrees with the curated id for 25 names; the table overrides 2 confident-but-wrong matcher results; 27 names would be unmatched or tied without the table.

| Exported name | Curated | Matcher alone | Why |
|---|---|---|---|
| Ab-Wheel Rollout | `0857` wheel rollerout | none | Kneeling ab-wheel rollout. |
| Arnold Dumbbell Press | `2137` dumbbell arnold press | 2137 (fuzzy 1.00) | Same words, different order (or plural only). |
| Barbell Curl | `0031` barbell curl | 0031 (exact 1.00) | Exact name match. |
| Barbell Front Squat | `0042` barbell front squat | 0042 (exact 1.00) | Exact name match. |
| Barbell Row | `0027` barbell bent over row | tie at 0.67 | FitNotes Barbell Row is the bent-over row; matcher tied incline vs Pendlay row. |
| Barbell Shrug | `0095` barbell shrug | 0095 (exact 1.00) | Exact name match. |
| Barbell Squat | `0043` barbell full squat | tie at 0.67 | Barbell back squat = barbell full squat (Fitbod "Back Squat"). |
| Cable Crossover | `0227` cable standing fly | none | Standing cable fly between two pulleys (Fitbod "Cable Crossover Fly"). |
| Cable Crunch | `0175` cable kneeling crunch | tie at 0.67 | Kneeling rope crunch at the high pulley; matcher tied kneeling vs reverse crunch. |
| Cable Curl | `0868` cable curl | 0868 (exact 1.00) | Exact name match. |
| Chin Up | `1326` chin-up | 1326 (exact 1.00) | Exact name match. |
| Close Grip Barbell Bench Press | `0030` barbell close-grip bench press | 0030 (fuzzy 1.00) | Same words, different order (or plural only). |
| Crunch | `0274` crunch floor | none | Floor crunch. |
| Cycling | `2138` stationary bike run v. 3 | none | FitNotes default cardio "Cycling"; the library's only cycling entry is the stationary bike. |
| Deadlift | `0032` barbell deadlift | none | FitNotes Deadlift is barbell (Fitbod decision). |
| Decline Barbell Bench Press | `0033` barbell decline bench press | 0033 (fuzzy 1.00) | Same words, different order (or plural only). |
| Dumbbell Concentration Curl | `0297` dumbbell concentration curl | 0297 (exact 1.00) | Exact name match. |
| Dumbbell Curl | `0294` dumbbell biceps curl | tie at 0.67 | Two-arm standing dumbbell biceps curl; matcher tied with concentration curl. |
| Dumbbell Hammer Curl | `0313` dumbbell hammer curl | 0313 (exact 1.00) | Exact name match. |
| Dumbbell Row | `0292` dumbbell one arm bent-over row | tie at 0.67 | Single-arm dumbbell row (Fitbod decision); matcher tied incline vs upright row. |
| EZ-Bar Curl | `0447` ez barbell curl | none | EZ-bar curl. |
| Flat Barbell Bench Press | `0025` barbell bench press | 0025 (fuzzy 0.75) | Matcher agrees (fuzzy 0.75); movement and equipment match. |
| Flat Dumbbell Bench Press | `0289` dumbbell bench press | 0289 (fuzzy 0.75) | Matcher agrees (fuzzy 0.75); movement and equipment match. |
| Flat Dumbbell Fly | `0308` dumbbell fly | 0308 (fuzzy 0.67) | Matcher agrees (fuzzy 0.67); movement and equipment match. |
| Front Dumbbell Raise | `0310` dumbbell front raise | 0310 (fuzzy 1.00) | Same words, different order (or plural only). |
| Hanging Leg Raise | `0472` hanging leg raise | 0472 (exact 1.00) | Exact name match. |
| Incline Barbell Bench Press | `0047` barbell incline bench press | 0047 (fuzzy 1.00) | Same words, different order (or plural only). |
| Incline Dumbbell Bench Press | `0314` dumbbell incline bench press | 0314 (fuzzy 1.00) | Same words, different order (or plural only). |
| Incline Dumbbell Fly | `0319` dumbbell incline fly | 0319 (fuzzy 1.00) | Same words, different order (or plural only). |
| Lat Pulldown | `0198` cable pulldown | none | Standard cable lat pulldown (Fitbod decision). |
| Lateral Dumbbell Raise | `0334` dumbbell lateral raise | 0334 (fuzzy 1.00) | Same words, different order (or plural only). |
| Leg Extension Machine | `0585` lever leg extension | none | Machine leg extension (Fitbod decision). |
| Leg Press | `0739` sled 45° leg press | 0760 (fuzzy 0.67) | The 45° plate-loaded sled (Fitbod decision), not the Smith leg press the fuzzy match suggested. |
| Lying Leg Curl Machine | `0586` lever lying leg curl | 0586 (fuzzy 0.60) | Matcher agrees (fuzzy 0.60); movement and equipment match. |
| Lying Triceps Extension | `0061` barbell lying triceps extension | tie at 0.75 | FitNotes files it under barbell/EZ-bar; mapped to the barbell lying extension. |
| Overhead Press | `1456` barbell standing close grip military press | none | Standing barbell overhead press at shoulder width = standing close-grip military press (no plain standing OHP entry); the matcher's seated press is a different, lighter lift. |
| Parallel Bar Triceps Dip | `1767` weighted triceps dip on high parallel bars | none | Upright parallel-bar dip. Library "triceps dip" (0814) is the bench dip (Fitbod decision), so the exact-name hit is overridden; imported with the logged added load (0 when bodyweight). |
| Plank | `2135` weighted front plank | none | Front forearm plank; imported with zero added weight and its duration (Fitbod decision). |
| Pull Up | `0652` pull-up | 0652 (exact 1.00) | Exact name match. |
| Push Press | **custom** | 1700 (fuzzy 0.67) | FitNotes Push Press is barbell; the library only has dumbbell/kettlebell push presses, loads not comparable. |
| Romanian Deadlift | `0085` barbell romanian deadlift | tie at 0.67 | FitNotes RDL is barbell (Fitbod decision); matcher tied barbell vs dumbbell. |
| Rope Push Down | `0200` cable pushdown (with rope attachment) | none | Rope pushdown (Fitbod "Cable Rope Tricep Extension"). |
| Rowing Machine | **custom** | none | No rowing ergometer in the library (only a SkiErg); becomes a custom cardio exercise. |
| Running (Treadmill) | `0685` run | none | Run (cardio), same id as Fitbod "Running". Treadmill and outdoor runs share it; "run (equipment)" (0684) is a duplicate with identical instructions. |
| Seated Cable Row | `0861` cable seated row | 0861 (fuzzy 1.00) | Same words, different order (or plural only). |
| Seated Calf Raise Machine | `0594` lever seated calf raise | tie at 0.60 | Seated calf raise machine (knee pad, plate loaded); the matcher offered barbell versions. |
| Seated Dumbbell Press | `0405` dumbbell seated shoulder press | tie at 0.75 | Seated two-arm dumbbell shoulder press (Fitbod "Dumbbell Shoulder Press"). |
| Seated Leg Curl Machine | `0599` lever seated leg curl | 0599 (fuzzy 0.60) | Matcher agrees (fuzzy 0.60); movement and equipment match. |
| Seated Machine Fly | `0596` lever seated fly | none | Pec deck = lever seated fly. |
| Standing Calf Raise Machine | `0605` lever standing calf raise | tie at 0.60 | Standing calf raise machine (shoulder pads); matcher tied barbell vs bodyweight. |
| Sumo Deadlift | `0117` barbell sumo deadlift | 0117 (fuzzy 0.67) | Matcher agrees (fuzzy 0.67); movement and equipment match. |
| T-Bar Row | `0606` lever t bar row | 0606 (fuzzy 0.75) | Matcher agrees (fuzzy 0.75); movement and equipment match. |
| V-Bar Push Down | `0241` cable triceps pushdown (v-bar) | none | Cable pushdown with a V-bar. |
| Walking | `3666` walking on incline treadmill | none | The library's only plain walking cardio entry (Fitbod decision). |

### Common names left unmatched

- **Push Press**: FitNotes Push Press is barbell; the library only has dumbbell/kettlebell push presses, loads not comparable.
- **Rowing Machine**: No rowing ergometer in the library (only a SkiErg); becomes a custom cardio exercise.

### Rules

Same curation policy as Fitbod ([fitbod-alias-review.md](fitbod-alias-review.md), "Rules applied"): equipment and grip must match the FitNotes name; non-comparable loads are never merged (the odd one out is `null`); two names may share one id; timed/cardio moves may map to library cardio entries and keep their duration and distance. Where the same movement exists in the Fitbod table, the same library id is reused.
