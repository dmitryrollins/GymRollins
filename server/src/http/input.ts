import { isStorableText } from '../sync/columns.ts'
import { ApiError } from './errors.ts'

// Reading the JSON bodies and the queries of the gym, photo and moderation routes. A value of the wrong type answers
// 400 bad_request, as Postgres refused a function argument it couldn't take (22P02, 22023).

export const badRequest = (message: string) => new ApiError(400, 'bad_request', message)

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** A JSON object body, or 400. */
export function objectBody(body: unknown): Record<string, unknown> {
  if (typeof body !== 'object' || body === null || Array.isArray(body)) {
    throw badRequest('The body must be a JSON object.')
  }
  return body as Record<string, unknown>
}

/** A UUID, lowercased (D1 compares text). */
export function uuidOf(value: unknown, name: string): string {
  if (typeof value !== 'string' || !UUID.test(value)) throw badRequest(`${name} must be a UUID.`)
  return value.toLowerCase()
}

export function textOf(value: unknown, name: string): string {
  if (typeof value !== 'string' || !isStorableText(value)) throw badRequest(`${name} must be text.`)
  return value
}

export const textOrNull = (value: unknown, name: string): string | null =>
  value === undefined || value === null ? null : textOf(value, name)

export function numberOrNull(value: unknown, name: string): number | null {
  if (value === undefined || value === null) return null
  if (typeof value !== 'number' || !Number.isFinite(value)) throw badRequest(`${name} must be a number.`)
  return value
}

export function intOrNull(value: unknown, name: string): number | null {
  if (value === undefined || value === null) return null
  if (typeof value !== 'number' || !Number.isSafeInteger(value)) throw badRequest(`${name} must be a whole number.`)
  return value
}

export function boolOr(value: unknown, name: string, fallback: boolean): boolean {
  if (value === undefined || value === null) return fallback
  if (typeof value !== 'boolean') throw badRequest(`${name} must be true or false.`)
  return value
}
