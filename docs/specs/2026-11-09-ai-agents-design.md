# AI agents: per-agent list and disconnect, proposals by agent, agent-logged workouts

Approved by the owner on 2026-11-09. Builds on the Cloudflare backend (`docs/specs/2026-11-07-cloudflare-backend-design.md`)
and the MCP connector, which since commit 2e44be9 takes any agent's https callback, not only Claude's.

## 1. Why

Meta's agent (Muse) connected on 2026-11-09 beside Claude. The app still treats the connector as Claude's: one
"Disconnect Claude" that cuts every agent, one "last used" for all of them, proposals with no sender, and a screen
named "Claude". Muse also found 9 Fitbod sessions (6 Oct – 7 Nov, 191 sets) missing from GymRollins and has no way to
add them: the only MCP writes are `propose_plan_changes` and `log_bodyweight`.

## 2. Decisions

| # | Decision | Why |
|---|---|---|
| 1 | The app screen becomes **"AI agents"**, worded for any agent. The "Use with Claude" prompt and Claude-specific instructions stay. | Owner's choice: Muse shouldn't live on a screen named Claude. |
| 2 | **One set of permission switches** for all agents. | Owner's choice (YAGNI). Disconnect cuts one agent off. |
| 3 | New proposals record **which agent sent them**; the app shows "From Muse". Older proposals show no name. | Owner's choice: several agents can propose. |
| 4 | A new MCP tool **`log_workout`** writes past workouts **straight into history**, behind a new **"Add workouts"** switch that is **off** by default. Each workout is marked with the agent that added it. | Owner's choice over approve-first: like `log_bodyweight`. The switch and the overlap check are the guard. |
| 5 | Agent-added workouts keep `source = 'import'` and gain an **`added_by`** name. | `workouts.source` is CHECKed to `app`/`import`; changing it means rebuilding the table. An agent's workout is imported history. |
| 6 | Disconnecting an agent keeps its OAuth client registration; only this account's grants for it go. | A registration may serve other accounts later; a new connection needs a new approval anyway. |

## 3. Server

### 3.1 Connected agents

