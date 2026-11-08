// The one Better Auth endpoint this app adds, callable only from the server (auth.api.connectSignIn): when
// the owner approved a code in the app, /connect gives the browser that showed it a short Better Auth session
// for the owner and records Claude's consent, so the authorize step it re-enters goes straight back to Claude
// with a code.
import type { BetterAuthPlugin } from 'better-auth'
import { APIError, createAuthEndpoint } from 'better-auth/api'
import { setSessionCookie } from 'better-auth/cookies'
import * as z from 'zod'

/**
 * Long enough to swap the code for tokens (Better Auth's codes last 10 minutes); the tokens don't need it
 * after.
 */
export const CONNECT_SESSION_SECONDS = 10 * 60

interface Consent {
  id: string
  scopes: string[]
  resources?: string[] | null
}

const union = (a: readonly string[], b: readonly string[]) => [...new Set([...a, ...b])]

export const connectPlugin = {
  id: 'gymrollins-connect',
  endpoints: {
    connectSignIn: createAuthEndpoint('/connect/sign-in', {
      method: 'POST',
      body: z.object({
        userId: z.string().min(1),
        clientId: z.string().min(1),
        scopes: z.array(z.string()).min(1),
        resources: z.array(z.string()),
      }),
      metadata: { SERVER_ONLY: true },
    }, async (ctx) => {
      const { userId, clientId, scopes, resources } = ctx.body
      const user = await ctx.context.internalAdapter.findUserById(userId)
      if (!user) throw new APIError('NOT_FOUND', { message: 'No such account.' })
      const now = new Date()
      const consent = await ctx.context.adapter.findOne<Consent>({
        model: 'oauthConsent',
        where: [{ field: 'clientId', value: clientId }, { field: 'userId', value: userId }],
      })
      if (consent) {
        await ctx.context.adapter.update({
          model: 'oauthConsent',
          where: [{ field: 'id', value: consent.id }],
          update: {
            scopes: union(consent.scopes, scopes),
            resources: union(consent.resources ?? [], resources),
            updatedAt: now,
          },
        })
      } else {
        await ctx.context.adapter.create({
          model: 'oauthConsent',
          data: { clientId, userId, scopes, resources, createdAt: now, updatedAt: now },
        })
      }
      const expiresAt = new Date(now.getTime() + CONNECT_SESSION_SECONDS * 1000)
      // dontRememberMe: a browser-session cookie that Better Auth never extends; overrideAll keeps this
      // expiry.
      const session = await ctx.context.internalAdapter.createSession(user.id, true, { expiresAt }, true)
      await setSessionCookie(ctx, { session, user }, true)
      return ctx.json({ sessionId: session.id })
    }),
  },
} satisfies BetterAuthPlugin
