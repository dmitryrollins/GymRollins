#!/usr/bin/env node
// Uploads GymRollins' own exercise photos (own-<id>-<frame>.jpg from the gitignored media/photos/, where the generator
// writes, and from ios/GymRollins/Resources/OwnPhotos/, the bundled ones) to the public `exercise-photos` Supabase
// Storage bucket, then writes `manifest.json` into the bucket so the app knows which exercises have hosted photos
// without listing the bucket. See docs/media/README.md ("Hosting"). Nothing is moved or deleted locally.
//
// Usage: node scripts/upload-photos.mjs [--dry-run] [--target local|remote] [--dir <photo folder>]...
//   --dir (repeatable) replaces the two default folders. A name present in several folders uses the first folder
//   (media/photos before the bundle); differing copies are reported.
//   --target local (default): the local stack (scripts/supabase-up.sh), URL + service-role key from
//                             supabase/.env.local; refuses anything that isn't a loopback URL.
//   --target remote:          SUPABASE_URL (https) + SUPABASE_SERVICE_ROLE_KEY from the environment or the gitignored
//                             app/.env. The key is never logged.
//
// Idempotent: an object is skipped when the bucket already holds one with the same size and MD5 (Storage's eTag for
// single-part uploads). Photos get `cache-control: max-age=31536000`; the manifest `max-age=60`. The manifest is built
// from the bucket listing after the uploads (so it only lists objects that really landed), and is only rewritten when
// its content changed:
//   { "version": 1, "updatedAt": "<ISO>", "photos": { "<id>": <frame count> }, "rev": { "<id>": "<12 hex>" } }
// `rev` changes whenever any frame of that exercise changes; the app appends it as `?v=<rev>` so a regenerated photo
// isn't served from the long-lived caches.
//
// Storage API (checked 2026-09-29 against the local stack, supabase CLI 2.118.0):
//   POST /storage/v1/object/<bucket>/<name>       upload (x-upsert: true overwrites; cache-control stored as sent)
//   POST /storage/v1/object/list/<bucket>         { prefix, limit, offset, sortBy } -> [{ name, metadata: { size, eTag } }]
//   GET  /storage/v1/object/authenticated/<bucket>/<name>  read with the service key (bypasses the public CDN copy)
import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(import.meta.dirname, '..')
export const BUCKET = 'exercise-photos'
export const MANIFEST_NAME = 'manifest.json'
const PHOTO_NAME = /^own-(\d+)-(\d+)\.jpg$/
const PHOTO_CACHE = 'max-age=31536000'
const MANIFEST_CACHE = 'max-age=60'
const LIST_PAGE = 1000
const MAX_ATTEMPTS = 3
const CONCURRENCY = 4

export const PATHS = {
  /** Upload sources, in precedence order: generated (gitignored) first, then the photos bundled in the app. */
  photoDirs: [resolve(ROOT, 'media/photos'), resolve(ROOT, 'ios/GymRollins/Resources/OwnPhotos')],
  envFile: resolve(ROOT, '.env'),
  localEnvFile: resolve(ROOT, 'supabase/.env.local'),
}

// ---------- args / config ----------

export function parseArgs(argv) {
  const args = { dryRun: false, target: 'local', dirs: [] }
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i]
    const value = () => {
      if (i + 1 >= argv.length) throw new Error(`${flag} needs a value`)
      return argv[++i]
    }
    if (flag === '--dry-run') args.dryRun = true
    else if (flag === '--target') {
      args.target = value()
      if (!['local', 'remote'].includes(args.target)) throw new Error(`--target must be local or remote, got "${args.target}"`)
    } else if (flag === '--dir') args.dirs.push(value())
    else throw new Error(`Unknown flag ${flag}`)
  }
  return args
}

/** True only for loopback URLs (the local Supabase stack). */
export function isLocalUrl(value) {
  try {
    const { hostname } = new URL(value)
    return hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '[::1]'
  } catch {
    return false
  }
}

