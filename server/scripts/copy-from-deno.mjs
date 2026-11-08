#!/usr/bin/env node
// Copies the Deno MCP server code (supabase/functions/_shared and mcp) into the Worker, converting the tests
// from Deno.test + @std/assert to Vitest with the same assertions (test/assert.ts keeps the @std/assert
// names). Plan 29 runs it once per group: `node scripts/copy-from-deno.mjs shared`, then `… mcp`. The Deno
// originals stay until plan 30 deletes supabase/. The conversion is mechanical:
// - every relative import is re-pointed at the file's new place (snake_case files become kebab-case),
// - npm:/jsr: specifiers become package names, and JSON import attributes are dropped (tsc's ES2022 module),
// - Deno.readTextFile(new URL(…, import.meta.url)) becomes a Vite `?raw` import of the same file,
// - Deno.test('name', fn) and Deno.test({ name, permissions, fn }) become test(name, fn),
// - `// deno-lint-ignore` lines go, and comments about the Deno file reads name the ?raw imports.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import path from 'node:path'

const SERVER = path.resolve(import.meta.dirname, '..')
const REPO = path.resolve(SERVER, '..')
const FROM = path.join(REPO, 'supabase/functions')
const ASSERT = path.join(SERVER, 'test/assert.ts')

const TOOLS = [
  'common',
  'format',
  'gyms',
  'history',
  'insights',
  'read',
  'register',
  'result',
  'schemas',
  'strength',
  'summary',
  'write',
]
const TOOL_TESTS = ['format', 'gyms', 'insights', 'preferences', 'read', 'strength', 'write']

/**
 * [source under supabase/functions, destination under server]. Plan 28 already wrote the server's
 * DomainLimits (src/shared/domain-limits.ts, the same values) and its drift test, so those two aren't copied:
 * KEPT only re-points imports at them.
 */
const SHARED = ['insights', 'plan-validation', 'strength-levels']
const GROUPS = {
  shared: [
    ...SHARED.map((n) => [`_shared/${n}.ts`, `src/shared/${n}.ts`]),
    ['_shared/strength-standards.json', 'src/shared/strength-standards.json'],
    ...SHARED.map((n) => [`_shared/${n}.test.ts`, `test/shared/${n}.test.ts`]),
  ],
  mcp: [
    ['mcp/db.ts', 'src/mcp/db.ts'],
    ['mcp/instructions.ts', 'src/mcp/instructions.ts'],
    ...TOOLS.map((n) => [`mcp/tools/${n}.ts`, `src/mcp/tools/${n}.ts`]),
    ['mcp/tools/fake_db.ts', 'test/mcp/fake-db.ts'],
    ['mcp/test_helpers.ts', 'test/mcp/rpc.ts'],
    ['mcp/testdata/owner.json', 'test/mcp/testdata/owner.json'],
    ['mcp/instructions_test.ts', 'test/mcp/instructions.test.ts'],
    ...TOOL_TESTS.map((n) => [`mcp/tools/${n}_test.ts`, `test/mcp/tools/${n}.test.ts`]),
  ],
}

const group = process.argv[2]
if (!(group in GROUPS)) {
  console.error(`usage: node scripts/copy-from-deno.mjs ${Object.keys(GROUPS).join('|')}`)
  process.exit(1)
}

const KEPT = [['_shared/domain-limits.ts', 'src/shared/domain-limits.ts']]

/** Absolute source path → absolute destination path, for every group, so imports across groups resolve. */
const MOVED = new Map(
  [...Object.values(GROUPS).flat(), ...KEPT].map((
    [from, to],
  ) => [path.join(FROM, from), path.join(SERVER, to)]),
)

const relative = (fromFile, target) => {
  const rel = path.relative(path.dirname(fromFile), target).split(path.sep).join('/')
  return rel.startsWith('.') ? rel : `./${rel}`
}

const camel = (file) => path.basename(file).replace(/[-_.](\w)/g, (_, c) => c.toUpperCase())

