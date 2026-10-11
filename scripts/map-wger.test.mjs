// Unit tests for the wger mapper: node --test scripts/map-wger.test.mjs
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  buildNames, buildPhotos, buildWgerMapping, musclesAgree, photoEntries, trimSnapshot, usableImage,
  usableTranslation, validatePolicy, wgerEquipment, MAX_ORIGINAL_BYTES,
} from './map-wger.mjs'

const LICENSES = {
  1: { short: 'CC-BY-SA 3', url: 'https://creativecommons.org/licenses/by-sa/3.0/deed.en' },
  2: { short: 'CC-BY-SA 4', url: 'https://creativecommons.org/licenses/by-sa/4.0/deed.en' },
  3: { short: 'CC0', url: 'http://creativecommons.org/publicdomain/zero/1.0/' },
  4: { short: 'CC-BY 4', url: 'https://creativecommons.org/licenses/by/4.0/' },
  5: { short: 'ODbL', url: 'https://opendatacommons.org/licenses/odbl/' },
}
const LANGUAGES = { 1: 'de', 2: 'en', 4: 'es', 12: 'fr' }

const ours = (id, n, eq, tg, sm = []) => ({ id, n, eq, tg, sm, bp: 'chest' })
const img = (id, over = {}) => ({
  id, url: `https://wger.de/media/exercise-images/${id}/a.png`, thumb: `https://wger.de/media/exercise-images/${id}/a.png.400x400_q85.png`,
  isMain: true, style: '4', license: 2, author: 'alice', ai: false, bytes: 50_000, ...over,
})
const tr = (lang, name, over = {}) => ({ lang, name, aliases: [], license: 2, author: 'bob', ...over })
const wger = (id, name, over = {}) => ({
  id, equipment: [], muscles: [4], musclesSecondary: [], images: [],
  translations: [tr(2, name), tr(1, `${name} (de)`)], ...over,
})
/** Image provenance policy: only trusted authors and individually reviewed images are shown. */
const POLICY = { trustedAuthors: { alice: 'test' }, allowedImages: { 42: 'reviewed' } }
const snap = exercises => ({ fetchedAt: '2026-09-30', apiVersion: '2.8.0-dev.0', licenses: LICENSES, languages: LANGUAGES, exercises })

test('usableImage: permitted CC license, an author, not AI-generated, https on wger.de', () => {
  assert.equal(usableImage(img(1)), true, 'license checks only without a policy')
  assert.equal(usableImage(img(1, { license: 1 })), true, 'CC-BY-SA 3')
  assert.equal(usableImage(img(1, { license: 3 })), true, 'CC0')
  assert.equal(usableImage(img(1, { license: 4 })), true, 'CC-BY 4')
  assert.equal(usableImage(img(1, { license: 5 })), false, 'ODbL is a database license: not used for images')
  assert.equal(usableImage(img(1, { license: 99 })), false, 'unknown license')
  assert.equal(usableImage(img(1, { author: '' })), false, 'no author to credit')
  assert.equal(usableImage(img(1, { author: '   ' })), false, 'blank author')
  assert.equal(usableImage(img(1, { ai: true })), false, 'AI-generated upstream')
  assert.equal(usableImage(img(1, { url: 'http://wger.de/media/x.png' })), false, 'plain http')
  assert.equal(usableImage(img(1, { url: 'https://evil.example/media/x.png' })), false, 'other host')
})

test('usableImage with a provenance policy: trusted author or an individually reviewed image only', () => {
  assert.equal(usableImage(img(1), POLICY), true, 'trusted author')
  assert.equal(usableImage(img(1, { author: ' alice ' }), POLICY), true, 'author compared trimmed')
  assert.equal(usableImage(img(1, { author: 'mallory' }), POLICY), false, 'unreviewed uploader')
  assert.equal(usableImage(img(42, { author: 'mallory' }), POLICY), true, 'reviewed image id')
  assert.equal(usableImage(img(42, { author: 'mallory', license: 5 }), POLICY), false, 'review never overrides the license')
  assert.equal(usableImage(img(42, { author: '' }), POLICY), false, 'review never overrides a missing author')
})

