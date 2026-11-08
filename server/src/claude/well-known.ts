// OAuth discovery for Claude (spec section 4, "Claude's connection", step 1), all served by Better Auth's
// plugins:
//   /.well-known/oauth-protected-resource[/mcp]           RFC 9728, from the mcp plugin
//   /.well-known/oauth-authorization-server/api/auth      RFC 8414 for the issuer <base>/api/auth
//   /.well-known/oauth-authorization-server               the same, for clients that look at the root
// (/api/auth/.well-known/oauth-authorization-server goes through src/auth/routes.ts.)
import { oauthProviderAuthServerMetadata } from '@better-auth/oauth-provider'
import { Hono } from 'hono'
import { createAuth } from '../auth/auth.ts'
import type { AppEnv } from '../env.ts'
import { errorBody } from '../http/errors.ts'
import { preflight, withCors } from '../http/cors.ts'

export const wellKnownRoutes = new Hono<AppEnv>()

wellKnownRoutes.options('/*', () => preflight())

wellKnownRoutes.get('/oauth-authorization-server', async (c) => {
  return withCors(await oauthProviderAuthServerMetadata(createAuth(c.env))(c.req.raw))
})

wellKnownRoutes.get('/*', async (c) => {
  const res = await createAuth(c.env).handler(c.req.raw)
  if (res.status === 404) return withCors(c.json(errorBody('not_found', 'No such route.'), 404))
  return withCors(res)
})
