// GymRollins OAuth consent page (Supabase's OAuth 2.1 authorization server flow).
// Supabase rewrites Edge Function HTML responses to text/plain, so this page is served as a plain static site by
// scripts/consent-server.mjs (locally on http://127.0.0.1:55430; see docs/research/2026-09-26-mcp-on-supabase.md
// §5 and the OAuth section of README.md for the cloud equivalent). Config comes from /config.js (window.GYM_CONFIG).
//
// Flow: read `authorization_id` from the query string. If there is no session, sign in (email/password locally;
// Apple only when window.GYM_APPLE_ENABLED). Then call supabase.auth.oauth.getAuthorizationDetails(id). If it
// returns a redirect (already consented), follow it. Otherwise this client has never been approved: show the client
// name, the full redirect URI, a first-time warning and what access means, then Approve/Deny -> approveAuthorization/denyAuthorization -> follow the returned redirect_url.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.117.2'

const els = {
  loading: document.getElementById('loading'),
  signIn: document.getElementById('sign-in'),
  signInError: document.getElementById('sign-in-error'),
  appleButton: document.getElementById('apple-sign-in'),
  email: document.getElementById('email'),
  password: document.getElementById('password'),
  consent: document.getElementById('consent'),
  consentError: document.getElementById('consent-error'),
  clientName: document.getElementById('client-name'),
  clientName2: document.getElementById('client-name-2'),
  redirectUri: document.getElementById('redirect-uri'),
  signedInEmail: document.getElementById('signed-in-email'),
  approve: document.getElementById('approve'),
  deny: document.getElementById('deny'),
  fatal: document.getElementById('fatal-error'),
  fatalMessage: document.getElementById('fatal-error-message'),
}

function showOnly(section) {
  for (const el of [els.loading, els.signIn, els.consent, els.fatal]) {
    el.hidden = el !== section
  }
}

function showFatal(message) {
  els.fatalMessage.textContent = message
  showOnly(els.fatal)
}

function authorizationErrorMessage(error) {
  if (!error) return 'Something went wrong. Try again.'
  return error.message ?? 'Something went wrong. Try again.'
}

async function main() {
  const config = window.GYM_CONFIG
  if (!config || !config.url || !config.anonKey) {
    showFatal('The consent server did not provide Supabase configuration. Check scripts/consent-server.mjs.')
    return
  }

  const params = new URLSearchParams(window.location.search)
  const authorizationId = params.get('authorization_id')
  if (!authorizationId) {
    showFatal('This link is missing an authorization request. Start the connection from Claude again.')
    return
  }

  const supabase = createClient(config.url, config.anonKey)

  if (window.GYM_APPLE_ENABLED) {
    els.appleButton.hidden = false
    els.appleButton.addEventListener('click', () => {
      supabase.auth.signInWithOAuth({
        provider: 'apple',
        options: { redirectTo: window.location.href },
      })
    })
  }

  els.signIn.addEventListener('submit', async (event) => {
    event.preventDefault()
    els.signInError.hidden = true
    const email = els.email.value.trim()
    const password = els.password.value
    const submitButton = els.signIn.querySelector('button[type="submit"]')
    submitButton.disabled = true
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    submitButton.disabled = false
    if (error) {
      els.signInError.textContent = error.message
      els.signInError.hidden = false
      return
    }
    await loadAuthorization(supabase, authorizationId)
  })

  els.approve.addEventListener('click', () => resolveAuthorization(supabase, authorizationId, 'approve'))
  els.deny.addEventListener('click', () => resolveAuthorization(supabase, authorizationId, 'deny'))

  const {
    data: { session },
  } = await supabase.auth.getSession()
  if (!session) {
    showOnly(els.signIn)
    return
  }
  await loadAuthorization(supabase, authorizationId)
}

async function loadAuthorization(supabase, authorizationId) {
  showOnly(els.loading)
  const { data, error } = await supabase.auth.oauth.getAuthorizationDetails(authorizationId)
  if (error) {
    showFatal(authorizationErrorMessage(error))
    return
  }
  if (!data || 'authorization_id' in data === false) {
    // Already consented: `data` is an OAuthRedirect ({ redirect_url }).
    window.location.href = data.redirect_url
    return
  }
  renderConsent(data)
}

function renderConsent(details) {
  const name = details.client?.name ?? 'This app'
  els.clientName.textContent = name
  els.clientName2.textContent = name
  // The full redirect URI (not just the host): that is where the authorization code goes on Approve.
  els.redirectUri.textContent = details.redirect_uri ?? '—'
  els.signedInEmail.textContent = details.user?.email ?? '—'
  els.consentError.hidden = true
  showOnly(els.consent)
}

async function resolveAuthorization(supabase, authorizationId, action) {
  els.approve.disabled = true
  els.deny.disabled = true
  els.consentError.hidden = true
  const method = action === 'approve' ? 'approveAuthorization' : 'denyAuthorization'
  const { data, error } = await supabase.auth.oauth[method](authorizationId, { skipBrowserRedirect: true })
  if (error || !data?.redirect_url) {
    els.consentError.textContent = authorizationErrorMessage(error)
    els.consentError.hidden = false
    els.approve.disabled = false
    els.deny.disabled = false
    return
  }
  window.location.href = data.redirect_url
}

main().catch((error) => {
  showFatal(authorizationErrorMessage(error))
})
