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
  /** The audience of Apple's id tokens for the app. */
  APPLE_BUNDLE_ID: string
  /** The address the Worker is reached at: Better Auth's base URL. */
  PUBLIC_BASE_URL: string
  /** "1" turns on email and password sign-in: debug builds and tests only. */
  ALLOW_PASSWORD_AUTH?: string
}

export interface AppEnv {
  Bindings: Env
  Variables: { userId: string }
}
