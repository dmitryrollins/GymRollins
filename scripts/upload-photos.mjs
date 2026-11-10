#!/usr/bin/env node
// Uploads GymRollins' own exercise photos (own-<id>-<frame>.jpg from the gitignored media/photos/, where the generator
// writes, and from ios/GymRollins/Resources/OwnPhotos/, the bundled ones) to the `exercise-photos` R2 bucket behind the
// Worker, then writes `manifest.json` into the bucket so the app knows which exercises have hosted photos without
// listing the bucket. Equipment kind photos (kind-<kindId>.jpg, shown for a gym listing that has no photo of its own)
// travel the same way: drop one into either folder and run this, no app release needed. See docs/media/README.md
// ("Hosting"). Nothing is moved or deleted locally, and nothing in the bucket is deleted.
//
// Usage: node scripts/upload-photos.mjs [--dry-run] [--target worker|cloud] [--dir <photo folder>]...
//   --dir (repeatable) replaces the two default folders. A name present in several folders uses the first folder
//   (media/photos before the bundle); differing copies are reported.
//   --target worker (default): the local Worker (scripts/server-up.sh) at WORKER_URL or http://127.0.0.1:8787. Writes
//                             go through `wrangler r2 object put --local` into server/.wrangler/state (WORKER_STATE
//                             names another local state folder), the folder `wrangler dev` reads. Loopback only.
//   --target cloud:           the deployed Worker at WORKER_URL (https only). Writes go through
//                             `wrangler r2 object put --remote` with the owner's Cloudflare login. It runs only with
//                             GYM_CLOUD_APPROVED=1, which says the owner approved this upload (docs/cloudflare-checklist.md).
// Reads always go through the Worker's public route, /photos/exercises/<name>: HEAD gives an object's size and ETag
// (its MD5), GET the stored manifest.
//
// Idempotent: an object is skipped when the bucket already holds one with the same size and MD5. Photos get
// `cache-control: max-age=31536000`; the manifest `max-age=60`. The manifest is built after the uploads from what the
// bucket holds (so it lists only objects that really landed): the local photos, and every photo the stored manifest
// already listed, so photos uploaded earlier from another checkout stay listed. It is only rewritten when its content
// changed:
//   { "version": 1, "updatedAt": "<ISO>", "photos": { "<id>": <frame count> }, "rev": { "<id>": "<12 hex>" },
//     "kinds": { "<kindId>": "<12 hex>" } }
// `rev` changes whenever any frame of that exercise changes; the app appends it as `?v=<rev>` so a regenerated photo
// isn't served from the long-lived caches. `kinds` does the same for kind photos (an older app ignores the key).
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs'
import { join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(import.meta.dirname, '..')
export const BUCKET = 'exercise-photos'
export const MANIFEST_NAME = 'manifest.json'
const PHOTO_NAME = /^own-(\d+)-(\d+)\.jpg$/
const KIND_PHOTO_NAME = /^kind-([a-z0-9-]{1,40})\.jpg$/
const isPhotoName = name => PHOTO_NAME.test(name) || KIND_PHOTO_NAME.test(name)
const shortHash = text => createHash('sha256').update(text).digest('hex').slice(0, 12)
const PHOTO_CACHE = 'max-age=31536000'
const MANIFEST_CACHE = 'max-age=60'
const MAX_ATTEMPTS = 3
/** Remote puts run side by side; local ones one at a time, because each starts its own local R2 on the same folder. */
const REMOTE_CONCURRENCY = 4
const DEFAULT_WORKER_URL = 'http://127.0.0.1:8787'
/** The owner's approval for one cloud upload, given in the environment of that run only. */
export const APPROVAL = 'GYM_CLOUD_APPROVED'

export const PATHS = {
  /** Upload sources, in precedence order: generated (gitignored) first, then the photos bundled in the app. */
  photoDirs: [resolve(ROOT, 'media/photos'), resolve(ROOT, 'ios/GymRollins/Resources/OwnPhotos')],
  /** The local Worker's project and state folder (wrangler dev's default, named in scripts/server-up.sh). */
  serverDir: resolve(ROOT, 'server'),
  // WORKER_STATE names another local state folder: the photo E2E's throwaway Worker (scripts/test-photo-hosting.sh).
  workerState: process.env.WORKER_STATE ? resolve(process.env.WORKER_STATE) : resolve(ROOT, 'server/.wrangler/state'),
}

// ---------- args / config ----------

export function parseArgs(argv) {
  const args = { dryRun: false, target: 'worker', dirs: [] }
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i]
    const value = () => {
      if (i + 1 >= argv.length) throw new Error(`${flag} needs a value`)
      return argv[++i]
    }
    if (flag === '--dry-run') args.dryRun = true
    else if (flag === '--target') {
      args.target = value()
      if (!['worker', 'cloud'].includes(args.target)) {
        throw new Error(`--target must be worker or cloud, got "${args.target}"`)
      }
    } else if (flag === '--dir') args.dirs.push(value())
    else throw new Error(`Unknown flag ${flag}`)
  }
  return args
}

