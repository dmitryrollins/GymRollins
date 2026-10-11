#!/usr/bin/env node
// Static server for the OAuth consent page (web/consent/), because Supabase rewrites Edge Function HTML
// responses to text/plain (docs/research/2026-09-26-mcp-on-supabase.md §5) so the consent page can't be an Edge
// Function. Binds to 127.0.0.1 only. Serves web/consent/* as-is, maps /oauth/consent to index.html, and generates
// /config.js (window.GYM_CONFIG: url, anonKey only — never a service key, read from supabase/.env.local) as an
// external, no-store script so the CSP needs no 'unsafe-inline'.
//
// Run directly: node scripts/consent-server.mjs [--port 55430] [--env-file supabase/.env.local]
// Importable for tests: `import { createServer, loadGymConfig, resolveStaticPath, configScript } from './consent-server.mjs'`

import { createServer as createHttpServer } from 'node:http'
import { readFile, realpath } from 'node:fs/promises'
import { existsSync, readFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

export const CONSENT_ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'web', 'consent')
const DEFAULT_ENV_FILE = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'supabase', '.env.local')
const DEFAULT_PORT = 55430
const DEFAULT_HOST = '127.0.0.1'

const CONFIG_PATH = '/config.js'
const NEVER_INJECT_KEYS = ['SERVICE_ROLE_KEY', 'SECRET_KEY', 'JWT_SECRET', 'DB_URL', 'S3_PROTOCOL_ACCESS_KEY_SECRET']

const CONTENT_TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
}

/** Parses `KEY="value"` / `KEY=value` lines (the shape `supabase status -o env` writes). Quotes are stripped. */
export function parseEnvFile(text) {
  const out = {}
  for (const rawLine of text.split('\n')) {
    const line = rawLine.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq === -1) continue
    const key = line.slice(0, eq).trim()
    let value = line.slice(eq + 1).trim()
    if (
      (value.startsWith('"') && value.endsWith('"') && value.length >= 2) ||
      (value.startsWith("'") && value.endsWith("'") && value.length >= 2)
    ) {
      value = value.slice(1, -1)
    }
    out[key] = value
  }
  return out
}

/** Reads supabase/.env.local and returns only what the consent page needs: the API URL and the anon key. */
export function loadGymConfig(envFile = DEFAULT_ENV_FILE) {
  if (!existsSync(envFile)) {
    throw new Error(
      `${envFile} not found. Run scripts/supabase-up.sh first (it writes this file from \`supabase status -o env\`).`,
    )
  }
  const parsed = parseEnvFile(readFileSync(envFile, 'utf8'))
  const apiUrl = parsed.API_URL
  const anonKey = parsed.ANON_KEY
  if (!apiUrl || !anonKey) {
    throw new Error(`${envFile} is missing API_URL or ANON_KEY.`)
  }
  return { apiUrl, anonKey }
}

/**
 * Builds the CSP for the consent page: scripts only from this origin (consent.js, config.js) and esm.sh
 * (supabase-js), no inline script or style; connect-src is exactly the Supabase API origin.
 */
export function contentSecurityPolicy(apiUrl) {
  return [
    "default-src 'self'",
    "script-src 'self' https://esm.sh",
    "style-src 'self'",
    `connect-src ${apiUrl}`,
    "base-uri 'none'",
    "form-action 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'",
  ].join('; ')
}

/** The body of /config.js: only the API URL and the anon key. Refuses configs that carry a secret. */
export function configScript(config) {
  for (const key of NEVER_INJECT_KEYS) {
    if (key in config) throw new Error(`refusing to serve ${key} to the consent page`)
  }
  const json = JSON.stringify({ url: config.apiUrl, anonKey: config.anonKey }).replace(/</g, '\\u003c')
  return `window.GYM_CONFIG = ${json};\n`
}

/**
 * Resolves a request path to a file under `root`, refusing anything that would escape it (`..`, absolute
 * overrides, symlink escapes). Returns null when the path is unsafe or doesn't exist.
 */
