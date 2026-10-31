# free-exercise-db (exercise photos)

- Source: https://github.com/yuhonas/free-exercise-db
- Pinned commit: `f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5` (main, committed 2026-09-27T02:26:41Z), checked 2026-09-28
- License: **Unlicense** (public-domain dedication) — `LICENSE.md` at the pinned commit, reproduced below; GitHub's
  license API reports `Unlicense` for the repository. The README states the dataset (JSON and images) is an
  "Open Public Domain Exercise Dataset". It restructures wrkout/exercises.json, which is also Unlicense.
- What GymRollins uses: the start/end position **photos** (`exercises/<id>/0.jpg`, `1.jpg`) of the upstream entries
  listed in `ios/GymRollins/Resources/exercise-photos.json`. The app downloads each photo on first view from
  `https://cdn.jsdelivr.net/gh/yuhonas/free-exercise-db@f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5/exercises/<path>` (jsDelivr's GitHub
  mirror, pinned to the commit so the files can't change underneath us) and caches it on the device.
- Bundled: the 43 equipment **kind photos** in `ios/GymRollins/Resources/OwnPhotos/kind-<kindId>.jpg`. Each is a copy of
  `exercises/<path>/0.jpg` at the pinned commit, resized to 800 px on the long edge. A gym listing with no photo of
  its own shows one, marked "Sample". The same files can be hosted in the `exercise-photos` bucket
  (`scripts/upload-photos.mjs`), which the app prefers. Three kinds have none: `lateral-raise-machine`, `skierg` and
  `upper-body-ergometer`.
- Upstream names/instructions are **not** used (ours come from hasaneyldrm/exercises-dataset, MIT).
- Attribution is not required by the Unlicense; the app credits it anyway in Settings → Credits.
- Stopgap (owner decision 2026-09-28) until GymRollins' own AI-generated images/GIFs exist; those replace these
  photos through `ExerciseMediaProvider` without code changes elsewhere.
- Never used: opengym's / hasaneyldrm's images and GIFs (© Gym visual, no reuse rights).

Regenerate the mapping: `node scripts/map-exercise-photos.mjs` (review: `docs/import/exercise-photo-review.md`).

## Kind photos: upstream entry per kind

Kinds named after an exercise use that exercise's entry in `exercise-photos.json` (its first frame); the rest are
direct matches. Paths are relative to `exercises/` at the pinned commit; each file is the `0.jpg` frame.

| Kind | Upstream path |
|---|---|
| `ab-crunch-machine` | `Ab_Crunch_Machine/0.jpg` |
| `ab-wheel` | `Ab_Roller/0.jpg` |
| `adjustable-bench` | `Incline_Dumbbell_Press/0.jpg` |
| `assisted-pullup-dip` | `Dip_Machine/0.jpg` |
| `back-extension` | `Hyperextensions_Back_Extensions/0.jpg` |
| `barbell` | `Barbell_Deadlift/0.jpg` |
| `bench-press-station` | `Close-Grip_Barbell_Bench_Press/0.jpg` |
| `bosu-ball` | `Bosu_Ball_Cable_Crunch_With_Side_Bends/0.jpg` |
| `cable-station` | `Cable_Crossover/0.jpg` |
| `calf-raise-machine` | `Standing_Calf_Raises/0.jpg` |
| `chest-press-machine` | `Leverage_Chest_Press/0.jpg` |
| `decline-bench` | `Decline_Barbell_Bench_Press/0.jpg` |
| `dip-station` | `Dips_-_Chest_Version/0.jpg` |
| `dumbbells` | `Arnold_Dumbbell_Press/0.jpg` |
| `elliptical` | `Elliptical_Trainer/0.jpg` |
| `ez-bar` | `EZ-Bar_Curl/0.jpg` |
| `flat-bench` | `Barbell_Bench_Press_-_Medium_Grip/0.jpg` |
| `hack-squat` | `Hack_Squat/0.jpg` |
| `hip-abductor-adductor` | `Thigh_Abductor/0.jpg` |
| `incline-bench` | `Barbell_Incline_Bench_Press_-_Medium_Grip/0.jpg` |
| `kettlebells` | `Alternating_Kettlebell_Press/0.jpg` |
| `lat-pulldown` | `Wide-Grip_Lat_Pulldown/0.jpg` |
| `leg-curl` | `Lying_Leg_Curls/0.jpg` |
| `leg-extension` | `Leg_Extensions/0.jpg` |
| `leg-press` | `Leg_Press/0.jpg` |
| `medicine-ball` | `Medicine_Ball_Chest_Pass/0.jpg` |
| `pec-deck` | `Butterfly/0.jpg` |
| `power-rack` | `Barbell_Full_Squat/0.jpg` |
| `preacher-bench` | `Preacher_Curl/0.jpg` |
| `preacher-curl-machine` | `Machine_Preacher_Curls/0.jpg` |
| `pull-up-bar` | `Pullups/0.jpg` |
| `resistance-bands` | `Band_Pull_Apart/0.jpg` |
| `seated-cable-row` | `Seated_Cable_Rows/0.jpg` |
| `seated-row-machine` | `Leverage_High_Row/0.jpg` |
| `shoulder-press-machine` | `Leverage_Shoulder_Press/0.jpg` |
| `smith-machine` | `Smith_Machine_Squat/0.jpg` |
| `stability-ball` | `Exercise_Ball_Crunch/0.jpg` |
| `stationary-bike` | `Recumbent_Bike/0.jpg` |
| `stepmill` | `Stairmaster/0.jpg` |
| `t-bar-row` | `T-Bar_Row_with_Handle/0.jpg` |
| `trap-bar` | `Trap_Bar_Deadlift/0.jpg` |
| `treadmill` | `Walking_Treadmill/0.jpg` |
| `triceps-machine` | `Machine_Triceps_Extension/0.jpg` |

## License text (LICENSE.md at `f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5`)

```
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or
distribute this software, either in source code form or as a compiled
binary, for any purpose, commercial or non-commercial, and by any
means.

In jurisdictions that recognize copyright laws, the author or authors
of this software dedicate any and all copyright interest in the
software to the public domain. We make this dedication for the benefit
of the public at large and to the detriment of our heirs and
successors. We intend this dedication to be an overt act of
relinquishment in perpetuity of all present and future rights to this
software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <https://unlicense.org>
```
