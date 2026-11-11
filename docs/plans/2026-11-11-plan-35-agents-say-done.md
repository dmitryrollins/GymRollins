# Plan 35: agents say the change is done

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** With "Apply changes without asking" on, an agent that changes the plan tells the owner the change is made and shows when they open the app. It doesn't say it "sent a proposal" or that the change is still pending.

**Why (owner, 2026-11-11):** An agent moved Push + Arms to today and replied "I sent a proposal… status is pending, no changes applied yet. I cannot apply it myself." Plan 33 already tells agents to say the change is made (`APPLIES_AUTOMATICALLY`). But the tool is named `propose_plan_changes`, its result says `status: "pending"`, and `get_proposal` says pending too until the phone opens the app. An honest agent goes by the status. The owner chose option 1 of three: change the words the server gives agents. No silent push, and the server still doesn't apply changes itself.

**Architecture:** Server-only behaviour. The `proposals` table, its statuses, the app's sync and its auto-apply are unchanged. Only what the MCP tools show agents changes:
- The tools are renamed: `propose_plan_changes` → `change_plan`, and `get_proposal` → `get_plan_change`.
- A pending row is reported to agents as `applies_when_app_opens` when auto-apply is on, or `waiting_for_review` when it's off.
- The result's id field is `id` (was `proposal_id`).
- The wording of the instructions and the descriptions changes to match.

The app changes one string: Today's "Ask Claude" prompt names the new tool. Old `mcp_audit` rows keep the old tool name, and nothing reads tool names from them.

**Tech stack:** Cloudflare Worker (Hono + MCP SDK), vitest with `@cloudflare/vitest-pool-workers`, SwiftUI app string.

**Branch:** `feat-agent-says-done`, from main 7ef0b20. Plan 34 (`feat-week-plan`) doesn't touch the server. Both branches touch `TodayView.swift`, but in different lines.

---

## Files

- Modify: `server/src/mcp/tools/write.ts`: `APPLIES_AUTOMATICALLY` wording, `agentStatus()`, `id` in the result, `get_plan_change` status.
- Modify: `server/src/mcp/tools/register.ts`: tool names, titles, descriptions, and the `PREFS` text.
- Modify: `server/src/mcp/instructions.ts`: the tool name and the auto-apply line.
- Modify: `server/README.md:100`.
- Tests:
  - `server/test/mcp/tools/write.test.ts`
  - `server/test/mcp/instructions.test.ts`
  - `server/test/mcp/agent-wording.test.ts`
  - `server/test/mcp/app.test.ts`
  - `server/test/mcp/tools/preferences.test.ts`
  - `server/test/claude-caps.test.ts`
  - `server/test/claude-connection.test.ts`
  - `server/test/proposals-from-agent.test.ts`
- App:
  - `ios/GymRollins/Features/Today/TodayView.swift:55` (`askClaudePrompt`).
  - `ios/GymRollinsUITests/ProposalSyncUITests.swift`, and `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/{ProposalTransportTests,AgentsTransportTests}.swift`: the tool names and `proposal_id` → `id`. These need a local server, so they're skipped in `scripts/ios-test.sh`.

## Task 1: What a change's result says (write.ts)

- [ ] **Step 1: Failing tests** in `server/test/mcp/tools/write.test.ts`:
  - **Auto-apply off:** the valid-fixture test expects `out.id === 'prop-1'`, `out.status === 'waiting_for_review'` and `out.proposal_id === undefined`.
  - **Auto-apply on:** the test expects `out.status === 'applies_when_app_opens'`, and `out.applies` contains "Tell the owner it's done" and "Don't call it a proposal".
  - **`get_plan_change` on a pending row:** `status` is `applies_when_app_opens` with auto-apply on and `waiting_for_review` with it off. An applied row still says `applied` and has no `applies`.
  - Rename the tests' titles to the new tool names.
- [ ] **Step 2: Run them and see them fail:** `cd server && npx vitest run test/mcp/tools/write.test.ts`.
- [ ] **Step 3: Implement** in `write.ts`:

```ts
export const APPLIES_AUTOMATICALLY =
  'Done: the owner turned on "Apply changes without asking", so nobody reviews or approves this. The GymRollins ' +
  'app puts it into the plan by itself the next time it opens or syncs; until then this status is expected, not a ' +
  "problem. Tell the owner it's done and shows when they open the app; they can undo it there for 7 days. Don't " +
  'call it a proposal or say it is pending or waiting. get_plan_change shows what the app applied.'

/** What agents see for a stored status: a pending row is either on its way in by itself or waiting for the owner. */
export function agentStatus(status: string, autoApply: boolean): string {
  if (status !== 'pending') return status
  return autoApply ? 'applies_when_app_opens' : 'waiting_for_review'
}
```

