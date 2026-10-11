// Tests for the exercise-photo uploader: node --test scripts/upload-photos.test.mjs
// Every test mocks fetch against an in-memory fake of the Storage API — no network, no real Supabase.
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { copyFileSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  BUCKET, buildManifest, isLocalUrl, parseArgs, planUploads, resolveTarget, scanPhotos, uploadPhotos,
} from './upload-photos.mjs'

const URL_LOCAL = 'http://127.0.0.1:55421'
const KEY = 'service-role-secret-key-xyz'
const md5 = buf => createHash('md5').update(buf).digest('hex')

function photoDir(files = { 'own-0453-0.jpg': 'a0', 'own-0453-1.jpg': 'a1', 'own-0227-0.jpg': 'b0' }) {
  const dir = mkdtempSync(join(tmpdir(), 'upload-photos-'))
  for (const [name, body] of Object.entries(files)) writeFileSync(join(dir, name), body)
  writeFileSync(join(dir, 'notes.txt'), 'ignored')
  writeFileSync(join(dir, 'own-abc-0.jpg'), 'ignored: bad id')
  return dir
}

/** In-memory Storage API: POST object (upload), POST list, GET public object. Records every request. */
function fakeStorage({ objects = {}, failUpload = () => false } = {}) {
  const store = new Map(Object.entries(objects).map(([name, body]) => [name, { body: Buffer.from(body), headers: {} }]))
  const calls = []
  const fetch = async (input, init = {}) => {
    const url = new URL(input)
    const method = init.method ?? 'GET'
    const headers = Object.fromEntries(Object.entries(init.headers ?? {}).map(([k, v]) => [k.toLowerCase(), v]))
    calls.push({ method, path: url.pathname, headers })
    const listPath = `/storage/v1/object/list/${BUCKET}`
    const objectPrefix = `/storage/v1/object/${BUCKET}/`
    const publicPrefix = `/storage/v1/object/public/${BUCKET}/`
    const authenticatedPrefix = `/storage/v1/object/authenticated/${BUCKET}/`
    if (method === 'POST' && url.pathname === listPath) {
      const { limit, offset } = JSON.parse(init.body)
      const all = [...store.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([name, o]) => ({
        name, metadata: {
          size: o.body.length, eTag: `"${md5(o.body)}"`, mimetype: o.headers['content-type'],
          cacheControl: o.headers['cache-control'] ?? 'max-age=31536000',
        },
      }))
      return new Response(JSON.stringify(all.slice(offset, offset + limit)), { status: 200 })
    }
    if (method === 'POST' && url.pathname.startsWith(objectPrefix)) {
      const name = decodeURIComponent(url.pathname.slice(objectPrefix.length))
      if (failUpload(name)) return new Response('{"error":"boom"}', { status: 500 })
      store.set(name, { body: Buffer.from(init.body), headers })
      return new Response(JSON.stringify({ Key: `${BUCKET}/${name}` }), { status: 200 })
    }
    if (method === 'GET' && url.pathname.startsWith(authenticatedPrefix)) {
      if (headers.authorization !== `Bearer ${KEY}`) return new Response('{"statusCode":"403"}', { status: 400 })
      const found = store.get(decodeURIComponent(url.pathname.slice(authenticatedPrefix.length)))
      return found ? new Response(found.body, { status: 200 }) : new Response('{"statusCode":"404"}', { status: 400 })
    }
    if (method === 'GET' && url.pathname.startsWith(publicPrefix)) {
      const found = store.get(decodeURIComponent(url.pathname.slice(publicPrefix.length)))
      return found ? new Response(found.body, { status: 200 }) : new Response('{"statusCode":"404"}', { status: 400 })
    }
    return new Response('unexpected', { status: 418 })
  }
  return { fetch, calls, store }
}

const quiet = () => {
  const lines = []
  return { log: line => lines.push(line), lines }
}

test('parseArgs: defaults to the local target, flags parsed', () => {
  assert.deepEqual(parseArgs([]), { dryRun: false, target: 'local', dirs: [] })
  assert.deepEqual(parseArgs(['--dry-run', '--target', 'remote', '--dir', '/x', '--dir', '/y']),
    { dryRun: true, target: 'remote', dirs: ['/x', '/y'] })
  assert.throws(() => parseArgs(['--target', 'prod']), /--target/)
  assert.throws(() => parseArgs(['--nope']), /Unknown flag/)
})

