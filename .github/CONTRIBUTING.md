# Contributing to GymRollins

Thanks for helping. A few things to know before you open a pull request.

## License of your contribution

GymRollins is open source under the AGPLv3, with some files under the GymRollins Commercial License (see
[LICENSE](../LICENSE)). Before a pull request can be merged you sign the
[Contributor License Agreement](CLA.md) once: the CLA Assistant bot comments on your first pull request and
tells you what to reply. The CLA lets the maintainer ship your code in the App Store build and in paid tiers;
you keep the copyright to your work.

Do not contribute to files marked `@license Pro` unless asked; changes there fall under the Commercial License.

## Before you open a pull request

- Read `README.md` (architecture, quick start, tests) and `docs/specs/` for the design.
- Keep changes focused: one feature or fix per pull request.
- Add or update tests, and run the suites listed under "Test" in `README.md`.
- Never commit secrets, `.env` files, `ios/Config/Local.xcconfig`, or personal workout exports.
- Commit messages follow Conventional Commits: `feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`.

## Data and assets

Third-party data needs a license that allows commercial use, and a note in `docs/licenses/` plus a line in
`ios/GymRollins/Resources/CREDITS.md`. Do not add images or data you cannot show the license for.

## Questions and bugs

Open a GitHub issue. For security problems, do not open a public issue; use GitHub's
"Report a vulnerability" (Security tab) instead.
