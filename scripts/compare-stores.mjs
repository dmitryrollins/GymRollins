#!/usr/bin/env node
// Compares two copies of the app's SwiftData store and prints every record that differs in anything but sync state.
// scripts/server-move-check.sh runs it on the owner's store before and after the server move and the first upload, to
// show that nothing else changed (spec section 8). It never opens the files it is given: each store (with its -wal and
// -shm) is copied to a temporary folder first.
//
//   node scripts/compare-stores.mjs <before.store> <after.store>
//
// Records are matched by their own id, because a pull writes a workout's entries and sets afresh (new Z_PK). Dates are
// compared to the microsecond the server keeps, a profile's day fields by calendar day, and JSON blobs by value. Exits
// 1 and lists the differences when there are any. A difference names the table, the column and the record's id, never
// the values: they come from a copy of someone's personal data.
import { copyFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { fileURLToPath } from 'node:url'

/** Core Data's bookkeeping and the sync state, which the move and the upload are meant to change. */
const SYNC_STATE = new Set(['Z_PK', 'Z_ENT', 'Z_OPT', 'ZDIRTY', 'ZSERVERUPDATEDAT'])
/** Core Data stores dates as seconds since 2001-01-01. */
const REFERENCE_DATE_MS = Date.UTC(2001, 0, 1)

/** Another user's listing cached from the old server's catalogue: the gym's next refresh may drop it. */
const isCachedFromCatalogue = (row) =>
  row.ZVISIBILITYRAW === 'shared' && !row.ZISOWN && row.ZUPLOADSTATERAW === 'uploaded'

/**
 * A listing as the move leaves it (`SyncStore.forgetOldCatalogue`): the user's own shared listings, and those still
 * waiting to be shared, become "This phone only", out of the old server's catalogue. An `unsupported` one stays so.
 */
function unshareListing(row) {
  if (row.ZVISIBILITYRAW !== 'shared' || isCachedFromCatalogue(row)) return row
  return {
    ...row,
    ZVISIBILITYRAW: 'device',
    ZUPLOADSTATERAW: 'local',
    ZUPLOADERROR: null,
    ZDUPLICATESDATA: null,
    ZREMOTEID: null,
    ZSTATUSRAW: row.ZSTATUSRAW === 'unsupported' ? 'unsupported' : 'active',
    ZCONFIRMCOUNT: 0,
    ZCONFIRMEDBYME: 0,
  }
}

/**
 * The tables compared, each keyed by the record's own id. `parents` are to-one columns, compared by the parent's id;
 * `skip` are columns the move changes on purpose, or caches; `days` are calendar days; `mayGo` says which records the
 * move may delete; `moved` turns a record from before into what the move makes of it.
 */
export const TABLES = [
  { table: 'ZWORKOUTRECORD', key: 'ZID', skip: ['ZENTRIESDATA'] },
  { table: 'ZWORKOUTENTRYRECORD', key: 'ZID', parents: { ZWORKOUT: 'ZWORKOUTRECORD' } },
  { table: 'ZSETRECORD', key: 'ZID', parents: { ZENTRY: 'ZWORKOUTENTRYRECORD' } },
  { table: 'ZROUTINERECORD', key: 'ZID' },
  { table: 'ZROUTINEEXERCISERECORD', key: 'ZID', parents: { ZROUTINE: 'ZROUTINERECORD' } },
  { table: 'ZWEEKDAYRECORD', key: 'ZWEEKDAY' },
  { table: 'ZMUSCLETARGETRECORD', key: 'ZMUSCLE' },
  { table: 'ZEXERCISEPREFERENCERECORD', key: 'ZID' },
  { table: 'ZCUSTOMEXERCISERECORD', key: 'ZID' },
  { table: 'ZBODYWEIGHTRECORD', key: 'ZID' },
  { table: 'ZPROFILERECORD', key: 'ZID', days: ['ZGOALDATE', 'ZLIMITSUNTIL'] },
  // The move clears the catalogue's refresh stamp, so a gym's next open refreshes it from the new server.
  { table: 'ZGYMRECORD', key: 'ZID', skip: ['ZCATALOGREFRESHEDAT'] },
  // The move forgets the old server's photo names, so a picture on the phone uploads again, and its catalogue: own
  // shared listings stay on this phone, and other people's cached ones may go.
  {
    table: 'ZGYMLISTINGRECORD', key: 'ZID', skip: ['ZREMOTEPHOTOPATH'], moved: unshareListing,
    mayGo: isCachedFromCatalogue,
  },
  // Pictures borrowed from the old server's catalogue are forgotten.
  { table: 'ZEQUIPMENTITEMRECORD', key: 'ZID', skip: ['ZCATALOGPHOTOPATH', 'ZCATALOGPHOTOLISTINGID'] },
  // The move drops pending proposals: only the old server could resolve them.
  { table: 'ZPROPOSALRECORD', key: 'ZID', mayGo: (row) => row.ZSTATUSRAW === 'pending' },
]

function openCopy(file) {
  const dir = mkdtempSync(path.join(tmpdir(), 'compare-stores-'))
  for (const suffix of ['', '-wal', '-shm']) {
    if (existsSync(file + suffix)) copyFileSync(file + suffix, path.join(dir, `store${suffix}`))
  }
  return { db: new DatabaseSync(path.join(dir, 'store')), dir }
}

const hex = (value) => (value instanceof Uint8Array ? Buffer.from(value).toString('hex') : value)

const sorted = (value) => {
  if (Array.isArray(value)) return value.map(sorted)
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sorted(value[key])]))
  }
  return value
}

