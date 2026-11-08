import { describe, expect, it } from 'vitest'
import { foldKey, isCleanText, trimmedOrNull, trimSpaces } from '../src/gyms/text.ts'

const at = (codePoint: number) => `Gym${String.fromCodePoint(codePoint)}One`

describe('clean text', () => {
  it('refuses control characters, and in text with lines allows only line breaks', () => {
    expect(isCleanText('Iron Works')).toBe(true)
    expect(isCleanText('by the door\nleft side')).toBe(false)
    expect(isCleanText('by the door\nleft side', true)).toBe(true)
    expect(isCleanText('two\r\nlines', true)).toBe(true)
    expect(isCleanText('a\tb', true)).toBe(false)
    expect(isCleanText('a\u0000b', true)).toBe(false)
    expect(isCleanText('a\u001Fb', true)).toBe(false)
  })

  it('refuses each hidden range at both ends, and takes its neighbours', () => {
    const hidden = [
      0x7f, 0x9f, 0xad, 0x34f, 0x61c, 0x115f, 0x1160, 0x17b4, 0x17b5, 0x180b, 0x180e, 0x180f, 0x200b, 0x200e, 0x200f,
      0x2028, 0x2029, 0x202e, 0x2060, 0x206f, 0x3164, 0xfe00, 0xfe0a, 0xfe0e, 0xfeff, 0xffa0, 0xfff9, 0xfffc, 0xe000,
      0xf8ff, 0x1d173, 0x1d17a, 0xe0000, 0xe0001, 0xe0080, 0xe01ef, 0xf0000, 0xffffd, 0x100000, 0x10fffd,
    ]
    const neighbours = [
      0xac, 0xae, 0x34e, 0x350, 0x115e, 0x1161, 0x17b3, 0x17b6, 0x180a, 0x1810, 0x2027, 0x202f, 0x3163, 0x3165, 0xfdff,
      0xfe10, 0xff9f, 0xffa1, 0xfffd, 0xd7ff, 0xf900, 0xeffff, 0xffffe, 0x1d172, 0x1d17b, 0xe01f0, 0x1f4aa,
    ]
    for (const cp of hidden) expect(isCleanText(at(cp)), cp.toString(16)).toBe(false)
    for (const cp of neighbours) expect(isCleanText(at(cp)), cp.toString(16)).toBe(true)
  })

  it('keeps the zero width joiners next to non-ASCII text only', () => {
    expect(isCleanText('Iron\u200DGym')).toBe(false)
    expect(isCleanText('\u200DIron')).toBe(false)
    expect(isCleanText('Gym\u200D')).toBe(false)
    expect(isCleanText('Iron\u200CGym')).toBe(false)
    expect(isCleanText('👨\u200D👩')).toBe(true)
    expect(isCleanText('\u0645\u200C\u06CC')).toBe(true)
    expect(isCleanText('Iron Gym 💪 \u0915\u094D\u200D\u0937')).toBe(true)
    expect(isCleanText('Équinoxe Fitness – 24/7 (Nørre) 健身房 Спорт-зал')).toBe(true)
  })

  it('takes U+FE0F only after non-ASCII text', () => {
    expect(isCleanText('\u2764\uFE0F')).toBe(true)
    expect(isCleanText('a\uFE0Fb')).toBe(false)
    expect(isCleanText('\uFE0Fa')).toBe(false)
    expect(isCleanText('a\uFE0F')).toBe(false)
  })

  it('refuses the line separator even where text has lines, and half of a UTF-16 pair', () => {
    expect(isCleanText('a\u2028b', true)).toBe(false)
    expect(isCleanText('a\uD800b')).toBe(false)
    expect(isCleanText('a\uDC00')).toBe(false)
    expect(isCleanText('😀')).toBe(true)
  })
})

describe('trimming and folding', () => {
  it('trims spaces only, as btrim did, and turns empty text into null', () => {
    expect(trimSpaces('  1 Main St ')).toBe('1 Main St')
    expect(trimSpaces('\tx\n')).toBe('\tx\n')
    expect(trimmedOrNull('   ')).toBeNull()
    expect(trimmedOrNull(null)).toBeNull()
    expect(trimmedOrNull(' a face ')).toBe('a face')
  })

  it('folds case in every script, where SQLite folds ASCII only', () => {
    expect(foldKey('Hammer Strength')).toBe('hammer strength')
    expect(foldKey('ÄRGER')).toBe('ärger')
    expect(foldKey('СПОРТ')).toBe('спорт')
    expect(foldKey(null)).toBeNull()
  })
})