test('isLocalUrl: only loopback hosts count as the local stack', () => {
  assert.equal(isLocalUrl('http://127.0.0.1:55421'), true)
  assert.equal(isLocalUrl('http://localhost:55421'), true)
  assert.equal(isLocalUrl('https://abc.supabase.co'), false)
  assert.equal(isLocalUrl('http://127.0.0.1.evil.com'), false)
  assert.equal(isLocalUrl('not a url'), false)
})

test('resolveTarget local: reads the local stack env file and refuses a non-local URL', () => {
  const dir = mkdtempSync(join(tmpdir(), 'upload-env-'))
  const localEnvFile = join(dir, '.env.local')
  writeFileSync(localEnvFile, `API_URL="${URL_LOCAL}"\nSERVICE_ROLE_KEY="${KEY}"\n`)
  const cloudEnv = { SUPABASE_URL: 'https://abc.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'cloud-key' }
  assert.deepEqual(resolveTarget({ target: 'local', env: cloudEnv, localEnvFile }), { url: URL_LOCAL, key: KEY })
  writeFileSync(localEnvFile, 'API_URL=https://abc.supabase.co\nSERVICE_ROLE_KEY=k\n')
  assert.throws(() => resolveTarget({ target: 'local', env: {}, localEnvFile }), /not the local stack/)
  assert.throws(() => resolveTarget({ target: 'local', env: {}, localEnvFile: join(dir, 'missing') }),
    /supabase-up\.sh/)
})

test('resolveTarget remote: env wins over .env, https only, key never echoed', () => {
  const dir = mkdtempSync(join(tmpdir(), 'upload-env-'))
  const envFile = join(dir, '.env')
  writeFileSync(envFile, 'SUPABASE_URL=https://file.supabase.co\nSUPABASE_SERVICE_ROLE_KEY=file-key\n')
  assert.deepEqual(resolveTarget({ target: 'remote', env: {}, envFile }),
    { url: 'https://file.supabase.co', key: 'file-key' })
  assert.deepEqual(resolveTarget({ target: 'remote', env: { SUPABASE_URL: 'https://env.supabase.co/', SUPABASE_SERVICE_ROLE_KEY: 'env-key' }, envFile }),
    { url: 'https://env.supabase.co', key: 'env-key' })
  assert.throws(() => resolveTarget({ target: 'remote', env: { SUPABASE_URL: 'http://x.co', SUPABASE_SERVICE_ROLE_KEY: 'k' } }),
    /https/)
  try {
    resolveTarget({ target: 'remote', env: { SUPABASE_URL: 'https://x.co' } })
    assert.fail('should throw')
  } catch (error) {
    assert.match(error.message, /SUPABASE_SERVICE_ROLE_KEY/)
  }
})

test('scanPhotos: only own-<digits>-<digits>.jpg, with size and md5', () => {
  const dir = photoDir()
  const photos = scanPhotos([dir])
  assert.deepEqual(photos.map(p => p.name), ['own-0227-0.jpg', 'own-0453-0.jpg', 'own-0453-1.jpg'])
  assert.equal(photos[1].size, 2)
  assert.equal(photos[1].md5, md5(Buffer.from('a0')))
})

test('scanPhotos: several folders (media/photos + the bundle), first folder wins, missing folders are skipped', () => {
  const generated = photoDir({ 'own-0001-0.jpg': 'new', 'own-0002-0.jpg': 'same' })
  const bundle = photoDir({ 'own-0001-0.jpg': 'old', 'own-0002-0.jpg': 'same', 'own-0453-0.jpg': 'ref' })
  const { log, lines } = quiet()
  const photos = scanPhotos([generated, bundle, join(generated, 'missing')], log)
  assert.deepEqual(photos.map(p => p.name), ['own-0001-0.jpg', 'own-0002-0.jpg', 'own-0453-0.jpg'])
  assert.equal(photos[0].path, join(generated, 'own-0001-0.jpg'))
  assert.equal(lines.filter(l => l.includes('differs')).length, 1, 'only the differing duplicate is reported')
})

test('planUploads: skips objects whose size and md5 match, uploads new or changed ones', () => {
  const local = [
    { name: 'own-0001-0.jpg', size: 2, md5: 'aaa' },
    { name: 'own-0001-1.jpg', size: 2, md5: 'bbb' },
    { name: 'own-0002-0.jpg', size: 3, md5: 'ccc' },
  ]
  const remote = new Map([
    ['own-0001-0.jpg', { size: 2, etag: 'aaa' }],
    ['own-0001-1.jpg', { size: 2, etag: 'zzz' }],
  ])
  const plan = planUploads(local, remote)
  assert.deepEqual(plan.skip.map(p => p.name), ['own-0001-0.jpg'])
  assert.deepEqual(plan.upload.map(p => p.name), ['own-0001-1.jpg', 'own-0002-0.jpg'])
})

test('buildManifest: frame counts are contiguous from 0; rev changes with content', () => {
  const now = new Date('2026-09-29T10:00:00Z')
  const objects = [
    { name: 'own-0453-0.jpg', etag: 'e0' }, { name: 'own-0453-1.jpg', etag: 'e1' },
    { name: 'own-0227-0.jpg', etag: 'f0' },
    { name: 'own-0999-1.jpg', etag: 'g1' }, // no start frame: not listed
    { name: 'own-0500-0.jpg', etag: 'h0' }, { name: 'own-0500-2.jpg', etag: 'h2' }, // gap: only frame 0
    { name: 'manifest.json', etag: 'm' },
  ]
  const manifest = buildManifest(objects, now)
  assert.equal(manifest.version, 1)
  assert.equal(manifest.updatedAt, '2026-09-29T10:00:00.000Z')
  assert.deepEqual(manifest.photos, { '0227': 1, '0453': 2, '0500': 1 })
  assert.match(manifest.rev['0453'], /^[0-9a-f]{12}$/)
  const changed = buildManifest(objects.map(o => o.name === 'own-0453-1.jpg' ? { ...o, etag: 'new' } : o), now)
  assert.notEqual(changed.rev['0453'], manifest.rev['0453'])
  assert.equal(changed.rev['0227'], manifest.rev['0227'])
})

test('uploadPhotos: uploads JPEGs with long cache-control, then the manifest; never logs the key', async () => {
  const dir = photoDir()
  const storage = fakeStorage()
  const { log, lines } = quiet()
  const summary = await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log, now: () => new Date(0) })
  assert.deepEqual(summary, { uploaded: 3, skipped: 0, failed: 0, manifest: 'uploaded', photos: 2 })
  const uploads = storage.calls.filter(c => c.method === 'POST' && !c.path.includes('/list/'))
  assert.deepEqual(uploads.map(c => c.path.split('/').pop()),
    ['own-0227-0.jpg', 'own-0453-0.jpg', 'own-0453-1.jpg', 'manifest.json'], 'manifest goes last')
  for (const c of uploads.slice(0, 3)) {
    assert.equal(c.headers['content-type'], 'image/jpeg')
    assert.equal(c.headers['cache-control'], 'max-age=31536000')
    assert.equal(c.headers['x-upsert'], 'true')
    assert.equal(c.headers.authorization, `Bearer ${KEY}`)
  }
  assert.equal(uploads[3].headers['content-type'], 'application/json')
  assert.equal(uploads[3].headers['cache-control'], 'max-age=60')
  const manifest = JSON.parse(storage.store.get('manifest.json').body)
  assert.deepEqual(manifest.photos, { '0227': 1, '0453': 2 })
  assert.ok(!lines.join('\n').includes(KEY), 'the key never reaches the log')
})