/** A blob as its JSON with sorted keys when it is JSON, else its bytes in hex. */
function blob(value) {
  const bytes = Buffer.from(value)
  try {
    return JSON.stringify(sorted(JSON.parse(bytes.toString('utf8'))))
  } catch {
    return bytes.toString('hex')
  }
}

function localDay(seconds) {
  const day = new Date(REFERENCE_DATE_MS + seconds * 1000)
  const pad = (n) => String(n).padStart(2, '0')
  return `${day.getFullYear()}-${pad(day.getMonth() + 1)}-${pad(day.getDate())}`
}

/** One column's value, ready to compare: `{ time }` in microseconds, or `{ value }`. */
function cell(value, type, isDay) {
  if (value === null || value === undefined) return { value: null }
  if (type === 'TIMESTAMP') return isDay ? { value: localDay(value) } : { time: Math.round(value * 1e6) }
  if (value instanceof Uint8Array) return { value: blob(value) }
  return { value }
}

const same = (a, b) =>
  a.time !== undefined && b.time !== undefined ? Math.abs(a.time - b.time) <= 1 : a.value === b.value

function hasTable(db, table) {
  return db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(table) !== undefined
}

/** One table's records by their key, each with its row and its cells by column (after `moved`, when given). */
function records(db, spec, moved = (row) => row) {
  const out = new Map()
  if (!hasTable(db, spec.table)) return out
  const parents = new Map(Object.entries(spec.parents ?? {}).map(([column, table]) => {
    const key = TABLES.find((t) => t.table === table).key
    const keys = db.prepare(`SELECT Z_PK AS pk, ${key} AS k FROM ${table}`).all().map((r) => [r.pk, hex(r.k)])
    return [column, new Map(keys)]
  }))
  const columns = db.prepare(`PRAGMA table_info(${spec.table})`).all()
    .filter((c) => !SYNC_STATE.has(c.name) && !(spec.skip ?? []).includes(c.name))
  for (const row of db.prepare(`SELECT * FROM ${spec.table}`).all()) {
    const expected = moved(row)
    const cells = new Map(columns.map(({ name, type }) => [
      name,
      parents.has(name)
        ? { value: parents.get(name).get(expected[name]) ?? null }
        : cell(expected[name], String(type).toUpperCase(), (spec.days ?? []).includes(name)),
    ]))
    out.set(String(hex(row[spec.key])), { row, cells })
  }
  return out
}

/** Every difference between the two stores, one line each; empty when the records match. */
export function compareStores(beforeFile, afterFile) {
  const before = openCopy(beforeFile)
  const after = openCopy(afterFile)
  try {
    const problems = []
    for (const spec of TABLES) {
      const was = records(before.db, spec, spec.moved)
      const is = records(after.db, spec)
      for (const [key, { row, cells }] of was) {
        const now = is.get(key)
        if (!now) {
          if (!spec.mayGo?.(row)) problems.push(`${spec.table} ${key}: missing after`)
          continue
        }
        for (const [column, value] of cells) {
          const other = now.cells.get(column) ?? { value: null }
          if (!same(value, other)) problems.push(`${spec.table} ${key}.${column} differs`)
        }
      }
      for (const key of is.keys()) if (!was.has(key)) problems.push(`${spec.table} ${key}: new after`)
    }
    return problems
  } finally {
    before.db.close()
    after.db.close()
    rmSync(before.dir, { recursive: true, force: true })
    rmSync(after.dir, { recursive: true, force: true })
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [beforeFile, afterFile] = process.argv.slice(2)
  if (!beforeFile || !afterFile) {
    console.error('usage: node scripts/compare-stores.mjs <before.store> <after.store>')
    process.exit(2)
  }
  const problems = compareStores(beforeFile, afterFile)
  for (const line of problems) console.log(line)
  console.log(problems.length === 0 ? 'Stores match apart from sync state.' : `${problems.length} differences.`)
  process.exit(problems.length === 0 ? 0 : 1)
}
