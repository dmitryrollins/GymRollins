import { describe, expect, it } from 'vitest'
import { request } from './helpers.ts'

describe('the Worker', () => {
  it('answers an unknown route with a JSON 404', async () => {
    const res = await request('GET', '/nowhere')
    expect(res.status).toBe(404)
    expect(await res.json()).toEqual({ error: { code: 'not_found', message: 'No such route.' } })
  })
})