export async function resolveStaticPath(root, requestPath) {
  const decoded = (() => {
    try {
      return decodeURIComponent(requestPath)
    } catch {
      return null
    }
  })()
  if (decoded === null || decoded.includes('\0')) return null

  const relative = decoded.replace(/^\/+/, '')
  const joined = path.join(root, relative)
  const normalizedRoot = path.normalize(root + path.sep)
  if (!path.normalize(joined).startsWith(normalizedRoot) && path.normalize(joined) !== path.normalize(root)) {
    return null
  }

  let realRoot
  let realTarget
  try {
    realRoot = await realpath(root)
    realTarget = await realpath(joined)
  } catch {
    return null
  }
  const realRootWithSep = realRoot.endsWith(path.sep) ? realRoot : realRoot + path.sep
  if (realTarget !== realRoot && !realTarget.startsWith(realRootWithSep)) return null
  return realTarget
}

async function serveFile(res, filePath, extraHeaders) {
  const ext = path.extname(filePath)
  const contentType = CONTENT_TYPES[ext]
  if (!contentType) {
    res.writeHead(404, extraHeaders)
    res.end('Not found')
    return
  }
  let body
  try {
    body = await readFile(filePath, 'utf8')
  } catch {
    res.writeHead(404, extraHeaders)
    res.end('Not found')
    return
  }
  res.writeHead(200, { 'content-type': contentType, ...extraHeaders })
  res.end(body)
}

/**
 * Creates (but does not start) the consent server. `root` defaults to web/consent; `config` defaults to what
 * loadGymConfig() reads from supabase/.env.local. Exposed for tests, which pass a temp root/config.
 */
export function createServer({ root = CONSENT_ROOT, config = loadGymConfig() } = {}) {
  const csp = contentSecurityPolicy(config.apiUrl)
  const securityHeaders = {
    'content-security-policy': csp,
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'referrer-policy': 'no-referrer',
  }

  return createHttpServer(async (req, res) => {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405, { ...securityHeaders, allow: 'GET, HEAD' })
      res.end('Method not allowed')
      return
    }

    const url = new URL(req.url, `http://${req.headers.host ?? 'localhost'}`)
    if (url.pathname === CONFIG_PATH) {
      res.writeHead(200, {
        'content-type': CONTENT_TYPES['.js'],
        'cache-control': 'no-store',
        ...securityHeaders,
      })
      res.end(req.method === 'HEAD' ? '' : configScript(config))
      return
    }
    const pathname = url.pathname === '/oauth/consent' || url.pathname === '/' ? '/index.html' : url.pathname

    const resolved = await resolveStaticPath(root, pathname)
    if (!resolved) {
      res.writeHead(404, securityHeaders)
      res.end('Not found')
      return
    }

    if (req.method === 'HEAD') {
      const ext = path.extname(resolved)
      const contentType = CONTENT_TYPES[ext]
      if (!contentType) {
        res.writeHead(404, securityHeaders)
      } else {
        res.writeHead(200, { 'content-type': contentType, ...securityHeaders })
      }
      res.end()
      return
    }

    await serveFile(res, resolved, securityHeaders)
  })
}

function parseArgs(argv) {
  const args = { port: DEFAULT_PORT, host: DEFAULT_HOST, envFile: DEFAULT_ENV_FILE }
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--port') args.port = Number(argv[++i])
    else if (argv[i] === '--env-file') args.envFile = argv[++i]
  }
  return args
}

const isMain = process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])
if (isMain) {
  const args = parseArgs(process.argv.slice(2))
  let config
  try {
    config = loadGymConfig(args.envFile)
  } catch (err) {
    console.error(err.message)
    process.exit(1)
  }
  const server = createServer({ config })
  server.listen(args.port, args.host, () => {
    console.log(`Consent page: http://${args.host}:${args.port}/oauth/consent`)
  })
  const shutdown = () => server.close(() => process.exit(0))
  process.on('SIGINT', shutdown)
  process.on('SIGTERM', shutdown)
}