test('usableTranslation: CC0 / CC-BY / CC-BY-SA with an author and a name', () => {
  assert.equal(usableTranslation(tr(1, 'Bankdrücken')), true)
  assert.equal(usableTranslation(tr(1, 'Bankdrücken', { license: 5 })), false, 'ODbL')
  assert.equal(usableTranslation(tr(1, 'Bankdrücken', { author: '' })), false)
  assert.equal(usableTranslation(tr(1, '  ')), false)
})

test('trimSnapshot keeps only what the mapper needs, with language codes and image sizes', () => {
  const raw = [{
    id: 73, uuid: 'u', category: { name: 'Chest' }, equipment: [{ id: 1, name: 'Barbell' }],
    muscles: [{ id: 4 }], muscles_secondary: [{ id: 5 }],
    images: [{ id: 9, image: 'https://wger.de/media/exercise-images/73/b.png',
      thumbnails: { medium: 'https://wger.de/media/exercise-images/73/b.png.400x400_q85.png' },
      is_main: true, style: '1', license: 1, license_author: 'Everkinetic', is_ai_generated: false }],
    translations: [{ language: 2, name: 'Bench Press', aliases: [], license: 1, license_author: 'x', description: 'long' },
      { language: 1, name: 'Bankdrücken LH', aliases: [{ alias: 'Flachbankdrücken' }], license: 2, license_author: 'y' }],
  }]
  const s = trimSnapshot({ exercises: raw, licenses: [{ id: 1, short_name: 'CC-BY-SA 3', url: 'u1' }],
    languages: [{ id: 1, short_name: 'de' }, { id: 2, short_name: 'en' }], version: '2.8.0-dev.0',
    fetchedAt: '2026-09-30', sizes: { 'https://wger.de/media/exercise-images/73/b.png': 1234 } })
  assert.equal(s.apiVersion, '2.8.0-dev.0')
  assert.deepEqual(s.licenses, { 1: { short: 'CC-BY-SA 3', url: 'u1' } })
  assert.deepEqual(s.languages, { 1: 'de', 2: 'en' })
  const e = s.exercises[0]
  assert.deepEqual(e.equipment, ['Barbell'])
  assert.deepEqual(e.muscles, [4])
  assert.deepEqual(e.musclesSecondary, [5])
  assert.deepEqual(e.images[0], { id: 9, url: 'https://wger.de/media/exercise-images/73/b.png',
    thumb: 'https://wger.de/media/exercise-images/73/b.png.400x400_q85.png', isMain: true, style: '1', license: 1,
    author: 'Everkinetic', ai: false, bytes: 1234 })
  assert.deepEqual(e.translations[1], { lang: 1, name: 'Bankdrücken LH', aliases: ['Flachbankdrücken'], license: 2, author: 'y' })
  assert.equal(e.translations[0].description, undefined, 'descriptions are not kept')
})

test('wgerEquipment: listed kit plus equipment words in the English name; neutral kit only = unknown', () => {
  assert.equal(wgerEquipment(wger(1, 'Bench Press', { equipment: ['Barbell', 'Bench'] })), 'barbell')
  assert.equal(wgerEquipment(wger(1, 'Biceps Curls With SZ-bar', { equipment: ['SZ-Bar'] })), 'ez')
  assert.equal(wgerEquipment(wger(1, 'Dips', { equipment: ['none (bodyweight exercise)'] })), 'body')
  assert.equal(wgerEquipment(wger(1, 'Chin Up', { equipment: ['Pull-up bar'] })), 'unknown')
  assert.equal(wgerEquipment(wger(1, 'Leg Extension')), 'unknown')
  assert.equal(wgerEquipment(wger(1, 'Machine Lateral Raise', { equipment: ['Gym mat'] })), 'machine')
  assert.equal(wgerEquipment(wger(1, 'Smith machine squat')), 'smith')
  assert.equal(wgerEquipment(wger(1, 'Front Raises', { equipment: ['Barbell', 'Dumbbell'] })), null, 'two kinds = ambiguous')
  assert.equal(wgerEquipment(wger(1, 'Barbell Clean and press', { equipment: ['Dumbbell'] })), null, 'name contradicts the list')
})