test('uploadPhotos: a second run is a no-op (idempotent)', async () => {
  const dir = photoDir()
  const storage = fakeStorage()
  await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log: () => {} })
  storage.calls.length = 0
  const summary = await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log: () => {} })
  assert.deepEqual(summary, { uploaded: 0, skipped: 3, failed: 0, manifest: 'unchanged', photos: 2 })
  assert.equal(storage.calls.filter(c => c.method === 'POST' && !c.path.includes('/list/')).length, 0)
})

test('uploadPhotos: an identical object stored with a wrong cache-control (e.g. by another uploader) is re-uploaded', async () => {
  const dir = photoDir({ 'own-0453-0.jpg': 'a0' })
  const storage = fakeStorage()
  await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log: () => {} })
  storage.store.get('own-0453-0.jpg').headers['cache-control'] = '31536000'
  const summary = await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log: () => {} })
  assert.equal(summary.uploaded, 1)
  assert.equal(storage.store.get('own-0453-0.jpg').headers['cache-control'], 'max-age=31536000')
})

test('uploadPhotos: reads the stored manifest through the authenticated endpoint (never a stale public/CDN copy)', async () => {
  const dir = photoDir()
  const storage = fakeStorage()
  await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log: () => {} })
  const reads = storage.calls.filter(c => c.method === 'GET')
  assert.ok(reads.length > 0)
  assert.ok(reads.every(c => c.path.startsWith(`/storage/v1/object/authenticated/${BUCKET}/`)), JSON.stringify(reads))
})

