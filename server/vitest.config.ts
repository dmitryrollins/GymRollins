import path from 'node:path'
import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin'
import { defineConfig } from 'vitest/config'

// Tests run in workerd with an in-memory D1 per test file (never server/.wrangler/state), migrated by
// test/apply-migrations.ts. These bindings override wrangler.jsonc's vars.
export default defineConfig(async () => {
  const migrations = await readD1Migrations(path.join(import.meta.dirname, 'migrations'))
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: './wrangler.jsonc' },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            ALLOW_PASSWORD_AUTH: '1',
            BETTER_AUTH_SECRET: 'test-secret-test-secret-test-secret-000001',
            APPLE_BUNDLE_ID: 'com.rollins.gymrollins',
            PUBLIC_BASE_URL: 'http://localhost',
            OAUTH_REGISTRATIONS_PER_HOUR: '1000',
          },
        },
      }),
    ],
    test: { setupFiles: ['./test/apply-migrations.ts'] },
  }
})