test('musclesAgree: our target/secondary muscles must meet wger primary/secondary muscles', () => {
  assert.equal(musclesAgree(ours('1', 'x', 'barbell', 'pectorals'), wger(1, 'x', { muscles: [4] })), true)
  assert.equal(musclesAgree(ours('1', 'x', 'barbell', 'glutes', ['hamstrings']), wger(1, 'x', { muscles: [12], musclesSecondary: [11] })), true)
  assert.equal(musclesAgree(ours('1', 'x', 'barbell', 'hamstrings', ['glutes']), wger(1, 'x', { muscles: [4] })), false)
  assert.equal(musclesAgree(ours('1', 'x', 'barbell', 'pectorals'), wger(1, 'x', { muscles: [] })), false, 'unverifiable')
  assert.equal(musclesAgree(ours('1', 'x', 'barbell', 'forearms'), wger(1, 'x', { muscles: [1] })), false, 'no wger muscle for forearms')
})

test('buildWgerMapping: exact normalized name + equipment + muscles, duplicates merged', () => {
  const library = [ours('0025', 'barbell bench press', 'barbell', 'pectorals'),
    ours('0334', 'dumbbell lateral raise', 'dumbbell', 'delts'),
    ours('0289', 'dumbbell bench press', 'dumbbell', 'pectorals')]
  const s = snap([wger(73, 'Bench Press', { equipment: ['Barbell', 'Bench'] }),
    wger(348, 'Lateral Raises', { equipment: ['Dumbbell'], muscles: [2] }),
    wger(2658, 'Dumbbell Lateral Raise', { equipment: ['Dumbbell'], muscles: [2] })])
  const { matches } = buildWgerMapping(library, s, {})
  assert.deepEqual(matches.get('0025'), { how: 'auto', wger: [73] })
  assert.deepEqual(matches.get('0334'), { how: 'auto', wger: [348, 2658] }, 'same key twice upstream = one exercise')
  assert.equal(matches.has('0289'), false, 'equipment disagrees')
})

test('buildWgerMapping: muscles must agree for an automatic match', () => {
  const library = [ours('0648', 'power clean', 'barbell', 'hamstrings', ['glutes'])]
  const { matches } = buildWgerMapping(library, snap([wger(683, 'Power Clean', { equipment: ['Barbell'], muscles: [4] })]), {})
  assert.equal(matches.has('0648'), false)
})

test('buildWgerMapping: unknown equipment matches body weight or machine, but not both at once', () => {
  const library = [ours('0585', 'lever leg extension', 'leverage machine', 'quads'),
    ours('1373', 'bodyweight standing calf raise', 'body weight', 'calves'),
    ours('0605', 'lever standing calf raise', 'leverage machine', 'calves')]
  const s = snap([wger(369, 'Leg Extension', { muscles: [10] }), wger(622, 'Standing Calf Raises', { muscles: [7] })])
  const { matches, dropped } = buildWgerMapping(library, s, {})
  assert.deepEqual(matches.get('0585'), { how: 'auto', wger: [369] })
  assert.equal(matches.has('1373'), false)
  assert.equal(matches.has('0605'), false)
  assert.deepEqual(dropped.map(d => d.wger), [622])
})

test('buildWgerMapping: curated aliases win, null vetoes, bad ids throw', () => {
  const library = [ours('0025', 'barbell bench press', 'barbell', 'pectorals'),
    ours('0813', 'triceps dip (between benches)', 'body weight', 'triceps')]
  const s = snap([wger(73, 'Bench Press', { equipment: ['Barbell'] }), wger(197, 'Dips Between Two Benches', { equipment: ['Bench'], muscles: [5] })])
  const { matches } = buildWgerMapping(library, s, {
    '0025': { wger: null, why: 'veto' }, '0813': { wger: [197], why: 'same movement' },
  })
  assert.deepEqual(matches.get('0025'), { how: 'veto', wger: [], why: 'veto' })
  assert.deepEqual(matches.get('0813'), { how: 'alias', wger: [197], why: 'same movement' })
  assert.throws(() => buildWgerMapping(library, s, { 9999: { wger: [73], why: 'x' } }), /not in the library/)
  assert.throws(() => buildWgerMapping(library, s, { '0025': { wger: [1], why: 'x' } }), /unknown wger/)
  assert.throws(() => buildWgerMapping(library, s, { '0025': { wger: [73] } }), /why/)
})

