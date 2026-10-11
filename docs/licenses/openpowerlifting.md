# OpenPowerlifting (strength-level standards)

- Source: https://www.openpowerlifting.org — bulk data from https://openpowerlifting.org/data, file
  `https://openpowerlifting.gitlab.io/opl-csv/files/openpowerlifting-latest.zip` (`last-modified` 2026-09-26),
  downloaded 2026-09-29. Archive: `openpowerlifting-2026-09-26/openpowerlifting-2026-09-26-f231b4f6.csv`
  (4,036,909 rows), zip sha256 `32a90763bff87e3e88174cae0dab0c5ee0b178b0db0cbee6027accdd5f350f98`, CSV sha256
  `64e9b473ee376164c9da5adf0a1af54730aeb79bc67a5705a9df1a867e887724`.
- License: **public domain**. The opl-data repository README ("Data Licensing", https://gitlab.com/openpowerlifting/opl-data):
  "OpenPowerlifting data (`*.csv`) under `meet-data/` is contributed to the public domain." The bulk archive's
  `LICENSE.txt` is reproduced below. The project's code is AGPLv3: **none of it is used, copied or linked** —
  GymRollins only reads the CSV with its own script.
- What GymRollins uses: `scripts/build-strength-standards.mjs` reduces the CSV to percentile curves (raw
  equipment, one best result per lifter per lift, sex × age group × 5 kg bodyweight bins, smoothed) in
  `ios/GymRollins/Resources/strength-standards.json` (a copy in `supabase/functions/_shared/` for the MCP
  server). No lifter names or individual rows are shipped. Filters and method: the JSON's `method` field and
  `docs/plans/2026-09-29-plan-14-strength-levels.md`.
- Attribution (not required, requested by the project): Settings → Credits (`ios/GymRollins/Resources/CREDITS.md`)
  and the strength-level method sheet: "Strength standards derived from OpenPowerlifting data, public domain."

Regenerate: download and unzip the archive outside the repo, then
`node scripts/build-strength-standards.mjs --csv <path>/openpowerlifting-YYYY-MM-DD-*.csv`
(tests: `node --test scripts/build-strength-standards.test.mjs`). Update the version, date and hashes above.

## LICENSE.txt (in `openpowerlifting-latest.zip`, 2026-09-26)

```
-- Public Domain

  OpenPowerlifting is a public-benefit archive of historical sports
data. OpenPowerlifting data is contributed to the public domain.

-- Related and Neighboring Rights

  The OpenPowerlifting database contains facts that, in and of
themselves, are not protected by copyright law. However, the copyright
laws of some jurisdictions may cover database design and structure.

  To the extent possible under law, all CSV data is waived of all
copyright and related or neighboring rights. The work is published
from the United States.

-- Attribution

  Although you are under no requirement to do so, if you incorporate
OpenPowerlifting data into your project, please consider adding a
statement of attribution so that people may know about this project
and help contribute data.

  Sample attribution text:

This page uses data from the OpenPowerlifting project, https://www.openpowerlifting.org.
You may download a copy of the data at https://gitlab.com/openpowerlifting/opl-data.

  If you modify the data or add useful new data, please consider
contributing the changes back so the entire powerlifting community
may benefit.
```
