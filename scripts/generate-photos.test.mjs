// Tests for the Gemini photo generator: node --test scripts/generate-photos.test.mjs
// Every test mocks fetch — no real API call is ever made.
import assert from 'node:assert/strict'
import { execFileSync, spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, writeFileSync, readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { test } from 'node:test'
import { toCSV } from './build-photo-prompts.mjs'
import {
  DEFAULT_MODEL, buildRequest, extractImage, generatePhotos, parseArgs, parseCSV, readApiKey, selectRows,
} from './generate-photos.mjs'

const KEY = 'test-key-123'
const REF_BYTES = Buffer.from('reference-jpeg-bytes')
const IMG_B64 = Buffer.from('generated-image').toString('base64')

const row = (id, frame, priority = 1, exercise = `Exercise ${id}`) => ({
  priority, id, exercise, body_part: 'chest', equipment: 'cable', frame, position: frame ? 'end' : 'start',
  file_name: `own-${id}-${frame}.jpg`, reference_image: frame ? `own-${id}-0.jpg` : '',
  prompt: `prompt ${id} frame ${frame}, "quoted", with, commas`,
})

function workspace(rows = [row('0215', 0), row('0215', 1), row('0227', 0), row('0227', 1)]) {
  const dir = mkdtempSync(join(tmpdir(), 'genphotos-'))
  const outDir = join(dir, 'OwnPhotos')
  execFileSync('mkdir', ['-p', outDir])
  const referencePath = join(outDir, 'own-0453-0.jpg')
  writeFileSync(referencePath, REF_BYTES)
  const csvPath = join(dir, 'photo-prompts.csv')
  writeFileSync(csvPath, toCSV(rows))
  return { dir, outDir, referencePath, csvPath, logPath: join(dir, 'generation-log.jsonl'), envFile: join(dir, '.env') }
}

const okBody = (data = IMG_B64) => ({
  candidates: [{ finishReason: 'STOP', content: { parts: [{ text: 'here' }, { inlineData: { mimeType: 'image/png', data } }] } }],
})

function jsonResponse(status, body, headers = {}) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', ...headers } })
}

function mockFetch(responder) {
  const calls = []
  const fn = async (url, init) => {
    calls.push({ url, init, body: JSON.parse(init.body) })
    return responder(calls.length, url, init)
  }
  fn.calls = calls
  return fn
}

function deps(fetch, extra = {}) {
  const lines = []
  return {
    fetch,
    env: { GEMINI_API_KEY: KEY },
    sleep: async () => {},
    random: () => 0,
    postProcess: async (raw, outPath) => writeFileSync(outPath, raw),
    log: line => lines.push(line),
    lines,
    ...extra,
  }
}

const opts = (ws, extra = {}) => ({
  csvPath: ws.csvPath, outDir: ws.outDir, referencePath: ws.referencePath, logPath: ws.logPath, envFile: ws.envFile,
  model: DEFAULT_MODEL, concurrency: 1, alsoCheckDirs: [], ...extra,
})

const readLog = ws => readFileSync(ws.logPath, 'utf8').trim().split('\n').map(l => JSON.parse(l))

// ---------- CSV / args / filters ----------

test('parseCSV round-trips the prompt builder CSV (quotes, commas, CRLF)', () => {
  const rows = [row('0215', 0), row('0215', 1)]
  const parsed = parseCSV(toCSV(rows))
  assert.equal(parsed.length, 2)
  assert.equal(parsed[0].prompt, rows[0].prompt)
  assert.equal(parsed[1].reference_image, 'own-0215-0.jpg')
  assert.equal(parsed[1].frame, '1')
})

test('parseArgs reads flags with defaults', () => {
  const a = parseArgs(['--priority', '1', '--limit', '3', '--ids', '0215,0227', '--dry-run', '--concurrency', '4',
    '--model', 'm-x'])
  assert.deepEqual({ ...a }, { priority: 1, limit: 3, ids: ['0215', '0227'], dryRun: true, concurrency: 4, model: 'm-x',
    imageSize: '2K', maxConsecutiveFailures: 6 })
  const d = parseArgs([])
  assert.equal(d.model, DEFAULT_MODEL)
  assert.equal(d.concurrency, 2)
  assert.equal(d.dryRun, false)
  assert.throws(() => parseArgs(['--limit', 'abc']), /--limit/)
  assert.throws(() => parseArgs(['--bogus']), /Unknown flag/)
})