`proposePlanChanges` returns `{ id: row.id, status: agentStatus('pending', autoApply), auto_apply, changes, applies, …warnings }`. `getProposal` reads `autoApply` once and returns `status: agentStatus(p.status, autoApply)`. It adds `applies` only while the row is pending.

- [ ] **Step 4: Run them and see them pass.**

## Task 1b: A waiting change that can't happen any more (added after review)

The review found that "Done" could be false. If none of a change fits the plan when the app opens, the app records the skip and keeps the row `pending` (`ProposalService.autoApplyPending`). The server is never told, so `get_plan_change` would say `applies_when_app_opens` forever. The common case is a `today` change whose day passed before the phone opened.

- [x] For a pending row (with plan reads on), `get_plan_change` runs `validateProposal` against the current plan. That's the check `change_plan` runs, with the same ±1 day slack for `today`.
  - `wont_apply` lists the changes that no longer fit, with the reason.
  - If none fit, the status is `wont_apply`, `note` is `WONT_APPLY_NOTE` and there's no `applies`.
  - If only some fail, the status stays and `note` is `SOME_WONT_APPLY_NOTE`.
- [x] `APPLIES_AUTOMATICALLY` says the app skips a part that no longer fits. The other agent-facing texts lose "proposal" and "propose": `DISMISSED_NOTE`, the not-saved error, the swap warning and the pending cap.
- Not covered: the server allows ±1 day for the owner's time zone, while the app checks their exact date. So for up to a day, `get_plan_change` can still say a passed day's change will apply.

## Task 2: Tool names, descriptions, instructions

- [ ] **Step 1: Failing tests:**
  - `instructions.test.ts`: `TOOL_NAME` matches `change_` too, and the count stays 8. The auto-apply test expects "say it's done" and "don't call it a proposal".
  - `agent-wording.test.ts`: `byName.change_plan` contains `permissions.auto_apply`, and `byName.get_plan_change` contains `applies_when_app_opens`.
  - `app.test.ts`: `writes` names `change_plan`. The `tools/call` test calls `change_plan` and reads `.id`. Also assert that no tool name contains "propose".
  - `preferences.test.ts`, `claude-caps.test.ts`, `claude-connection.test.ts` and `proposals-from-agent.test.ts`: call `change_plan`. The audit query looks for `tool = 'change_plan'`.
- [ ] **Step 2: Run them and see them fail:** `npx vitest run test/mcp test/claude-caps.test.ts test/claude-connection.test.ts test/proposals-from-agent.test.ts`.
- [ ] **Step 3: Implement:**
  - In `register.ts`, rename the tools, with titles "Change the plan" and "Check a plan change".
  - Reword the `change_plan` description: "Change the owner's plan. With … on, the change is made: the app puts it in the plan the next time it opens …; with it off, the owner reviews it in the app …". Swap "proposal" for "change" or "request" in the validation text.
  - `get_plan_change` description: "What happened to a change made with change_plan: applies_when_app_opens (auto-apply on: it's made, and the app puts it in the plan when it next opens), waiting_for_review (auto-apply off), applied, partial or dismissed, and which change ids were applied."
  - Change `PREFS` and the other two description mentions to `change_plan`.
  - In `instructions.ts`, line 1 names `change_plan`. The auto-apply line becomes: "- Change the plan only with change_plan; its result's `applies` says what to tell the owner. If get_profile says auto_apply is on, the change is made: the app puts it in the plan by itself the next time it opens, and the owner can undo it for 7 days. Say it's done and shows when they open the app; don't call it a proposal or ask for a review. If it's off, tell the owner to review it in the app. Keep changes small and give each a reason."
  - Update `README.md:100`.
- [ ] **Step 4: Run the whole server suite and the type check:** `npx vitest run && npx tsc --noEmit`.

## Task 3: The app's prompt and the iOS tests that call the tools

- [ ] Set `askClaudePrompt` to "Build me a training plan using get_profile and change_plan."
- [ ] In `ProposalSyncUITests`, `ProposalTransportTests` and `AgentsTransportTests`, call `change_plan` and `get_plan_change` and read `id`.
- [ ] Build and run the unit tests that touch the prompt: `scripts/ios-test.sh -only-testing:GymRollinsTests`. Then `swift build --build-tests` in `ios/Packages/GymSync`, so the integration tests still compile.

## Task 4: Review, deploy, outcome

- [ ] Review the branch diff with a reviewer agent.
- [ ] Privacy scan: run gitleaks, and check the diff and commit messages for the surname and the account id.
- [ ] Deploy (owner approved option 1, server deploy included, on 2026-11-11): `cd server && npx wrangler deploy --message "plan 35: agents say the change is done"`. Then check that `https://api.gymrollins.com/mcp` answers 401 without a token and that the well-known endpoint answers 200.
- [ ] Append `## Outcome` (commits, test counts, version id, what's unverified) and commit `docs: plan 35 outcome`.

**Not verified by tests:** whether a real agent now says "done". The owner checks by asking an agent for a one-day change.
