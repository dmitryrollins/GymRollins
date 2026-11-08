import { env } from 'cloudflare:workers'
import app from '../src/index.ts'
import { ORIGIN, request, signUp } from './helpers.ts'

// Claude's side of the connection, as its servers and the owner's browser make the requests: registration,
// PKCE, authorize, /connect, the token endpoint and /mcp. Redirects are never followed, so each step can be
// checked.

export const RESOURCE = `${ORIGIN}/mcp`
export const LOOPBACK = 'http://127.0.0.1:33418/callback'
export const CLAUDE_AI = 'https://claude.ai/api/mcp/auth_callback'

export function call(path: string, init: RequestInit = {}): Promise<Response> {
  const url = path.startsWith('http') ? path : `${ORIGIN}${path}`
  return Promise.resolve(app.fetch(new Request(url, { redirect: 'manual', ...init }), env))
}

export function register(body: Record<string, unknown>): Promise<Response> {
  return call('/api/auth/oauth2/register', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  })
}

/** A public client (Claude Code's kind) for one redirect URL; its client_id. */
export async function registerClient(redirectUri = LOOPBACK, name = 'Claude Code'): Promise<string> {
  const res = await register({
    client_name: name,
    redirect_uris: [redirectUri],
    token_endpoint_auth_method: 'none',
  })
  if (res.status !== 201) throw new Error(`registration failed: ${res.status} ${await res.text()}`)
  return (await res.json<{ client_id: string }>()).client_id
}

const base64url = (bytes: ArrayBuffer) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, '-').replace(/\//g, '_').replace(
    /=+$/,
    '',
  )

export interface Flow {
  clientId: string
  redirectUri: string
  verifier: string
  state: string
  /** /connect?… as the authorize step redirected to it. */
  connectUrl: string
}

/**
 * What Claude sends to the authorize endpoint: PKCE, its state, the resource, scope mcp and prompt=consent.
 */
export async function startFlow(clientId: string, redirectUri = LOOPBACK): Promise<Flow> {
  const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)).buffer)
  const challenge = base64url(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)))
  const state = crypto.randomUUID()
  const query = new URLSearchParams({
    response_type: 'code',
    client_id: clientId,
    redirect_uri: redirectUri,
    state,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    scope: 'mcp',
    resource: RESOURCE,
    prompt: 'consent',
  })
  const res = await call(`/api/auth/oauth2/authorize?${query}`, { headers: { accept: 'text/html' } })
  const location = res.headers.get('location') ?? ''
  if (res.status !== 302 || !location.startsWith('/connect?')) {
    throw new Error(`authorize did not send the browser to /connect: ${res.status} ${location}`)
  }
  return { clientId, redirectUri, verifier, state, connectUrl: location }
}
