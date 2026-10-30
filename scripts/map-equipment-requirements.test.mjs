// Unit tests for the equipment-requirements mapper: node --test scripts/map-equipment-requirements.test.mjs
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { test } from 'node:test'
import {
  DECLINE_BENCH, FLAT_BENCH, INCLINE_BENCH, benchFor, buildRequirements, requirementsFor, review,
} from './map-equipment-requirements.mjs'

const ex = (n, eq, id = '0001') => ({ id, n, eq })
const groups = (n, eq) => requirementsFor(ex(n, eq)).groups
const unmapped = (n, eq) => requirementsFor(ex(n, eq)).unmapped

test('free weights need their load and the bench the name implies', () => {
  assert.deepEqual(groups('dumbbell curl', 'dumbbell'), [['dumbbells']])
  assert.deepEqual(groups('dumbbell incline fly', 'dumbbell'), [['dumbbells'], INCLINE_BENCH])
  assert.deepEqual(groups('dumbbell decline bench press', 'dumbbell'), [['dumbbells'], DECLINE_BENCH])
  assert.deepEqual(groups('dumbbell fly', 'dumbbell'), [['dumbbells'], FLAT_BENCH])
  assert.deepEqual(groups('kettlebell one arm row', 'kettlebell'), [['kettlebells']])
  assert.deepEqual(groups('ez barbell preacher curl', 'ez barbell'), [['ez-bar'], ['preacher-bench']])
  assert.deepEqual(groups('dumbbell incline fly on exercise ball', 'dumbbell'), [['dumbbells'], ['stability-ball']])
})

test('barbell presses need a bench and a rack, or a station that is both; squats need a rack', () => {
  assert.deepEqual(groups('barbell bench press', 'barbell'),
    [['barbell'], ['flat-bench', 'adjustable-bench', 'bench-press-station'], ['power-rack', 'bench-press-station']])
  assert.deepEqual(groups('barbell incline bench press', 'barbell'),
    [['barbell'], INCLINE_BENCH, ['power-rack', 'incline-bench']])
  assert.deepEqual(groups('barbell decline bench press', 'barbell'),
    [['barbell'], DECLINE_BENCH, ['power-rack', 'decline-bench']])
  assert.deepEqual(groups('barbell full squat', 'barbell'), [['barbell'], ['power-rack']])
  assert.deepEqual(groups('barbell curl', 'barbell'), [['barbell']])
  assert.deepEqual(groups('barbell lying triceps extension', 'barbell'), [['barbell'], FLAT_BENCH])
})

test('machines map to one specific kind, or stay unmapped', () => {
  assert.deepEqual(groups('lever chest press', 'leverage machine'), [['chest-press-machine']])
  assert.deepEqual(groups('lever seated squat calf raise on leg press machine', 'leverage machine'), [['leg-press']])
  assert.deepEqual(groups('lever standing calf raise', 'leverage machine'), [['calf-raise-machine']])
  assert.deepEqual(groups('hack calf raise', 'sled machine'), [['hack-squat']])
  assert.deepEqual(groups('sled 45° leg wide press', 'sled machine'), [['leg-press']])
  assert.deepEqual(groups('lever one arm lateral wide pulldown', 'leverage machine'), [['lat-pulldown']])
  assert.deepEqual(groups('lever one arm lateral high row', 'leverage machine'), [['seated-row-machine']])
  assert.deepEqual(groups('lever t bar row', 'leverage machine'), [['t-bar-row']])
  assert.deepEqual(groups('assisted pull-up', 'leverage machine'), [['assisted-pullup-dip']])
  assert.deepEqual(groups('lever overhand triceps dip', 'leverage machine'), [['triceps-machine']])
  assert.deepEqual(groups('walking on incline treadmill', 'leverage machine'), [['treadmill']])
  assert.equal(unmapped('lever shrug', 'leverage machine'), 'machine not identified')
  assert.equal(unmapped('lever bent-over row with v-bar', 'leverage machine'), 'machine not identified')
  assert.equal(unmapped('lever reverse hyperextension', 'leverage machine'), 'machine not identified')
})

