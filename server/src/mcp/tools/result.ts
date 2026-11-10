// Tool results: compact JSON text content. `ToolError` is an expected, user-facing failure (bad input, not found,
// not permitted); its message goes to the client. Anything else is an internal error and is never shown.
import type { Db } from '../db.ts'

export interface ToolResult {
  [key: string]: unknown
  content: { type: 'text'; text: string }[]
  isError?: boolean
}

export interface ToolCtx {
  db: Db
  now: Date
}

export class ToolError extends Error {
  constructor(message: string, readonly details?: Record<string, unknown>) {
    super(message)
    this.name = 'ToolError'
  }
}

export function ok(data: Record<string, unknown>): ToolResult {
  return { content: [{ type: 'text', text: JSON.stringify(data) }] }
}

export function fail(message: string, details?: Record<string, unknown>): ToolResult {
  return { content: [{ type: 'text', text: JSON.stringify({ error: message, ...details }) }], isError: true }
}

/** A copy without null/undefined fields, so results stay compact. */
export function compact<T extends Record<string, unknown>>(obj: T): Partial<T> {
  return Object.fromEntries(Object.entries(obj).filter(([, v]) => v !== null && v !== undefined)) as Partial<
    T
  >
}