function readEnvFile(file) {
  if (!file || !existsSync(file)) return {}
  const values = {}
  for (const line of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const match = line.match(/^\s*(?:export\s+)?([A-Z0-9_]+)\s*=\s*(.*?)\s*$/)
    if (match) values[match[1]] = match[2].replace(/^(['"])(.*)\1$/, '$2')
  }
  return values
}

const trimSlash = url => url.replace(/\/+$/, '')

/** Where to upload and with which key. Local: supabase/.env.local only (never a cloud URL). Remote: env, then .env. */
export function resolveTarget({ target, env = process.env, envFile = PATHS.envFile, localEnvFile = PATHS.localEnvFile }) {
  if (target === 'local') {
    if (!existsSync(localEnvFile)) throw new Error(`Missing ${localEnvFile} — run scripts/supabase-up.sh first`)
    const local = readEnvFile(localEnvFile)
    const url = trimSlash(local.API_URL ?? '')
    if (!isLocalUrl(url)) throw new Error(`API_URL in ${localEnvFile} is not the local stack; use --target remote for a cloud project`)
    if (!local.SERVICE_ROLE_KEY) throw new Error(`SERVICE_ROLE_KEY missing from ${localEnvFile}`)
    return { url, key: local.SERVICE_ROLE_KEY }
  }
  const file = readEnvFile(envFile)
  const url = trimSlash(env.SUPABASE_URL?.trim() || file.SUPABASE_URL || '')
  const key = env.SUPABASE_SERVICE_ROLE_KEY?.trim() || file.SUPABASE_SERVICE_ROLE_KEY
  if (!url.startsWith('https://')) throw new Error('--target remote needs SUPABASE_URL=https://<project>.supabase.co')
  if (!key) throw new Error('--target remote needs SUPABASE_SERVICE_ROLE_KEY (environment or app/.env, gitignored)')
  return { url, key }
}

// ---------- pure planning ----------

/**
 * Local photos named own-<digits>-<digits>.jpg from `dirs` (missing folders are skipped), sorted by name, with size
 * and MD5. A name found in several folders comes from the first one; a differing copy is reported via `log`.
 */
export function scanPhotos(dirs, log = () => {}) {
  const byName = new Map()
  for (const dir of dirs.filter(d => existsSync(d))) {
    for (const name of readdirSync(dir).filter(n => PHOTO_NAME.test(n))) {
      const path = join(dir, name)
      const photo = { name, path, size: statSync(path).size, md5: createHash('md5').update(readFileSync(path)).digest('hex') }
      const first = byName.get(name)
      if (!first) byName.set(name, photo)
      else if (first.md5 !== photo.md5) log(`note: ${name} differs between ${first.path} and ${path}; uploading the first`)
    }
  }
  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name))
}

/**
 * `remote`: Map name -> { size, etag, cacheControl? }. Same size and MD5 = already there, unless the object was stored
 * with a different cache-control (e.g. by another uploader): then it is re-uploaded to fix the header.
 */
export function planUploads(local, remote) {
  const upload = []
  const skip = []
  for (const photo of local) {
    const existing = remote.get(photo.name)
    const sameHeaders = existing?.cacheControl === undefined || existing.cacheControl === PHOTO_CACHE
    if (existing && existing.size === photo.size && existing.etag === photo.md5 && sameHeaders) skip.push(photo)
    else upload.push(photo)
  }
  return { upload, skip }
}

/** The manifest for the objects in the bucket (`[{ name, etag }]`). Frames count contiguously from 0. */
export function buildManifest(objects, now = new Date()) {
  const byId = new Map()
  for (const { name, etag } of objects) {
    const match = name.match(PHOTO_NAME)
    if (!match) continue
    const frames = byId.get(match[1]) ?? new Map()
    frames.set(Number(match[2]), etag ?? '')
    byId.set(match[1], frames)
  }
  const photos = {}
  const rev = {}
  for (const id of [...byId.keys()].sort()) {
    const frames = byId.get(id)
    let count = 0
    while (frames.has(count)) count++
    if (count === 0) continue
    photos[id] = count
    const tags = Array.from({ length: count }, (_, frame) => frames.get(frame)).join('|')
    rev[id] = createHash('sha256').update(tags).digest('hex').slice(0, 12)
  }
  return { version: 1, updatedAt: now.toISOString(), photos, rev }
}

const sameContent = (a, b) => !!a && !!b && JSON.stringify(a.photos) === JSON.stringify(b.photos) &&
  JSON.stringify(a.rev) === JSON.stringify(b.rev)

// ---------- Storage API ----------

function storageClient({ url, key, fetch }) {
  const auth = { authorization: `Bearer ${key}`, apikey: key }
  const objectURL = name => `${url}/storage/v1/object/${BUCKET}/${encodeURIComponent(name)}`

  async function list() {
    const objects = new Map()
    for (let offset = 0; ; offset += LIST_PAGE) {
      const response = await fetch(`${url}/storage/v1/object/list/${BUCKET}`, {
        method: 'POST',
        headers: { ...auth, 'content-type': 'application/json' },
        body: JSON.stringify({ prefix: '', limit: LIST_PAGE, offset, sortBy: { column: 'name', order: 'asc' } }),
      })
      if (!response.ok) throw new Error(`Listing bucket ${BUCKET} failed: HTTP ${response.status}`)
      const page = await response.json()
      for (const item of page) {
        if (!item?.metadata) continue // folders
        objects.set(item.name, {
          size: item.metadata.size,
          etag: String(item.metadata.eTag ?? '').replaceAll('"', ''),
          cacheControl: item.metadata.cacheControl,
        })
      }
      if (page.length < LIST_PAGE) return objects
    }
  }

  async function upload(name, body, contentType, cacheControl) {
    const response = await fetch(objectURL(name), {
      method: 'POST',
      headers: { ...auth, 'content-type': contentType, 'cache-control': cacheControl, 'x-upsert': 'true' },
      body,
    })
    if (!response.ok) throw new Error(`HTTP ${response.status}`)
  }

  /** Reads through the authenticated endpoint: the public URL may be a stale CDN copy (manifest max-age=60). */
  async function storedJSON(name) {
    const response = await fetch(`${url}/storage/v1/object/authenticated/${BUCKET}/${encodeURIComponent(name)}`, {
      headers: { ...auth, 'cache-control': 'no-cache' },
    })
    if (!response.ok) return null
    try { return await response.json() } catch { return null }
  }

  return { list, upload, storedJSON }
}

async function withRetry(fn, { attempts = MAX_ATTEMPTS, delayMs = 500 } = {}) {
  for (let attempt = 1; ; attempt++) {
    try {
      return await fn()
    } catch (error) {
      if (attempt >= attempts) throw error
      await new Promise(done => setTimeout(done, delayMs * attempt))
    }
  }
}

async function forEachLimited(items, limit, fn) {
  let next = 0
  const worker = async () => {
    while (next < items.length) await fn(items[next++])
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker))
}

