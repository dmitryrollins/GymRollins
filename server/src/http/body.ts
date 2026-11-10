import type { Context } from 'hono'
import { ApiError } from './errors.ts'

export async function jsonBody(c: Context): Promise<unknown> {
  try {
    return await c.req.json()
  } catch {
    throw new ApiError(400, 'bad_request', 'The body must be JSON.')
  }
}
