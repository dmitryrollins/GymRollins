import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { gymReadable, itemReadable } from '../src/gyms/visibility.ts'
import { block, insertGym, insertItem, insertListing, makeAdmin, setStatus } from './gym-fixtures.ts'
import { signUp } from './helpers.ts'

const db = env.DB

/** Whether the caller, bound as ?3 (gym-links.ts binds it as ?2), can read the row. */
async function readable(table: 'gyms' | 'equipment_items', alias: string, rule: string, id: string, me: string) {
  const row = await db.prepare(`SELECT 1 FROM ${table} ${alias} WHERE ${alias}.id = ?1 AND ?2 = 'unused' AND ${rule}`)
    .bind(id, 'unused', me).first()
  return row !== null
}
const canReadItem = (item: string, me: string) => readable('equipment_items', 'i', itemReadable('i', '?3'), item, me)

describe('the read rules', () => {
  it('read the caller from the parameter they are given', async () => {
    const a = await signUp()
    const b = await signUp()
    const gym = await insertGym({ visibility: 'private', owner: a.userId })
    expect(await readable('gyms', 'g', gymReadable('g', '?3'), gym, a.userId)).toBe(true)
    expect(await readable('gyms', 'g', gymReadable('g', '?3'), gym, b.userId)).toBe(false)
  })

  it('show a branded item to its creator, and to others once it has an active shared listing', async () => {
    const a = await signUp()
    const b = await signUp()
    const item = await insertItem({ brand: 'Acme', model: 'R1', createdBy: a.userId })
    expect(await canReadItem(item, a.userId)).toBe(true)
    expect(await canReadItem(item, b.userId)).toBe(false)
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    expect(await canReadItem(item, b.userId)).toBe(true)
  })

  it('hide an item whose only listing is flagged, or whose creator the caller blocked', async () => {
    const a = await signUp()
    const b = await signUp()
    const c = await signUp()
    const item = await insertItem({ brand: 'Acme', model: 'R2', createdBy: a.userId })
    const gym = await insertGym({ visibility: 'public', createdBy: a.userId })
    const listing = await insertListing({ gym, item, visibility: 'public', addedBy: a.userId })
    await block(b.userId, a.userId)
    expect(await canReadItem(item, b.userId)).toBe(false)
    expect(await canReadItem(item, c.userId)).toBe(true)
    await setStatus('gym_equipment', listing, 'flagged')
    expect(await canReadItem(item, c.userId)).toBe(false)
  })

  it('show a removed item only to an admin and its creator', async () => {
    const a = await signUp()
    const b = await signUp()
    const admin = await signUp()
    await makeAdmin(admin.userId)
    const item = await insertItem({ brand: 'Acme', model: 'R3', createdBy: a.userId })
    await setStatus('equipment_items', item, 'removed')
    expect(await canReadItem(item, admin.userId)).toBe(true)
    expect(await canReadItem(item, a.userId)).toBe(true)
    expect(await canReadItem(item, b.userId)).toBe(false)
  })

  it("don't count a listing by an author the caller blocked towards an item being shown", async () => {
    const creator = await signUp()
    const author = await signUp()
    const viewer = await signUp()
    const item = await insertItem({ brand: 'Acme', model: 'R4', createdBy: creator.userId })
    const gym = await insertGym({ visibility: 'public', createdBy: author.userId })
    await insertListing({ gym, item, visibility: 'public', addedBy: author.userId })
    expect(await canReadItem(item, viewer.userId)).toBe(true)
    await block(viewer.userId, author.userId)
    expect(await canReadItem(item, viewer.userId)).toBe(false)
  })
})
