// Tests for the exercise-photo uploader: node --test scripts/upload-photos.test.mjs
// Every test runs against an in-memory fake of the Worker's public photo route and of wrangler: no network, no
// Cloudflare account, no real wrangler.
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { copyFileSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { spawnSync } from 'node:child_process'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { test } from 'node:test'
import {
  APPROVAL, BUCKET, PATHS, buildManifest, isLocalUrl, namesIn, parseArgs, planUploads, resolveTarget, runWrangler,
  scanPhotos, uploadPhotos,
} from './upload-photos.mjs'

const LOCAL = 'http://127.0.0.1:8787'
const DEPLOYED = 'https://gymrollins.example.workers.dev'
const md5 = buf => createHash('md5').update(buf).digest('hex')

function photoDir(files = { 'own-0453-0.jpg': 'a0', 'own-0453-1.jpg': 'a1', 'own-0227-0.jpg': 'b0' }) {
  const dir = mkdtempSync(join(tmpdir(), 'upload-photos-'))
  for (const [name, body] of Object.entries(files)) writeFileSync(join(dir, name), body)
  writeFileSync(join(dir, 'notes.txt'), 'ignored')
  writeFileSync(join(dir, 'own-abc-0.jpg'), 'ignored: bad id')
  return dir
}

/**
 * The Worker's public route over a map of objects, and a fake wrangler that writes into that map. `fail(name)` makes
 * a put of that name exit 1. Records every request and every wrangler run.
 */
function fakeWorker({ objects = {}, fail = () => false } = {}) {
  const store = new Map(Object.entries(objects).map(([name, body]) => [name, Buffer.from(body)]))
  const requests = []
  const runs = []
  const fetch = async (input, init = {}) => {
    const url = new URL(input)
    const method = init.method ?? 'GET'
    requests.push({ method, url: url.href })
    const prefix = '/photos/exercises/'
    const body = url.pathname.startsWith(prefix) ? store.get(decodeURIComponent(url.pathname.slice(prefix.length))) : null
    if (!body) return new Response('{"error":{"code":"not_found"}}', { status: 404 })
    const headers = { etag: `"${md5(body)}"`, 'content-length': String(body.length) }
    return new Response(method === 'HEAD' ? null : body, { status: 200, headers })
  }
  const run = async (args, input, options) => {
    const name = args[3].slice(`${BUCKET}/`.length)
    runs.push({ args, name, options })
    if (fail(name)) return { status: 1, stderr: 'boom' }
    store.set(name, Buffer.from(input))
    return { status: 0, stderr: '' }
  }
  return { fetch, run, runs, requests, store }
}

const quiet = () => {
  const lines = []
  return { log: line => lines.push(line), lines }
}

const flag = (args, name) => args[args.indexOf(name) + 1]

test('parseArgs: defaults to the local Worker, flags parsed', () => {
  assert.deepEqual(parseArgs([]), { dryRun: false, target: 'worker', dirs: [] })
  assert.deepEqual(parseArgs(['--dry-run', '--target', 'cloud', '--dir', '/x', '--dir', '/y']),
    { dryRun: true, target: 'cloud', dirs: ['/x', '/y'] })
  assert.throws(() => parseArgs(['--target', 'local']), /--target/)
  assert.throws(() => parseArgs(['--target', 'remote']), /--target/)
  assert.throws(() => parseArgs(['--nope']), /Unknown flag/)
})

test('isLocalUrl: only loopback hosts count as the local Worker', () => {
  assert.equal(isLocalUrl('http://127.0.0.1:8787'), true)
  assert.equal(isLocalUrl('http://localhost:8788'), true)
  assert.equal(isLocalUrl(DEPLOYED), false)
  assert.equal(isLocalUrl('http://127.0.0.1.evil.com'), false)
  assert.equal(isLocalUrl('not a url'), false)
})

test('resolveTarget worker: the local Worker only, at WORKER_URL or 127.0.0.1:8787', () => {
  assert.deepEqual(resolveTarget({ target: 'worker', env: {} }), { url: LOCAL, remote: false })
  assert.deepEqual(resolveTarget({ target: 'worker', env: { WORKER_URL: 'http://localhost:9000/' } }),
    { url: 'http://localhost:9000', remote: false })
  assert.throws(() => resolveTarget({ target: 'worker', env: { WORKER_URL: DEPLOYED } }), /not the local Worker/)
})

test("resolveTarget cloud: the deployed Worker over https, and only with the owner's approval", () => {
  assert.throws(() => resolveTarget({ target: 'cloud', env: { WORKER_URL: DEPLOYED } }), new RegExp(APPROVAL))
  assert.throws(() => resolveTarget({ target: 'cloud', env: { WORKER_URL: DEPLOYED, [APPROVAL]: 'yes' } }),
    new RegExp(APPROVAL))
  const approved = { [APPROVAL]: '1' }
  assert.throws(() => resolveTarget({ target: 'cloud', env: approved }), /WORKER_URL=https/)
  assert.throws(() => resolveTarget({ target: 'cloud', env: { ...approved, WORKER_URL: 'http://x.example' } }),
    /WORKER_URL=https/)
  assert.throws(() => resolveTarget({ target: 'cloud', env: { ...approved, WORKER_URL: 'https://127.0.0.1:8787' } }),
    /WORKER_URL=https/)
  assert.deepEqual(resolveTarget({ target: 'cloud', env: { ...approved, WORKER_URL: `${DEPLOYED}/` } }),
    { url: DEPLOYED, remote: true })
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

test('scanPhotos: also picks up kind-<kindId>.jpg, and only well-formed ids', () => {
  const dir = photoDir({
    'own-0453-0.jpg': 'a0', 'kind-dumbbells.jpg': 'k1', 'kind-ab-wheel.jpg': 'k2',
    'kind-Bad.jpg': 'x', 'kind-.jpg': 'x', [`kind-${'a'.repeat(41)}.jpg`]: 'x', 'kind-x.png': 'x', 'kind-a_b.jpg': 'x',
  })
  const photos = scanPhotos([dir])
  assert.deepEqual(photos.map(p => p.name), ['kind-ab-wheel.jpg', 'kind-dumbbells.jpg', 'own-0453-0.jpg'])
})

test('buildManifest: kinds maps each kind photo to a rev hashed from its etag', () => {
  const now = new Date('2026-09-29T10:00:00Z')
  const objects = [
    { name: 'own-0453-0.jpg', etag: 'e0' }, { name: 'kind-dumbbells.jpg', etag: 'k1' },
    { name: 'kind-ab-wheel.jpg', etag: 'k2' }, { name: 'kind-Bad.jpg', etag: 'x' },
  ]
  const manifest = buildManifest(objects, now)
  assert.deepEqual(Object.keys(manifest.kinds), ['ab-wheel', 'dumbbells'])
  assert.equal(manifest.kinds.dumbbells, createHash('sha256').update('k1').digest('hex').slice(0, 12))
  assert.equal(manifest.version, 1)
  assert.deepEqual(buildManifest([], now).kinds, {}, 'always present, so an old app and a new one read the same shape')
  const changed = buildManifest(objects.map(o => o.name === 'kind-dumbbells.jpg' ? { ...o, etag: 'new' } : o), now)
  assert.notEqual(changed.kinds.dumbbells, manifest.kinds.dumbbells)
  assert.equal(changed.kinds['ab-wheel'], manifest.kinds['ab-wheel'])
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

test('namesIn: the photos and kind photos a stored manifest lists, and nothing malformed', () => {
  assert.deepEqual(namesIn(null), [])
  assert.deepEqual(namesIn({ photos: { '0777': 2, bad: 1, '0001': 0, '0002': 1.5 }, kinds: { dumbbells: 'r', Bad: 'r' } }),
    ['own-0777-0.jpg', 'own-0777-1.jpg', 'kind-dumbbells.jpg'])
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

test('uploadPhotos --target worker: wrangler --local into the state folder, JPEGs with a long cache, then the manifest',
  async () => {
    const dir = photoDir()
    const worker = fakeWorker()
    const summary = await uploadPhotos({ url: LOCAL, dirs: [dir], fetch: worker.fetch, run: worker.run, ...quiet(),
      now: () => new Date(0) })
    assert.deepEqual(summary, { uploaded: 3, skipped: 0, failed: 0, manifest: 'uploaded', photos: 2 })
    assert.deepEqual(worker.runs.map(r => r.name),
      ['own-0227-0.jpg', 'own-0453-0.jpg', 'own-0453-1.jpg', 'manifest.json'], 'one at a time, the manifest last')
    for (const { args, options } of worker.runs) {
      assert.ok(args.includes('--local') && !args.includes('--remote'))
      assert.equal(flag(args, '--persist-to'), PATHS.workerState)
      assert.deepEqual(options, { remote: false })
    }
    for (const { args } of worker.runs.slice(0, 3)) {
      assert.equal(flag(args, '--content-type'), 'image/jpeg')
      assert.equal(flag(args, '--cache-control'), 'max-age=31536000')
    }
    const last = worker.runs.at(-1).args
    assert.equal(flag(last, '--content-type'), 'application/json')
    assert.equal(flag(last, '--cache-control'), 'max-age=60')
    assert.deepEqual(JSON.parse(worker.store.get('manifest.json')).photos, { '0227': 1, '0453': 2 })
    assert.ok(worker.requests.every(r => r.url.startsWith(`${LOCAL}/photos/exercises/`)), 'reads only the public route')
  })

test('uploadPhotos: a second run is a no-op (idempotent)', async () => {
  const dir = photoDir()
  const worker = fakeWorker()
  await uploadPhotos({ url: LOCAL, dirs: [dir], fetch: worker.fetch, run: worker.run, log: () => {} })
  worker.runs.length = 0
  const summary = await uploadPhotos({ url: LOCAL, dirs: [dir], fetch: worker.fetch, run: worker.run, log: () => {} })
  assert.deepEqual(summary, { uploaded: 0, skipped: 3, failed: 0, manifest: 'unchanged', photos: 2 })
  assert.equal(worker.runs.length, 0)
})

test('uploadPhotos: a run that only adds a kind photo rewrites the manifest', async () => {
  const dir = photoDir()
  const worker = fakeWorker()
  const options = { url: LOCAL, dirs: [dir], fetch: worker.fetch, run: worker.run, log: () => {} }
  await uploadPhotos(options)
  writeFileSync(join(dir, 'kind-dumbbells.jpg'), 'k1')
  const second = await uploadPhotos(options)
  assert.equal(second.manifest, 'uploaded')
  assert.equal(second.uploaded, 1)
  assert.deepEqual(Object.keys(JSON.parse(worker.store.get('manifest.json')).kinds), ['dumbbells'])
  assert.equal((await uploadPhotos(options)).manifest, 'unchanged')
})

test('uploadPhotos: a changed photo is re-uploaded and its manifest rev changes', async () => {
  const dir = photoDir()
  const worker = fakeWorker()
  const options = { url: LOCAL, dirs: [dir], fetch: worker.fetch, run: worker.run, log: () => {} }
  await uploadPhotos(options)
  const before = JSON.parse(worker.store.get('manifest.json'))
  writeFileSync(join(dir, 'own-0453-1.jpg'), 'regenerated')
  const summary = await uploadPhotos(options)
  assert.equal(summary.uploaded, 1)
  assert.equal(summary.manifest, 'uploaded')
  const after = JSON.parse(worker.store.get('manifest.json'))
  assert.notEqual(after.rev['0453'], before.rev['0453'])
  assert.equal(after.rev['0227'], before.rev['0227'])
})

test('uploadPhotos: photos the stored manifest lists stay listed when this checkout lacks them', async () => {
  const dir = photoDir({ 'own-0001-0.jpg': 'x' })
  const earlier = { version: 1, photos: { '0777': 2, '0888': 1 }, rev: {}, kinds: {} }
  // own-0888-0 is listed but gone from the bucket: it drops out.
  const worker = fakeWorker({ objects: { 'own-0777-0.jpg': 'old', 'own-0777-1.jpg': 'old1', 'manifest.json': JSON.stringify(earlier) } })
  const summary = await uploadPhotos({ url: LOCAL, dirs: [dir], fetch: worker.fetch, run: worker.run, log: () => {} })
  assert.equal(summary.photos, 2)
  assert.deepEqual(JSON.parse(worker.store.get('manifest.json')).photos, { '0001': 1, '0777': 2 })
})

test('uploadPhotos: a failed upload is reported, the rest continue, the manifest lists only what landed', async () => {
  const dir = photoDir()
  const worker = fakeWorker({ fail: name => name === 'own-0227-0.jpg' })
  const summary = await uploadPhotos({ url: LOCAL, dirs: [dir], fetch: worker.fetch, run: worker.run, log: () => {},
    retryDelayMs: 0 })
  assert.equal(summary.failed, 1)
  assert.equal(summary.uploaded, 2)
  assert.deepEqual(JSON.parse(worker.store.get('manifest.json')).photos, { '0453': 2 })
})

test('uploadPhotos --dry-run: lists the plan, writes nothing', async () => {
  const dir = photoDir()
  const worker = fakeWorker({ objects: { 'own-0453-0.jpg': 'a0' } })
  const { log, lines } = quiet()
  const summary = await uploadPhotos({ url: LOCAL, dirs: [dir], fetch: worker.fetch, run: worker.run, log, dryRun: true })
  assert.deepEqual(summary, { uploaded: 2, skipped: 1, failed: 0, manifest: 'dry-run', photos: 2 })
  assert.equal(worker.runs.length, 0)
  assert.equal(worker.store.size, 1)
  assert.ok(lines.some(l => l.includes('would upload own-0227-0.jpg')))
})

test('uploadPhotos: an unreachable Worker stops the run before any upload', async () => {
  const dir = photoDir()
  const worker = fakeWorker()
  const fetch = async () => new Response('{"error":{"code":"server_error"}}', { status: 500 })
  await assert.rejects(uploadPhotos({ url: LOCAL, dirs: [dir], fetch, run: worker.run, log: () => {} }), /HTTP 500/)
  assert.equal(worker.runs.length, 0)
})

test('uploadPhotos --target cloud: wrangler --remote, side by side, reads through the deployed Worker', async () => {
  const dir = photoDir()
  const worker = fakeWorker()
  const summary = await uploadPhotos({ url: DEPLOYED, remote: true, dirs: [dir], fetch: worker.fetch, run: worker.run,
    log: () => {} })
  assert.equal(summary.uploaded, 3)
  assert.equal(summary.manifest, 'uploaded')
  for (const { args, options } of worker.runs) {
    assert.ok(args.includes('--remote'))
    assert.ok(!args.includes('--local') && !args.includes('--persist-to'))
    assert.deepEqual(options, { remote: true })
  }
  assert.equal(worker.runs.at(-1).name, 'manifest.json')
  assert.ok(worker.requests.every(r => r.url.startsWith(`${DEPLOYED}/photos/exercises/`)))
})

test("runWrangler: only --local, or --remote asked for with the owner's approval; it never starts wrangler otherwise",
  async () => {
    const put = ['r2', 'object', 'put', `${BUCKET}/x.jpg`, '--pipe']
    await assert.rejects(runWrangler(put, ''), /only with --local/)
    await assert.rejects(runWrangler([...put, '--remote'], '', { env: { [APPROVAL]: '1' } }), /only with --local/)
    await assert.rejects(runWrangler([...put, '--remote'], '', { remote: true, env: {} }), /only with --local/)
    await assert.rejects(runWrangler([...put, '--remote', '--local'], '', { remote: true, env: { [APPROVAL]: '1' } }),
      /only with --local/)
  })

test('the CLI runs from a checkout path with spaces (entry-point check is path-safe)', () => {
  const root = mkdtempSync(join(tmpdir(), 'upload photos ü '))
  mkdirSync(join(root, 'scripts'))
  const script = join(root, 'scripts', 'upload-photos.mjs')
  copyFileSync(new URL('./upload-photos.mjs', import.meta.url), script)
  const env = { ...process.env, [APPROVAL]: '', WORKER_URL: DEPLOYED }
  const run = spawnSync(process.execPath, [script, '--target', 'cloud', '--dry-run'], { encoding: 'utf8', env })
  assert.equal(run.status, 1, 'no approval -> the CLI must run and refuse loudly, not exit 0 silently')
  assert.match(run.stderr, new RegExp(APPROVAL))
})
