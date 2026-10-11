// GymRollins remote MCP server (Supabase Edge Function, verify_jwt = false — auth is done here).
// Wires the environment into createApp: token verification with Supabase Auth, and a Db on a user-scoped client
// (anon key + the caller's bearer token) so RLS applies to every tool. The service role is never used here.
import { createClient } from 'jsr:@supabase/supabase-js@2.117.2'
import { createApp } from './app.ts'
import type { TokenVerifier } from './auth.ts'
import { SupabaseDb } from './supabase_db.ts'

function requireEnv(...names: string[]): string {
  for (const name of names) {
    const value = Deno.env.get(name)
    if (value) return value
  }
  throw new Error(`missing env: ${names.join(' or ')}`)
}

/** URL the function uses to reach Supabase (inside the runtime this can be an internal host like kong:8000). */
const API_URL = requireEnv('SUPABASE_URL')
const ANON_KEY = requireEnv('SUPABASE_ANON_KEY', 'SUPABASE_PUBLISHABLE_KEY')
/** Public origin MCP clients use; set MCP_PUBLIC_BASE_URL when it differs from SUPABASE_URL (local serve). */
const PUBLIC_BASE = Deno.env.get('MCP_PUBLIC_BASE_URL') ?? API_URL

const clientOptions = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false } }
const authClient = createClient(API_URL, ANON_KEY, clientOptions)

const verify: TokenVerifier = async (token) => {
  const { data, error } = await authClient.auth.getUser(token)
  if (!error) return data.user ? { id: data.user.id } : null
  if (error.status && error.status >= 400 && error.status < 500) return null
  throw new Error(`auth unavailable (${error.status ?? 'network'})`)
}

Deno.serve(createApp({
  publicBase: PUBLIC_BASE,
  verify,
  dbFor: (auth) =>
    new SupabaseDb(
      createClient(API_URL, ANON_KEY, {
        ...clientOptions,
        global: { headers: { Authorization: `Bearer ${auth.token}` } },
      }),
      auth.clientId,
    ),
}))