/** True only for loopback URLs (the local Worker). */
export function isLocalUrl(value) {
  try {
    const { hostname } = new URL(value)
    return hostname === '127.0.0.1' || hostname === 'localhost' || hostname === '[::1]'
  } catch {
    return false
  }
}

const trimSlash = url => url.replace(/\/+$/, '')

/**
 * Where to upload. worker: the local Worker only. cloud: the deployed Worker over https, and only with the owner's
 * approval in the environment.
 */
export function resolveTarget({ target, env = process.env }) {
  if (target === 'worker') {
    const url = trimSlash(env.WORKER_URL?.trim() || DEFAULT_WORKER_URL)
    if (!isLocalUrl(url)) throw new Error(`WORKER_URL (${url}) is not the local Worker; the deployed one is --target cloud`)
    return { url, remote: false }
  }
  if (env[APPROVAL] !== '1') {
    throw new Error(`--target cloud writes to the deployed bucket: set ${APPROVAL}=1 only with the owner's approval`)
  }
  const url = trimSlash(env.WORKER_URL?.trim() || '')
  if (!url.startsWith('https://') || isLocalUrl(url)) {
    throw new Error('--target cloud needs WORKER_URL=https://<the deployed Worker>')
  }
  return { url, remote: true }
}

// ---------- pure planning ----------

/**
 * Local photos named own-<digits>-<digits>.jpg or kind-<kindId>.jpg from `dirs` (missing folders are skipped), sorted by
 * name, with size and MD5. A name found in several folders comes from the first one; a differing copy is reported via
 * `log`.
 */
export function scanPhotos(dirs, log = () => {}) {
  const byName = new Map()
  for (const dir of dirs.filter(d => existsSync(d))) {
    for (const name of readdirSync(dir).filter(isPhotoName)) {
      const path = join(dir, name)
      const photo = { name, path, size: statSync(path).size, md5: createHash('md5').update(readFileSync(path)).digest('hex') }
      const first = byName.get(name)
      if (!first) byName.set(name, photo)
      else if (first.md5 !== photo.md5) log(`note: ${name} differs between ${first.path} and ${path}; uploading the first`)
    }
  }
  return [...byName.values()].sort((a, b) => a.name.localeCompare(b.name))
}

/** `remote`: Map name -> { size, etag, cacheControl? }. Same size and MD5 (and cache-control, when known) = already there. */
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
  const kinds = {}
  for (const { name, etag } of objects) {
    const kind = name.match(KIND_PHOTO_NAME)
    if (kind) kinds[kind[1]] = shortHash(etag ?? '')
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
    rev[id] = shortHash(tags)
  }
  const sortedKinds = Object.fromEntries(Object.entries(kinds).sort(([a], [b]) => a.localeCompare(b)))
  return { version: 1, updatedAt: now.toISOString(), photos, rev, kinds: sortedKinds }
}

/** The object names a stored manifest lists, so photos uploaded from another checkout stay in the next manifest. */
export function namesIn(manifest) {
  const names = []
  for (const [id, count] of Object.entries(manifest?.photos ?? {})) {
    if (!/^\d+$/.test(id) || !Number.isInteger(count) || count < 1 || count > 20) continue
    for (let frame = 0; frame < count; frame++) names.push(`own-${id}-${frame}.jpg`)
  }
  for (const kind of Object.keys(manifest?.kinds ?? {})) {
    if (KIND_PHOTO_NAME.test(`kind-${kind}.jpg`)) names.push(`kind-${kind}.jpg`)
  }
  return names
}

const sameContent = (a, b) => !!a && !!b && JSON.stringify(a.photos) === JSON.stringify(b.photos) &&
  JSON.stringify(a.rev) === JSON.stringify(b.rev) && JSON.stringify(a.kinds ?? {}) === JSON.stringify(b.kinds ?? {})

// ---------- the bucket, through the Worker and wrangler ----------

/**
 * The bucket behind a Worker. Reads go through the Worker's public route, whose ETag is the object's MD5. Writes go
 * through `wrangler r2 object put`: --local into the local state folder (which a running `wrangler dev` sees at once),
 * or --remote into the deployed bucket.
 */
