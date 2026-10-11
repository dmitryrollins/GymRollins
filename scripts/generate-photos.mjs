#!/usr/bin/env node
// Generates the missing exercise photos listed in docs/media/photo-prompts.csv with Google's Gemini image model
// ("Nano Banana Pro") and saves them as media/photos/own-<id>-<frame>.jpg (gitignored, 1536x1024 JPEG), from where
// scripts/upload-photos.mjs puts them in Supabase Storage. Resumable: files that already exist (in media/photos or
// bundled in ios/GymRollins/Resources/OwnPhotos) are skipped, so re-running after a failure or a quota stop picks up where it
// left off. Frame 0 (start) of each exercise is generated first with own-0453-0.jpg attached as the identity/style
// reference; frame 1 (end) then gets the new frame 0 attached. See docs/media/README.md for how to run it.
//
// Usage: node scripts/generate-photos.mjs [--priority 1] [--ids 0215,0227] [--limit N] [--dry-run]
//                                         [--concurrency 2] [--model gemini-3-pro-image] [--image-size 2K]
//                                         [--max-consecutive-failures 6]  (stops when credit/quota runs out)
// Key: GEMINI_API_KEY from the environment, or from a gitignored app/.env (GEMINI_API_KEY=...). Never logged.
//
// API shape (checked 2026-09-29):
// - https://ai.google.dev/gemini-api/docs/models/gemini-3-pro-image — model code `gemini-3-pro-image` (Nano Banana
//   Pro, stable; replaces `gemini-3-pro-image-preview`), image + text in, image + text out.
// - https://ai.google.dev/api/generate-content — POST /v1beta/models/<model>:generateContent; GenerationConfig has
//   responseModalities and imageConfig { aspectRatio, imageSize }; response parts carry inlineData {mimeType, data}.
// - https://ai.google.dev/gemini-api/docs/generate-content/image-generation — REST examples: x-goog-api-key header,
//   input images as parts[].inline_data { mime_type, data }; aspect ratios include "3:2"; sizes "1K", "2K", "4K".
// - https://ai.google.dev/gemini-api/docs/pricing — Gemini 3 Pro Image: $0.134 per 1K/2K image, $0.24 per 4K image.
import { execFileSync, spawn } from 'node:child_process'
import { appendFileSync, existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = resolve(import.meta.dirname, '..')
export const DEFAULT_MODEL = 'gemini-3-pro-image'
const API_BASE = 'https://generativelanguage.googleapis.com/v1beta/models'
const ASPECT_RATIO = '3:2'
const MAX_ATTEMPTS = 5
/** Images failing in a row (after retries) that end the run: the usual sign the credit or quota ran out. */
const DEFAULT_MAX_CONSECUTIVE_FAILURES = 6
const BASE_BACKOFF_MS = 2000
const MAX_BACKOFF_MS = 60000
const USD_PER_IMAGE = { '1K': 0.134, '2K': 0.134, '4K': 0.24 }

export const PATHS = {
  csvPath: resolve(ROOT, 'docs/media/photo-prompts.csv'),
  // New photos go outside the app bundle (gitignored); scripts/upload-photos.mjs puts them in Supabase Storage.
  outDir: resolve(ROOT, 'media/photos'),
  // Photos already here (the app's bundled own photos) count as done too, so nothing is generated twice.
  alsoCheckDirs: [resolve(ROOT, 'ios/GymRollins/Resources/OwnPhotos')],
  referencePath: resolve(ROOT, 'ios/GymRollins/Resources/OwnPhotos/own-0453-0.jpg'),
  logPath: resolve(ROOT, 'docs/media/generation-log.jsonl'),
  envFile: resolve(ROOT, '.env'),
}

const IDENTITY_PREFIX = 'The attached image is the identity and style reference: show the same man (same face, ' +
  'hair, build and clothes) in the same light-grey concrete studio with the same lighting, camera distance and ' +
  'framing, but performing a DIFFERENT exercise — do not copy the pose or the equipment from the attached image. '

// ---------- CSV / args ----------

/** Parses the RFC-4180-style CSV written by build-photo-prompts.mjs into row objects keyed by the header. */
export function parseCSV(text) {
  const records = []
  let record = []
  let field = ''
  let quoted = false
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i++ } else if (c === '"') quoted = false
      else field += c
    } else if (c === '"') quoted = true
    else if (c === ',') { record.push(field); field = '' }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i++
      record.push(field); records.push(record); record = []; field = ''
    } else field += c
  }
  if (field || record.length) { record.push(field); records.push(record) }
  const [header, ...rows] = records.filter(r => r.length > 1 || r[0])
  return rows.map(r => Object.fromEntries(header.map((h, i) => [h, r[i] ?? ''])))
}

