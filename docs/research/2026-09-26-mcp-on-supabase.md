# Research: Remote MCP server on Supabase Edge Functions + Claude custom connector OAuth (Sept 2026)

## 1. MCP TypeScript SDK v2 — real, current, and Supabase's own official pick

**Packages confirmed to exist on npm** (real, not hallucinated):
- `@modelcontextprotocol/server` — **2.1.0** (published within days of Sept 2026), implements the **2026-07-28** MCP spec revision. [npm](https://www.npmjs.com/package/@modelcontextprotocol/server)
- `@modelcontextprotocol/core`, `@modelcontextprotocol/express`, `@modelcontextprotocol/fastify`, `@modelcontextprotocol/hono`, `@modelcontextprotocol/node` — optional adapters.
- `@modelcontextprotocol/sdk` 1.30.x — legacy v1, still on npm.
- Migration guides: https://ts.sdk.modelcontextprotocol.io/v2/migration/ , codemod: `npx @modelcontextprotocol/codemod@latest v1-to-v2 .`
- v2 requires Node.js 20+ conceptually but is web-standard/Fetch-based, so it runs fine on Deno. ESM-first, ships CJS too.

**IMPORTANT — Supabase's own official guide (Sept 2026) uses v2, not v1.**
Official doc: **"Deploy MCP servers" — https://supabase.com/docs/guides/ai-tools/byo-mcp** (this is the exact guide the task asked me to find). It states: *"The tutorial uses the official MCP TypeScript SDK. Any MCP framework that runs on the Edge Runtime works the same way, for example mcp-lite."* — i.e., Supabase recommends `@modelcontextprotocol/server` v2 as primary, `mcp-lite` as an alternative. **Recommendation: use v2 (`@modelcontextprotocol/server`) — it is what Supabase itself documents and tests against for Edge Functions, it's Fetch/Request-Response native (no Deno-specific shims needed), and v1 is legacy.**

### Exact v2 API (verified via SDK migration docs + Supabase's own guide, cross-checked, consistent)

```ts
import 'jsr:@supabase/functions-js/edge-runtime.d.ts'
import { createMcpHandler, McpServer } from 'npm:@modelcontextprotocol/server@^2.0.0'
import { z } from 'npm:zod@^4.3.6'   // Zod v4 REQUIRED (Standard Schema spec) — v3 will NOT work with registerTool's schema validation in v2

const handler = createMcpHandler(() => {
  const server = new McpServer({ name: 'todos', version: '0.1.0' })

  server.registerTool(
    'list_todos',
    {
      description: 'List the todos of the signed-in user',
      inputSchema: z.object({ limit: z.number().int().min(1).max(100).default(20) }),
      annotations: { readOnlyHint: true },   // Claude reads these — see §4
    },
    async ({ limit }, ctx) => {
      const token = ctx.http?.authInfo?.token   // bearer token, undefined on stdio
      // ... use token or the RLS-scoped client (see §3)
      return { content: [{ type: 'text', text: JSON.stringify([]) }] }
    }
  )
  return server
})

Deno.serve((req) => handler.fetch(req))
```

- Schema library: **Zod v4** (v2 SDK accepts any Standard-Schema-compliant validator — Zod v4, ArkType, Valibot; **not Zod v3**, which predates Standard Schema).
- Web-standard transport: the v2 SDK's `@modelcontextprotocol/server` package itself implements a transport that speaks native `Request`/`Response` — no separate "WebStandardStreamableHTTPServerTransport" import needed when using the high-level `createMcpHandler(...).fetch(req)` pattern shown in Supabase's guide. (A lower-level `WebStandardStreamableHTTPServerTransport` class also exists in the SDK for manual wiring, confirmed via SDK docs, if you need per-request server instantiation control beyond what `createMcpHandler` gives you — both are stateless-friendly.)
- Auth info in handlers: `ctx.http.authInfo.token` (v2's `extra.authInfo` from v1 became `ctx.http?.authInfo` in v2).
- `@modelcontextprotocol/hono` exists for Hono-based routing (DNS-rebinding protection etc.) but is **not required** — Supabase's own example uses plain `Deno.serve` + `handler.fetch(req)`.

### Supabase's purpose-built auth middleware (this is the biggest finding — use it)

Supabase ships **`@supabase/middleware`** and **`@supabase/server`** npm packages specifically for this MCP-on-Edge-Functions use case:

```ts
import { pipeline } from 'npm:@supabase/middleware@^0.5.0'
import { withOAuthProtectedResource, withSupabase } from 'npm:@supabase/server@^1.6.0'
import type { Database } from './database.types.ts'

Deno.serve(
  pipeline(
    [withOAuthProtectedResource(), withSupabase<Database>({ auth: 'user' })],
    async (req, { supabase }) => {
      const handler = createMcpHandler(() => { /* server + registerTool as above, using `supabase` from context */ })
      return handler.fetch(req)
    }
  )
)
```

- `withOAuthProtectedResource()` — auto-handles the 401 + `WWW-Authenticate` + the metadata endpoint (see §2/§3).
- `withSupabase<Database>({ auth: 'user' })` — rejects requests without a valid user token, and hands your handler a Supabase client **already scoped to that user via RLS** (this answers task item 3d directly — no need to hand-roll `createClient(url, anonKey, { global: { headers: { Authorization: ... } } })`, though that classic pattern still works and is what `withSupabase` does internally).
- `@supabase/server`'s token validation ([github.com/supabase/server](https://github.com/supabase/server)) is **JWKS/jose-based** (asymmetric verification), not `auth.getUser()`: env vars `SUPABASE_JWKS` (inline) or `SUPABASE_JWKS_URL` (remote), plus `audience`/`issuer` pinning via a `fromSupabaseUrl()` helper — this matches Supabase's move to asymmetric (ES256) signing keys. Current version **1.8.0** on npm as of Sept 2026 (guide pins `^1.6.0`).
- Caveat found in Supabase's own docs: *"The pipeline composition approach is alpha and tracks `@supabase/middleware` 0.x, though a nested form...is stable."* — i.e., `pipeline([...])` sugar is alpha; a manual nested-function-call form is the stable fallback if you want to avoid alpha APIs in production.

**Recommendation:** v2 SDK + `@supabase/middleware`/`@supabase/server` is the path of least resistance and is Supabase's own blessed stack as of Sept 2026. Don't bother with v1 `@modelcontextprotocol/sdk` — it's legacy and Supabase's current guide doesn't use it.

Sources: https://supabase.com/docs/guides/ai-tools/byo-mcp , https://supabase.com/docs/guides/functions/examples/mcp-server-mcp-lite , https://ts.sdk.modelcontextprotocol.io/v2/migration/upgrade-to-v2.html , https://github.com/modelcontextprotocol/typescript-sdk , https://www.npmjs.com/package/@supabase/server

---

## 2. MCP Authorization spec — 2025-06-18 (and 2025-11-25 / 2026-07-28 revisions)

Fetched directly from https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization (2025-06-18 is the baseline; Claude's own docs as of Sept 2026 cite the **2025-11-25** revision for CIMD, and the SDK targets **2026-07-28**; the authorization mechanics below are unchanged across these, with hardening add-ons noted).

### 401 response requirement
- MCP servers **MUST** return `401 Unauthorized` with a `WWW-Authenticate` header pointing to the Protected Resource Metadata URL, per RFC 9728 §5.1:
  ```http
  HTTP/1.1 401 Unauthorized
  WWW-Authenticate: Bearer resource_metadata="https://mcp.example.com/.well-known/oauth-protected-resource"
  ```
- Servers **MUST** implement RFC 9728 Protected Resource Metadata; clients **MUST** use it for AS discovery.
- Error codes: 401 = unauthorized/invalid token, 403 = insufficient scope, 400 = malformed request.

### Protected Resource Metadata document fields (RFC 9728)
- **Required:** `resource` (canonical resource URI)
- **Recommended:** `scopes_supported`
- **Optional:** `authorization_servers`, `jwks_uri`, `bearer_methods_supported`, `resource_signing_alg_values_supported`, `resource_name`, `resource_documentation`, `resource_policy_uri`, `resource_tos_uri`, `tls_client_certificate_bound_access_tokens`, `authorization_details_types_supported`, `dpop_signing_alg_values_supported`, `dpop_bound_access_tokens_required`, `signed_metadata`.
- MCP spec requires `authorization_servers` to have **at least one** entry.

### Audience / resource-indicator handling (RFC 8707)
- MCP clients **MUST** send a `resource` parameter (canonical server URI, e.g. `https://mcp.example.com/mcp`, no trailing slash, no fragment) in both authorization and token requests.
- MCP servers **MUST** validate the access token's audience matches themselves; **MUST NOT** accept tokens without them in the audience claim; **MUST NOT** pass through the client's token to upstream APIs (confused-deputy prevention).

### Well-known URL path construction — where the "path-suffix" assumption breaks, and how Claude/Supabase actually solve it
- **Strict RFC 9728 rule:** the well-known suffix is inserted **before** the resource's path, not appended after: for resource `https://host/functions/v1/mcp`, the "correct" RFC9728-only construction is `https://host/.well-known/oauth-protected-resource/functions/v1/mcp` — **not** `https://host/functions/v1/mcp/.well-known/oauth-protected-resource` as originally assumed in the task brief. (Verified directly against RFC 9728 text.)
- **But this doesn't actually matter in practice**, per Claude's own official docs (https://claude.com/docs/connectors/building/authentication, fetched verbatim Sept 2026):
  > *"The `resource_metadata` URL doesn't have to be on the MCP server's origin. It can be any HTTPS location that serves the JSON document, which makes this the most reliable path on serverless or edge platforms that only route requests under a path prefix and can't serve `/.well-known/*` at the root."*
  - Claude requires the `401` status (it explicitly **ignores** `WWW-Authenticate` on a `200`).
  - Claude uses **only the first** `authorization_servers` entry (no fallback to later ones).
  - **Fallback if you omit the header pointer:** Claude probes `/.well-known/oauth-protected-resource/<mcp-path>` first, then `/.well-known/oauth-protected-resource` on the MCP server's own origin — i.e. it *does* implement the strict RFC9728 insertion-before convention as a fallback, but only if you don't give it an explicit pointer.
- **Practical answer for Supabase Edge Functions:** since Supabase cannot serve arbitrary root-level `/.well-known/*` paths (see §3a), the correct approach — and the one Supabase's own guide and Claude's own docs both converge on — is: serve the metadata at an **arbitrary path under the same function**, e.g. `https://<ref>.supabase.co/functions/v1/mcp/oauth-protected-resource` (Supabase's actual guide doesn't even use the `.well-known` segment — just `/oauth-protected-resource`), and **always** send the explicit `resource_metadata="..."` pointer in the `WWW-Authenticate` header. This is fully spec-compliant and is exactly what Claude's docs recommend for edge/serverless platforms.

Sources: https://modelcontextprotocol.io/specification/2025-06-18/basic/authorization , https://www.rfc-editor.org/rfc/rfc9728.html , https://claude.com/docs/connectors/building/authentication

---

## 3. Supabase specifics

### (a) Edge Functions routing / sub-paths — YES, one function can serve sub-paths
- A single Edge Function (e.g. named `mcp`) receives **all** requests under `/functions/v1/mcp/*` — you route internally using the URL Pattern API or a lightweight router (Hono optional, not required). Confirmed both by Supabase's routing docs (https://supabase.com/docs/guides/functions/routing) and by the working example: `GET /oauth-protected-resource` and `POST/GET/DELETE /mcp` dispatched from one `Deno.serve` handler based on `new URL(req.url).pathname`.
- **Custom domains**: Edge Functions ARE now reachable via custom domains (`https://api.example.com/functions/v1/your_function_name`) — but **`.well-known` paths cannot be customized/served at the root on Supabase today**, confirmed directly (quoted) from Supabase maintainer **gregnr** in [GitHub Discussion #43050](https://github.com/orgs/supabase/discussions/43050) (answered/accepted, 2026):
  > *"You are correct that `.well-known` paths cannot be customized on Supabase today, but our solution to this actually doesn't require `.well-known` at all. MCP auth expects a `www-authenticate` header in the HTTP response which tells the client where to find the protected resource metadata... you could set the protected resource metadata to `https://<ref>.supabase.co/functions/v1/mcp/oauth-protected-resource` and the same Edge Function can handle both routes."*
  - Reference implementation cited: `github.com/gregnr/edge-function-mcp-sandbox` (commit `3158d8f`, file `supabase/functions/mcp/index.ts`) — this repo appears to no longer be publicly resolvable (404 on direct fetch as of this research; may have been renamed/removed), but a **real, live, production fork exists and is public**: **https://github.com/marmelab/atomic-crm/blob/main/supabase/functions/mcp/index.ts** (the CRM's own author, `fzaninotto`, confirmed in the same thread: *"It works! I managed to port my standalone MCP server into an edge function... it's available at [that URL]"*). This is a real-world reference implementation worth reading directly when implementing.
  - **Known blocker reported by fzaninotto (Mar 25, 2026, same thread) — still worth checking if fixed by Sept 2026:** *"Using the `www-authenticate` header to point to the Edge function was my original attempt, but for some reason it didn't work at the time. I believe the OAuth implementation on the client side (Claude and ChatGPT) wasn't complete."* He ended up needing production deploys to debug (see §6 local-testing blocker below). **This predates Claude's Sept-2026 docs update (which explicitly documents and endorses off-origin/path-suffixed `resource_metadata` pointers), so it is very likely fixed now, but has not been independently re-verified in this research — flag as residual risk to smoke-test early.**

### (b) `verify_jwt` + token validation
- Exact `config.toml`:
  ```toml
  [functions.mcp]
  verify_jwt = false

  [auth]
  site_url = "http://localhost:3000"

  [auth.oauth_server]
  enabled = true
  authorization_url_path = "/oauth/consent"
  allow_dynamic_registration = true   # REQUIRED for Claude's DCR flow (see §4) — default is false
  ```
  `verify_jwt = false` is required because the function must serve the unauthenticated discovery request (`/oauth-protected-resource`) and the `initialize` 401 itself — the platform gateway would otherwise reject anything without a valid Supabase-platform JWT before your code even runs.
- **Token validation inside the function — two viable approaches:**
  1. **`supabase.auth.getUser(token)`** — simplest, one call, does a network round-trip to Auth per request.
  2. **JWKS verification with `jose`** (or via Supabase's own `@supabase/server` package, which wraps this) — validates locally against the project's **asymmetric (ES256) JWT signing key**, no network round-trip, recommended for latency-sensitive MCP tool calls. Supabase migrated new projects to asymmetric signing keys (JWKS-discoverable at `/auth/v1/.well-known/jwks.json`) — this is the modern, faster path and what `@supabase/server`'s `withSupabase()` does under the hood (`SUPABASE_JWKS` / `SUPABASE_JWKS_URL` env vars, `jose`-based).
  - **Recommendation: use `@supabase/server`'s `withSupabase({ auth: 'user' })`** (see §1) rather than hand-rolling either — it does JWKS verification AND hands you an RLS-scoped client in one call.

### (c) Supabase's own OAuth 2.1 authorization server
- **Status: Public Beta** as of **Nov 26, 2025** (confirmed via GitHub Discussion #38022, maintainer quote: *"We support dynamic client registration & other MCP auth spec requirements so it'll be plug & play!"*). Docs: https://supabase.com/docs/guides/auth/oauth-server
- Feature set (Phase 1): authorization code + PKCE, refresh tokens, JWT access tokens with `client_id` claim, **Dynamic Client Registration**, JWKS endpoint, Dashboard UI for OAuth client management.
- **Discovery URLs** (confirmed verbatim from https://supabase.com/docs/guides/auth/oauth-server/getting-started):

  | Endpoint | Cloud | Local CLI |
  |---|---|---|
  | Authorization | `https://<ref>.supabase.co/auth/v1/oauth/authorize` | `http://localhost:54321/auth/v1/oauth/authorize` |
  | Token | `https://<ref>.supabase.co/auth/v1/oauth/token` | `http://localhost:54321/auth/v1/oauth/token` |
  | JWKS | `https://<ref>.supabase.co/auth/v1/.well-known/jwks.json` | `http://localhost:54321/auth/v1/.well-known/jwks.json` |
  | **AS metadata discovery** | `https://<ref>.supabase.co/.well-known/oauth-authorization-server/auth/v1` | `http://localhost:54321/.well-known/oauth-authorization-server/auth/v1` |
  | OIDC | `https://<ref>.supabase.co/auth/v1/.well-known/openid-configuration` | `http://localhost:54321/auth/v1/.well-known/openid-configuration` |

  Note the **path form**: `/.well-known/oauth-authorization-server/auth/v1` (suffix appended after the well-known segment, prefix inserted before `/auth/v1` — this is the RFC 8414 path-insertion convention, confirmed working). A community report (real-world verification against a running local Supabase instance, referenced via a fastmcp/Supabase integration project) found local gateway routing sometimes 404s on this and only the (non-compliant) `/auth/v1/.well-known/oauth-authorization-server` suffix form answers — **this is a local-Kong-routing quirk you should smoke-test locally before relying on it**; the docs-stated form above is what's officially correct and what Claude's client expects.
- **Dynamic Client Registration**: supported, but **disabled by default** — must set `allow_dynamic_registration = true` in `[auth.oauth_server]` (confirmed in Supabase's own worked MCP example, §1). This directly matters because Claude's connector flow defaults to DCR (`oauth_dcr`) unless CIMD is advertised (see §4).
- **Known bugs / limitations found (GitHub, current as of Sept 2026):**
  - **[supabase/auth#2408](https://github.com/supabase/auth/issues/2408)** (open): on hosted/cloud projects, the OAuth authorize redirect can point to `{SITE_URL}/oauth/consent` even when GoTrue doesn't serve that path itself (your own consent-page app must be at that route on `SITE_URL`) — the `GOTRUE_OAUTH_SERVER_AUTHORIZATION_PATH` env var exists to customize this but **is not exposed in the Dashboard**, so you must set it via CLI/`config.toml`'s `authorization_url_path` (confirmed available in config.toml, see (b) above) or via self-hosted env vars.
  - **Loopback redirect_uri exact-match issue** ([Discussion #41695](https://github.com/orgs/supabase/discussions/41695)): Supabase's OAuth server validates `redirect_uri` with strict exact-string matching, which breaks **native/CLI MCP clients** using RFC 8252 ephemeral loopback ports (this affects tools like Claude Code, not the claude.ai/Desktop/iOS web-style connector flow, which uses the fixed `https://claude.ai/api/mcp/auth_callback` redirect — so **not a blocker for the claude.ai custom-connector scenario** this plan targets, but worth knowing if you also want Claude Code to use the same server). CIMD (Client ID Metadata Documents) is the proposed long-term fix; a community member (OR13) posted a ~750-line Go implementation plan in a PR discussion (Apr 2026); no confirmed Supabase-team merge as of this research.
  - **Local OAuth redirect bug** (reported Mar 2026 by fzaninotto, marmelab/atomic-crm author): the local Supabase OAuth server hardcodes `http://127.0.0.1` in its redirect responses (wrong scheme *and* unreachable from an external tunnel), making it **impossible to test the full OAuth handshake against `supabase start` while exposing it via ngrok** — he had to test entirely in production. **Treat local end-to-end OAuth testing as unreliable; plan to do final auth-flow verification against a real (or branch) cloud project** (see §6).

### (d) User-scoped client for RLS
- Classic pattern (still valid, current supabase-js v2 syntax):
  ```ts
  import { createClient } from 'jsr:@supabase/supabase-js@2'
  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
  })
  // subsequent supabase.from(...) calls run as that user; RLS applies
  ```
- Supabase's own MCP guide instead recommends `withSupabase<Database>({ auth: 'user' })` from `@supabase/server` (§1/§3b), which does the equivalent (extracts bearer token, JWKS-validates it, constructs a client scoped to that user) and rejects the request if invalid — less boilerplate, one official code path to maintain.

Sources: https://supabase.com/docs/guides/ai-tools/byo-mcp , https://supabase.com/docs/guides/auth/oauth-server , https://supabase.com/docs/guides/auth/oauth-server/getting-started , https://supabase.com/docs/guides/auth/oauth-server/mcp-authentication , https://github.com/orgs/supabase/discussions/43050 , https://github.com/orgs/supabase/discussions/38022 , https://github.com/orgs/supabase/discussions/41695 , https://github.com/supabase/auth/issues/2408 , https://github.com/marmelab/atomic-crm/blob/main/supabase/functions/mcp/index.ts , https://github.com/supabase/server

---

## 4. Claude custom connectors — official docs (claude.com/docs/connectors/...), fetched verbatim Sept 2026

This is the single most important source for the whole plan: **https://claude.com/docs/connectors/building/authentication** (redirects from the older `support.anthropic.com`/`support.claude.com` help-center article, which no longer carries the technical detail — the real spec lives in `claude.com/docs`).

### Requirements
- Must be public HTTPS, reachable from **Anthropic's egress range `160.79.104.0/21`** (allowlist this for firewalls/WAFs).
- Transport: Streamable HTTP (current). No SSE-only mention in current docs — Streamable HTTP is what all current examples/quickstarts use; treat SSE-only transport as legacy/unsupported for new connectors.
- **Claude's OAuth client is stricter than the bare MCP spec** (direct quote, verified above in §2): requires `401` (ignores `WWW-Authenticate` on `200`), uses only first `authorization_servers` entry, gives OAuth endpoints **10s** (discovery/registration/token) / **30s** (refresh) before treating the flow as failed, requires PKCE **S256** on every request, requires token endpoint to accept `application/x-www-form-urlencoded` (not JSON) while `/register` uses `application/json`.

### OAuth / DCR
- **`oauth_dcr`** (RFC 7591) — supported by default; Claude self-registers. This is what you use with Supabase's OAuth server as configured in §3c (`allow_dynamic_registration = true`).
- **`oauth_cimd`** (Client ID Metadata Document) — supported by default too; Claude prefers CIMD only if your AS metadata advertises **both** `client_id_metadata_document_supported: true` **and** `"none"` in `token_endpoint_auth_methods_supported`; otherwise falls back to DCR automatically. (Supabase's OAuth server as of Sept 2026 does not appear to advertise CIMD support in its metadata per the docs read — so **expect Claude to use DCR** against a Supabase-hosted AS.)
- Redirect/callback URIs Claude registers/uses:
  - Hosted apps (claude.ai web, Desktop, mobile, Cowork): **`https://claude.ai/api/mcp/auth_callback`** (also seen as `https://claude.com/api/mcp/auth_callback` in some community sources amid the claude.ai→claude.com rebrand — register both to be safe).
  - Claude Code (not relevant to this plan but noted): loopback `http://localhost:<port>/callback` / `http://127.0.0.1:<port>/callback`, port-agnostic matching required.
- Scope control: put a `scope` param in the `WWW-Authenticate` header of your 401, else Claude requests whatever `scopes_supported` your protected-resource metadata advertises; Claude auto-appends `offline_access` if your AS metadata lists it (for refresh tokens).

### Tool annotations
- Claude's UI **does** read/use `readOnlyHint`, `destructiveHint`, `idempotentHint`, `openWorldHint` — directory submission requires every tool to have an explicit title plus the applicable `readOnlyHint`/`destructiveHint`. Set them explicitly; don't rely on defaults.

### Limits (as documented / commonly cited alongside the official docs)
- Tool call timeout: **300s (5 min)** for claude.ai/Desktop; Claude Code has a separate configurable timeout.
- Tool result size: ~150,000 characters commonly cited limit for claude.ai/Desktop (Claude Code: ~25,000 tokens, configurable).
- No documented hard cap on number of tools found, but keep tool count reasonable for context/latency.

### Testing your connector (official guidance, directly relevant to §6)
- **No staging environment — you test in production** against the real claude.ai client. Add your server as a custom connector via `claude.ai/customize/connectors` → **+ Add custom connector** by URL.
- For a locally-running server: expose via Cloudflare Tunnel or **ngrok**, then add the tunnel URL. If using the TS SDK's `createMcpExpressApp()` (Node-side helper, analogous constraint likely applies conceptually if you front Deno with any Host-based DNS-rebinding guard), you must allowlist the tunnel hostname or get a `403 Invalid Host`.
- **Validate first with MCP Inspector** before ever touching Claude:
  ```bash
  npx @modelcontextprotocol/inspector --cli https://<your-tunnel>/functions/v1/mcp --transport http --method tools/list
  ```
- Claude identifies itself in `initialize`'s `clientInfo` as `"claude-ai"`, `"Anthropic"` (sometimes with suffix), or `"claude-code"` — unauthenticated, never gate auth decisions on it, telemetry/coarse feature-detection only.
- Common failure: `initialize` timeout → check OAuth endpoint latency, `Origin` header validation, and WAF/firewall blocking Anthropic's egress range.

Sources: https://claude.com/docs/connectors/building/authentication , https://claude.com/docs/connectors/building/testing , https://claude.com/docs/connectors/building/lazy-authentication (referenced), https://platform.claude.com/docs/en/api/ip-addresses

---

## 5. The OAuth consent page

### Supabase-js API (confirmed, exact)
- Namespace: **`supabase.auth.oauth.*`** (NOT `auth.admin.oauth.*` — that's the separate server-side client-management API used to pre-register OAuth clients, see §3c). Added in **PR supabase-js#1793**, merged **Oct 29, 2025**. First shipped in **`@supabase/supabase-js@2.77.0`** (published same day, Oct 29 2025). Current latest as of Sept 2026: **2.117.2** — pin to `^2.77.0` minimum, but just use latest.
- Methods (all take `authorizationId: string`, optional `{ skipBrowserRedirect?: boolean }` options):
  ```ts
  const { data, error } = await supabase.auth.oauth.getAuthorizationDetails(authorizationId)
  // data: { client, redirect_uri, scope /* space-separated string */, ... }

  const { data, error } = await supabase.auth.oauth.approveAuthorization(authorizationId)
  window.location.href = data.redirect_url

  const { data, error } = await supabase.auth.oauth.denyAuthorization(authorizationId)
  window.location.href = data.redirect_url
  ```
- Workflow: user navigates to your consent page with `authorization_id` (or similar) in query params (redirected there by Supabase's OAuth server per `authorization_url_path` config, §3b/§3c) → your page verifies the user is signed in (normal Supabase Auth session) → calls `getAuthorizationDetails` → renders client name + `scope.split(' ')` → on Approve/Deny, calls the matching method and redirects the browser to `data.redirect_url` (which itself redirects back to Claude's callback with the auth code).
- This uses the **regular anon key + a signed-in user session** — no service-role key needed for the consent page itself (distinguish from `auth.admin.oauth.createClient()` which is a service-role/admin operation for *registering* OAuth clients, not for the consent screen).

### The HTML-serving restriction — confirmed real and current
- Official Supabase docs (https://supabase.com/docs/guides/functions/limits), quoted verbatim:
  > *"Serving of HTML content is only supported with custom domains (Otherwise GET requests that return text/html will be rewritten to text/plain)."*
- This applies both to the default `*.supabase.co` domain **and to local dev via `supabase functions serve`** (confirmed — not just a cloud-only quirk).
- **Cloud workaround:** use a **custom domain** (Supabase Pro plan feature) — HTML serving is explicitly supported once you're on a custom domain. This is the cleanest fix if you're already using a custom domain for the MCP endpoint anyway (recall §3a: custom domains work for Edge Functions, just not for root-level `.well-known`).
- **Alternative cloud workaround** (if not using a custom domain / not on Pro): host the consent HTML on a separate static host (Vercel/Netlify/Cloudflare Pages) that calls the Supabase JS methods above client-side against your project's public URL + anon key (CORS-permitting) — fully decoupled from Edge Functions' HTML restriction.
- **Local dev workaround:** since the rewrite applies locally too, serve the consent page from a tiny separate static dev server (e.g. `vite` / `python -m http.server` / a trivial `Deno.serve` on a different port serving a plain HTML string is *also* subject to the same restriction if it's an Edge Function — so use a genuinely separate process, not another `supabase functions serve` function) that talks to the local Supabase instance (`http://localhost:54321`) via `createClient`. Given the local-OAuth-redirect bug found in §3c (hardcoded `http://127.0.0.1` in redirects, breaking ngrok-tunneled local testing), realistically **plan to do full end-to-end consent + Claude-connector testing against a real (or Supabase branch) cloud project**, using the local static-server workaround only for iterating on the consent page's own UI/logic in isolation.

Sources: https://supabase.com/docs/guides/functions/limits , https://github.com/orgs/supabase/discussions/31238 , https://supabase.com/docs/guides/auth/oauth-server/getting-started , https://supabase.com/docs/guides/platform/custom-domains , npm registry data for `@supabase/supabase-js` (fetched directly)

---

## 6. Testing

### Unit-testing a tool handler (Deno, no HTTP)
```ts
// supabase/functions/mcp/tools/list_todos.test.ts
import { assertEquals } from "jsr:@std/assert";
import { listTodosHandler } from "./list_todos.ts";

Deno.test("list_todos returns todos for the scoped user", async () => {
  const fakeSupabase = {
    from: () => ({
      select: () => ({ order: () => ({ limit: async () => ({ data: [{ id: 1, title: "x", done: false }], error: null }) }) }),
    }),
  };
  const result = await listTodosHandler({ limit: 10 }, fakeSupabase as any);
  assertEquals(JSON.parse(result.content[0].text).length, 1);
});
```
Run: `deno test --allow-net supabase/functions/mcp/`. `jsr:@std/assert` is the current (Sept 2026) canonical import for Deno's std assertions (JSR-hosted, replaces the old `https://deno.land/std/testing/asserts.ts` URL import style).

### HTTP-level integration test against `supabase functions serve`
1. **Get a bearer token via local password grant:**
   ```ts
   import { createClient } from "jsr:@supabase/supabase-js@2";
   const supabase = createClient("http://127.0.0.1:54321", LOCAL_ANON_KEY);
   const { data, error } = await supabase.auth.signInWithPassword({
     email: "test@example.com",
     password: "test-password-123",
   });
   const token = data.session?.access_token;
   ```
   Seed the test user beforehand with `supabase.auth.admin.createUser({ email, password, email_confirm: true })` (service-role client) in a setup script, or in `supabase/seed.sql` — community reports (Discussion #9251, #35391) show raw SQL-inserted `auth.users` rows commonly fail `signInWithPassword` due to password-hash mismatches, so **prefer `auth.admin.createUser()`** over hand-crafted SQL seeding.
2. **MCP JSON-RPC handshake over Streamable HTTP** (exact request shapes, confirmed against Supabase's own worked example):
   ```bash
   # initialize
   curl -si -X POST 'http://127.0.0.1:54321/functions/v1/mcp' \
     -H "Authorization: Bearer $TOKEN" \
     -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}'

   # tools/list
   curl -si -X POST 'http://127.0.0.1:54321/functions/v1/mcp' \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'

   # tools/call
   curl -si -X POST 'http://127.0.0.1:54321/functions/v1/mcp' \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -H 'Accept: application/json, text/event-stream' \
     -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list_todos","arguments":{"limit":5}}}'
   ```
   For a **stateless** server (recommended for edge functions — no cross-request session affinity needed), there's no `Mcp-Session-Id` to manage between calls; each request is independent and re-validates the bearer token.
3. **Unauthenticated discovery check** (no `Authorization` header) should return `401` + `www-authenticate` header, and:
   ```bash
   curl -s 'http://127.0.0.1:54321/functions/v1/mcp/oauth-protected-resource'
   # → {"resource":"http://127.0.0.1:54321/functions/v1/mcp","authorization_servers":["http://127.0.0.1:54321/auth/v1"],"bearer_methods_supported":["header"]}
   ```
4. **Protocol-compliance smoke test via MCP Inspector** (official Anthropic-recommended step before ever pointing Claude at it):
   ```bash
   npx @modelcontextprotocol/inspector --cli http://127.0.0.1:54321/functions/v1/mcp --transport http --method tools/list
   ```
5. **Full OAuth-handshake + Claude-connector test**: per the local-redirect bug in §3c/§5, this reliably needs a real (or Supabase preview-branch) cloud project + a public URL — plan for a "deploy to a branch/staging project, add as custom connector, run through consent" step in CI/manual QA rather than expecting it to work end-to-end against pure `supabase start` + tunnel.

Sources: https://docs.deno.com/runtime/test/ , https://jsr.io/@std/assert , https://supabase.com/docs/guides/local-development/seeding-your-database , https://github.com/orgs/supabase/discussions/9251 , https://github.com/orgs/supabase/discussions/35391 , https://supabase.com/docs/guides/ai-tools/byo-mcp , https://claude.com/docs/connectors/building/testing

---

## Summary of blockers / open uncertainties to smoke-test early

1. **`.well-known` off-origin pointer reliability**: a community report from Mar 2026 says pointing `WWW-Authenticate`'s `resource_metadata` at a non-`.well-known` path under the function "didn't work" against Claude/ChatGPT at the time. Claude's current (Sept 2026) docs explicitly bless this pattern, so it's very likely fixed — but **not independently re-verified here**. Test this first, before building anything else.
2. **Local end-to-end OAuth testing is unreliable** — Supabase's local OAuth server hardcodes `http://127.0.0.1` (wrong scheme, unreachable via tunnel) in redirects as of a Mar 2026 report. Budget for testing the full consent+connector flow against a deployed (branch) project, not pure local dev.
3. **`pipeline([...])` composition from `@supabase/middleware` is explicitly labeled alpha** by Supabase's own docs — the nested-function-call form is the stable fallback; pin versions carefully (`@supabase/middleware@^0.5.0`, `@supabase/server@^1.6.0` minimum, but check for newer `@supabase/server` — 1.8.0 is current on npm).
4. **`allow_dynamic_registration` defaults to `false`** in `config.toml` — must explicitly enable for Claude's DCR flow to work at all.
5. **`supabase/auth#2408`** (open bug): hosted-project OAuth redirects to `/oauth/consent` on `SITE_URL` even though `authorization_url_path` is configurable — make sure your consent page is actually deployed at whatever `SITE_URL + authorization_url_path` resolves to, and double check the Dashboard doesn't silently override your `config.toml` setting on push.
6. **Local Kong/gateway routing may 404 on `/.well-known/oauth-authorization-server/auth/v1`** in some local setups (unclear if project-specific misconfiguration or a general local-CLI gap) — verify locally before assuming the documented path works out of the box.
7. Zod version must be **v4** (Standard Schema) for `registerTool`'s `inputSchema` in SDK v2 — a leftover Zod v3 dependency in the project will break tool schema validation silently or with an unclear error.