export function workerClient({ url, fetch, run = runWrangler, remote = false }) {
  const publicURL = name => `${url}/photos/exercises/${encodeURIComponent(name)}`

  async function list(names) {
    const objects = new Map()
    for (const name of names) {
      const response = await fetch(publicURL(name), { method: 'HEAD' })
      if (response.status === 404) continue
      if (!response.ok) throw new Error(`Reading ${name} from ${url} failed: HTTP ${response.status}`)
      objects.set(name, {
        size: Number(response.headers.get('content-length')),
        etag: String(response.headers.get('etag') ?? '').replaceAll('"', ''),
      })
    }
    return objects
  }

  async function upload(name, body, contentType, cacheControl) {
    const where = remote ? ['--remote'] : ['--local', '--persist-to', PATHS.workerState]
    const args = ['r2', 'object', 'put', `${BUCKET}/${name}`, ...where, '--pipe', '--content-type', contentType,
      '--cache-control', cacheControl]
    const { status, stderr } = await run(args, body, { remote })
    if (status !== 0) throw new Error(`wrangler exited with ${status}: ${String(stderr).trim().split('\n').pop()}`)
  }

  async function storedJSON(name) {
    const response = await fetch(publicURL(name), { headers: { 'cache-control': 'no-cache' } })
    if (!response.ok) return null
    try { return await response.json() } catch { return null }
  }

  return { list, upload, storedJSON }
}

/**
 * `npx wrangler <args>` in server/, with `input` on stdin. Only with --local, or with --remote when the caller asks for
 * the deployed bucket and the owner's approval is in the environment.
 */
export function runWrangler(args, input, { remote = false, env = process.env } = {}) {
  const local = args.includes('--local') && !args.includes('--remote')
  const approved = remote && args.includes('--remote') && !args.includes('--local') && env[APPROVAL] === '1'
  if (!local && !approved) {
    return Promise.reject(new Error(`wrangler runs here only with --local, or with --remote and ${APPROVAL}=1`))
  }
  return new Promise((done, fail) => {
    const child = spawn('npx', ['wrangler', ...args], { cwd: PATHS.serverDir, stdio: ['pipe', 'ignore', 'pipe'] })
    let stderr = ''
    child.stderr.on('data', chunk => { stderr += chunk })
    child.on('error', fail)
    child.on('close', status => done({ status, stderr }))
    child.stdin.end(input)
  })
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
 * Uploads new/changed photos from `dirs`, then the manifest. Returns
 * { uploaded, skipped, failed, manifest: 'uploaded'|'unchanged'|'dry-run', photos } (photos = exercises in the manifest).
 */
export async function uploadPhotos({
  url, dirs = PATHS.photoDirs, dryRun = false, fetch = globalThis.fetch, log = console.log,
  now = () => new Date(), retryDelayMs = 500, remote = false, run = runWrangler,
}) {
  const client = workerClient({ url, fetch, run, remote })
  const local = scanPhotos(dirs, log)
  const stored = await client.storedJSON(MANIFEST_NAME)
  const localNames = new Set(local.map(p => p.name))
  const names = [...localNames, ...namesIn(stored).filter(name => !localNames.has(name))]
  const before = await client.list(names)
  const { upload, skip } = planUploads(local, before)
  log(`${local.length} local photos in ${dirs.join(', ')}; ${skip.length} already in ${BUCKET}, ${upload.length} to upload (${url})`)

  if (dryRun) {
    for (const photo of upload) log(`would upload ${photo.name} (${photo.size} bytes)`)
    const after = new Map(before)
    for (const photo of upload) after.set(photo.name, { size: photo.size, etag: photo.md5 })
    const manifest = buildManifest([...after].map(([name, o]) => ({ name, etag: o.etag })), now())
    log(`would write ${MANIFEST_NAME}: ${Object.keys(manifest.photos).length} exercises`)
    return { uploaded: upload.length, skipped: skip.length, failed: 0, manifest: 'dry-run', photos: Object.keys(manifest.photos).length }
  }

  let uploaded = 0
  let failed = 0
  await forEachLimited(upload, remote ? REMOTE_CONCURRENCY : 1, async photo => {
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

  const objects = await client.list(names)
  const manifest = buildManifest([...objects].map(([name, o]) => ({ name, etag: o.etag })), now())
  const photos = Object.keys(manifest.photos).length
  if (sameContent(manifest, stored)) {
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
  const { url, remote } = resolveTarget({ target: args.target })
  const dirs = args.dirs.length > 0 ? args.dirs.map(d => resolve(d)) : PATHS.photoDirs
  const summary = await uploadPhotos({ url, remote, dirs, dryRun: args.dryRun })
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
