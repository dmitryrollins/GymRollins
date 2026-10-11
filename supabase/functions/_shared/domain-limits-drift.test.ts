// Drift guard (item 16): fails the suite if the numeric domain limits kept in Swift (the source of truth,
// ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift + Plan/PlanChange.swift's `PlanChangeLimits`) and
// their hand-maintained TypeScript ports (./domain-limits.ts, ./plan-validation.ts's `PlanChangeLimits`) fall
// out of sync. Neither port is generated from the other, so nothing else catches a value changed on one side
// only — see the doc comments on both TS files ("Keep in sync with the Swift source by hand").
//
// This reads the Swift files as text (Deno.readTextFile, paths resolved relative to this file via
// import.meta.url — no Swift toolchain involved) and regex-parses `public static let name = value` /
// `public static let name: ClosedRange<T> = lo...hi` declarations out of them, then compares the result
// against the imported TS objects, name by name. A name on only one side, or a value that differs, fails the
// test with every mismatch listed — unless the name is in ALLOWLIST below with a documented reason.
import { assert } from 'jsr:@std/assert@^1'
import { DomainLimits } from './domain-limits.ts'
import { PlanChangeLimits } from './plan-validation.ts'

type LimitValue = number | { min: number; max: number }
type LimitMap = Record<string, LimitValue>

/** name -> why it's fine for this name to be missing on one side or to differ. Keep this list short: it's an
 *  escape hatch for genuinely intentional divergence, not a way to silence a real drift. */
const ALLOWLIST: Record<string, string> = {}

const domainLimitsSwiftUrl = new URL(
  '../../../ios/Packages/GymCore/Sources/GymCore/DomainLimits.swift',
  import.meta.url,
)
const planChangeSwiftUrl = new URL(
  '../../../ios/Packages/GymCore/Sources/GymCore/Plan/PlanChange.swift',
  import.meta.url,
)

// ---- Swift constant parsing -------------------------------------------------------------------------------

/** Evaluates a small arithmetic expression such as "20 - 1" or "DomainLimits.routineExercisesMax - 1",
 *  substituting any `Identifier.member` reference from `knownScalars` first. Only digits, `_`, `.`, `+`, `-`,
 *  `*`, `/`, parens and spaces are allowed to reach `Function` — anything else throws, so this can't run
 *  arbitrary Swift text, only literal arithmetic on already-parsed numbers. */
function evalExpr(raw: string, knownScalars: Record<string, number>): number {
  const substituted = raw.replace(/[A-Za-z_]\w*\.[A-Za-z_]\w*/g, (ref) => {
    const member = ref.split('.')[1]
    const value = knownScalars[member]
    if (value === undefined) {
      throw new Error(`domain-limits-drift: unknown reference '${ref}' in Swift expression '${raw}'`)
    }
    return String(value)
  })
  const cleaned = substituted.replace(/_/g, '')
  if (!/^[\d.+\-*/() ]+$/.test(cleaned)) {
    throw new Error(`domain-limits-drift: unsafe/unparsable Swift expression '${raw}' -> '${cleaned}'`)
  }
  return new Function(`return (${cleaned});`)() as number
}

/** Parses `public static let name = <value>` / `public static let name: ClosedRange<T> = <value>` lines out
 *  of a chunk of Swift source. `lo...hi` ranges become `{min, max}`; plain numbers become a `number`.
 *  `knownScalars` resolves `Other.member` references inside a range bound (e.g. PlanChangeLimits.position
 *  reaching into DomainLimits). Anything else (functions, string/bool lets, computed properties, comments)
 *  is silently skipped — it isn't a domain limit. */
function parseSwiftConstants(source: string, knownScalars: Record<string, number> = {}): LimitMap {
  const out: LimitMap = {}
  const lineRe = /public static let (\w+)(?::\s*ClosedRange<\w+>)?\s*=\s*(.+)$/gm
  let m: RegExpExecArray | null
  while ((m = lineRe.exec(source)) !== null) {
    const name = m[1]
    const rhs = m[2].replace(/\/\/.*$/, '').trim()
    const rangeMatch = rhs.match(/^(\(.+?\)|-?[\d._]+)\.\.\.(\(.+?\)|-?[\d._]+)$/)
    if (rangeMatch) {
      const lo = rangeMatch[1].replace(/^\(|\)$/g, '')
      const hi = rangeMatch[2].replace(/^\(|\)$/g, '')
      out[name] = { min: evalExpr(lo, knownScalars), max: evalExpr(hi, knownScalars) }
    } else if (/^-?[\d._]+$/.test(rhs)) {
      out[name] = evalExpr(rhs, knownScalars)
    }
    // else: not a numeric constant — skip.
  }
  return out
}

