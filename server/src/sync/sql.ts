import type { Column } from './columns.ts'

// SQL text built from column lists, shared by the generic table sync (table-sync.ts) and the workout save
// (workouts.ts).

/** `a, b, c`: the columns' names. */
export const columnNames = (columns: readonly Column[]) => columns.map((c) => c.name).join(', ')

/** `json_extract(value, '$.a'), …`: each column read from one element of json_each(?). */
export const extracted = (columns: readonly Column[]) =>
  columns.map((c) => `json_extract(value, '$.${c.name}')`).join(', ')

/** `<column> IN (SELECT value FROM json_each(<param>))`: a list bound as one JSON value, within D1's 100 bound values. */
export const inJson = (column: string, param: string) => `${column} IN (SELECT value FROM json_each(${param}))`