`GET /v1/agents` (the app's session, like `/v1/claude/*`) answers `{ "agents": [...] }`, one entry per OAuth client that
holds a consent or a live refresh token for the account, newest connection first:

```json
{ "client_id": "…", "name": "Muse", "host": "agent.meta.ai", "known_host": false,
  "connected_at": "2026-11-09T01:20:00.000000Z", "last_used_at": "2026-11-09T01:31:12.000000Z" }
```

- `name` is the registered `client_name` (already checked: at most 64 characters of visible text), or the host when
  it registered none.
- `host` is the host of its first redirect URL; `known_host` is true for claude.ai and claude.com (the same set the
  approve sheet uses).
- `connected_at` is the consent's creation time; `last_used_at` the newest `mcp_audit.at` for that client and account,
  or null.

### 3.2 Disconnect one agent

`POST /v1/agents/:clientId/disconnect` answers `{ "disconnected": true }`, or 404 `unknown_agent` when the account has
no grant for that client. In one batch, for this account and this client only:

- its access tokens, refresh tokens and consent;
- its unredeemed authorization codes (the `verification` rows whose stored JSON names this user and this client);
- its `connect_requests` rows, and the `/connect` browser sessions those rows created (`session_id`).

Every other agent keeps working. `POST /v1/claude/revoke` stays as **Disconnect all**.

### 3.3 Proposals by agent

`proposals` gains `from_agent TEXT` (nullable): `propose_plan_changes` stores the calling client's name at the time.
`GET /v1/claude/proposals` and the proposal sync include it.

### 3.4 `log_workout`

Input: `{ "workouts": [ … up to 20 … ] }`, each:

```json
{ "started_at": "2026-10-08T17:02:00Z", "ended_at": "2026-10-08T18:05:00Z", "name": "Upper", "note": "…",
  "exercises": [ { "exercise_id": "0025", "sets": [ { "reps": 8, "weight_kg": 63.5 }, … ] }, … ] }
```

- A set has `reps`, `weight_kg`, and optionally `duration_s`, `distance_m` and `warmup`, the same fields the app
  syncs.
- `exercise_id` is a library id (`search_exercises`) or one of the owner's custom exercises.

Each workout is checked on its own; the result lists every workout as `added` (with its new id) or `refused` with a
reason, so one bad workout doesn't block the rest:

| Refusal | When |
|---|---|
| `not_allowed` | The "Add workouts" switch is off (every workout is refused, before anything is read). |
| `overlaps` | Its `[started_at, ended_at)` overlaps a workout of the account that isn't deleted, including one added earlier in the same call. |
| `unknown_exercise` | An `exercise_id` is neither a library id nor the owner's custom exercise (the ids are named). |
| `invalid` | `ended_at` isn't after `started_at`, a date is in the future, or a value is out of range. |
| a cap code | The existing per-workout caps (50 exercises, 50 sets each) or the account caps (plan 31). |

An added workout gets `source = 'import'`, `added_by` = the client's name, and the server's own timestamps, so the
phone pulls it on its next sync like any other. The call is audited like every MCP call. Weights are kg; the agent
converts. A second identical call adds nothing new: every workout overlaps its first copy.

### 3.5 Database (one migration)

- `profiles.mcp_log_workouts INTEGER NOT NULL DEFAULT 0 CHECK (mcp_log_workouts IN (0,1))`, synced with the profile.
- `workouts.added_by TEXT` (nullable, at most 64 characters), synced with the workout.
- `proposals.from_agent TEXT` (nullable, at most 64 characters).

### 3.6 Wording

Tool descriptions and the 401 say "agents" or "the owner", not "Claude". The server's MCP instructions keep their
Claude-specific advice.

## 4. App

**Settings › AI agents** (was "Claude"), top to bottom:

1. **Connected agents**: one row per agent with its name, host and "Last used …" (or "Not used yet"), and
   **Disconnect**, which asks "Disconnect Muse? It loses access until you approve it again." Empty state: "No agents
   connected."
2. **Connect**: the server address and Approve a connection, as now.
3. **Plan changes from your agents**: as now, each labelled "From Muse" when the server knows the sender.
4. **What agents can do**: the current switches plus **Add workouts** ("Let agents add past workouts to your
   history"), off by default.
5. **Use with Claude**: unchanged.
6. **Disconnect all**, with a confirmation.

A workout an agent added shows **"Added by Muse"** on its screen; it can be edited and deleted like any other. The
approve screen keeps the host and the opener's place. Its warning becomes neutral for any host: "Approve only if you
started this connection yourself, in agent.meta.ai." Claude's own hosts show no warning, as now.

## 5. Testing

- **Server (vitest):** the list (consented and token-only clients, last use per client, other accounts not shown); single
  disconnect (that agent refused afterwards, another agent still served, its codes and connect sessions gone, 404 for
  an unknown client); `from_agent` stored and served; `log_workout` (switch off, overlap with an existing and with a
  sibling in the same call, unknown exercise, invalid times, caps, partial success, the pulled row carries `added_by`);
  the migration's defaults.
- **App:** unit tests for the agents model (list, disconnect, empty state, errors) and the labels; UI tests for the
  screen's sections, Disconnect's confirmation, and the Add workouts switch; the accessibility audits pass.
- **End to end, local:** an agent registered against the local Worker logs a workout, and it reaches the simulator's
  history marked "Added by …".

## 6. Rollout

1. Migration and server deploy (owner's approval): the Worker before the app, as the checklist's order rule says.
2. Back up the phone, build and install (owner's approval).
3. The owner turns on Add workouts; Muse loads its 9 sessions; the counts are checked (157 workouts if all 9 land).

## 7. Out of scope

Per-agent switches; approve-before-adding for agent workouts; agents editing or deleting past workouts; renaming the
`/v1/claude/*` routes; the 5 unused test registrations (the checklist's cleanup step).
