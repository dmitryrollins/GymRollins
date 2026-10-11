# wger.de (exercise photos and other-language names)

- Source: the public wger REST API, `https://wger.de/api/v2/` (`exerciseinfo`, `license`, `language`, `version`).
  Snapshot **2026-09-30**, server/API version `2.8.0-dev.0`; the trimmed snapshot's sha256 is in
  `docs/import/wger-review.md` (the file itself lives in the gitignored `media/wger/`).
- **Data only.** wger's application code is AGPL-3.0 (https://github.com/wger-project/wger); none of it is copied
  or linked.
- Licenses are **per item**: every exercise translation (name) and every image has its own `license` and
  `license_author`. wger offers CC-BY-SA 3.0, CC-BY-SA 4.0, CC-BY 4.0, CC0 1.0 and ODbL.
  - Used: CC-BY-SA 3.0/4.0, CC-BY 4.0 and CC0 items **with a named author**.
  - Not used: ODbL items, items without an author, and images wger flags as AI-generated.
  - Images additionally need a trusted author or an individual review (`scripts/wger-image-policy.json`): the
    uploader chooses the license, and a visual review found commercial images re-uploaded under CC licenses
    (details in `docs/import/wger-review.md`, "Image provenance"). In practice this is the Everkinetic line-art set
    (CC-BY-SA 3.0, wger's original illustrations) plus one reviewed photo.
- Obligations and how the app meets them:
  - Attribution (title, author, source, license): each photo carries its credit in
    `ios/GymRollins/Resources/wger-photos.json`; the exercise detail photo shows "Photo: <author> · <license>",
    tapping it opens the title, author, license link and wger page link. Names: author and license per name in
    `exercise-names-i18n.json`, listed under "Other names" on the exercise detail with a link to the wger page.
    Settings → Credits has the dataset-level credit.
  - Indicate changes: photos are resized/cropped for display — stated in the credit sheet ("modified").
  - ShareAlike: applies to the images/names themselves. The app does not ship copies of the images; it loads the
    originals on demand from `https://wger.de/media/...` and caches them on the device. It does not extend to the
    app's code.
- Regenerate: `node scripts/map-wger.mjs --fetch` (new snapshot), then `node scripts/map-wger.mjs`
  (review: `docs/import/wger-review.md`; tests: `node --test scripts/map-wger.test.mjs`).
