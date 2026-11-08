import { betterAuth } from 'better-auth'
import { bearer } from 'better-auth/plugins'
import type { Env } from '../env.ts'

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

/** Built per request, because the D1 binding only exists on `env`. Better Auth recognises D1 by its shape. */
export function createAuth(env: Env) {
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
        // the raw nonce (Better Auth accepts the token's nonce claim as the raw value or its SHA-256). There is no web
        // flow, so no Services ID and no client secret.
        clientId: env.APPLE_BUNDLE_ID,
        clientSecret: 'unused-native-id-token-only',
        appBundleIdentifier: env.APPLE_BUNDLE_ID,
      },
    },
    plugins: [bearer()],
  })
}