function scalarsOf(map: LimitMap): Record<string, number> {
  const out: Record<string, number> = {}
  for (const [name, value] of Object.entries(map)) {
    if (typeof value === 'number') out[name] = value
  }
  return out
}

// ---- Comparison ---------------------------------------------------------------------------------------------

function diffLimits(swift: LimitMap, ts: LimitMap, allowlist: Record<string, string>): string[] {
  const problems: string[] = []
  const names = new Set([...Object.keys(swift), ...Object.keys(ts)])
  for (const name of names) {
    if (name in allowlist) continue
    const s = swift[name]
    const t = ts[name]
    if (s === undefined) {
      problems.push(`'${name}': present in TS but not found in Swift`)
    } else if (t === undefined) {
      problems.push(`'${name}': present in Swift but has no TS counterpart`)
    } else if (typeof s === 'number' && typeof t === 'number') {
      if (s !== t) problems.push(`'${name}': swift=${s} ts=${t}`)
    } else if (typeof s === 'object' && typeof t === 'object') {
      if (s.min !== t.min || s.max !== t.max) {
        problems.push(`'${name}': swift={min:${s.min},max:${s.max}} ts={min:${t.min},max:${t.max}}`)
      }
    } else {
      problems.push(`'${name}': type mismatch (swift=${JSON.stringify(s)} ts=${JSON.stringify(t)})`)
    }
  }
  return problems.sort()
}

// ---- Load + parse once, shared by every test below -----------------------------------------------------

const [domainLimitsSource, planChangeSource] = await Promise.all([
  Deno.readTextFile(domainLimitsSwiftUrl),
  Deno.readTextFile(planChangeSwiftUrl),
])

const swiftDomainLimits = parseSwiftConstants(domainLimitsSource)

const planChangeLimitsEnum = planChangeSource.match(/public enum PlanChangeLimits \{([\s\S]*?)\n\}/)
if (!planChangeLimitsEnum) {
  throw new Error(
    "domain-limits-drift: could not find 'enum PlanChangeLimits' in PlanChange.swift — has it moved or been renamed?",
  )
}
const swiftPlanChangeLimits = parseSwiftConstants(planChangeLimitsEnum[1], scalarsOf(swiftDomainLimits))

const tsDomainLimits = DomainLimits as unknown as LimitMap
const tsPlanChangeLimits = PlanChangeLimits as unknown as LimitMap

Deno.test({
  name: 'domain-limits drift: DomainLimits.swift matches domain-limits.ts',
  permissions: { read: true },
  fn: () => {
    const problems = diffLimits(swiftDomainLimits, tsDomainLimits, ALLOWLIST)
    assert(
      problems.length === 0,
      `DomainLimits drift between Swift and TypeScript:\n  ${problems.join('\n  ')}`,
    )
  },
})

Deno.test({
  name:
    'domain-limits drift: PlanChangeLimits (PlanChange.swift) matches PlanChangeLimits (plan-validation.ts)',
  permissions: { read: true },
  fn: () => {
    const problems = diffLimits(swiftPlanChangeLimits, tsPlanChangeLimits, ALLOWLIST)
    assert(
      problems.length === 0,
      `PlanChangeLimits drift between Swift and TypeScript:\n  ${problems.join('\n  ')}`,
    )
  },
})

Deno.test({
  name:
    'domain-limits drift: the Swift parser is actually finding constants (guards against a silent 0-match pass)',
  permissions: { read: true },
  fn: () => {
    assert(
      Object.keys(swiftDomainLimits).length >= 10,
      `Only parsed ${
        Object.keys(swiftDomainLimits).length
      } DomainLimits constants — did the Swift syntax change?`,
    )
    assert(
      Object.keys(swiftPlanChangeLimits).length >= 5,
      `Only parsed ${
        Object.keys(swiftPlanChangeLimits).length
      } PlanChangeLimits constants — did the Swift syntax change?`,
    )
  },
})