test('uploadPhotos: a changed photo is re-uploaded and its manifest rev changes', async () => {
  const dir = photoDir()
  const storage = fakeStorage()
  await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log: () => {} })
  const before = JSON.parse(storage.store.get('manifest.json').body)
  writeFileSync(join(dir, 'own-0453-1.jpg'), 'regenerated')
  const summary = await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log: () => {} })
  assert.equal(summary.uploaded, 1)
  assert.equal(summary.manifest, 'uploaded')
  const after = JSON.parse(storage.store.get('manifest.json').body)
  assert.notEqual(after.rev['0453'], before.rev['0453'])
  assert.equal(after.rev['0227'], before.rev['0227'])
})

test('uploadPhotos: the manifest covers what is in the bucket, including photos uploaded earlier from elsewhere', async () => {
  const dir = photoDir({ 'own-0001-0.jpg': 'x' })
  const storage = fakeStorage({ objects: { 'own-0777-0.jpg': 'old', 'own-0777-1.jpg': 'old1' } })
  const summary = await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log: () => {} })
  assert.equal(summary.photos, 2)
  assert.deepEqual(JSON.parse(storage.store.get('manifest.json').body).photos, { '0001': 1, '0777': 2 })
})

test('uploadPhotos: a failed upload is reported, the rest continue, the manifest lists only what landed', async () => {
  const dir = photoDir()
  const storage = fakeStorage({ failUpload: name => name === 'own-0227-0.jpg' })
  const summary = await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log: () => {}, retryDelayMs: 0 })
  assert.equal(summary.failed, 1)
  assert.equal(summary.uploaded, 2)
  assert.deepEqual(JSON.parse(storage.store.get('manifest.json').body).photos, { '0453': 2 })
})

test('uploadPhotos --dry-run: lists the plan, writes nothing', async () => {
  const dir = photoDir()
  const storage = fakeStorage({ objects: { 'own-0453-0.jpg': 'a0' } })
  const { log, lines } = quiet()
  const summary = await uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch: storage.fetch, log, dryRun: true })
  assert.deepEqual(summary, { uploaded: 2, skipped: 1, failed: 0, manifest: 'dry-run', photos: 2 })
  assert.equal(storage.calls.filter(c => c.method === 'POST' && !c.path.includes('/list/')).length, 0)
  assert.equal(storage.store.size, 1)
  assert.ok(lines.some(l => l.includes('would upload own-0227-0.jpg')))
})

test('uploadPhotos: an unreachable or unauthorised list stops the run before any upload', async () => {
  const dir = photoDir()
  const fetch = async () => new Response('{"message":"invalid signature"}', { status: 401 })
  await assert.rejects(uploadPhotos({ url: URL_LOCAL, key: KEY, dirs: [dir], fetch, log: () => {} }), /401/)
})

test('the CLI runs from a checkout path with spaces (entry-point check is path-safe)', () => {
  const root = mkdtempSync(join(tmpdir(), 'upload photos ü '))
  mkdirSync(join(root, 'scripts'))
  const script = join(root, 'scripts', 'upload-photos.mjs')
  copyFileSync(new URL('./upload-photos.mjs', import.meta.url), script)
  const run = spawnSync(process.execPath, [script, '--dry-run'], { encoding: 'utf8' })
  assert.equal(run.status, 1, 'no local stack env in the copy -> the CLI must run and fail loudly, not exit 0 silently')
  assert.match(run.stderr, /supabase-up\.sh/)
})
