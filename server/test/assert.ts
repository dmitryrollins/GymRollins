// The @std/assert functions the tests moved from Deno use (plan 29), on Vitest's expect, with the same
// meaning: assertEquals is a strict deep equality, assertRejects and assertThrows return the error after
// checking its class and message.
import { expect } from 'vitest'

type ErrorClass<E extends Error> = new (...args: never[]) => E

export function assert(expr: unknown, msg?: string): asserts expr {
  expect(Boolean(expr), msg).toBe(true)
}

export function assertFalse(expr: unknown, msg?: string): void {
  expect(Boolean(expr), msg).toBe(false)
}

export function assertEquals<T>(actual: T, expected: T, msg?: string): void {
  expect(actual, msg).toStrictEqual(expected)
}

export function assertMatch(actual: string, expected: RegExp, msg?: string): void {
  expect(actual, msg).toMatch(expected)
}

export function assertAlmostEquals(actual: number, expected: number, tolerance = 1e-7, msg?: string): void {
  expect(Math.abs(actual - expected), msg ?? `${actual} is not within ${tolerance} of ${expected}`)
    .toBeLessThanOrEqual(tolerance)
}

function checked<E extends Error>(error: unknown, errorClass?: ErrorClass<E>, includes?: string): E {
  expect(error).toBeInstanceOf(errorClass ?? Error)
  if (includes !== undefined) expect((error as Error).message).toContain(includes)
  return error as E
}

export function assertThrows<E extends Error = Error>(
  fn: () => unknown,
  errorClass?: ErrorClass<E>,
  includes?: string,
): E {
  try {
    fn()
  } catch (error) {
    return checked(error, errorClass, includes)
  }
  throw new Error('Expected the function to throw.')
}

export async function assertRejects<E extends Error = Error>(
  fn: () => PromiseLike<unknown>,
  errorClass?: ErrorClass<E>,
  includes?: string,
): Promise<E> {
  try {
    await fn()
  } catch (error) {
    return checked(error, errorClass, includes)
  }
  throw new Error('Expected the promise to reject.')
}
