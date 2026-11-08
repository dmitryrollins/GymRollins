// The one Better Auth endpoint this app adds, callable only from the server (auth.api.connectSignIn): when
// the owner approved a code in the app, /connect gives the browser that showed it a short Better Auth session
// for the owner and records Claude's consent, so the authorize step it re-enters goes straight back to Claude
// with a code. That session is marked (session.claudeConnect), so the app's routes never take it.
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

/**
 * True for the browser session connectSignIn made: it is for Claude's authorize step only, so /v1 and the
 * app's get-session refuse it (added after review). Every other session has it false. Any truthy value
 * counts, so a 1 that Better Auth didn't turn into true still refuses.
 */
export const isConnectSession = (session: { claudeConnect?: unknown }): boolean =>
  Boolean(session.claudeConnect)

export const connectPlugin = {
  id: 'gymrollins-connect',
  // Added after review. The column is migrations/0008_connect_session.sql, whose trigger also keeps a marked
  // session's expiry: Better Auth would extend it to 60 days whenever it is sent without the dont_remember
  // cookie (as a bearer, say). Not an input: no request can set it.
  schema: {
    session: {
      fields: {
        claudeConnect: { type: 'boolean', required: false, defaultValue: false, input: false },
      },
    },
  },
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
        // Added after review: with no consent, any tokens left for this client and account are a pair a
        // refresh minted while Disconnect Claude ran (/mcp refuses them for want of a consent). Claude reuses
        // its client id, so they go before the new consent would revive them. Access tokens first: they name
        // their refresh.
        const pair = [{ field: 'clientId', value: clientId }, { field: 'userId', value: userId }]
        await ctx.context.adapter.deleteMany({ model: 'oauthAccessToken', where: pair })
        await ctx.context.adapter.deleteMany({ model: 'oauthRefreshToken', where: pair })
        await ctx.context.adapter.create({
          model: 'oauthConsent',
          data: { clientId, userId, scopes, resources, createdAt: now, updatedAt: now },
        })
      }
      const expiresAt = new Date(now.getTime() + CONNECT_SESSION_SECONDS * 1000)
      // dontRememberMe: a browser-session cookie; overrideAll keeps this expiry and the mark.
      const session = await ctx.context.internalAdapter.createSession(
        user.id,
        true,
        { expiresAt, claudeConnect: true },
        true,
      )
      await setSessionCookie(ctx, { session, user }, true)
      return ctx.json({ sessionId: session.id })
    }),
  },
} satisfies BetterAuthPlugin
