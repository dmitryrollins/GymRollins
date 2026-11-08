import { RowError } from '../sync/columns.ts'

// The text rules on shared gym data (gym_private.clean_text, supabase/migrations/20261030000001_gyms.sql), and the
// trimming and case folding the sharing functions did. D1's CHECKs keep only the control-character part: SQLite has no
// Unicode classes, and its lower() folds ASCII only.

/** Control characters. U+0000 is refused too: Postgres couldn't hold it, and D1's length() stops at it. */
const CONTROL = /[\u0000-\u001F]/
/** In text that has lines (notes), only \n and \r are allowed; a tab is not, as in clean_text(t, true). */
const CONTROL_IN_LINES = /[\u0000-\u0009\u000B\u000C\u000E-\u001F]/

/**
 * What the eye can't see but a model can read, code point for code point as clean_text lists it: C1 controls, the soft
 * hyphen, the combining grapheme joiner, the Arabic letter mark, the Hangul and Khmer fillers, the Mongolian variation
 * selectors, the zero width space, the direction marks, the line and paragraph separators and the bidi embeddings, the
 * word joiner and invisible operators, variation selectors 1–15, the BOM, the interlinear annotation marks, the object
 * replacement character, the private use areas, the musical formatting characters and the tag characters.
 */
const HIDDEN = new RegExp(
  '[\\u007F-\\u009F\\u00AD\\u034F\\u061C\\u115F\\u1160\\u17B4\\u17B5\\u180B-\\u180F\\u200B\\u200E\\u200F' +
    '\\u2028-\\u202E\\u2060-\\u206F\\u3164\\uFE00-\\uFE0E\\uFEFF\\uFFA0\\uFFF9-\\uFFFC\\uE000-\\uF8FF' +
    '\\u{1D173}-\\u{1D17A}\\u{E0000}-\\u{E01EF}\\u{F0000}-\\u{FFFFD}\\u{100000}-\\u{10FFFD}]',
  'u',
)

/**
 * U+200C and U+200D (the zero width joiners) are also emoji and script characters, so they stay next to non-ASCII text;
 * between ASCII letters or at an edge they can only hide something. U+FE0F stays only after the character it applies to.
 */
const LOOSE_JOINER = /(^|[\u0001-\u007F])[\u200C\u200D\uFE0F]|[\u200C\u200D]([\u0001-\u007F]|$)/u

/** Half of a UTF-16 pair. */
const LONE_SURROGATE = /[\uD800-\uDFFF]/u

/** clean_text(t, lines). */
export function isCleanText(text: string, lines = false): boolean {
  return !(lines ? CONTROL_IN_LINES : CONTROL).test(text) && !HIDDEN.test(text) && !LOOSE_JOINER.test(text) &&
    !LONE_SURROGATE.test(text)
}

/** Refuses shared text that breaks clean_text: 422 row_rejected, as the CHECK's 23514 was. */
export function requireCleanText(text: string | null, name: string, lines = false): void {
  if (text !== null && !isCleanText(text, lines)) throw new RowError(`${name} has hidden or control characters`)
}

/** btrim(t): spaces only, as Postgres's btrim with no characters given. */
export const trimSpaces = (text: string) => text.replace(/^ +| +$/g, '')

/** nullif(btrim(t), ''). */
export function trimmedOrNull(text: string | null | undefined): string | null {
  if (text === null || text === undefined) return null
  const trimmed = trimSpaces(text)
  return trimmed === '' ? null : trimmed
}

/**
 * The catalogue's identity key for a brand or model (lower() as Postgres did it, for every script). JavaScript lowers
 * a word-final Σ to ς, which Postgres didn't, so ς becomes σ: "ΟΔΟΣ" and "οδοσ" are one key.
 */
export const foldKey = (text: string | null): string | null =>
  text === null ? null : text.toLowerCase().replaceAll('ς', 'σ')
