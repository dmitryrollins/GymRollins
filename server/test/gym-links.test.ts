import { env } from 'cloudflare:workers'
import { describe, expect, it } from 'vitest'
import { entryListings, workoutGym } from '../src/sync/gym-links.ts'
import { block, genericItem, insertGym, insertItem, insertListing, makeAdmin, setStatus } from './gym-fixtures.ts'
import { signUp } from './helpers.ts'

const db = env.DB
const linkTo = (userId: string, gym: string) => workoutGym(db, userId, null, gym)
const entry = (id: string, gymEquipmentId: string | null) => ({ id, gymEquipmentId })

describe("a workout's gym", () => {
  it('takes a gym you can read: your private gym, or an active public one', async () => {
    const { userId } = await signUp()
    const mine = await insertGym({ visibility: 'private', owner: userId })
    const open = await insertGym({ visibility: 'public' })
    expect(await linkTo(userId, mine)).toBe(mine)
    expect(await linkTo(userId, open)).toBe(open)
  })

  it("drops one you can't: another account's private gym, a removed gym, a flagged gym you didn't add", async () => {
    const me = await signUp()
    const other = await signUp()
    expect(await linkTo(me.userId, await insertGym({ visibility: 'private', owner: other.userId }))).toBeNull()
    expect(await linkTo(me.userId, await insertGym({ visibility: 'public', status: 'removed' }))).toBeNull()
    const flagged = await insertGym({ visibility: 'public', status: 'flagged', createdBy: other.userId })
    expect(await linkTo(me.userId, flagged)).toBeNull()
  })

  it('lets a flagged gym through to whoever added it, and any public gym to an admin', async () => {
    const me = await signUp()
    const admin = await signUp()
    await makeAdmin(admin.userId)
    const flagged = await insertGym({ visibility: 'public', status: 'flagged', createdBy: me.userId })
    expect(await linkTo(me.userId, flagged)).toBe(flagged)
    const removed = await insertGym({ visibility: 'public', status: 'removed' })
    expect(await linkTo(admin.userId, removed)).toBe(removed)
  })

  it('keeps the stored gym when the phone sends none or the same one, while it survives', async () => {
    const me = await signUp()
    const other = await signUp()
    const gym = await insertGym({ visibility: 'public', status: 'flagged', createdBy: other.userId })
    expect(await workoutGym(db, me.userId, gym, null)).toBe(gym)
    expect(await workoutGym(db, me.userId, gym, gym)).toBe(gym)
  })

  it('drops a stored gym once it is removed, even when the phone sends it again', async () => {
    const { userId } = await signUp()
    const gym = await insertGym({ visibility: 'public' })
    await setStatus('gyms', gym, 'removed')
    expect(await workoutGym(db, userId, gym, null)).toBeNull()
    expect(await workoutGym(db, userId, gym, gym)).toBeNull()
  })

  it('replaces the stored gym with a new one you can read, or with nothing', async () => {
    const me = await signUp()
    const other = await signUp()
    const old = await insertGym({ visibility: 'public' })
    const next = await insertGym({ visibility: 'public' })
    expect(await workoutGym(db, me.userId, old, next)).toBe(next)
    const hidden = await insertGym({ visibility: 'private', owner: other.userId })
    expect(await workoutGym(db, me.userId, old, hidden)).toBeNull()
  })

  it("drops a stored link to another account's private gym, and to a flagged gym with no creator", async () => {
    const me = await signUp()
    const other = await signUp()
    const theirs = await insertGym({ visibility: 'private', owner: other.userId })
    expect(await workoutGym(db, me.userId, theirs, null)).toBeNull()
    const flagged = await insertGym({ visibility: 'public', status: 'flagged' })
    expect(await workoutGym(db, me.userId, flagged, null)).toBe(flagged)
    expect(await workoutGym(db, me.userId, null, flagged)).toBeNull()
  })
})

