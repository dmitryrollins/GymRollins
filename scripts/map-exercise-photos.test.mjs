// Unit tests for the exercise-photo matcher: node --test scripts/map-exercise-photos.test.mjs
import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  buildMapping, canonicalEquipment, matchKey, nameTokens, ourEquipment, validPhotoPath,
} from './map-exercise-photos.mjs'

const ours = (id, n, eq) => ({ id, n, eq, bp: 'chest' })
const theirs = (id, name, equipment, images = [`${id}/0.jpg`, `${id}/1.jpg`]) => ({ id, name, equipment, images })

test('nameTokens normalizes punctuation, plurals and known synonyms', () => {
  assert.deepEqual(nameTokens('DB Flyes'), ['dumbbell', 'fly'])
  assert.deepEqual(nameTokens('Push-Ups'), ['pushup'])
  assert.deepEqual(nameTokens('Lat Pull Down'), ['lat', 'pulldown'])
  assert.deepEqual(nameTokens('Tricep Pushdown'), ['pushdown', 'triceps'])
  assert.deepEqual(nameTokens('Bench Press'), ['bench', 'press'], '"press" keeps its double s')
})

test('equipment is canonicalized on both sides, with name hints winning for smith and EZ bars', () => {
  assert.equal(ourEquipment('leverage machine'), 'machine')
  assert.equal(ourEquipment('sled machine'), 'machine')
  assert.equal(ourEquipment('smith machine'), 'smith')
  assert.equal(ourEquipment('ez barbell'), 'ez')
  assert.equal(ourEquipment('body weight'), 'body')
  assert.equal(ourEquipment('upper body ergometer'), null, 'rare equipment never auto-matches')
  assert.equal(canonicalEquipment('Smith Machine Bench Press', 'machine'), 'smith')
  assert.equal(canonicalEquipment('Close-Grip EZ Bar Curl', 'barbell'), 'ez')
  assert.equal(canonicalEquipment('Leg Extensions', 'machine'), 'machine')
  assert.equal(canonicalEquipment('Hyperextensions', 'other'), null, '"other" never auto-matches')
  assert.equal(canonicalEquipment('Inverted Row', null), 'body', 'no listed equipment = bodyweight')
})

test('matchKey ignores word order and equipment words but keeps equipment as part of the key', () => {
  assert.equal(matchKey('dumbbell incline press', 'dumbbell'), matchKey('Incline Dumbbell Press', 'dumbbell'))
  assert.equal(matchKey('lever leg extension', 'machine'), matchKey('Leg Extensions', 'machine'))
  assert.notEqual(matchKey('barbell curl', 'barbell'), matchKey('Dumbbell Curl', 'dumbbell'))
})

test('buildMapping: exact normalized match with agreeing equipment', () => {
  const { photos, decisions } = buildMapping(
    [ours('0294', 'dumbbell biceps curl', 'dumbbell')],
    [theirs('Dumbbell_Bicep_Curl', 'Dumbbell Bicep Curl', 'dumbbell')], {})
  assert.deepEqual(photos['0294'], ['Dumbbell_Bicep_Curl/0.jpg', 'Dumbbell_Bicep_Curl/1.jpg'])
  assert.equal(decisions.get('0294').how, 'auto')
})

test('buildMapping: equipment disagreement never matches', () => {
  const { photos } = buildMapping(
    [ours('1', 'curl', 'cable')], [theirs('Curl', 'Curl', 'dumbbell')], {})
  assert.equal(photos['1'], undefined)
})

test('buildMapping: an ambiguous key (two upstream entries) is left unmatched', () => {
  const { photos, ambiguous } = buildMapping(
    [ours('1', 'barbell squat', 'barbell')],
    [theirs('Barbell_Squat', 'Barbell Squat', 'barbell'), theirs('Squat_Barbell', 'Squat - Barbell', 'barbell')], {})
  assert.equal(photos['1'], undefined)
  assert.equal(ambiguous.length, 1)
})

test('buildMapping: aliases add near-misses and null aliases veto an automatic match', () => {
  const lib = [ours('0025', 'barbell bench press', 'barbell'), ours('9', 'dumbbell fly', 'dumbbell')]
  const up = [
    theirs('Barbell_Bench_Press_-_Medium_Grip', 'Barbell Bench Press - Medium Grip', 'barbell'),
    theirs('Dumbbell_Flyes', 'Dumbbell Flyes', 'dumbbell'),
  ]
  const { photos, decisions } = buildMapping(lib, up,
    { '0025': { fedb: 'Barbell_Bench_Press_-_Medium_Grip', why: 'medium grip is the default' }, 9: { fedb: null, why: 'veto' } })
  assert.deepEqual(photos['0025'], ['Barbell_Bench_Press_-_Medium_Grip/0.jpg', 'Barbell_Bench_Press_-_Medium_Grip/1.jpg'])
  assert.equal(decisions.get('0025').how, 'alias')
  assert.equal(photos['9'], undefined)
})

test('buildMapping: an alias pointing at an unknown upstream id throws', () => {
  assert.throws(() => buildMapping([ours('1', 'x', 'barbell')], [], { 1: { fedb: 'Nope', why: '' } }), /unknown/)
})

test('buildMapping: an alias for an unknown library id throws', () => {
  assert.throws(() => buildMapping([], [theirs('A', 'A', 'barbell')], { 42: { fedb: 'A', why: '' } }), /library/)
})

test('validPhotoPath accepts upstream shapes and rejects traversal or odd files', () => {
  assert.ok(validPhotoPath('3_4_Sit-Up/0.jpg'))
  assert.ok(validPhotoPath('Front_Squat_(Clean_Grip)/1.jpg'))
  assert.ok(!validPhotoPath('../etc/passwd'))
  assert.ok(!validPhotoPath('A/0.png'))
  assert.ok(!validPhotoPath('https://evil.example/0.jpg'))
})

test('buildMapping drops entries whose image paths fail validation', () => {
  const { photos } = buildMapping([ours('1', 'barbell curl', 'barbell')],
    [theirs('Barbell_Curl', 'Barbell Curl', 'barbell', ['../x/0.jpg'])], {})
  assert.equal(photos['1'], undefined)
})

test('an equipment word in the name that contradicts the equipment field blocks the automatic match', () => {
  // "lever bent over row" is filed under barbell upstream-side style, but "lever" says machine/landmine.
  const { photos } = buildMapping([ours('0574', 'lever bent over row', 'barbell')],
    [theirs('Bent_Over_Barbell_Row', 'Bent Over Barbell Row', 'barbell')], {})
  assert.equal(photos['0574'], undefined)
  assert.equal(matchKey('lever bent over row', 'barbell'), null)
  assert.equal(matchKey('Smith Machine Squat', 'smith'), 'smith|squat', 'smith + machine words agree with smith')
})

test('"ez barbell" names are compatible with the EZ-bar equipment', () => {
  assert.equal(matchKey('ez barbell curl', 'ez'), 'ez|curl')
})
