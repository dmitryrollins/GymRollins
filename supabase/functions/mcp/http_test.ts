// HTTP end-to-end tests against `supabase functions serve mcp` on the local stack (scripts/test-mcp.sh).
// Skipped unless MCP_E2E_URL is set (e.g. http://127.0.0.1:55421/functions/v1/mcp).
//
// Test setup only: the service-role key from supabase/.env.local (gitignored) creates and deletes the test users.
// Everything the tests exercise runs as a real client would: each user signs in (app session, used to seed data
// and to act as the app), then connects an OAuth client through the real OAuth 2.1 flow (DCR → authorize →
// consent approve → PKCE code exchange, oauth_test_util.ts); MCP calls use that OAuth access token.
import { assert, assertEquals, assertFalse } from 'jsr:@std/assert@^1'
import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2.117.2'
import {
  initializeBody,
  readRpc,
  rpcBody,
  type RpcMessage,
  rpcRequest,
  toolCallBody,
  toolJson,
} from './test_helpers.ts'
import { type OAuthTokens, oauthTokensFor, refresh, revokeGrant } from './oauth_test_util.ts'

function env(name: string): string | undefined {
  try {
    return Deno.env.get(name)
  } catch {
    return undefined // no --allow-env: treat as unset
  }
}

const MCP_URL = env('MCP_E2E_URL')
const BENCH = '0025'
const RATE_LIMIT = 60

async function localEnv(): Promise<Record<string, string>> {
  const text = await Deno.readTextFile(new URL('../../.env.local', import.meta.url))
  return Object.fromEntries(
    text.split('\n').flatMap((line) => {
      const m = /^([A-Z_]+)="?(.*?)"?$/.exec(line.trim())
      return m ? [[m[1], m[2]]] : []
    }),
  )
}

interface TestUser {
  id: string
  /** The app's own session token (no client_id): seeds data; the MCP endpoint must refuse it. */
  sessionToken: string
  /** Client acting as the app (owner session). */
  client: SupabaseClient
  /** OAuth-client tokens (JWT carries client_id), as Claude gets them. */
  oauth: OAuthTokens
  token: string
}

const noSession = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } }

const userClient = (apiUrl: string, anonKey: string, token: string) =>
  createClient(apiUrl, anonKey, { ...noSession, global: { headers: { Authorization: `Bearer ${token}` } } })

async function createUser(admin: SupabaseClient, apiUrl: string, anonKey: string): Promise<TestUser> {
  const email = `mcp-e2e-${crypto.randomUUID()}@example.test`
  const password = `pw-${crypto.randomUUID()}`
  const created = await admin.auth.admin.createUser({ email, password, email_confirm: true })
  if (created.error) throw created.error
  const anon = createClient(apiUrl, anonKey, noSession)
  const signed = await anon.auth.signInWithPassword({ email, password })
  if (signed.error || !signed.data.session) throw signed.error ?? new Error('no session')
  const sessionToken = signed.data.session.access_token
  const client = userClient(apiUrl, anonKey, sessionToken)
  const oauth = await oauthTokensFor(apiUrl, anonKey, sessionToken)
  return { id: created.data.user.id, sessionToken, client, oauth, token: oauth.accessToken }
}

function must<T>(res: { data: T; error: unknown }): T {
  if (res.error) throw res.error
  return res.data
}

/** Seeds user A the way the app does: profile, a routine with bench, the schedule, a workout (RPC), a weigh-in. */
async function seedOwner(user: TestUser): Promise<{ routineId: string; workoutId: string }> {
  const routineId = crypto.randomUUID()
  const workoutId = crypto.randomUUID()
  const entryId = crypto.randomUUID()
  must(await user.client.from('profiles').insert({ unit: 'lb' }))
  must(
    await user.client.from('routines').insert({
      id: routineId,
      name: 'Push + Arms',
      exercises: [{
        id: crypto.randomUUID(),
        exercise_id: BENCH,
        position: 0,
        sets: 3,
        reps: 10,
        reps_min: 8,
        weight_kg: 58.967,
        mode: 'reps',
      }],
    }),
  )
  must(await user.client.from('week_schedule').insert({ weekday: 1, routine_id: routineId }))
  const set = (position: number) => ({ id: crypto.randomUUID(), position, w_kg: 58.967, r: 10, done: true })
  const status = must(
    await user.client.rpc('upsert_workout', {
      payload: {
        id: workoutId,
        started_at: '2026-09-19T17:00:00Z',
        ended_at: '2026-09-19T18:00:00Z',
        routine_id: routineId,
        name: 'Push + Arms',
        client_updated_at: new Date().toISOString(),
        entries: [{ id: entryId, exercise_id: BENCH, position: 0, sets: [set(0), set(1), set(2)] }],
      },
    }),
  ) as { status: string }
  assertEquals(status.status, 'ok')
  must(
    await user.client.from('bodyweight').insert({
      id: crypto.randomUUID(),
      measured_at: '2026-09-20T07:00:00Z',
      w_kg: 81.2,
    }),
  )
  return { routineId, workoutId }
}

