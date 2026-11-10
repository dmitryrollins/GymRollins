import { DomainLimits } from '../shared/domain-limits.ts'

// The words for the storage caps (plan 31). The app shows a refusal's message in Account › "items couldn't sync",
// beside the row it keeps on the phone, so each says what happened and that nothing was lost. The numbers come from
// DomainLimits, as the triggers' do (test/domain-limits-drift.test.ts).

/** 10000 → "10,000", as the app writes numbers. */
export const grouped = (n: number): string => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ',')

const full = (max: number, things: string, deleted = 'deleted ones', kept = 'This one') =>
  `You've reached the limit of ${grouped(max)} ${things} on one account, ${deleted} included. ` +
  `${kept} stays on this iPhone.`

/**
 * What migrations/0010_account_caps.sql RAISEs, with the app's words (src/http/errors.ts answers 422 with them). The
 * two proposal codes are raised only under Claude's insert, which words them for Claude (CLAUDE_CAPS).
 */
export const ACCOUNT_CAPS: Readonly<Record<string, string>> = {
  too_many_workouts: full(DomainLimits.workoutsMax, 'workouts'),
  too_many_body_weights: full(DomainLimits.bodyweightsMax, 'weigh-ins'),
  too_many_routines: full(DomainLimits.routinesMax, 'routines'),
  too_many_custom_exercises: full(DomainLimits.customExercisesMax, 'custom exercises'),
  too_many_exercise_prefs: `You've reached the limit of ${grouped(DomainLimits.exercisePrefsMax)} exercise ` +
    'preferences on one account. This one stays on this iPhone.',
  too_many_gyms_total: full(DomainLimits.privateGymsTotalMax, 'gyms'),
  too_many_listings_total: full(DomainLimits.privateListingsTotalMax, 'equipment listings'),
  too_many_logged_exercises:
    full(DomainLimits.accountEntriesMax, 'exercises logged', 'deleted workouts', 'This workout'),
  too_many_logged_sets: full(DomainLimits.accountSetsMax, 'sets logged', 'deleted workouts', 'This workout'),
  too_many_pending_proposals: `${grouped(DomainLimits.pendingProposalsMax)} proposals are waiting for review.`,
  too_many_proposals: `The account holds ${grouped(DomainLimits.proposalsMax)} proposals.`,
}

/** What a workout save refuses before it writes (src/sync/workouts.ts): one workout's size, as the app shows it. */
export const WORKOUT_CAPS = {
  too_many_workout_exercises:
    `A workout can have up to ${DomainLimits.workoutEntriesMax} exercises. This one stays on this iPhone.`,
  too_many_exercise_sets:
    `An exercise in a workout can have up to ${DomainLimits.entrySetsMax} sets. This workout stays on this iPhone.`,
} as const

/** Claude's words when a cap refuses its write (src/mcp/d1-db.ts): a ToolError, which Claude reads. */
export const CLAUDE_CAPS = {
  too_many_pending_proposals:
    `The owner already has ${grouped(DomainLimits.pendingProposalsMax)} proposals waiting for review, the most one ` +
    'account holds. Nothing was saved: ask the owner to apply or dismiss some in the app, then propose again.',
  too_many_proposals:
    `The owner's account already holds ${grouped(DomainLimits.proposalsMax)} proposals, resolved ones included, the ` +
    'most it can. Nothing was saved.',
  too_many_body_weights:
    `The owner's account already holds ${grouped(DomainLimits.bodyweightsMax)} weigh-ins, deleted ones included, ` +
    'the most it can. Nothing was saved.',
} as const

/**
 * An agent's words when a cap refuses a workout it adds with log_workout (src/mcp/d1-db.ts, plan 32): the workout's
 * refusal names the code and says this. Nothing of that workout was saved; the others in the call are checked on their
 * own.
 */
export const AGENT_WORKOUT_CAPS = {
  too_many_workouts:
    `The owner's account already holds ${grouped(DomainLimits.workoutsMax)} workouts, deleted ones included, the ` +
    'most it can. This workout was not added.',
  too_many_logged_exercises:
    `The owner's account already holds ${grouped(DomainLimits.accountEntriesMax)} logged exercises, deleted ` +
    'workouts included, the most it can. This workout was not added.',
  too_many_logged_sets:
    `The owner's account already holds ${grouped(DomainLimits.accountSetsMax)} logged sets, deleted workouts ` +
    'included, the most it can. This workout was not added.',
  too_many_workout_exercises:
    `A workout can have up to ${DomainLimits.workoutEntriesMax} exercises. This workout was not added: split it ` +
    'into several.',
  too_many_exercise_sets:
    `An exercise in a workout can have up to ${DomainLimits.entrySetsMax} sets. This workout was not added: split ` +
    'it into several.',
} as const