describe("an entry's listing", () => {
  it('takes a listing you can read: active on an active gym and item, or your own private one', async () => {
    const { userId } = await signUp()
    const item = await genericItem()
    const open = await insertListing({ gym: await insertGym({ visibility: 'public' }), item, visibility: 'public' })
    const myGym = await insertGym({ visibility: 'private', owner: userId })
    const mine = await insertListing({ gym: myGym, item, visibility: 'private', owner: userId })
    const links = await entryListings(db, userId, [entry('a', open), entry('b', mine)], new Map())
    expect(Object.fromEntries(links)).toEqual({ a: open, b: mine })
  })

  it("drops one under a flagged gym, by an author you blocked, or another account's private one", async () => {
    const me = await signUp()
    const other = await signUp()
    const item = await genericItem()
    const flaggedGym = await insertGym({ visibility: 'public', status: 'flagged' })
    const underFlagged = await insertListing({ gym: flaggedGym, item, visibility: 'public' })
    const openGym = await insertGym({ visibility: 'public' })
    const byBlocked = await insertListing({ gym: openGym, item, visibility: 'public', addedBy: other.userId })
    await block(me.userId, other.userId)
    const theirGym = await insertGym({ visibility: 'private', owner: other.userId })
    const theirs = await insertListing({ gym: theirGym, item, visibility: 'private', owner: other.userId })
    const links = await entryListings(
      db,
      me.userId,
      [entry('a', underFlagged), entry('b', byBlocked), entry('c', theirs)],
      new Map(),
    )
    expect(Object.fromEntries(links)).toEqual({ a: null, b: null, c: null })
  })

  it('keeps the previous listing when the phone leaves it out, while it survives', async () => {
    const me = await signUp()
    const other = await signUp()
    const gym = await insertGym({ visibility: 'public' })
    const listing = await insertListing({
      gym, item: await genericItem(), visibility: 'public', addedBy: other.userId, status: 'flagged',
    })
    const links = await entryListings(db, me.userId, [entry('a', null)], new Map([['a', listing]]))
    expect(links.get('a')).toBe(listing)
  })

  it('drops the previous listing once it is removed', async () => {
    const { userId } = await signUp()
    const gym = await insertGym({ visibility: 'public' })
    const listing = await insertListing({ gym, item: await genericItem(), visibility: 'public' })
    await setStatus('gym_equipment', listing, 'removed')
    const links = await entryListings(db, userId, [entry('a', null)], new Map([['a', listing]]))
    expect(links.get('a')).toBeNull()
  })

  it('shows an admin any public listing: flagged, or under a removed gym or item', async () => {
    const admin = await signUp()
    await makeAdmin(admin.userId)
    const item = await genericItem()
    const flagged = await insertListing({
      gym: await insertGym({ visibility: 'public' }), item, visibility: 'public', status: 'flagged',
    })
    const removedGym = await insertGym({ visibility: 'public' })
    const underRemovedGym = await insertListing({ gym: removedGym, item, visibility: 'public' })
    await setStatus('gyms', removedGym, 'removed')
    const removedItem = await insertItem({ brand: 'Acme', model: 'X1', createdBy: admin.userId })
    const underRemovedItem = await insertListing({
      gym: await insertGym({ visibility: 'public' }), item: removedItem, visibility: 'public',
    })
    await setStatus('equipment_items', removedItem, 'removed')
    const links = await entryListings(
      db,
      admin.userId,
      [entry('a', flagged), entry('b', underRemovedGym), entry('c', underRemovedItem)],
      new Map(),
    )
    expect(Object.fromEntries(links)).toEqual({ a: flagged, b: underRemovedGym, c: underRemovedItem })
  })

  it('shows a flagged listing to whoever added it, and hides a listing under a flagged or removed item from others', async () => {
    const me = await signUp()
    const gym = await insertGym({ visibility: 'public' })
    const mine = await insertListing({
      gym, item: await genericItem(), visibility: 'public', addedBy: me.userId, status: 'flagged',
    })
    const flaggedItem = await insertItem({ brand: 'Acme', model: 'F1', createdBy: me.userId })
    await setStatus('equipment_items', flaggedItem, 'flagged')
    const underFlaggedItem = await insertListing({ gym, item: flaggedItem, visibility: 'public' })
    const removedItem = await insertItem({ brand: 'Acme', model: 'R1', createdBy: me.userId })
    await setStatus('equipment_items', removedItem, 'removed')
    const underRemovedItem = await insertListing({ gym, item: removedItem, visibility: 'public' })
    const links = await entryListings(
      db,
      me.userId,
      [entry('a', mine), entry('b', underFlaggedItem), entry('c', underRemovedItem)],
      new Map(),
    )
    expect(Object.fromEntries(links)).toEqual({ a: mine, b: null, c: null })
  })

  it("drops a previous link to a blocked author's listing", async () => {
    const me = await signUp()
    const other = await signUp()
    const listing = await insertListing({
      gym: await insertGym({ visibility: 'public' }), item: await genericItem(), visibility: 'public',
      addedBy: other.userId,
    })
    await block(me.userId, other.userId)
    const links = await entryListings(db, me.userId, [entry('a', null)], new Map([['a', listing]]))
    expect(links.get('a')).toBeNull()
  })

  it("drops a previous link once its gym or item is removed, or when it's another account's private listing", async () => {
    const me = await signUp()
    const other = await signUp()
    const item = await genericItem()
    const gym = await insertGym({ visibility: 'public' })
    const underGym = await insertListing({ gym, item, visibility: 'public' })
    await setStatus('gyms', gym, 'removed')
    const removedItem = await insertItem({ brand: 'Acme', model: 'R2', createdBy: me.userId })
    const underItem = await insertListing({ gym: await insertGym({ visibility: 'public' }), item: removedItem, visibility: 'public' })
    await setStatus('equipment_items', removedItem, 'removed')
    const theirGym = await insertGym({ visibility: 'private', owner: other.userId })
    const theirs = await insertListing({ gym: theirGym, item, visibility: 'private', owner: other.userId })
    const links = await entryListings(
      db,
      me.userId,
      [entry('a', null), entry('b', null), entry('c', null)],
      new Map([['a', underGym], ['b', underItem], ['c', theirs]]),
    )
    expect(Object.fromEntries(links)).toEqual({ a: null, b: null, c: null })
  })

  it("hides another account's private gym and listing even from an admin", async () => {
    const admin = await signUp()
    await makeAdmin(admin.userId)
    const other = await signUp()
    const theirGym = await insertGym({ visibility: 'private', owner: other.userId })
    const theirs = await insertListing({
      gym: theirGym, item: await genericItem(), visibility: 'private', owner: other.userId,
    })
    expect(await workoutGym(db, admin.userId, null, theirGym)).toBeNull()
    const links = await entryListings(db, admin.userId, [entry('a', theirs)], new Map())
    expect(links.get('a')).toBeNull()
  })

  it('hides a listing only from whoever blocked its author', async () => {
    const me = await signUp()
    const other = await signUp()
    const third = await signUp()
    const listing = await insertListing({
      gym: await insertGym({ visibility: 'public' }), item: await genericItem(), visibility: 'public',
      addedBy: other.userId,
    })
    await block(third.userId, other.userId)
    const mine = await entryListings(db, me.userId, [entry('a', listing)], new Map())
    expect(mine.get('a')).toBe(listing)
    const theirs = await entryListings(db, third.userId, [entry('a', listing)], new Map())
    expect(theirs.get('a')).toBeNull()
  })

  it('takes a different new listing over the previous one, and reads one listing shared by two entries once', async () => {
    const { userId } = await signUp()
    const gym = await insertGym({ visibility: 'public' })
    const item = await genericItem()
    const x = await insertListing({ gym, item, visibility: 'public' })
    const y = await insertListing({ gym, item, visibility: 'public' })
    const links = await entryListings(
      db,
      userId,
      [entry('a', y), entry('b', y), entry('c', y)],
      new Map([['a', x]]),
    )
    expect(Object.fromEntries(links)).toEqual({ a: y, b: y, c: y })
  })
})
