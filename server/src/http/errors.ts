import type { Context } from 'hono'

/** The statuses the API answers errors with (spec section 6). */
export type ErrorStatus = 400 | 401 | 403 | 404 | 409 | 413 | 422 | 429 | 500

/**
 * An error the app is told about, as `{"error": {"code", "message"}}`. Codes keep the strings the app already maps
 * (row_rejected, not_allowed, photos_remain, …), so its messages don't change.
 */
export class ApiError extends Error {
  constructor(readonly status: ErrorStatus, readonly code: string, message: string) {
    super(message)
  }
}

export function errorBody(code: string, message: string) {
  return { error: { code, message } }
}

const CONSTRAINT = /(CHECK|NOT NULL|FOREIGN KEY|UNIQUE) constraint failed/

/** SQLite's message when D1 refused a row's data (what Postgres raised as 22xxx/23xxx), or null. */
export function constraintMessage(error: unknown): string | null {
  const message = error instanceof Error ? error.message : String(error)
  if (!CONSTRAINT.test(message)) return null
  return message.replace(/^D1_ERROR:\s*/, '').replace(/:\s*SQLITE_CONSTRAINT\S*$/, '')
}

export function onError(error: Error, c: Context): Response {
  if (error instanceof ApiError) return c.json(errorBody(error.code, error.message), error.status)
  const constraint = constraintMessage(error)
  if (constraint !== null) return c.json(errorBody('row_rejected', constraint), 422)
  console.error('unhandled', error)
  return c.json(errorBody('server_error', 'Something went wrong.'), 500)
}
