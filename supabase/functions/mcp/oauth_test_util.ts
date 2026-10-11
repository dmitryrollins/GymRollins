// Test-only: obtains real OAuth-client tokens from the local Supabase Auth OAuth 2.1 server, the way Claude does —
// Dynamic Client Registration, authorize (PKCE S256), the signed-in user's consent approval through the Auth API
// (what the consent page's Approve button calls), and the code exchange. Also refreshes and revokes grants.
// Used by http_test.ts; never imported by the function itself.

export interface OAuthClient {
  clientId: string
  redirectUri: string
}

export interface OAuthTokens {
  accessToken: string
  refreshToken: string
  clientId: string
}

export interface PendingAuthorization {
  client: OAuthClient
  authorizationId: string
  /** The authorize redirect's Location (the consent page URL built from Auth's site_url). */
  consentUrl: string
  codeVerifier: string
  state: string
}

const REDIRECT_URI = 'http://127.0.0.1:8976/cb'

function b64url(bytes: Uint8Array): string {
  return btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

async function pkce(): Promise<{ verifier: string; challenge: string }> {
  const verifier = b64url(crypto.getRandomValues(new Uint8Array(48)))
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(verifier)))
  return { verifier, challenge: b64url(digest) }
}

async function expectOk(res: Response, what: string): Promise<Response> {
  if (!res.ok) throw new Error(`${what}: HTTP ${res.status} ${await res.text()}`)
  return res
}

/** Registers a public OAuth client (DCR), as Claude does when the connector is added. */
export async function registerClient(apiUrl: string, name = 'GymRollins test client'): Promise<OAuthClient> {
  const res = await expectOk(
    await fetch(`${apiUrl}/auth/v1/oauth/clients/register`, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        client_name: name,
        redirect_uris: [REDIRECT_URI],
        grant_types: ['authorization_code', 'refresh_token'],
        response_types: ['code'],
        token_endpoint_auth_method: 'none',
      }),
    }),
    'client registration',
  )
  const body = await res.json()
  return { clientId: body.client_id, redirectUri: REDIRECT_URI }
}

/** Starts the authorization-code flow; Auth answers with a redirect to the consent page. */
export async function startAuthorization(apiUrl: string, client: OAuthClient): Promise<PendingAuthorization> {
  const { verifier, challenge } = await pkce()
  const state = crypto.randomUUID()
  const url = new URL(`${apiUrl}/auth/v1/oauth/authorize`)
  url.search = new URLSearchParams({
    response_type: 'code',
    client_id: client.clientId,
    redirect_uri: client.redirectUri,
    code_challenge: challenge,
    code_challenge_method: 'S256',
    scope: 'email profile',
    state,
    resource: `${apiUrl}/functions/v1/mcp`,
  }).toString()
  const res = await fetch(url, { redirect: 'manual' })
  await res.body?.cancel()
  const location = res.headers.get('location')
  if (res.status < 300 || res.status >= 400 || !location) {
    throw new Error(`authorize: expected a redirect, got HTTP ${res.status}`)
  }
  const authorizationId = new URL(location).searchParams.get('authorization_id')
  if (!authorizationId) throw new Error(`authorize: no authorization_id in ${location}`)
  return { client, authorizationId, consentUrl: location, codeVerifier: verifier, state }
}

/** The signed-in user approves (or denies) the request — what the consent page does. Returns the redirect URL. */
export async function consent(
  apiUrl: string,
  anonKey: string,
  userToken: string,
  authorizationId: string,
  action: 'approve' | 'deny' = 'approve',
): Promise<string> {
  const headers = {
    apikey: anonKey,
    authorization: `Bearer ${userToken}`,
    'content-type': 'application/json',
  }
  const base = `${apiUrl}/auth/v1/oauth/authorizations/${authorizationId}`
  const details = await (await expectOk(await fetch(base, { headers }), 'authorization details')).json()
  if (details.redirect_url) return details.redirect_url // already consented
  const res = await expectOk(
    await fetch(`${base}/consent`, { method: 'POST', headers, body: JSON.stringify({ action }) }),
    'consent',
  )
  return (await res.json()).redirect_url
}

async function tokenRequest(apiUrl: string, form: Record<string, string>): Promise<Response> {
  return await fetch(`${apiUrl}/auth/v1/oauth/token`, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams(form),
  })
}

function tokensFrom(body: Record<string, string>, clientId: string): OAuthTokens {
  if (!body.access_token || !body.refresh_token) throw new Error('token response without tokens')
  return { accessToken: body.access_token, refreshToken: body.refresh_token, clientId }
}

/** Exchanges the code from the consent redirect (PKCE-verified) for tokens. */
export async function exchangeCode(
  apiUrl: string,
  pending: PendingAuthorization,
  redirectUrl: string,
): Promise<OAuthTokens> {
  const params = new URL(redirectUrl).searchParams
  if (params.get('state') !== pending.state) throw new Error('state mismatch')
  const code = params.get('code')
  if (!code) throw new Error(`no code in redirect: ${redirectUrl}`)
  const res = await expectOk(
    await tokenRequest(apiUrl, {
      grant_type: 'authorization_code',
      code,
      redirect_uri: pending.client.redirectUri,
      client_id: pending.client.clientId,
      code_verifier: pending.codeVerifier,
    }),
    'token exchange',
  )
  return tokensFrom(await res.json(), pending.client.clientId)
}

/** Refresh-token grant; the raw response so callers can assert on failures. */
export async function refresh(apiUrl: string, tokens: OAuthTokens): Promise<Response> {
  return await tokenRequest(apiUrl, {
    grant_type: 'refresh_token',
    refresh_token: tokens.refreshToken,
    client_id: tokens.clientId,
  })
}

/** Full flow for a signed-in user: a fresh client, authorize, approve, exchange. */
export async function oauthTokensFor(
  apiUrl: string,
  anonKey: string,
  userToken: string,
): Promise<OAuthTokens> {
  const pending = await startAuthorization(apiUrl, await registerClient(apiUrl))
  const redirectUrl = await consent(apiUrl, anonKey, userToken, pending.authorizationId)
  return await exchangeCode(apiUrl, pending, redirectUrl)
}

/** The user's OAuth grants (GET /auth/v1/user/oauth/grants), as the app lists them. */
export async function listGrants(apiUrl: string, anonKey: string, userToken: string): Promise<unknown[]> {
  const res = await expectOk(
    await fetch(`${apiUrl}/auth/v1/user/oauth/grants`, {
      headers: { apikey: anonKey, authorization: `Bearer ${userToken}` },
    }),
    'list grants',
  )
  return await res.json()
}

/** Revokes the user's grant for a client (DELETE /auth/v1/user/oauth/grants?client_id=…), as "Disconnect" does. */
export async function revokeGrant(
  apiUrl: string,
  anonKey: string,
  userToken: string,
  clientId: string,
): Promise<void> {
  const url = `${apiUrl}/auth/v1/user/oauth/grants?client_id=${encodeURIComponent(clientId)}`
  const res = await expectOk(
    await fetch(url, {
      method: 'DELETE',
      headers: { apikey: anonKey, authorization: `Bearer ${userToken}` },
    }),
    'revoke grant',
  )
  await res.body?.cancel()
}
