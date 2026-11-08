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

/** A new account by email and password (on in tests: ALLOW_PASSWORD_AUTH=1). */
export async function signUp(): Promise<{ token: string; userId: string }> {
  const email = `t-${crypto.randomUUID()}@test.local`
  const res = await request('POST', '/api/auth/sign-up/email', {
    body: { email, password: 'correct-horse-battery', name: 'Test' },
  })
  if (res.status !== 200) throw new Error(`sign-up failed: ${res.status} ${await res.text()}`)
  const body = await res.json<{ token: string; user: { id: string } }>()
  return { token: body.token, userId: body.user.id }
}