function convert(source, from, to) {
  let text = source
  const rawImports = []
  const raw = (rel, name) => {
    const target = path.resolve(path.dirname(from), rel)
    rawImports.push(`import ${name} from '${relative(to, MOVED.get(target) ?? target)}?raw'`)
    return name
  }
  // A URL kept in a const: the const becomes the file's text, named …Text instead of …Url.
  text = text.replace(
    /const (\w+)Url = new URL\(\s*'([^']+)',\s*import\.meta\.url,?\s*\)\n/g,
    (_, name, rel) => {
      raw(rel, `${name}Text`)
      return ''
    },
  )
  for (const m of source.matchAll(/const (\w+)Url = new URL\(/g)) {
    text = text.replace(new RegExp(`(await )?Deno\\.readTextFile\\(${m[1]}Url\\)`, 'g'), `${m[1]}Text`)
  }
  // A URL read inline.
  text = text.replace(
    /(await )?Deno\.readTextFile\(new URL\('([^']+)', import\.meta\.url\)\)/g,
    (_, _await, rel) => raw(rel, camel(rel)),
  )
  text = text.replace(/^\s*\/\/ deno-lint-ignore.*\n/gm, '')
  // Comments that describe the Deno file reads.
  text = text.replace(/^(\s*\/\/.*)Deno\.readTextFile/gm, '$1Vite ?raw imports')
  text = text.replace(/^(\s*\/\/.*)import\.meta\.url/gm, "$1the file's own URL")
  text = text.replace(/'npm:@modelcontextprotocol\/server@[^']+'/g, "'@modelcontextprotocol/server'")
  text = text.replace(/'npm:zod@[^']+'/g, "'zod'")
  text = text.replace(/ with \{ type: 'json' \}/g, '')
  text = text.replace(/from '(\.{1,2}\/[^']+)'/g, (_, spec) => {
    const target = path.resolve(path.dirname(from), spec)
    return `from '${relative(to, MOVED.get(target) ?? target)}'`
  })
  if (text.includes('Deno.test')) {
    text = text.replace(/from 'jsr:@std\/assert@[^']+'/, `from '${relative(to, ASSERT)}'`)
    text = convertTests(text)
    text = text.replace(/^(\/\/.*\n)*/, (header) => `${header}import { test } from 'vitest'\n`)
  }
  if (rawImports.length > 0) {
    const firstImport = /^import /m.exec(text)
    const at = firstImport ? firstImport.index : 0
    text = `${text.slice(0, at)}${rawImports.join('\n')}\n${text.slice(at)}`
  }
  const left = text.match(/Deno\.|jsr:|npm:|import\.meta\.url/)
  if (left) throw new Error(`${from}: unconverted "${left[0]}"`)
  return text
}

/** Deno.test('name', fn) → test('name', fn); Deno.test({ name, permissions, fn }) → test(name, fn). */
function convertTests(text) {
  let out = ''
  let i = 0
  for (;;) {
    const start = text.indexOf('Deno.test(', i)
    if (start < 0) return out + text.slice(i)
    out += text.slice(i, start)
    const open = start + 'Deno.test('.length
    if (text[open] !== '{') {
      out += 'test('
      i = open
      continue
    }
    const close = matching(text, open)
    const props = topLevelProps(text.slice(open + 1, close))
    if (!props.name || !props.fn) throw new Error(`Deno.test object without name or fn at ${start}`)
    const unknown = Object.keys(props).filter((k) => !['name', 'fn', 'permissions'].includes(k))
    if (unknown.length > 0) throw new Error(`Deno.test option(s) ${unknown.join(', ')} have no Vitest form`)
    out += `test(${props.name}, ${props.fn.replace(/\n {2}/g, '\n')})`
    i = text.indexOf(')', close) + 1
  }
}

/** The index of the bracket that closes the one at `open`, skipping strings and template literals. */
function matching(text, open) {
  let depth = 0
  for (let j = open; j < text.length; j++) {
    const c = text[j]
    if (c === "'" || c === '"' || c === '`') {
      j = endOfString(text, j)
    } else if ('({['.includes(c)) {
      depth++
    } else if (')}]'.includes(c)) {
      depth--
      if (depth === 0) return j
    }
  }
  throw new Error('unbalanced brackets')
}

function endOfString(text, start) {
  const quote = text[start]
  for (let j = start + 1; j < text.length; j++) {
    if (text[j] === '\\') j++
    else if (quote === '`' && text.startsWith('${', j)) j = matching(text, j + 1)
    else if (text[j] === quote) return j
  }
  throw new Error('unterminated string')
}

/** `name: …, permissions: …, fn: …` (an object literal's body) → { name, permissions, fn } as source text. */
function topLevelProps(body) {
  const props = {}
  let j = 0
  while (j < body.length) {
    const key = /^\s*(\w+):\s*/.exec(body.slice(j))
    if (!key) break
    j += key[0].length
    let end = j
    while (end < body.length && body[end] !== ',') {
      const c = body[end]
      if (c === "'" || c === '"' || c === '`') end = endOfString(body, end) + 1
      else if ('({['.includes(c)) end = matching(body, end) + 1
      else end++
    }
    props[key[1]] = body.slice(j, end).trim()
    j = end + 1
  }
  return props
}

for (const [from, to] of GROUPS[group]) {
  const source = path.join(FROM, from)
  const target = path.join(SERVER, to)
  mkdirSync(path.dirname(target), { recursive: true })
  const text = readFileSync(source, 'utf8')
  writeFileSync(target, from.endsWith('.json') ? text : convert(text, source, target))
  console.log(`${path.relative(REPO, source)} → server/${to}`)
}
