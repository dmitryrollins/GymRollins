# react-native-body-highlighter (recovery map figure and muscle badges)

- Source: https://github.com/HichamELBSI/react-native-body-highlighter
- Pinned commit: `8ed39ac2ae9cb46fb79d77eedec7e5b029a75174` (main, committed 2026-09-13), checked 2026-10-03
- License: **MIT** — `LICENSE` at the pinned commit, reproduced below; GitHub's license API reports `MIT`.
- What GymRollins uses: the SVG path data of the male figure — the muscle and body parts in
  `assets/bodyFront.ts` / `assets/bodyBack.ts` and the two body outlines in `components/SvgMaleWrapper.tsx` —
  extracted by `scripts/build-body-map.mjs` into `ios/GymRollins/Resources/body-map.json`. The script reads the
  files as text (it never runs them); the app parses the paths itself (`SVGPath.swift`). None of the library's
  code is used and it is not an npm dependency.
- Modifications: paths are rewritten as absolute move/line/cubic commands (arcs and quadratic curves converted to
  cubics, coordinates rounded to 0.01); each part's pieces are merged per side; the largest "upper-back" piece is
  named "lats" and the smaller "gluteal" piece "gluteus-medius"; view boxes are cropped to the figure. The app groups
  parts into its own 16 muscle groups (`BodyMapRegions` in `BodyMapShapes.swift`).
- Attribution: Settings → Credits (`ios/GymRollins/Resources/CREDITS.md`), `body-highlighter-LICENSE.txt` in the
  app bundle, and this file.
- Replaces vulovix/body-muscles (Apache-2.0), used until 2026-10-03.

Regenerate: `node scripts/build-body-map.mjs` (tests: `node --test scripts/build-body-map.test.mjs`).

## License text (LICENSE at `8ed39ac2ae9cb46fb79d77eedec7e5b029a75174`)

```
MIT License

Copyright (c) 2022 ELABBASSI Hicham

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
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
```