test('photoEntries: main image first, then one more by the same author and license; credits complete', () => {
  const e = wger(73, 'Bench Press', { images: [
    img(1, { isMain: false }), img(2, { isMain: true }), img(3, { isMain: false, author: 'carol' }), img(4, { isMain: false }),
    img(5, { isMain: false, ai: true }),
  ] })
  const entries = photoEntries([e], snap([e]), POLICY)
  assert.deepEqual(entries.map(p => p.url), [img(2).url, img(1).url])
  assert.deepEqual(entries[0], {
    url: 'https://wger.de/media/exercise-images/2/a.png', title: 'Bench Press', author: 'alice', license: 'CC-BY-SA 4',
    licenseUrl: 'https://creativecommons.org/licenses/by-sa/4.0/deed.en', sourceUrl: 'https://wger.de/exercise/73/view-base',
    modified: true,
  })
})

test('photoEntries: originals above the size cap use the 400 px thumbnail; skips exercises without usable images', () => {
  const big = wger(1634, 'Rope Pullover', { images: [img(7, { bytes: MAX_ORIGINAL_BYTES + 1 })] })
  assert.equal(photoEntries([big], snap([big]), POLICY)[0].url, img(7).thumb)
  const none = wger(12, 'Seated Hip Adduction', { images: [img(8, { author: '' })] })
  assert.deepEqual(photoEntries([none], snap([none]), POLICY), [])
  const unknownSize = wger(13, 'x', { images: [img(9, { bytes: null })] })
  assert.equal(photoEntries([unknownSize], snap([unknownSize]), POLICY)[0].url, img(9).thumb, 'size unknown: the safe thumbnail')
  const untrusted = wger(14, 'x', { images: [img(10, { author: 'mallory' })] })
  assert.deepEqual(photoEntries([untrusted], snap([untrusted]), POLICY), [], 'unreviewed uploads are not shown')
})

test('photoEntries: several merged wger entries use the first one that has usable images', () => {
  const a = wger(348, 'Lateral Raises')
  const b = wger(2658, 'Dumbbell Lateral Raise', { images: [img(3)] })
  assert.equal(photoEntries([a, b], snap([a, b]), POLICY)[0].title, 'Dumbbell Lateral Raise')
})

test('buildPhotos / buildNames: per-exercise output with licensed names only (no English)', () => {
  const library = [ours('0025', 'barbell bench press', 'barbell', 'pectorals')]
  const e = wger(73, 'Bench Press', { equipment: ['Barbell'], images: [img(1)], translations: [
    tr(2, 'Bench Press'), tr(1, 'Bankdrücken LH', { aliases: ['Flachbankdrücken'], license: 1, author: 'flori' }),
    tr(12, 'Développé couché', { license: 5 }), tr(4, 'Press de Banca', { author: '' }),
  ] })
  const s = snap([e])
  const { matches } = buildWgerMapping(library, s, {})
  assert.deepEqual(Object.keys(buildPhotos(matches, s, POLICY)), ['0025'])
  const names = buildNames(matches, s)
  assert.deepEqual(names['0025'], {
    names: { de: [{ n: 'Bankdrücken LH', a: 'flori', l: 'CC-BY-SA 3', w: 73 }, { n: 'Flachbankdrücken', a: 'flori', l: 'CC-BY-SA 3', w: 73 }] },
    sources: ['https://wger.de/exercise/73/view-base'],
  })
})

test('buildNames: duplicate names across merged entries are kept once; exercises without names are left out', () => {
  const library = [ours('0334', 'dumbbell lateral raise', 'dumbbell', 'delts'), ours('0025', 'barbell bench press', 'barbell', 'pectorals')]
  const a = wger(348, 'Lateral Raises', { equipment: ['Dumbbell'], muscles: [2], translations: [tr(2, 'Lateral Raises'), tr(1, 'Seitheben')] })
  const b = wger(2658, 'Dumbbell Lateral Raise', { equipment: ['Dumbbell'], muscles: [2], translations: [tr(2, 'Dumbbell Lateral Raise'), tr(1, 'seitheben')] })
  const c = wger(73, 'Bench Press', { equipment: ['Barbell'], translations: [tr(2, 'Bench Press')] })
  const s = snap([a, b, c])
  const names = buildNames(buildWgerMapping(library, s, {}).matches, s)
  assert.deepEqual(names['0334'].names.de.map(x => x.n), ['Seitheben'])
  assert.equal(names['0025'], undefined)
})

