// Unit tests for the photo-prompt CSV builder: node --test scripts/build-photo-prompts.test.mjs
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  buildRows, csvLine, displayName, equipmentPhrase, fileName, movementSteps, toCSV,
} from './build-photo-prompts.mjs'

const ex = (id, n, eq = 'dumbbell', extra = {}) => ({
  id, n, eq, bp: 'upper arms', tg: 'biceps',
  st: ['Stand holding the dumbbells at your sides.', 'Curl the weights up to your shoulders.',
    'Pause, then slowly lower back to the starting position.', 'Repeat for the desired number of repetitions.'],
  ...extra,
})

test('csvLine quotes every field and doubles embedded quotes; newlines never split a row', () => {
  assert.equal(csvLine(['a', 'b,c', 'say "hi"']), '"a","b,c","say ""hi"""')
  assert.equal(csvLine(['line1\nline2']), '"line1 line2"')
})

test('toCSV writes a header and CRLF rows (opens cleanly in Excel/Sheets)', () => {
  const csv = toCSV([{ a: 1, b: 'x' }, { a: 2, b: 'y' }])
  assert.equal(csv, '"a","b"\r\n"1","x"\r\n"2","y"\r\n')
})

test('movementSteps drops repeat/alternate filler and keeps the movement', () => {
  const steps = movementSteps([
    'Sit on the bench.', 'Press up.', 'Repeat for the desired number of repetitions.',
    'Continue alternating sides.', 'Switch legs and repeat the stretch on the other side.',
    'Alternate between arms for the desired number of repetitions.', 'Hold this position for 20-30 seconds.',
  ])
  assert.deepEqual(steps, ['Sit on the bench.', 'Press up.', 'Hold this position for 20-30 seconds.'])
})

test('names and file names', () => {
  assert.equal(displayName('ez barbell seated triceps extension'), 'EZ Barbell Seated Triceps Extension')
  assert.equal(displayName('45° side bend'), '45° Side Bend')
  assert.equal(fileName('0453', 1), 'own-0453-1.jpg')
})

test('equipment phrases fall back to a generic description for rare equipment', () => {
  assert.match(equipmentPhrase('ez barbell'), /EZ curl bar/)
  assert.match(equipmentPhrase('cable'), /cable station/)
  assert.match(equipmentPhrase('upper body ergometer'), /upper body ergometer/)
})

test('only exercises without any photo get rows; start then end; owner-used first', () => {
  const library = [ex('0001', 'dumbbell curl'), ex('0002', 'hammer curl'), ex('0003', 'zottman curl'),
    ex('0004', 'concentration curl')]
  const rows = buildRows(library, {
    stockPhotoIds: new Set(['0001']), ownPhotoIds: new Set(['0002']), ownerUsedIds: new Set(['0004']),
  })
  assert.deepEqual(rows.map(r => `${r.id}-${r.frame}`), ['0004-0', '0004-1', '0003-0', '0003-1'])
  assert.equal(rows[0].priority, 1)
  assert.equal(rows[2].priority, 2)
  assert.equal(rows[0].file_name, 'own-0004-0.jpg')
  assert.equal(rows[1].reference_image, 'own-0004-0.jpg')
})

test('prompts describe the style, 3:2 framing, the exercise steps and the position to show', () => {
  const [start, end] = buildRows([ex('0010', 'dumbbell curl')], {
    stockPhotoIds: new Set(), ownPhotoIds: new Set(), ownerUsedIds: new Set(),
  })
  assert.match(start.prompt, /landscape 3:2/)
  assert.match(start.prompt, /light-grey concrete wall/)
  assert.match(start.prompt, /Dumbbell Curl/)
  assert.match(start.prompt, /1\) Stand holding the dumbbells at your sides\./)
  assert.doesNotMatch(start.prompt, /desired number of repetitions/)
  assert.match(start.prompt, /STARTING position/)
  assert.match(start.prompt, /No text, no logos/)
  assert.match(end.prompt, /attached image/)
  assert.match(end.prompt, /END position/)
})

test('partner-assisted exercises include a coach instead of forbidding other people', () => {
  const [start] = buildRows([ex('0020', 'assisted lying calves stretch', 'assisted')], {
    stockPhotoIds: new Set(), ownPhotoIds: new Set(), ownerUsedIds: new Set(),
  })
  assert.match(start.prompt, /coach/)
  assert.match(start.prompt, /no other people besides the coach\./)
  assert.doesNotMatch(start.prompt, /no other people\./)
})
