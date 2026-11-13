# hasaneyldrm/exercises-dataset (exercise names, muscles, equipment and instructions)

- Source: https://github.com/hasaneyldrm/exercises-dataset
- Pinned commit: `7455efae41b330c265e7cd4b78dfa848e7ce5ebd` (main, committed 2026-07-16), checked 2026-11-13
- License: **MIT** for the code, tooling, dataset structure and instruction text, with a media exception. It's the
  `LICENSE` at the pinned commit, reproduced below. GitHub's license API reports `NOASSERTION` because of the exception.
- What GymRollins uses: from `data/exercises.json`, each exercise's id, name, body part, equipment, target, muscle
  group, secondary muscles and English instruction steps. That's 1324 exercises in
  `ios/GymRollins/Resources/exercises.json`, built by `scripts/build-exercise-library.mjs`. The server's exercise
  seed (`server/migrations/0003_seed_exercises.sql`) is generated from that file by `scripts/gen-exercise-seed.mjs`.
- Modifications: keys are shortened (`n`, `bp`, `eq`, `tg`, `mg`, `sm`, `st`); only the English instructions are
  kept; a broken degree sign (`в°`) is fixed and text is trimmed.
- Never used: the `images/` and `videos/` media, which are © Gym visual and outside the MIT license. The same goes for
  the `image`, `gif_url`, `media_id` and `attribution` fields that point to that media. Exercise photos come from
  free-exercise-db and wger (`free-exercise-db.md`, `wger.md`).
- Attribution: Settings → Credits (`ios/GymRollins/Resources/CREDITS.md`), `exercises-dataset-LICENSE.txt` in the
  app bundle, and this file.
- Checked 2026-11-13: rebuilding from the pinned commit gives a byte-for-byte copy of the bundled `exercises.json`.
  None of it comes from openGym, which also uses this dataset.

Regenerate: `node scripts/build-exercise-library.mjs`, then `node scripts/map-exercise-photos.mjs` and
`node scripts/gen-exercise-seed.mjs`.

## License text (LICENSE at `7455efae41b330c265e7cd4b78dfa848e7ce5ebd`)

```
MIT License

Copyright (c) 2026 Hasan Emir Yıldırım

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation and data files (the "Software"),
to deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

------------------------------------------------------------------------------
MEDIA EXCEPTION
------------------------------------------------------------------------------

The MIT license above covers ONLY the code, tooling, dataset structure, and
instruction text/translations in this repository.

It DOES NOT cover the exercise media in the `images/` and `videos/`
directories. That media is © Gym visual (https://gymvisual.com/) and is
included here with the rights holder's written permission, at 180×180
resolution, and must retain the attribution "© Gym visual —
https://gymvisual.com/". Its use and reuse are governed by Gym visual's Terms
& Conditions (https://gymvisual.com/content/3-terms-and-conditions-of-use) and
by `NOTICE.md` in this repository — NOT by the MIT license above. Cloning this
repository does not grant you any license to the media; obtain your own from
Gym visual.
```