test('selectRows filters by priority, ids and limit (limit counts exercises, frames stay paired)', () => {
  const rows = [row('0001', 0), row('0001', 1), row('0002', 0), row('0002', 1), row('0003', 0, 2), row('0003', 1, 2)]
    .map(r => ({ ...r, priority: String(r.priority), frame: String(r.frame) }))
  assert.deepEqual(selectRows(rows, { priority: 1 }).map(r => r.id), ['0001', '0001', '0002', '0002'])
  assert.deepEqual(selectRows(rows, { ids: ['0003'] }).map(r => `${r.id}-${r.frame}`), ['0003-0', '0003-1'])
  assert.deepEqual(selectRows(rows, { limit: 1 }).map(r => `${r.id}-${r.frame}`), ['0001-0', '0001-1'])
})

// ---------- key ----------

test('readApiKey: env wins, falls back to a simple .env file, fails fast with a clear message', () => {
  const ws = workspace()
  assert.equal(readApiKey({ env: { GEMINI_API_KEY: 'from-env' }, envFile: ws.envFile }), 'from-env')
  writeFileSync(ws.envFile, '# comment\nOTHER=1\nexport GEMINI_API_KEY="from-file"\n')
  assert.equal(readApiKey({ env: {}, envFile: ws.envFile }), 'from-file')
  assert.throws(() => readApiKey({ env: {}, envFile: join(ws.dir, 'nope.env') }), /GEMINI_API_KEY is not set/)
})

test('missing key → clear error before any fetch', async () => {
  const ws = workspace()
  const fetch = mockFetch(() => jsonResponse(200, okBody()))
  await assert.rejects(generatePhotos(opts(ws), deps(fetch, { env: {} })), /GEMINI_API_KEY is not set/)
  assert.equal(fetch.calls.length, 0)
})

// ---------- request / response ----------

test('buildRequest: model URL, key header, reference image as inline_data, 3:2 image config', () => {
  const { url, init } = buildRequest({
    model: 'gemini-3-pro-image', apiKey: KEY, prompt: 'hello',
    images: [{ mimeType: 'image/jpeg', data: REF_BYTES }], aspectRatio: '3:2', imageSize: '2K',
  })
  assert.equal(url, 'https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image:generateContent')
  assert.equal(init.method, 'POST')
  assert.equal(init.headers['x-goog-api-key'], KEY)
  assert.ok(!url.includes(KEY))
  const body = JSON.parse(init.body)
  const parts = body.contents[0].parts
  assert.equal(parts[0].text, 'hello')
  assert.deepEqual(parts[1], { inline_data: { mime_type: 'image/jpeg', data: REF_BYTES.toString('base64') } })
  assert.deepEqual(body.generationConfig.responseModalities, ['TEXT', 'IMAGE'])
  assert.deepEqual(body.generationConfig.imageConfig, { aspectRatio: '3:2', imageSize: '2K' })
})

test('extractImage accepts camelCase and snake_case parts; blocked/no-image responses throw', () => {
  assert.equal(extractImage(okBody()).data.toString(), 'generated-image')
  const snake = { candidates: [{ content: { parts: [{ inline_data: { mime_type: 'image/jpeg', data: IMG_B64 } }] } }] }
  assert.equal(extractImage(snake).mimeType, 'image/jpeg')
  assert.throws(() => extractImage({ promptFeedback: { blockReason: 'SAFETY' } }), /blocked: SAFETY/)
  assert.throws(() => extractImage({ candidates: [{ finishReason: 'IMAGE_SAFETY', content: { parts: [{ text: 'no' }] } }] }),
    /no image.*IMAGE_SAFETY/)
})

// ---------- run ----------