function positiveInt(flag, value) {
  const n = Number(value)
  if (!Number.isInteger(n) || n < 1) throw new Error(`${flag} needs a positive whole number, got "${value}"`)
  return n
}

export function parseArgs(argv) {
  const opts = { model: DEFAULT_MODEL, concurrency: 2, dryRun: false, imageSize: '2K',
    maxConsecutiveFailures: DEFAULT_MAX_CONSECUTIVE_FAILURES }
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i]
    const next = () => {
      if (i + 1 >= argv.length) throw new Error(`${flag} needs a value`)
      return argv[++i]
    }
    if (flag === '--priority') opts.priority = positiveInt(flag, next())
    else if (flag === '--limit') opts.limit = positiveInt(flag, next())
    else if (flag === '--concurrency') opts.concurrency = positiveInt(flag, next())
    else if (flag === '--max-consecutive-failures') opts.maxConsecutiveFailures = positiveInt(flag, next())
    else if (flag === '--ids') opts.ids = next().split(',').map(s => s.trim()).filter(Boolean)
    else if (flag === '--model') opts.model = next()
    else if (flag === '--image-size') opts.imageSize = next()
    else if (flag === '--dry-run') opts.dryRun = true
    else throw new Error(`Unknown flag ${flag}`)
  }
  if (!(opts.imageSize in USD_PER_IMAGE)) throw new Error('--image-size must be 1K, 2K or 4K')
  return opts
}

/** Keeps the rows matching --priority / --ids; --limit counts exercises so start and end frames stay together. */
export function selectRows(rows, { priority, ids, limit } = {}) {
  const idSet = ids?.length ? new Set(ids) : null
  const filtered = rows.filter(r => (priority == null || Number(r.priority) === priority) && (!idSet || idSet.has(r.id)))
  if (!limit) return filtered
  const keep = new Set([...new Set(filtered.map(r => r.id))].slice(0, limit))
  return filtered.filter(r => keep.has(r.id))
}

// ---------- key ----------

