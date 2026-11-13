/** The Worker's bindings and vars (wrangler.jsonc; secrets in server/.dev.vars locally). */
export interface Env {
  DB: D1Database
  /** gym-photos: shared listing photos, read by anyone through /photos/shared. */
  GYM_PHOTOS: R2Bucket
  /** gym-photos-private: private listing photos, their owner only. */
  GYM_PHOTOS_PRIVATE: R2Bucket
  /** exercise-photos: GymRollins' own photos and manifest.json, read by anyone through /photos/exercises. */
  EXERCISE_PHOTOS: R2Bucket
  BETTER_AUTH_SECRET: string
  /**
   * The audiences of Apple's id tokens: the app's bundle ids, comma-separated (`appleBundleIds`). The first is the
   * current app; the rest are older builds that still sign in.
   */
  APPLE_BUNDLE_IDS: string
  /** The address the Worker is reached at: Better Auth's base URL. */
  PUBLIC_BASE_URL: string
  /** "1" turns on email and password sign-in: debug builds and tests only. */
  ALLOW_PASSWORD_AUTH?: string
  /** New OAuth clients allowed per rolling hour (src/auth/routes.ts); 30 when unset. The tests raise it. */
  OAUTH_REGISTRATIONS_PER_HOUR?: string
}

export interface AppEnv {
  Bindings: Env
  Variables: { userId: string }
}
