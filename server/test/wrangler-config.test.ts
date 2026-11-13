import { describe, expect, it } from 'vitest'
import packageSource from '../package.json?raw'
import wranglerSource from '../wrangler.jsonc?raw'
import { parseJsonc } from './jsonc.ts'

// wrangler.jsonc's top level is the deployed Worker, so a bare `wrangler deploy` can only ship the production values.
// Every local start of the Worker (scripts/*.sh, `npm run dev`) passes its own loopback PUBLIC_BASE_URL and keeps its
// real local origin. database_id may be the placeholder or the id `wrangler d1 create` printed.

interface Binding {
  readonly binding: string
  readonly remote?: boolean
}

interface WranglerConfig {
  readonly name: string
  readonly main: string
  readonly routes?: unknown
  readonly route?: unknown
  readonly workers_dev?: boolean
  readonly preview_urls?: boolean
  readonly vars: Readonly<Record<string, string>>
  readonly secrets?: unknown
  readonly env?: unknown
  readonly d1_databases: readonly (Binding & Readonly<Record<string, unknown>>)[]
  readonly r2_buckets: readonly (Binding & Readonly<Record<string, unknown>>)[]
  readonly dev: unknown
}

const ORIGIN = 'https://api.gymrollins.com'
const config = parseJsonc(wranglerSource) as WranglerConfig
const shellScripts = import.meta.glob<string>('../../scripts/*.sh', { query: '?raw', import: 'default', eager: true })
const npmScripts = (JSON.parse(packageSource) as { scripts: Record<string, string> }).scripts

/** The `wrangler dev` commands of a shell script: continuation lines joined, comment lines left out. */
function wranglerDevCommands(source: string): string[] {
  return source
    .replace(/\\\n\s*/g, ' ')
    .split('\n')
    .filter((line) => !/^\s*#/.test(line) && /\bwrangler dev\b/.test(line))
}

const localStarts: readonly { readonly where: string; readonly command: string }[] = [
  ...Object.entries(shellScripts).flatMap(([path, source]) =>
    wranglerDevCommands(source).map((command) => ({ where: path, command }))),
  ...Object.entries(npmScripts)
    .filter(([, command]) => /\bwrangler dev\b/.test(command))
    .map(([name, command]) => ({ where: `npm run ${name}`, command })),
]

describe('parseJsonc', () => {
  it('drops comments and trailing commas, never inside a string', () => {
    expect(parseJsonc('{\n  // a comment\n  "url": "http://x//y", /* block */ "list": ["a,]", "b",],\n}'))
      .toEqual({ url: 'http://x//y', list: ['a,]', 'b'] })
  })
})

describe('wrangler.jsonc, the deployed Worker', () => {
  it('answers on the custom domain api.gymrollins.com only: no workers.dev address and no preview URLs', () => {
    expect(config.routes).toEqual([{ pattern: 'api.gymrollins.com', custom_domain: true }])
    expect(config.route).toBeUndefined()
    expect(config.workers_dev).toBe(false)
    expect(config.preview_urls).toBe(false)
  })

  it('builds the OAuth issuer and the MCP resource from the https origin, and takes no passwords', () => {
    expect(config.vars).toEqual({
      ALLOW_PASSWORD_AUTH: '0',
      APPLE_BUNDLE_IDS: 'com.gymrollins.app,com.rollins.gymrollins',
      PUBLIC_BASE_URL: ORIGIN,
    })
    expect(`https://${(config.routes as { pattern: string }[])[0].pattern}`).toBe(config.vars.PUBLIC_BASE_URL)
  })

  it('is never deployed without BETTER_AUTH_SECRET', () => {
    expect(config.secrets).toEqual({ required: ['BETTER_AUTH_SECRET'] })
  })

  it('is one configuration: no wrangler environment a deploy could pick instead', () => {
    expect(config.env).toBeUndefined()
    expect(config.name).toBe('gymrollins')
    expect(config.main).toBe('src/index.ts')
  })

  it('keeps the D1 database and the three R2 buckets, with database_id a UUID (the placeholder until d1 create)', () => {
    expect(config.d1_databases).toHaveLength(1)
    const [d1] = config.d1_databases
    expect(d1).toMatchObject({ binding: 'DB', database_name: 'gymrollins', migrations_dir: 'migrations' })
    expect(d1.database_id).toMatch(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/)
    expect(config.r2_buckets).toEqual([
      { binding: 'GYM_PHOTOS', bucket_name: 'gym-photos' },
      { binding: 'GYM_PHOTOS_PRIVATE', bucket_name: 'gym-photos-private' },
      { binding: 'EXERCISE_PHOTOS', bucket_name: 'exercise-photos' },
    ])
  })

  it('gives local dev no remote binding and the local address 127.0.0.1:8787', () => {
    for (const binding of [...config.d1_databases, ...config.r2_buckets]) {
      expect(binding.remote, binding.binding).toBeUndefined()
    }
    expect(config.dev).toEqual({ ip: '127.0.0.1', port: 8787 })
  })
})

describe('the local Worker never takes the production values', () => {
  it('finds every local start: scripts/server-up.sh, scripts/test-server.sh and npm run dev', () => {
    expect(localStarts.map(({ where }) => where)).toEqual(
      expect.arrayContaining(['../../scripts/server-up.sh', '../../scripts/test-server.sh', 'npm run dev']))
  })

  it('runs local, with a loopback PUBLIC_BASE_URL and its real local origin', () => {
    for (const { where, command } of localStarts) {
      expect(command, where).toMatch(/\s--local(\s|$)/)
      expect(command, where).not.toMatch(/--remote/)
      expect(command, where).toMatch(/\s--infer-origin-from-routes=false(\s|$)/)
      expect(command, where).toMatch(/\s--var "?PUBLIC_BASE_URL:(http:\/\/127\.0\.0\.1:\d+|\$TEST_API_URL)[\s"]/)
    }
  })

  it('names the address each local Worker listens on', () => {
    const port = (config.dev as { port: number }).port
    const serverUp = localStarts.find(({ where }) => where.endsWith('/server-up.sh'))
    expect(serverUp?.command).toContain(`PUBLIC_BASE_URL:http://127.0.0.1:${port}`)
    expect(npmScripts.dev).toContain(`PUBLIC_BASE_URL:http://127.0.0.1:${port}`)
    expect(shellScripts['../../scripts/test-server.sh']).toContain('TEST_API_URL="http://127.0.0.1:$TEST_API_PORT"')
  })
})
