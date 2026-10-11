import { assertEquals } from 'jsr:@std/assert@^1'
import { displayWeight, epley, formatNumber, slopePerWeek, weight } from './format.ts'

Deno.test('formatNumber: one decimal at most, trailing .0 trimmed (WeightFormatter.number)', () => {
  assertEquals(formatNumber(140), '140')
  assertEquals(formatNumber(63.5029), '63.5')
  assertEquals(formatNumber(129.96), '130')
  assertEquals(formatNumber(0.04), '0')
})

Deno.test('displayWeight: owner unit first, the other in parentheses', () => {
  assertEquals(displayWeight(63.5029318, 'lb'), '140 lb (63.5 kg)')
  assertEquals(displayWeight(20, 'kg'), '20 kg (44.1 lb)')
})

Deno.test('weight: kg rounded to 2 decimals plus display', () => {
  assertEquals(weight(58.967008, 'lb'), { weight_kg: 58.97, weight_display: '130 lb (59 kg)' })
})

Deno.test('epley: 1..12 reps only, 1 rep is the weight itself (OneRepMax.swift)', () => {
  assertEquals(epley(100, 1), 100)
  assertEquals(Math.round(epley(58.97, 6)! * 10) / 10, 70.8)
  assertEquals(Math.round(epley(58.97, 10)! * 10) / 10, 78.6)
  assertEquals(epley(100, 13), null)
  assertEquals(epley(100, 0), null)
  assertEquals(epley(0, 5), null)
})

Deno.test('slopePerWeek: least-squares slope in kg per week', () => {
  assertEquals(slopePerWeek([]), null)
  assertEquals(slopePerWeek([{ t: 0, v: 80 }]), null)
  const day = 86_400_000
  assertEquals(slopePerWeek([{ t: 0, v: 81 }, { t: 14 * day, v: 81.6 }]), 0.3)
})
