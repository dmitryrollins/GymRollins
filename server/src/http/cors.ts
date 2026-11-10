// CORS for /mcp and the OAuth metadata only (spec section 7): browser-based MCP clients read them
// cross-origin. The app's routes and Better Auth's other routes send no CORS headers.
export const CORS_HEADERS: Readonly<Record<string, string>> = {
  'access-control-allow-origin': '*',
  'access-control-allow-methods': 'GET, POST, DELETE, OPTIONS',
  'access-control-allow-headers':
    'authorization, content-type, accept, mcp-session-id, mcp-protocol-version, last-event-id',
  'access-control-expose-headers': 'www-authenticate, mcp-session-id',
}

export function preflight(): Response {
  return new Response(null, { status: 204, headers: { ...CORS_HEADERS, 'access-control-max-age': '86400' } })
}

/** A copy of the response with the CORS headers it lacks. */
export function withCors(res: Response): Response {
  const headers = new Headers(res.headers)
  for (const [k, v] of Object.entries(CORS_HEADERS)) if (!headers.has(k)) headers.set(k, v)
  return new Response(res.body, { status: res.status, statusText: res.statusText, headers })
}
