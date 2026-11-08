import { ApiError } from '../http/errors.ts'
import { normalizeTimestamp } from './time.ts'

/** How a column travels between the app's JSON and D1 (spec section 3, "Type mapping"). */
export type Kind = 'text' | 'int' | 'real' | 'bool' | 'json' | 'ts' | 'date' | 'uuid'

export interface Column {
  readonly name: string
  readonly kind: Kind
  /** Missing or null is stored as NULL. */
  readonly nullable?: boolean
  /** Missing or null is stored as this, like upsert_workout's coalesce(…, default). */
  readonly fallback?: unknown
}

/** A row the server won't store: 422 row_rejected, which the app records as a refused row (as with SQLSTATE 22/23). */
export class RowError extends ApiError {
  constructor(message: string) {
    super(422, 'row_rejected', message)
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const DAY = /^\d{4}-\d{2}-\d{2}$/

/** YYYY-MM-DD and a real day, as Postgres's `date` type required (the D1 CHECK only sees the shape). */
function isCalendarDay(raw: string): boolean {
  if (!DAY.test(raw)) return false
  const day = new Date(`${raw}T00:00:00Z`)
  return !Number.isNaN(day.getTime()) && day.toISOString().slice(0, 10) === raw
}

/** `raw`, a value from the app's JSON, as D1 stores it; throws RowError naming `label.column` when it doesn't fit. */
export function storedValue(column: Column, raw: unknown, label: string): unknown {
  if (raw === undefined || raw === null) {
    if (column.fallback !== undefined) return storedValue({ ...column, fallback: undefined }, column.fallback, label)
    if (column.nullable) return null
    throw new RowError(`${label}.${column.name} is required`)
  }
  const value = convert(column.kind, raw)
  if (value === undefined) throw new RowError(`${label}.${column.name} is not a valid ${column.kind}`)
  return value
}

function convert(kind: Kind, raw: unknown): unknown {
  switch (kind) {
    case 'text':
      return typeof raw === 'string' ? raw : undefined
    case 'int':
      return Number.isInteger(raw) ? raw : undefined
    case 'real':
      return typeof raw === 'number' && Number.isFinite(raw) ? raw : undefined
    case 'bool':
      return typeof raw === 'boolean' ? (raw ? 1 : 0) : undefined
    case 'json':
      return typeof raw === 'object' ? JSON.stringify(raw) : undefined
    case 'ts':
      return typeof raw === 'string' ? (normalizeTimestamp(raw) ?? undefined) : undefined
    case 'date':
      return typeof raw === 'string' && isCalendarDay(raw) ? raw : undefined
    case 'uuid':
      return typeof raw === 'string' && UUID.test(raw) ? raw.toLowerCase() : undefined
  }
}

/** The `columns` of `raw` (an object from the app), stored. Keys it doesn't name, like updated_at, are ignored. */
export function storedRow(columns: readonly Column[], raw: unknown, label: string): Record<string, unknown> {
  if (typeof raw !== 'object' || raw === null || Array.isArray(raw)) throw new RowError(`${label} is not an object`)
  const source = raw as Record<string, unknown>
  return Object.fromEntries(columns.map((c) => [c.name, storedValue(c, source[c.name], label)]))
}

/** A stored value as the app's JSON has it: booleans as true/false, JSON parsed. */
export function wireValue(column: Column, stored: unknown): unknown {
  if (stored === null || stored === undefined) return null
  if (column.kind === 'bool') return stored === 1
  if (column.kind === 'json') return JSON.parse(String(stored))
  return stored
}

/** A stored row as the app's JSON has it. Keys that aren't in `columns` (updated_at, user_id) pass through. */
export function wireRow(columns: readonly Column[], row: Record<string, unknown>): Record<string, unknown> {
  const out = { ...row }
  for (const column of columns) out[column.name] = wireValue(column, row[column.name])
  return out
}