test('cables use a pulldown or row station when the name says so, and a bench only when named', () => {
  assert.deepEqual(groups('cable pulldown', 'cable'), [['lat-pulldown', 'cable-station']])
  assert.deepEqual(groups('cable seated row', 'cable'), [['seated-cable-row', 'cable-station']])
  assert.deepEqual(groups('cable middle fly', 'cable'), [['cable-station']], 'a standing cable fly needs no bench')
  assert.deepEqual(groups('cable incline fly', 'cable'), [['cable-station'], INCLINE_BENCH])
  assert.deepEqual(groups('smith bench press', 'smith machine'), [['smith-machine'], FLAT_BENCH])
})

test('bodyweight needs a bar, dip station, bench or ball only when named', () => {
  assert.deepEqual(groups('pull-up', 'body weight'), [['pull-up-bar', 'power-rack']])
  assert.deepEqual(groups('hanging leg raise', 'body weight'), [['pull-up-bar', 'power-rack']])
  assert.deepEqual(groups('chest dip', 'body weight'), [['dip-station', 'assisted-pullup-dip']])
  assert.deepEqual(groups('chest dip (on dip-pull-up cage)', 'body weight'), [['dip-station', 'assisted-pullup-dip']])
  assert.deepEqual(groups('triceps dip (between benches)', 'body weight'), [FLAT_BENCH])
  assert.deepEqual(groups('triceps dips floor', 'body weight'), [])
  assert.deepEqual(groups('inverted row', 'body weight'), [['power-rack', 'smith-machine']])
  assert.deepEqual(groups('hyperextension', 'body weight'), [['back-extension']])
  assert.deepEqual(groups('incline push-up', 'body weight'), [FLAT_BENCH])
  assert.deepEqual(groups('push-up', 'body weight'), [])
  assert.equal(unmapped('ring dips', 'body weight'), 'needs equipment that has no kind')
  assert.equal(unmapped('incline push-up (on box)', 'body weight'), 'needs equipment that has no kind')
})

test('stretches, partner-assisted and kind-less equipment are unmapped', () => {
  assert.equal(unmapped('assisted lying glutes stretch', 'assisted'), 'stretch')
  assert.equal(unmapped('calf stretch with rope', 'rope'), 'stretch')
  assert.equal(unmapped('assisted sit-up', 'assisted'), 'no kind for "assisted"')
  assert.equal(unmapped('weighted pull-up', 'weighted'), 'no kind for "weighted"')
  assert.equal(unmapped('battling ropes', 'rope'), 'no kind for "rope"')
  assert.equal(unmapped('mystery move', 'hoverboard'), 'unknown equipment "hoverboard"')
})

test('benchFor: a ball replaces the bench, and only free weights read "fly" as lying on a bench', () => {
  assert.deepEqual(benchFor('cable incline fly (on stability ball)', { fly: false }), [['stability-ball']])
  assert.deepEqual(benchFor('dumbbell fly', { fly: true }), [FLAT_BENCH])
  assert.deepEqual(benchFor('cable middle fly', { fly: false }), [])
})

test('buildRequirements rejects kinds that are not in equipment-kinds.json', () => {
  assert.throws(() => buildRequirements([ex('dumbbell curl', 'dumbbell')], ['barbell']), /unknown kind "dumbbells"/)
})

test('the real library maps with known kinds, and the review lists machines and unmapped exercises', () => {
  const root = resolve(import.meta.dirname, '..')
  const library = JSON.parse(readFileSync(resolve(root, 'ios/GymRollins/Resources/exercises.json'), 'utf8'))
  const kinds = JSON.parse(readFileSync(resolve(root, 'ios/GymRollins/Resources/equipment-kinds.json'), 'utf8')).kinds
  const result = buildRequirements(library, kinds.map(k => k.id))
  const mapped = Object.keys(result.requirements).length
  assert.equal(mapped + result.unmapped.length, library.length)
  assert.ok(mapped >= 1_150, `expected most exercises mapped, got ${mapped}`)
  const text = review(library, result)
  assert.match(text, /## Machines \(check these\)/)
  assert.match(text, /\| lever chest press \| chest-press-machine \|/)
  assert.match(text, /\| stretch \| /)
})