test('validatePolicy: every entry explains itself and reviewed images exist', () => {
  const s = snap([wger(1, 'x', { images: [img(42)] })])
  assert.doesNotThrow(() => validatePolicy(POLICY, s))
  assert.throws(() => validatePolicy({ trustedAuthors: { alice: '' } }, s), /missing why/)
  assert.throws(() => validatePolicy({ allowedImages: { 7: 'x' } }, s), /unknown wger image 7/)
})

test('buildNames: credits link every wger entry that contributed a name, and only those', () => {
  const library = [ours('0594', 'lever seated calf raise', 'leverage machine', 'calves')]
  const a = wger(2628, 'Machine Seated Calf Raise', { translations: [tr(2, 'Machine Seated Calf Raise')] })
  const b = wger(590, 'Sitting Calf Raises', { translations: [tr(2, 'Sitting Calf Raises'), tr(1, 'Wadenheben Sitzend')] })
  const s = snap([a, b])
  const names = buildNames(new Map([['0594', { how: 'alias', wger: [2628, 590], why: 'x' }]]), s)
  assert.deepEqual(names['0594'].sources, ['https://wger.de/exercise/590/view-base'])
  assert.equal(names['0594'].names.de[0].w, 590)
})

test('buildNames: vetoed (mistranslated) names are left out; vetoes must name a generated name', () => {
  const library = [ours('0652', 'pull-up', 'body weight', 'lats')]
  const e = wger(475, 'Pull-ups', { translations: [tr(2, 'Pull-ups'), tr(7, 'Flexões de braço'), tr(1, 'Klimmzüge')] })
  const s = snap([e])
  s.languages = { ...s.languages, 7: 'pt' }
  const matches = new Map([['0652', { how: 'auto', wger: [475] }]])
  const vetoes = { '0652': { 'Flexões de braço': 'Portuguese for push-ups, not pull-ups.' } }
  const names = buildNames(matches, s, vetoes)
  assert.deepEqual(Object.keys(names['0652'].names), ['de'])
  assert.throws(() => buildNames(matches, s, { '0652': { Liegestütz: 'x' } }), /not a generated name/)
  assert.throws(() => buildNames(matches, s, { '0652': { 'Flexões de braço': '' } }), /why/)
})

test('buildNames: a non-English name equal to wger\'s English label is kept (our English name differs)', () => {
  const e = wger(135, 'Butterfly', { translations: [tr(2, 'Butterfly'), tr(1, 'Butterfly'), tr(12, 'Butterfly')] })
  const s = snap([e])
  const names = buildNames(new Map([['0596', { how: 'alias', wger: [135], why: 'x' }]]), s)
  assert.deepEqual(names['0596'].names.de.map(n => n.n), ['Butterfly'])
  assert.deepEqual(names['0596'].names.fr.map(n => n.n), ['Butterfly'])
})

test('buildNames: a name wger also uses for an unmatched exercise is search-only (s), never an import alias', () => {
  const crunch = wger(167, 'Crunches', { translations: [tr(2, 'Crunches'), tr(4, 'Abdominales'), tr(1, 'Crunch am Boden')] })
  const situp = wger(591, 'Sit-ups', { translations: [tr(2, 'Sit-ups'), tr(4, 'abdominales')] })
  const s = snap([crunch, situp])
  const names = buildNames(new Map([['0274', { how: 'alias', wger: [167], why: 'x' }]]), s)
  assert.deepEqual(names['0274'].names.es, [{ n: 'Abdominales', a: 'bob', l: 'CC-BY-SA 4', w: 167, s: true }])
  assert.equal(names['0274'].names.de[0].s, undefined, 'unique names stay import aliases')
  const merged = buildNames(new Map([['0274', { how: 'alias', wger: [167, 591], why: 'x' }]]), s)
  assert.equal(merged['0274'].names.es[0].s, undefined, 'shared only within the same match: not ambiguous')
})

test('buildNames: collisions use the app import normalization (punctuation and case ignored)', () => {
  const a = wger(1, 'Biceps Curl', { translations: [tr(2, 'Biceps Curl'), tr(1, 'Bizeps-Curl')] })
  const b = wger(2, 'Cable Curl', { translations: [tr(2, 'Cable Curl'), tr(1, 'bizeps curl!')] })
  const names = buildNames(new Map([['0294', { how: 'alias', wger: [1], why: 'x' }]]), snap([a, b]))
  assert.equal(names['0294'].names.de[0].s, true)
})
