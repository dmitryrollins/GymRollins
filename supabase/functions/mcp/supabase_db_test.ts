import { assertEquals } from 'jsr:@std/assert@^1'
import { collectPages } from './supabase_db.ts'

Deno.test('collectPages reads every page until a short one', async () => {
  const rows = Array.from({ length: 2_503 }, (_, i) => i)
  const calls: [number, number][] = []
  const out = await collectPages(1_000, 15_000, (from, to) => {
    calls.push([from, to])
    return Promise.resolve(rows.slice(from, to + 1))
  })
  assertEquals(out.length, 2_503)
  assertEquals(calls, [[0, 999], [1_000, 1_999], [2_000, 2_999]])
})

Deno.test('collectPages stops at the cap and at an exactly full last page', async () => {
  const out = await collectPages(
    10,
    25,
    (from, to) => Promise.resolve(Array.from({ length: to - from + 1 }, () => 1)),
  )
  assertEquals(out.length, 25)
  const calls: number[] = []
  const exact = await collectPages(10, 100, (from, to) => {
    calls.push(from)
    return Promise.resolve(from < 20 ? Array.from({ length: to - from + 1 }, () => 1) : [])
  })
  assertEquals(exact.length, 20)
  assertEquals(calls, [0, 10, 20])
})