function keyFromEnvFile(envFile) {
  if (!envFile || !existsSync(envFile)) return undefined
  for (const line of readFileSync(envFile, 'utf8').split(/\r?\n/)) {
    const m = /^\s*(?:export\s+)?GEMINI_API_KEY\s*=\s*(.*)\s*$/.exec(line)
    if (m) return m[1].replace(/^(['"])(.*)\1$/, '$2').trim() || undefined
  }
  return undefined
}

export function readApiKey({ env = process.env, envFile } = {}) {
  const key = env.GEMINI_API_KEY?.trim() || keyFromEnvFile(envFile)
  if (!key) {
    throw new Error('GEMINI_API_KEY is not set. Run `export GEMINI_API_KEY=...` or add GEMINI_API_KEY=... to ' +
      'app/.env (gitignored), then re-run.')
  }
  return key
}

// ---------- request / response ----------

export function buildRequest({ model, apiKey, prompt, images, aspectRatio = ASPECT_RATIO, imageSize = '2K' }) {
  const parts = [{ text: prompt }, ...images.map(img => ({
    inline_data: { mime_type: img.mimeType, data: Buffer.from(img.data).toString('base64') },
  }))]
  return {
    url: `${API_BASE}/${encodeURIComponent(model)}:generateContent`,
    init: {
      method: 'POST',
      headers: { 'content-type': 'application/json', 'x-goog-api-key': apiKey },
      body: JSON.stringify({
        contents: [{ role: 'user', parts }],
        generationConfig: { responseModalities: ['TEXT', 'IMAGE'], imageConfig: { aspectRatio, imageSize } },
      }),
    },
  }
}

/** Returns the first image in a generateContent response, or throws why there is none (blocked, no image). */
export function extractImage(json) {
  const blocked = json?.promptFeedback?.blockReason
  if (blocked) throw new Error(`blocked: ${blocked}`)
  const candidate = json?.candidates?.[0]
  for (const part of candidate?.content?.parts ?? []) {
    const inline = part.inlineData ?? part.inline_data
    if (inline?.data) {
      return { mimeType: inline.mimeType ?? inline.mime_type ?? 'image/png', data: Buffer.from(inline.data, 'base64') }
    }
  }
  const text = (candidate?.content?.parts ?? []).map(p => p.text).filter(Boolean).join(' ').slice(0, 200)
  throw new Error(`no image in response (finishReason: ${candidate?.finishReason ?? 'none'})${text ? `: ${text}` : ''}`)
}

// ---------- HTTP with retry ----------

class FatalError extends Error {}

function retryAfterMs(header, now = Date.now()) {
  if (!header) return null
  const seconds = Number(header)
  if (Number.isFinite(seconds)) return Math.max(0, seconds * 1000)
  const date = Date.parse(header)
  return Number.isNaN(date) ? null : Math.max(0, date - now)
}

async function errorMessage(res) {
  try {
    const body = await res.json()
    return `HTTP ${res.status}: ${body?.error?.message ?? JSON.stringify(body).slice(0, 200)}`
  } catch {
    return `HTTP ${res.status}`
  }
}

/** POSTs with exponential backoff + jitter on 429/5xx/network errors, honouring Retry-After. */
export async function postWithRetry(request, { fetch, sleep, random }) {
  let lastError
  for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
    let wait = null
    let res
    try {
      res = await fetch(request.url, request.init)
    } catch (err) {
      lastError = new Error(`network error: ${err.message}`)
    }
    if (res?.ok) return { json: await res.json(), attempts: attempt }
    if (res) {
      const message = await errorMessage(res)
      if (res.status === 402) {
        throw Object.assign(new FatalError(message), { attempts: attempt, creditOut: true })
      }
      if (res.status === 401 || res.status === 403) throw Object.assign(new FatalError(message), { attempts: attempt })
      if (res.status !== 429 && res.status < 500) throw Object.assign(new Error(message), { attempts: attempt })
      lastError = new Error(message)
      wait = retryAfterMs(res.headers.get('retry-after'))
    }
    if (attempt < MAX_ATTEMPTS) {
      const backoff = Math.min(MAX_BACKOFF_MS, BASE_BACKOFF_MS * 2 ** (attempt - 1)) + Math.floor(random() * 1000)
      await sleep(wait ?? backoff)
    }
  }
  throw Object.assign(lastError, { attempts: MAX_ATTEMPTS })
}

// ---------- image post-processing ----------

const HELPER = resolve(import.meta.dirname, 'photo-postprocess.py')

/** Converts the model's image to an exact 1536x1024 JPEG via scripts/photo-postprocess.py (Pillow + numpy). */
export function pythonPostProcess(raw, outPath) {
  const inPath = join(tmpdir(), `gymrollins-raw-${process.pid}-${Date.now()}-${basename(outPath)}.img`)
  writeFileSync(inPath, raw)
  return new Promise((resolvePromise, reject) => {
    const child = spawn('python3', [HELPER, inPath, outPath], { stdio: ['ignore', 'ignore', 'pipe'] })
    let stderr = ''
    child.stderr.on('data', d => { stderr += d })
    child.on('error', err => { rmSync(inPath, { force: true }); reject(err) })
    child.on('close', code => {
      rmSync(inPath, { force: true })
      if (code === 0) resolvePromise()
      else reject(new Error(`photo-postprocess.py failed (${code}): ${stderr.trim().slice(0, 300)}`))
    })
  })
}

// ---------- run ----------

function mimeFor(path) {
  return /\.png$/i.test(path) ? 'image/png' : 'image/jpeg'
}

function groupByExercise(rows) {
  const groups = new Map()
  for (const r of rows) groups.set(r.id, [...(groups.get(r.id) ?? []), r])
  return [...groups.values()].map(frames => [...frames].sort((a, b) => Number(a.frame) - Number(b.frame)))
}

async function generateFrame(row, ctx) {
  const outPath = join(ctx.outDir, row.file_name)
  const isStart = Number(row.frame) === 0
  const startName = row.reference_image || `own-${row.id}-0.jpg`
  const refPath = isStart ? ctx.referencePath : (existingPath(ctx, startName) ?? join(ctx.outDir, startName))
  if (!existsSync(refPath)) {
    throw new Error(isStart ? `style reference missing: ${refPath}` : `start frame ${basename(refPath)} missing, ` +
      'end frame not attempted')
  }
  const request = buildRequest({
    model: ctx.model, apiKey: ctx.apiKey, imageSize: ctx.imageSize,
    prompt: isStart ? `${IDENTITY_PREFIX}${row.prompt}` : row.prompt,
    images: [{ mimeType: mimeFor(refPath), data: readFileSync(refPath) }],
  })
  const { json, attempts } = await postWithRetry(request, ctx.deps)
  let image
  try {
    image = extractImage(json)
  } catch (err) {
    throw Object.assign(err, { attempts })
  }
  ctx.stats.imagesGenerated++
  const tmpPath = join(ctx.outDir, `.${row.file_name}.tmp-${process.pid}.jpg`)
  try {
    await ctx.deps.postProcess(image.data, tmpPath)
    renameSync(tmpPath, outPath)
  } catch (err) {
    rmSync(tmpPath, { force: true })
    throw Object.assign(err, { attempts })
  }
  return attempts
}

function countStreak(ctx) {
  ctx.failureStreak = (ctx.failureStreak ?? 0) + 1
  if (ctx.failureStreak >= ctx.maxConsecutiveFailures && !ctx.aborted) {
    ctx.aborted = true
    ctx.stoppedByStreak = true
  }
}

/** Where `name` already exists: the output folder first, then the other folders checked for finished photos. */
function existingPath(ctx, name) {
  return [ctx.outDir, ...(ctx.alsoCheckDirs ?? [])].map(d => join(d, name)).find(p => existsSync(p)) ?? null
}

async function processExercise(frames, ctx) {
  for (const row of frames) {
    const label = `${row.id}-${row.frame} ${row.exercise} (${row.position})`
    if (existingPath(ctx, row.file_name)) {
      ctx.stats.skipped++
      ctx.deps.log(`skip   ${row.file_name} (exists)`)
      continue
    }
    if (ctx.aborted) return
    const started = ctx.deps.now()
    const entry = { ts: new Date(started).toISOString(), id: row.id, frame: Number(row.frame), file: row.file_name,
      model: ctx.model }
    try {
      const attempts = await generateFrame(row, ctx)
      ctx.stats.done++
      ctx.failureStreak = 0
      ctx.writeLog({ ...entry, status: 'done', ms: ctx.deps.now() - started, attempts })
      ctx.deps.log(`done   ${label}`)
    } catch (err) {
      ctx.stats.failed++
      if (err instanceof FatalError) {
        ctx.aborted = true
        if (err.creditOut) ctx.creditOut = true
      }
      if (err.attempts) countStreak(ctx) // only images actually sent; a skipped end frame isn't a new failure
      ctx.writeLog({ ...entry, status: 'failed', ms: ctx.deps.now() - started, attempts: err.attempts ?? 0,
        error: err.message })
      ctx.deps.log(`FAIL   ${label}: ${err.message}`)
    }
  }
}

async function runPool(items, concurrency, worker) {
  let next = 0
  const lanes = Array.from({ length: Math.min(concurrency, items.length) }, async () => {
    while (next < items.length) await worker(items[next++])
  })
  await Promise.all(lanes)
}

function loadRows(csvPath, deps) {
  if (!existsSync(csvPath)) {
    deps.log(`${csvPath} missing — building it with scripts/build-photo-prompts.mjs`)
    deps.buildCsv()
  }
  return parseCSV(readFileSync(csvPath, 'utf8'))
}

function dryRun(groups, opts, log) {
  let todo = 0
  for (const frames of groups) {
    for (const r of frames) {
      const exists = existingPath(opts, r.file_name) !== null
      if (!exists) todo++
      log(`${exists ? 'skip ' : 'would'}  ${r.file_name}  ${r.exercise} (${r.position})`)
    }
  }
  log(`Dry run: ${todo} to generate, ${groups.flat().length - todo} already exist. No request sent.`)
  return { done: 0, skipped: groups.flat().length - todo, failed: 0, imagesGenerated: 0, estimatedUsd: 0 }
}

const defaultDeps = () => ({
  fetch: globalThis.fetch,
  env: process.env,
  sleep: ms => new Promise(r => setTimeout(r, ms)),
  random: Math.random,
  now: Date.now,
  postProcess: pythonPostProcess,
  log: line => console.log(line),
  buildCsv: () => execFileSync(process.execPath, [resolve(import.meta.dirname, 'build-photo-prompts.mjs')],
    { stdio: 'inherit' }),
})

/** Runs a generation pass and returns { done, skipped, failed, imagesGenerated, estimatedUsd }. */
export async function generatePhotos(options, injected = {}) {
  const opts = { ...PATHS, model: DEFAULT_MODEL, concurrency: 2, imageSize: '2K',
    maxConsecutiveFailures: DEFAULT_MAX_CONSECUTIVE_FAILURES, ...options }
  const deps = { ...defaultDeps(), ...injected }
  const groups = groupByExercise(selectRows(loadRows(opts.csvPath, deps), opts))
  if (opts.dryRun) return dryRun(groups, opts, deps.log)

  const apiKey = readApiKey({ env: deps.env, envFile: opts.envFile })
  mkdirSync(opts.outDir, { recursive: true })
  mkdirSync(dirname(opts.logPath), { recursive: true })
  const ctx = {
    ...opts, apiKey, deps, aborted: false,
    stats: { done: 0, skipped: 0, failed: 0, imagesGenerated: 0 },
    writeLog: entry => appendFileSync(opts.logPath, `${JSON.stringify(entry)}\n`),
  }
  deps.log(`Generating ${groups.length} exercises with ${opts.model} (${ASPECT_RATIO}, ${opts.imageSize}), ` +
    `concurrency ${opts.concurrency}`)
  await runPool(groups, opts.concurrency, frames => processExercise(frames, ctx))
  if (ctx.creditOut) {
    deps.log('Stopped: the prepaid Gemini credit is used up (HTTP 402). Top up in AI Studio, then re-run the same ' +
      'command; finished photos are skipped.')
  } else if (ctx.stoppedByStreak) {
    deps.log(`Stopped early: ${opts.maxConsecutiveFailures} images failed in a row (usually the credit or quota ran ` +
      'out). Re-run the same command later to continue; finished photos are skipped.')
  } else if (ctx.aborted) deps.log('Stopped early: the API rejected the key (401/403). Check GEMINI_API_KEY.')
  const estimatedUsd = Math.round(ctx.stats.imagesGenerated * USD_PER_IMAGE[opts.imageSize] * 1000) / 1000
  return { ...ctx.stats, estimatedUsd }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2))
  const summary = await generatePhotos(opts)
  if (opts.dryRun) return
  console.log(`\nSummary: ${summary.done} done, ${summary.skipped} skipped, ${summary.failed} failed. ` +
    `Images generated (billed): ${summary.imagesGenerated} ≈ $${summary.estimatedUsd.toFixed(2)}. ` +
    `Log: ${PATHS.logPath}`)
  if (summary.failed) process.exitCode = 1
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch(err => {
    console.error(`Error: ${err.message}`)
    process.exitCode = 1
  })
}
