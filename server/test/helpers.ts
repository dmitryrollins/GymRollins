import { env } from 'cloudflare:workers'
import app from '../src/index.ts'

export const ORIGIN = 'http://localhost'

interface Options {
  token?: string
  /** JSON-encoded unless it is already a string. */
  body?: unknown
}

/** A request as the app makes it: JSON, the session token as a bearer, and no Origin header. */
export function request(method: string, path: string, options: Options = {}): Promise<Response> {
  const headers: Record<string, string> = {}
  if (options.token) headers.authorization = `Bearer ${options.token}`
  let body: string | undefined
  if (options.body !== undefined) {
    headers['content-type'] = 'application/json'
    body = typeof options.body === 'string' ? options.body : JSON.stringify(options.body)
  }
  return Promise.resolve(app.fetch(new Request(`${ORIGIN}${path}`, { method, headers, body }), env))
}
