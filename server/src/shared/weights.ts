// Pound numbers next to kilograms (plan 38). Kg is the number used for maths; a pound number is the weight as the
// owner entered or chose it, so 45 lb shows as 45 lb and not as 44.8. Mirrors GymCore's PoundWeight (Swift).

/** Kilograms in a pound, exact by definition. */
export const KG_PER_LB = 0.45359237
/** The most a kg and a pound number for one weight may differ by (in kg) and still be the same weight. */
export const WEIGHT_AGREE_KG = 0.01
/** The pound range of a set (workout_sets.w_lb's CHECK): 1,000 kg, rounded up. */
export const SET_WEIGHT_LB = { min: 0, max: 2_205 } as const
/** The pound range log_workout takes: 1,000 kg rounded down, so the kg it converts to stays within w_kg's CHECK. */
export const LOGGED_SET_WEIGHT_LB = { min: 0, max: 2_204 } as const

/** True when `kg` and `lb` describe the same weight, within WEIGHT_AGREE_KG. */
export const weightsAgree = (kg: number, lb: number): boolean => Math.abs(kg - lb * KG_PER_LB) <= WEIGHT_AGREE_KG

/** The kg for a pound number: exact, not rounded. */
export const kgFromLb = (lb: number): number => lb * KG_PER_LB

/** The stored pound number for a weight, or null when it is missing or disagrees with `kg`. */
export function agreeingLb(kg: number, lb: number | null | undefined): number | null {
  return typeof lb === 'number' && Number.isFinite(lb) && weightsAgree(kg, lb) ? lb : null
}

/** The refusal text when both are given and disagree, or null. */
export function weightDisagreement(
  kg: number | undefined,
  lb: number | undefined,
  kgField: string,
  lbField: string,
): string | null {
  if (kg === undefined || lb === undefined || weightsAgree(kg, lb)) return null
  const asKg = Math.round(kgFromLb(lb) * 100) / 100
  return `${kgField} and ${lbField} are different weights (${lb} lb is ${asKg} kg, not ${kg} kg). ` +
    `Send ${lbField} alone when the owner's unit is lb.`
}
