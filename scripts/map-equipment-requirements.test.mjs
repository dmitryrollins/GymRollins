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
  assert.deepEqual(groups('triceps dip (bench leg)', 'body weight'), [FLAT_BENCH])
  assert.deepEqual(groups('triceps dips floor', 'body weight'), [FLAT_BENCH])
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
  assert.ok(mapped >= 1_100, `expected most exercises mapped, got ${mapped}`)
  const text = review(library, result)
  assert.match(text, /## Machines \(check these\)/)
  assert.match(text, /\| lever chest press \| chest-press-machine \|/)
  assert.match(text, /\| stretch \| /)
})

test('bodyweight work on a bar needs the bar, however the name is spelled', () => {
  for (const name of ['archer pull up', 'pull up (neutral grip)', 'gorilla chin', 'side-to-side chin']) {
    assert.deepEqual(groups(name, 'body weight'), [['pull-up-bar', 'power-rack']], name)
  }
})

test('bodyweight work that needs gear with no kind stays unmapped', () => {
  for (const name of [
    'front lever', 'back lever', 'flag', 'skin the cat', 'elevator', 'full maltese', 'swing 360', 'suspended push-up',
    'inverted row with straps', 'glute-ham raise', 'balance board', 'bodyweight standing row',
    'bodyweight squatting row', 'donkey calf raise', 'standing calf raise (on a staircase)',
    'self assisted inverse leg curl', 'inverse leg curl (on pull-up cable machine)', 'run (equipment)',
    'triceps dip (between benches)',
  ]) {
    assert.ok(unmapped(name, 'body weight'), name)
  }
})

test('bodyweight work names the bench, bars or wheel it needs', () => {
  const bodyweightGroups = name => groups(name, 'body weight')
  assert.deepEqual(bodyweightGroups('incline close-grip push-up'), [FLAT_BENCH])
  assert.deepEqual(bodyweightGroups('bodyweight incline side plank'), [FLAT_BENCH])
  assert.deepEqual(bodyweightGroups('seated leg raise'), [FLAT_BENCH])
  assert.deepEqual(bodyweightGroups('body-up'), [FLAT_BENCH])
  assert.deepEqual(bodyweightGroups('inverse leg curl (bench support)'), [FLAT_BENCH])
  assert.deepEqual(bodyweightGroups('incline twisting sit-up'), [INCLINE_BENCH])
  assert.deepEqual(bodyweightGroups('decline crunch'), [['decline-bench']])
  assert.deepEqual(bodyweightGroups('vertical leg raise (on parallel bars)'), [['dip-station']])
  assert.deepEqual(bodyweightGroups('wheel run'), [['ab-wheel']])
  assert.deepEqual(bodyweightGroups('decline push-up'), [FLAT_BENCH])
  assert.deepEqual(bodyweightGroups('monster walk'), [['resistance-bands']])
})

test('a decline bench is its own kind: adjustable benches rarely go below flat', () => {
  assert.deepEqual(DECLINE_BENCH, ['decline-bench'])
  assert.deepEqual(groups('barbell decline bench press', 'barbell'),
    [['barbell'], ['decline-bench'], ['power-rack', 'decline-bench']])
})

test('step-ups need a bench to step on, whatever carries the load', () => {
  assert.deepEqual(groups('dumbbell step-up', 'dumbbell'), [['dumbbells'], FLAT_BENCH])
  assert.deepEqual(groups('dumbbell step up single leg balance with bicep curl', 'dumbbell'), [['dumbbells'], FLAT_BENCH])
  assert.deepEqual(groups('dumbbell single leg deadlift with stepbox support', 'dumbbell'), [['dumbbells'], FLAT_BENCH])
  assert.deepEqual(groups('barbell step-up', 'barbell'), [['barbell'], FLAT_BENCH])
  assert.deepEqual(groups('band step-up', 'band'), [['resistance-bands'], FLAT_BENCH])
})

test('band exercises also need the bar, wheel or bench they name', () => {
  assert.deepEqual(groups('band assisted pull-up', 'band'), [['resistance-bands'], ['pull-up-bar', 'power-rack']])
  assert.deepEqual(groups('band assisted wheel rollerout', 'band'), [['resistance-bands'], ['ab-wheel']])
  assert.deepEqual(groups('band bench press', 'band'), [['resistance-bands'], FLAT_BENCH])
  assert.deepEqual(groups('band lying hip raise', 'band'), [['resistance-bands']], 'floor work needs no bench')
  assert.deepEqual(groups('band close-grip pulldown', 'band'), [['resistance-bands']])
})

test('rack pulls and pin presses need a rack; special bars have no kind', () => {
  assert.deepEqual(groups('barbell rack pull', 'barbell'), [['barbell'], ['power-rack']])
  assert.deepEqual(groups('barbell pin presses', 'barbell'), [['barbell'], ['power-rack']])
  assert.ok(unmapped('cambered bar lying row', 'barbell'))
})

test('a cable inverse leg curl is done lying on a bench', () => {
  assert.deepEqual(groups('cable assisted inverse leg curl', 'cable'), [['cable-station'], FLAT_BENCH])
})

test('words that only look like equipment need nothing', () => {
  for (const name of ['push-up', 'crunch', 'chinese plank', 'wheelie', 'rowing motion', 'flagpole hold']) {
    assert.deepEqual(groups(name, 'body weight'), [], name)
  }
})

test('mobility moves and advanced skills are never picked', () => {
  for (const name of [
    'two toe touch (male)', 'wrist circles', 'butterfly yoga pose', 'seated wide angle pose sequence', 'sphinx',
    'upward facing dog', 'standing pelvic tilt', 'spine twist', 'hug keens to chest', 'bent knee lying twist (male)',
    'one arm against wall', 'left hook. boxing', 'full planche push-up', 'straddle planche', 'handstand',
    'handstand push-up', 'stalder press', 'l-sit on floor', 'v-sit on floor', 'isometric chest squeeze',
  ]) {
    assert.match(unmapped(name, 'body weight') ?? '', /mobility or advanced skill/, name)
  }
  for (const name of ['push-up', 'russian twist', 'glute bridge march', 'sit-up v. 2', 'front plank with twist']) {
    assert.deepEqual(groups(name, 'body weight'), [], name)
  }
})

test('no-equipment exercises whose steps use a bench or weights say so', () => {
  assert.deepEqual(groups('bench dip on floor', 'body weight'), [FLAT_BENCH])
  assert.deepEqual(groups('triceps dips floor', 'body weight'), [FLAT_BENCH])
  assert.deepEqual(groups('kick out sit', 'body weight'), [FLAT_BENCH])
  assert.ok(unmapped('biceps leg concentration curl', 'body weight'))
  assert.ok(unmapped('three bench dip', 'body weight'))
})

test('a stretch is the word stretch, not outstretched', () => {
  assert.deepEqual(groups('single leg bridge with outstretched leg', 'body weight'), [])
  assert.ok(unmapped('chest stretch with exercise ball', 'stability ball'))
  assert.ok(unmapped('hamstring stretching', 'body weight'))
})

test('holds, conditioning drills and moves tagged for the wrong muscle are never picked', () => {
  for (const name of [
    'side bridge v. 2', 'power point plank', 'wind sprints', 'quick feet v. 2', 'standing archer', 'inchworm',
    'single arm push-up', 'single leg squat (pistol) male', 'superman push-up', 'outside leg kick push-up',
    'push-up inside leg kick', 'pike-to-cobra push-up', 'spider crawl push up', 'potty squat',
  ]) {
    assert.match(unmapped(name, 'body weight') ?? '', /mobility or advanced skill/, name)
  }
})

