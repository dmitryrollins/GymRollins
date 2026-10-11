# free-exercise-db (exercise photos)

- Source: https://github.com/yuhonas/free-exercise-db
- Pinned commit: `f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5` (main, committed 2026-09-27T02:26:41Z), checked 2026-09-28
- License: **Unlicense** (public-domain dedication) — `LICENSE.md` at the pinned commit, reproduced below; GitHub's
  license API reports `Unlicense` for the repository. The README states the dataset (JSON and images) is an
  "Open Public Domain Exercise Dataset". It restructures wrkout/exercises.json, which is also Unlicense.
- What GymRollins uses: the start/end position **photos** (`exercises/<id>/0.jpg`, `1.jpg`) of the upstream entries
  listed in `ios/GymRollins/Resources/exercise-photos.json`. Nothing is bundled: the app downloads each photo on
  first view from `https://cdn.jsdelivr.net/gh/yuhonas/free-exercise-db@f00c92c7dcf1216a928a52c3706c7ce8e2f71ed5/exercises/<path>` (jsDelivr's GitHub
  mirror, pinned to the commit so the files can't change underneath us) and caches it on the device.
- Upstream names/instructions are **not** used (ours come from hasaneyldrm/exercises-dataset, MIT).
- Attribution is not required by the Unlicense; the app credits it anyway in Settings → Credits.
- Stopgap (owner decision 2026-09-28) until GymRollins' own AI-generated images/GIFs exist; those replace these
  photos through `ExerciseMediaProvider` without code changes elsewhere.
- Never used: opengym's / hasaneyldrm's images and GIFs (© Gym visual, no reuse rights).

Regenerate the mapping: `node scripts/map-exercise-photos.mjs` (review: `docs/import/exercise-photo-review.md`).

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
