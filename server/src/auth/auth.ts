import { betterAuth } from 'better-auth'
import { bearer } from 'better-auth/plugins'
import type { Env } from '../env.ts'
import { connectPlugin } from './connect-plugin.ts'
import { claudeOAuth } from './oauth.ts'

/** Sessions last 60 days and renew once a day while the app uses them (spec section 4, Sign-in). */
export const SESSION_EXPIRES_IN = 60 * 60 * 24 * 60
export const SESSION_UPDATE_AGE = 60 * 60 * 24

/** The hosts of a Worker on this machine (wrangler dev, the tests). */
const LOCAL_HOSTS: ReadonlySet<string> = new Set(['127.0.0.1', 'localhost'])

/**
 * Email and password sign-in: ALLOW_PASSWORD_AUTH is "1" and the Worker is reached on this machine. A deployed Worker
 * never takes passwords, even if the var is copied there by mistake.
 */
export function passwordAuthAllowed(env: Env): boolean {
  if (env.ALLOW_PASSWORD_AUTH !== '1') return false
  try {
    return LOCAL_HOSTS.has(new URL(env.PUBLIC_BASE_URL).hostname)
  } catch {
    return false
  }
}

/**
 * The bundle ids Apple's id tokens may carry, from APPLE_BUNDLE_IDS (comma-separated), the current app first. Sign in
 * with Apple scopes a user's id to the developer team, so each app id signs in to its own accounts. Throws when the
 * var names none: no Apple sign-in could work.
 */
export function appleBundleIds(env: Pick<Env, 'APPLE_BUNDLE_IDS'>): string[] {
  const ids = env.APPLE_BUNDLE_IDS.split(',').map((id) => id.trim()).filter((id) => id.length > 0)
  if (ids.length === 0) throw new Error('APPLE_BUNDLE_IDS names no bundle id')
  return ids
}

/** The provider tokens Better Auth would keep on an `account` row. */
const PROVIDER_TOKENS = ['idToken', 'accessToken', 'refreshToken'] as const

/**
 * An account row's data with no provider token kept. Nothing reads them back: the app signs in with a fresh Apple
 * token every time, so a stored one would only be a signed copy of the user's email and Apple id for a leak to expose.
 */
function withoutProviderTokens(data: Record<string, unknown>): { data: Record<string, null> } {
  return { data: Object.fromEntries(PROVIDER_TOKENS.filter((key) => key in data).map((key) => [key, null])) }
}

/** Built per request, because the D1 binding only exists on `env`. Better Auth recognises D1 by its shape. */
export function createAuth(env: Env) {
  const bundleIds = appleBundleIds(env)
  return betterAuth({
    database: env.DB,
    secret: env.BETTER_AUTH_SECRET,
    baseURL: env.PUBLIC_BASE_URL,
    basePath: '/api/auth',
    emailAndPassword: { enabled: passwordAuthAllowed(env) },
    session: { expiresIn: SESSION_EXPIRES_IN, updateAge: SESSION_UPDATE_AGE },
    advanced: { database: { generateId: () => crypto.randomUUID() } },
    socialProviders: {
      apple: {
        // Native Sign in with Apple only: the app sends Apple's id token, whose audience is the app's bundle id, and
        // the raw nonce, whose SHA-256 the token must carry (checked in routes.ts before Better Auth, which would also
        // take the claim itself). There is no web flow, so no Services ID and no client secret.
        clientId: bundleIds[0],
        clientSecret: 'unused-native-id-token-only',
        appBundleIdentifier: bundleIds[0],
        audience: bundleIds,
      },
    },
    // encryptOAuthTokens would leave the id token in plain text (it covers access and refresh tokens only).
    databaseHooks: {
      account: {
        create: { before: async (account) => withoutProviderTokens(account) },
        update: { before: async (account) => withoutProviderTokens(account) },
      },
    },
    // bearer: the app's session token. claudeOAuth: Claude's OAuth. connectPlugin: /connect's sign-in.
    plugins: [bearer(), claudeOAuth(env), connectPlugin],
  })
}
