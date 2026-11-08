import type { D1Migration } from 'cloudflare:test'
import type { Env as ServerEnv } from '../src/env.ts'

declare global {
  namespace Cloudflare {
    interface Env extends ServerEnv {
      TEST_MIGRATIONS: D1Migration[]
    }
  }
}

export {}
