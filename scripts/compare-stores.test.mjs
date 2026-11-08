import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { test } from 'node:test'
import { compareStores } from './compare-stores.mjs'

const id = (n) => Buffer.from(n.toString(16).padStart(32, '0'), 'hex')
const hexId = (n) => n.toString(16).padStart(32, '0')

/** A store holding only weigh-ins, laid out as Core Data lays out ZBODYWEIGHTRECORD. */
function store(dir, name, rows) {
  const file = path.join(dir, name)
  const db = new DatabaseSync(file)
  db.exec(`CREATE TABLE ZBODYWEIGHTRECORD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDIRTY INTEGER,
    ZDATE TIMESTAMP, ZSERVERUPDATEDAT TIMESTAMP, ZWEIGHTKG FLOAT, ZID BLOB)`)
  const insert = db.prepare('INSERT INTO ZBODYWEIGHTRECORD VALUES (?, 1, ?, ?, ?, ?, ?, ?)')
  for (const r of rows) insert.run(r.pk, r.opt ?? 1, r.dirty ?? 0, r.date, r.server ?? null, r.kg, id(r.id))
  db.close()
  return file
}

function inTemp(body) {
  const dir = mkdtempSync(path.join(tmpdir(), 'compare-stores-test-'))
  try {
    body(dir)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

test('sync state and sub-microsecond noise are not differences', () => inTemp((dir) => {
  const before = store(dir, 'before', [{ pk: 1, id: 1, date: 800000000.1234567, kg: 81.4, server: 799999999 }])
  const after = store(dir, 'after', [{ pk: 9, id: 1, date: 800000000.123457, kg: 81.4, opt: 4, dirty: 1 }])
  assert.deepEqual(compareStores(before, after), [])
}))

test('a changed value, a missing record and a new one are', () => inTemp((dir) => {
  const before = store(dir, 'before', [{ pk: 1, id: 1, date: 800000000, kg: 81.4 }, { pk: 2, id: 2, date: 800000100, kg: 82 }])
  const after = store(dir, 'after', [{ pk: 1, id: 1, date: 800000000, kg: 82 }, { pk: 3, id: 3, date: 800000200, kg: 80 }])
  assert.deepEqual(compareStores(before, after), [
    `ZBODYWEIGHTRECORD ${hexId(1)}.ZWEIGHTKG: 81.4 -> 82`,
    `ZBODYWEIGHTRECORD ${hexId(2)}: missing after`,
    `ZBODYWEIGHTRECORD ${hexId(3)}: new after`,
  ])
}))

/** A store holding only gym listings, with the columns the move's catalogue step changes. */
function listings(dir, name, rows) {
  const file = path.join(dir, name)
  const db = new DatabaseSync(file)
  db.exec(`CREATE TABLE ZGYMLISTINGRECORD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDIRTY INTEGER,
    ZSERVERUPDATEDAT TIMESTAMP, ZISOWN INTEGER, ZCONFIRMCOUNT INTEGER, ZCONFIRMEDBYME INTEGER, ZQUANTITY INTEGER,
    ZREMOTEPHOTOPATH VARCHAR, ZSTATUSRAW VARCHAR, ZUPLOADERROR VARCHAR, ZUPLOADSTATERAW VARCHAR, ZVISIBILITYRAW VARCHAR,
    ZID BLOB, ZREMOTEID BLOB, ZDUPLICATESDATA BLOB)`)
  const insert = db.prepare(
    'INSERT INTO ZGYMLISTINGRECORD VALUES (?, 1, 1, 0, NULL, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)')
  for (const r of rows) {
    insert.run(r.pk, r.own ? 1 : 0, r.confirms ?? 0, r.confirmedByMe ? 1 : 0, r.quantity ?? 1, r.photo ?? null,
      r.status ?? 'active', r.error ?? null, r.upload ?? 'local', r.visibility, id(r.id),
      r.remote === undefined ? null : id(r.remote), r.duplicates ?? null)
  }
  db.close()
  return file
}

test("the move's catalogue step is not a difference: own shared listings go to this phone, others may go", () =>
  inTemp((dir) => {
    const shared = { visibility: 'shared', upload: 'uploaded', remote: 99, photo: 'old.jpg', confirms: 3 }
    const before = listings(dir, 'before', [
      { pk: 1, id: 1, own: true, status: 'flagged', confirmedByMe: true, ...shared },
      { pk: 2, id: 2, own: true, status: 'unsupported', ...shared },
      { pk: 3, id: 3, own: true, visibility: 'shared', upload: 'failed', error: 'offline', duplicates: '[]' },
      { pk: 4, id: 4, own: false, ...shared },
      { pk: 5, id: 5, own: true, visibility: 'synced' },
    ])
    const after = listings(dir, 'after', [
      { pk: 1, id: 1, own: true, visibility: 'device' },
      { pk: 2, id: 2, own: true, visibility: 'device', status: 'unsupported' },
      { pk: 3, id: 3, own: true, visibility: 'device' },
      { pk: 5, id: 5, own: true, visibility: 'synced' },
    ])
    assert.deepEqual(compareStores(before, after), [])
  }))

test('the catalogue step does not excuse other changes to listings', () => inTemp((dir) => {
  const before = listings(dir, 'before', [
    { pk: 1, id: 1, own: true, visibility: 'shared', upload: 'uploaded', quantity: 2 },
    { pk: 2, id: 2, own: true, visibility: 'synced' },
    { pk: 3, id: 3, own: false, visibility: 'shared', upload: 'uploaded', status: 'flagged' },
  ])
  const after = listings(dir, 'after', [
    { pk: 1, id: 1, own: true, visibility: 'device', quantity: 3 },
    { pk: 2, id: 2, own: true, visibility: 'device' },
    { pk: 3, id: 3, own: false, visibility: 'shared', upload: 'uploaded' },
  ])
  assert.deepEqual(compareStores(before, after), [
    `ZGYMLISTINGRECORD ${hexId(1)}.ZQUANTITY: 2 -> 3`,
    `ZGYMLISTINGRECORD ${hexId(2)}.ZVISIBILITYRAW: "synced" -> "device"`,
    `ZGYMLISTINGRECORD ${hexId(3)}.ZSTATUSRAW: "flagged" -> "active"`,
  ])
}))