async function post(body: unknown, token?: string): Promise<Response> {
  return await fetch(rpcRequest(MCP_URL!, body, token))
}

async function call(
  token: string,
  id: number,
  name: string,
  args: Record<string, unknown> = {},
): Promise<RpcMessage> {
  const res = await post(toolCallBody(id, name, args), token)
  assertEquals(res.status, 200, `${name}: HTTP ${res.status}`)
  return await readRpc(res)
}

Deno.test({
  name: 'MCP over HTTP against the local stack',
  ignore: !MCP_URL,
  sanitizeResources: false,
  sanitizeOps: false,
  fn: async (t) => {
    const e = await localEnv()
    const apiUrl = e.API_URL
    const anonKey = e.ANON_KEY ?? e.PUBLISHABLE_KEY
    const admin = createClient(apiUrl, e.SERVICE_ROLE_KEY ?? e.SECRET_KEY, noSession)
    const users: TestUser[] = []
    try {
      const a = await createUser(admin, apiUrl, anonKey)
      const b = await createUser(admin, apiUrl, anonKey)
      const c = await createUser(admin, apiUrl, anonKey)
      const d = await createUser(admin, apiUrl, anonKey)
      users.push(a, b, c, d)
      const seeded = await seedOwner(a)

      await t.step('no token: initialize → 401 with the metadata pointer; metadata → 200 JSON', async () => {
        const res = await post(initializeBody())
        assertEquals(res.status, 401)
        const origin = new URL(MCP_URL!).origin
        assertEquals(
          res.headers.get('www-authenticate'),
          `Bearer resource_metadata="${origin}/functions/v1/mcp/oauth-protected-resource"`,
        )
        await res.body?.cancel()
        const meta = await fetch(`${MCP_URL}/oauth-protected-resource`)
        assertEquals(meta.status, 200)
        const doc = await meta.json()
        assertEquals(doc.resource, `${origin}/functions/v1/mcp`)
        assertEquals(doc.authorization_servers, [`${origin}/auth/v1`])
      })

      await t.step('a garbage token → 401', async () => {
        const res = await post(initializeBody(), 'not.a.token')
        assertEquals(res.status, 401)
        await res.body?.cancel()
      })

      await t.step("the app's own session token (no client_id) → 401 with the metadata pointer", async () => {
        const res = await post(toolCallBody(1, 'get_plan'), a.sessionToken)
        assertEquals(res.status, 401)
        assert(res.headers.get('www-authenticate')?.includes('resource_metadata='))
        await res.body?.cancel()
      })

      await t.step('RLS treats the OAuth token as an MCP client: reads yes, plan writes no', async () => {
        const mcp = userClient(apiUrl, anonKey, a.token)
        const routines = must(await mcp.from('routines').select('id')) as unknown[]
        assertEquals(routines.length, 1)
        const denied = await mcp.from('routines').insert({
          id: crypto.randomUUID(),
          name: 'Sneaky',
          exercises: [],
        })
        assertEquals(denied.error?.code, '42501')
        const isClient = must(await mcp.rpc('is_mcp_client')) as boolean
        assertEquals(isClient, true)
      })

      await t.step('A: initialize, tools/list with 13 annotated tools', async () => {
        const init = await readRpc(await post(initializeBody(), a.token))
        assertEquals(init.result.serverInfo.name, 'gymrollins')
        const list = await readRpc(await post(rpcBody(2, 'tools/list'), a.token))
        const tools = list.result.tools as { name: string; annotations: Record<string, boolean> }[]
        assertEquals(tools.length, 13)
        for (const tool of tools) {
          const write = tool.name === 'propose_plan_changes' || tool.name === 'log_bodyweight'
          assertEquals(tool.annotations.readOnlyHint, !write, tool.name)
          if (write) assertEquals(tool.annotations.destructiveHint, false, tool.name)
        }
      })

      await t.step('A: get_plan returns the routine with bench and the schedule', async () => {
        const plan = toolJson(await call(a.token, 3, 'get_plan'))
        assertEquals(plan.routines.length, 1)
        assertEquals(plan.routines[0].id, seeded.routineId)
        assertEquals(plan.routines[0].exercises[0].name, 'barbell bench press')
        assertEquals(plan.routines[0].exercises[0].weight_display, '130 lb (59 kg)')
        assertEquals(plan.week[0].routine, 'Push + Arms')
      })

      await t.step('A: get_exercise_history("barbell bench press") → 1 session', async () => {
        const out = toolJson(
          await call(a.token, 4, 'get_exercise_history', { exercise: 'barbell bench press' }),
        )
        assertEquals(out.exercise.id, BENCH)
        assertEquals(out.sessions.length, 1)
        assertEquals(out.sessions[0].e1rm_kg, 78.6)
        assertEquals(out.sessions[0].workout_id, seeded.workoutId)
      })

      await t.step(
        'A: list_workouts, get_workout, get_training_summary, get_bodyweight, search, profile',
        async () => {
          const list = toolJson(await call(a.token, 5, 'list_workouts', { since: '2026-09-01' }))
          assertEquals(list.workouts.length, 1)
          assertEquals(list.workouts[0].volume_kg, 1769)
          const w = toolJson(await call(a.token, 6, 'get_workout', { id: seeded.workoutId }))
          assertEquals(w.entries[0].sets.length, 3)
          const summary = await call(a.token, 7, 'get_training_summary', { weeks: 12 })
          assertFalse(summary.result.isError)
          const bw = toolJson(await call(a.token, 8, 'get_bodyweight', { since: '2026-09-01' }))
          assertEquals(bw.entries[0].weight_kg, 81.2)
          const found = toolJson(
            await call(a.token, 9, 'search_exercises', { query: 'bench press', equipment: 'barbell' }),
          )
          assert(found.results.some((r: { id: string }) => r.id === BENCH))
          assertEquals(toolJson(await call(a.token, 10, 'get_profile')).unit, 'lb')
          const insights = toolJson(
            await call(a.token, 20, 'get_training_insights', { time_zone: 'Europe/Warsaw' }),
          )
          assertEquals(insights.recovery.length, 16)
          assertEquals(insights.weekly_sets.muscles.length, 16)
          assertEquals(typeof insights.streak.current_weeks, 'number')
          const strength = toolJson(await call(a.token, 21, 'get_strength_levels'))
          assertEquals(strength.lifts.length, 3)
          assert(Array.isArray(strength.missing))
        },
      )

      await t.step('A: propose_plan_changes (weight on bench) → pending proposal row', async () => {
        const change = {
          id: 'c1',
          type: 'weight',
          routineId: seeded.routineId,
          exerciseId: BENCH,
          weightKg: 61.235,
          reason: 'All sets hit 10 reps',
        }
        const out = toolJson(
          await call(a.token, 11, 'propose_plan_changes', { summary: 'Bench +5 lb', changes: [change] }),
        )
        assertEquals(out.status, 'pending')
        const row = must(
          await a.client.from('proposals').select('status, changes').eq('id', out.proposal_id).single(),
        ) as { status: string; changes: { id: string }[] }
        assertEquals(row.status, 'pending')
        assertEquals(row.changes[0].id, 'c1')
        const status = toolJson(await call(a.token, 12, 'get_proposal', { id: out.proposal_id }))
        assertEquals(status.status, 'pending')
      })

      await t.step('A: an invalid proposal → isError with violations, nothing stored', async () => {
        const bad = { id: 'c1', type: 'sets', routineId: seeded.routineId, exerciseId: '0047', sets: 3 }
        const msg = await call(a.token, 13, 'propose_plan_changes', { summary: 'Bad', changes: [bad] })
        assertEquals(msg.result.isError, true)
        assertEquals(toolJson(msg).violations[0].field, 'exerciseId')
        const rows = must(await a.client.from('proposals').select('id')) as unknown[]
        assertEquals(rows.length, 1)
      })

      await t.step('A: log_bodyweight stores a row the app can pull', async () => {
        const out = toolJson(
          await call(a.token, 14, 'log_bodyweight', { weight_kg: 81.5, date: '2026-09-26' }),
        )
        const row = must(await a.client.from('bodyweight').select('w_kg').eq('id', out.id).single()) as {
          w_kg: number
        }
        assertEquals(row.w_kg, 81.5)
      })

      await t.step("B: get_workout(A's workout) → not found (RLS)", async () => {
        const msg = await call(b.token, 15, 'get_workout', { id: seeded.workoutId })
        assertEquals(msg.result.isError, true)
        assert(toolJson(msg).error.includes('not found'))
        const plan = toolJson(await call(b.token, 16, 'get_plan'))
        assertEquals(plan.routines.length, 0)
      })

      await t.step("audit: A's calls are recorded (ok and error), B sees none of them", async () => {
        const rows = must(await a.client.from('mcp_audit').select('tool, ok, args_digest, user_id')) as {
          tool: string
          ok: boolean
          args_digest: string
          user_id: string
        }[]
        assertEquals(rows.length, 14) // tools/call only: get_plan … log_bodyweight
        assert(rows.every((r) => r.user_id === a.id && /^[0-9a-f]{64}$/.test(r.args_digest)))
        assert(rows.some((r) => r.tool === 'get_training_insights' && r.ok))
        assert(rows.some((r) => r.tool === 'get_strength_levels' && r.ok))
        assert(rows.some((r) => r.tool === 'propose_plan_changes' && r.ok))
        assert(rows.some((r) => r.tool === 'propose_plan_changes' && !r.ok))
        const seenByB = must(await b.client.from('mcp_audit').select('user_id')) as { user_id: string }[]
        assert(seenByB.every((r) => r.user_id === b.id))
      })

      await t.step(
        `rate limit: 70 concurrent requests → exactly ${RATE_LIMIT} pass, the rest 429`,
        async () => {
          const responses = await Promise.all(
            Array.from({ length: 70 }, (_, i) => post(toolCallBody(100 + i, 'get_profile'), c.token)),
          )
          const statuses = responses.map((r) => r.status)
          await Promise.all(responses.map((r) => r.body?.cancel()))
          assertEquals(statuses.filter((st) => st === 200).length, RATE_LIMIT)
          assertEquals(statuses.filter((st) => st === 429).length, 70 - RATE_LIMIT)
          const res = await post(toolCallBody(999, 'get_profile'), c.token)
          assertEquals(res.status, 429)
          assertEquals(res.headers.get('retry-after'), '60')
          await res.body?.cancel()
        },
      )

      await t.step(`mcp_take_call(): 70 concurrent RPCs → exactly ${RATE_LIMIT} true`, async () => {
        const mcp = userClient(apiUrl, anonKey, d.token)
        const taken = await Promise.all(Array.from({ length: 70 }, () => mcp.rpc('mcp_take_call')))
        assertEquals(taken.filter((r) => r.data === true).length, RATE_LIMIT)
        assertEquals(taken.filter((r) => r.data === false).length, 70 - RATE_LIMIT)
      })

      await t.step('mcp_read_plan off → the plan and profile are hidden from the MCP client', async () => {
        must(await b.client.from('profiles').insert({ unit: 'kg', mcp_read_plan: false }))
        must(
          await b.client.from('routines').insert({ id: crypto.randomUUID(), name: 'Hidden', exercises: [] }),
        )
        const plan = toolJson(await call(b.token, 17, 'get_plan'))
        assertEquals(plan.routines.length, 0)
        const profile = toolJson(await call(b.token, 18, 'get_profile'))
        assertEquals(profile.profile_saved, false)
        must(await b.client.from('profiles').update({ mcp_read_plan: true }).eq('user_id', b.id))
        assertEquals(toolJson(await call(b.token, 19, 'get_plan')).routines.length, 1)
      })

      await t.step(
        'revoking the grant ("Disconnect") kills refresh and the access token at once',
        async () => {
          const res = await refresh(apiUrl, b.oauth)
          assertEquals(res.status, 200)
          const renewed = await res.json()
          await revokeGrant(apiUrl, anonKey, b.sessionToken, b.oauth.clientId)
          const again = await refresh(apiUrl, { ...b.oauth, refreshToken: renewed.refresh_token })
          assertEquals(again.status, 400)
          await again.body?.cancel()
          const mcp = await post(toolCallBody(20, 'get_plan'), renewed.access_token)
          assertEquals(mcp.status, 401) // auth.getUser rejects it: revocation ends the session
          await mcp.body?.cancel()
        },
      )
    } finally {
      for (const u of users) await admin.auth.admin.deleteUser(u.id)
    }
  },
})