test('generates frame 0 before frame 1; frame 0 uses the style reference, frame 1 the new frame 0', async () => {
  const ws = workspace([row('0215', 0), row('0215', 1)])
  let n = 0
  const fetch = mockFetch(() => jsonResponse(200, okBody(Buffer.from(`img-${n++}`).toString('base64'))))
  const d = deps(fetch)
  const summary = await generatePhotos(opts(ws), d)
  assert.equal(fetch.calls.length, 2)
  const [first, second] = fetch.calls
  assert.match(first.body.contents[0].parts[0].text, /^The attached image is the identity and style reference/)
  assert.match(first.body.contents[0].parts[0].text, /prompt 0215 frame 0/)
  assert.equal(first.body.contents[0].parts[1].inline_data.data, REF_BYTES.toString('base64'))
  assert.match(second.body.contents[0].parts[0].text, /prompt 0215 frame 1/)
  assert.equal(Buffer.from(second.body.contents[0].parts[1].inline_data.data, 'base64').toString(), 'img-0')
  assert.equal(readFileSync(join(ws.outDir, 'own-0215-0.jpg'), 'utf8'), 'img-0')
  assert.equal(readFileSync(join(ws.outDir, 'own-0215-1.jpg'), 'utf8'), 'img-1')
  assert.deepEqual(summary, { done: 2, skipped: 0, failed: 0, imagesGenerated: 2, estimatedUsd: 0.268 })
  assert.deepEqual(readdirSync(ws.outDir).filter(f => f.includes('.tmp')), [], 'no temp files left behind')
  const log = readLog(ws)
  assert.deepEqual(log.map(l => `${l.id}-${l.frame}-${l.status}`), ['0215-0-done', '0215-1-done'])
  assert.ok(!readFileSync(ws.logPath, 'utf8').includes(KEY))
  assert.ok(!d.lines.join('\n').includes(KEY))
})

test('skips existing files (resume) and uses an existing frame 0 as the frame 1 reference', async () => {
  const ws = workspace([row('0215', 0), row('0215', 1), row('0227', 0), row('0227', 1)])
  writeFileSync(join(ws.outDir, 'own-0215-0.jpg'), 'old-start')
  writeFileSync(join(ws.outDir, 'own-0227-0.jpg'), 'x')
  writeFileSync(join(ws.outDir, 'own-0227-1.jpg'), 'y')
  const fetch = mockFetch(() => jsonResponse(200, okBody()))
  const summary = await generatePhotos(opts(ws), deps(fetch))
  assert.equal(fetch.calls.length, 1)
  assert.equal(Buffer.from(fetch.calls[0].body.contents[0].parts[1].inline_data.data, 'base64').toString(), 'old-start')
  assert.equal(summary.done, 1)
  assert.equal(summary.skipped, 3)
  assert.equal(readFileSync(join(ws.outDir, 'own-0227-1.jpg'), 'utf8'), 'y', 'existing file untouched')
})

test('retries 429 (respecting Retry-After) then succeeds', async () => {
  const ws = workspace([row('0215', 0)])
  const slept = []
  const fetch = mockFetch(n => (n === 1 ? jsonResponse(429, { error: { message: 'quota' } }, { 'retry-after': '7' })
    : n === 2 ? jsonResponse(503, { error: { message: 'busy' } }) : jsonResponse(200, okBody())))
  const summary = await generatePhotos(opts(ws), deps(fetch, { sleep: async ms => { slept.push(ms) } }))
  assert.equal(fetch.calls.length, 3)
  assert.equal(slept[0], 7000)
  assert.ok(slept[1] >= 1000)
  assert.equal(summary.done, 1)
  assert.equal(readLog(ws)[0].attempts, 3)
})

test('gives up after 5 attempts on persistent 5xx and records a failure', async () => {
  const ws = workspace([row('0215', 0)])
  const fetch = mockFetch(() => jsonResponse(500, { error: { message: 'boom' } }))
  const summary = await generatePhotos(opts(ws), deps(fetch))
  assert.equal(fetch.calls.length, 5)
  assert.equal(summary.failed, 1)
  assert.match(readLog(ws)[0].error, /HTTP 500/)
})