/**
 * Uploads new/changed photos from `dir`, then the manifest. Returns
 * { uploaded, skipped, failed, manifest: 'uploaded'|'unchanged'|'dry-run', photos } (photos = exercises in the manifest).
 */
export async function uploadPhotos({
  url, key, dirs = PATHS.photoDirs, dryRun = false, fetch = globalThis.fetch, log = console.log,
  now = () => new Date(), retryDelayMs = 500,
}) {
  const client = storageClient({ url, key, fetch })
  const local = scanPhotos(dirs, log)
  const remote = await client.list()
  const { upload, skip } = planUploads(local, remote)
  log(`${local.length} local photos in ${dirs.join(', ')}; ${skip.length} already in ${BUCKET}, ${upload.length} to upload (${url})`)

  if (dryRun) {
    for (const photo of upload) log(`would upload ${photo.name} (${photo.size} bytes)`)
    const after = new Map(remote)
    for (const photo of upload) after.set(photo.name, { size: photo.size, etag: photo.md5 })
    const manifest = buildManifest([...after].map(([name, o]) => ({ name, etag: o.etag })), now())
    log(`would write ${MANIFEST_NAME}: ${Object.keys(manifest.photos).length} exercises`)
    return { uploaded: upload.length, skipped: skip.length, failed: 0, manifest: 'dry-run', photos: Object.keys(manifest.photos).length }
  }

  let uploaded = 0
  let failed = 0
  await forEachLimited(upload, CONCURRENCY, async photo => {
    try {
      await withRetry(() => client.upload(photo.name, readFileSync(photo.path), 'image/jpeg', PHOTO_CACHE),
        { delayMs: retryDelayMs })
      uploaded++
      log(`uploaded ${photo.name}`)
    } catch (error) {
      failed++
      log(`FAILED ${photo.name}: ${error.message}`)
    }
  })

  const objects = await client.list()
  const manifest = buildManifest([...objects].map(([name, o]) => ({ name, etag: o.etag })), now())
  const photos = Object.keys(manifest.photos).length
  if (sameContent(manifest, await client.storedJSON(MANIFEST_NAME))) {
    log(`${MANIFEST_NAME} unchanged (${photos} exercises)`)
    return { uploaded, skipped: skip.length, failed, manifest: 'unchanged', photos }
  }
  await withRetry(() => client.upload(MANIFEST_NAME, JSON.stringify(manifest), 'application/json', MANIFEST_CACHE),
    { delayMs: retryDelayMs })
  log(`wrote ${MANIFEST_NAME} (${photos} exercises)`)
  return { uploaded, skipped: skip.length, failed, manifest: 'uploaded', photos }
}

async function main() {
  const args = parseArgs(process.argv.slice(2))
  const { url, key } = resolveTarget({ target: args.target })
  const dirs = args.dirs.length > 0 ? args.dirs.map(d => resolve(d)) : PATHS.photoDirs
  const summary = await uploadPhotos({ url, key, dirs, dryRun: args.dryRun })
  console.log(`done: ${summary.uploaded} ${args.dryRun ? 'to upload' : 'uploaded'}, ${summary.skipped} skipped, ` +
    `${summary.failed} failed; manifest ${summary.manifest} (${summary.photos} exercises)`)
  if (summary.failed > 0) process.exitCode = 1
}

const isEntryPoint = () => {
  try {
    return !!process.argv[1] && realpathSync(process.argv[1]) === realpathSync(fileURLToPath(import.meta.url))
  } catch {
    return false
  }
}

if (isEntryPoint()) {
  main().catch(error => {
    console.error(`upload-photos: ${error.message}`)
    process.exitCode = 1
  })
}
