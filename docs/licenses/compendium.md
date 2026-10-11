# 2024 Adult Compendium of Physical Activities (MET values)

- Source: https://pacompendium.com/adult-compendium/ (activity tables under Conditioning Exercise, Running,
  Bicycling and Walking), fetched 2026-09-30.
- Citation: Herrmann SD, Willis EA, Ainsworth BE, Barreira TV, Hastert M, Kracht CL, Schuna Jr. JM, Cai Z, Quan M,
  Tudor-Locke C, Whitt-Glover MC, Jacobs DR. 2024 Adult Compendium of Physical Activities: A third update of the
  energy costs of human activities. *Journal of Sport and Health Science*, 2024;13(1): 6-12.
- Terms of use, quoted from https://pacompendium.com/ (checked 2026-09-30):
  > The Adult, Older Adult, and Wheelchair Compendia are free to use for commercial purposes. […] Please do not
  > change MET values or combine activities with different MET levels. Please cite the Compendium website or
  > publication(s).
- What GymRollins uses: 25 activity codes with their published MET values and descriptions, copied unaltered into
  `ios/GymRollins/Resources/met-values.json` (which also carries the citation and terms). Each part of a workout
  keeps its own activity's MET; activities are never averaged into a new MET value — the estimate is the sum of
  `MET × body weight (kg) × hours` per activity. The rules that pick an activity are in
  `docs/plans/2026-09-30-plan-15-health.md`.
- The app cites the Compendium in the calorie info sheet and in Settings → Credits (`CREDITS.md`).