test('blocked response → failure logged, its end frame is not attempted, the run continues', async () => {
  const ws = workspace()
  const fetch = mockFetch((n, url, init) => (JSON.parse(init.body).contents[0].parts[0].text.includes('0215 frame 0')
    ? jsonResponse(200, { promptFeedback: { blockReason: 'SAFETY' } }) : jsonResponse(200, okBody())))
  const summary = await generatePhotos(opts(ws), deps(fetch))
  assert.equal(fetch.calls.length, 3, '0215-0 (blocked), 0227-0, 0227-1')
  assert.deepEqual(summary, { done: 2, skipped: 0, failed: 2, imagesGenerated: 2, estimatedUsd: 0.268 })
  const log = readLog(ws)
  const byKey = Object.fromEntries(log.map(l => [`${l.id}-${l.frame}`, l]))
  assert.equal(byKey['0215-0'].status, 'failed')
  assert.match(byKey['0215-0'].error, /blocked: SAFETY/)
  assert.equal(byKey['0215-1'].status, 'failed')
  assert.match(byKey['0215-1'].error, /start frame/)
  assert.equal(byKey['0227-1'].status, 'done')
  assert.ok(!existsSync(join(ws.outDir, 'own-0215-0.jpg')))
})

test('an invalid key (401/403) stops the run instead of burning through every exercise', async () => {
  const ws = workspace()
  const fetch = mockFetch(() => jsonResponse(403, { error: { message: 'API key not valid' } }))
  const summary = await generatePhotos(opts(ws), deps(fetch))
  assert.equal(fetch.calls.length, 1)
  assert.equal(summary.failed, 1)
})

test('HTTP 402 (prepaid credit used up) stops the run at once', async () => {
  const ws = workspace()
  const fetch = mockFetch(() => jsonResponse(402, { error: { message: 'Your prepayment credits are depleted.' } }))
  const d = deps(fetch)
  const summary = await generatePhotos(opts(ws), d)
  assert.equal(fetch.calls.length, 1, 'no retries, no further exercises')
  assert.equal(summary.failed, 1)
  assert.ok(d.lines.some(l => /credit is used up/.test(l)))
})

test('credit/quota running out (429 on every exercise in a row) stops the run instead of grinding on', async () => {
  const rows = ['0101', '0102', '0103', '0104', '0105', '0106'].flatMap(id => [row(id, 0), row(id, 1)])
  const ws = workspace(rows)
  const fetch = mockFetch(() => jsonResponse(429, { error: { message: 'You exceeded your current quota' } }))
  const d = deps(fetch)
  const summary = await generatePhotos(opts(ws, { maxConsecutiveFailures: 3 }), d)
  assert.equal(summary.failed, 5, '3 start frames failed (+2 end frames skipped for them), then the run stopped')
  assert.equal(fetch.calls.length, 3 * 5, 'each tried 5 times; exercises 4-6 never sent')
  assert.ok(d.lines.some(l => /Stopped early: 3 images failed in a row/.test(l)))
})

test('a success resets the failure streak (sporadic blocked images do not stop the run)', async () => {
  const rows = ['0201', '0202', '0203'].flatMap(id => [row(id, 0), row(id, 1)])
  const ws = workspace(rows)
  // 0201 start blocked, 0202 fine, 0203 start blocked: never 2 failures in a row.
  const blocked = { candidates: [{ finishReason: 'SAFETY', content: { parts: [] } }] }
  const fetch = mockFetch((n, url, init) => {
    const prompt = JSON.parse(init.body).contents[0].parts[0].text
    return jsonResponse(200, /prompt (0201|0203) frame 0/.test(prompt) ? blocked : okBody())
  })
  const summary = await generatePhotos(opts(ws, { maxConsecutiveFailures: 2 }), deps(fetch))
  assert.equal(summary.done, 2)
  assert.equal(summary.failed, 4, 'both blocked starts and their skipped end frames are counted')
})

test('parseArgs reads --max-consecutive-failures', () => {
  assert.equal(parseArgs(['--max-consecutive-failures', '4']).maxConsecutiveFailures, 4)
  assert.equal(parseArgs([]).maxConsecutiveFailures, 6)
})

test('photos already in another folder (e.g. the app bundle) are skipped and used as end-frame references', async () => {
  const ws = workspace([row('0215', 0), row('0215', 1)])
  const bundled = join(ws.dir, 'Bundled')
  execFileSync('mkdir', ['-p', bundled])
  writeFileSync(join(bundled, 'own-0215-0.jpg'), 'bundled-start')
  const fetch = mockFetch(() => jsonResponse(200, okBody()))
  const summary = await generatePhotos(opts(ws, { alsoCheckDirs: [bundled] }), deps(fetch))
  assert.equal(summary.skipped, 1)
  assert.equal(summary.done, 1)
  assert.equal(fetch.calls.length, 1)
  const ref = fetch.calls[0].body.contents[0].parts.find(p => p.inline_data)
  assert.equal(Buffer.from(ref.inline_data.data, 'base64').toString(), 'bundled-start')
  assert.ok(existsSync(join(ws.outDir, 'own-0215-1.jpg')), 'new photos go to outDir')
  assert.ok(!existsSync(join(bundled, 'own-0215-1.jpg')))
})

test('dry run makes no fetch, needs no key, writes nothing and lists what would be generated', async () => {
  const ws = workspace()
  writeFileSync(join(ws.outDir, 'own-0227-0.jpg'), 'x')
  const fetch = mockFetch(() => { throw new Error('should not fetch') })
  const d = deps(fetch, { env: {} })
  const summary = await generatePhotos(opts(ws, { dryRun: true }), d)
  assert.equal(fetch.calls.length, 0)
  assert.ok(!existsSync(ws.logPath))
  assert.equal(summary.imagesGenerated, 0)
  const out = d.lines.join('\n')
  assert.match(out, /own-0215-0\.jpg/)
  assert.match(out, /own-0227-1\.jpg/)
  assert.match(out, /3 to generate/)
})

test('filters apply to the run (--ids)', async () => {
  const ws = workspace()
  const fetch = mockFetch(() => jsonResponse(200, okBody()))
  await generatePhotos(opts(ws, { ids: ['0227'] }), deps(fetch))
  assert.equal(fetch.calls.length, 2)
  assert.ok(fetch.calls.every(c => c.body.contents[0].parts[0].text.includes('0227')))
})

test('regenerates the CSV when it is missing', async () => {
  const ws = workspace()
  const csvPath = join(ws.dir, 'missing.csv')
  let built = false
  const fetch = mockFetch(() => jsonResponse(200, okBody()))
  await generatePhotos(opts(ws, { csvPath, dryRun: true }), deps(fetch, {
    buildCsv: () => { built = true; writeFileSync(csvPath, toCSV([row('0215', 0)])) },
  }))
  assert.ok(built)
})

// ---------- image post-processing (real python helper; skipped without Pillow) ----------

const hasPillow = spawnSync('python3', ['-c', 'import PIL, numpy'], { stdio: 'ignore' }).status === 0
const HELPER = resolve(import.meta.dirname, 'photo-postprocess.py')

function makeImage(path, w, h) {
  execFileSync('python3', ['-c',
    `from PIL import Image; Image.new('RGB', (${w}, ${h}), (200, 200, 205)).save('${path}')`])
}

function size(path) {
  return execFileSync('python3', ['-c', `from PIL import Image; im = Image.open('${path}'); print(im.format, *im.size)`],
    { encoding: 'utf8' }).trim()
}

for (const [w, h] of [[1024, 1024], [2528, 1696], [2000, 1000]]) {
  test(`photo-postprocess turns a ${w}x${h} image into a 1536x1024 JPEG`, { skip: !hasPillow }, () => {
    const dir = mkdtempSync(join(tmpdir(), 'pp-'))
    const src = join(dir, 'in.png')
    const out = join(dir, 'out.jpg')
    makeImage(src, w, h)
    execFileSync('python3', [HELPER, src, out])
    assert.equal(size(out), 'JPEG 1536 1024')
  })
}
