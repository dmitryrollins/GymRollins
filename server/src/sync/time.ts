// Timestamps are stored as text in one form, YYYY-MM-DDTHH:MM:SS.ffffffZ (UTC, six digits), so text order is time order
// and last-write-wins compares like with like. The app writes that form too (SyncDate.format) and reads any form below.

const PATTERN = /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|z|[+-]\d{2}(?::?\d{2})?)?$/

/**
 * The server's clock, in the stored form, read by SQLite in the statement that writes. D1 runs writes one at a time, so
 * a later write never gets an earlier stamp; the Worker's own clock is frozen during a request, so it isn't used.
 */
export const NOW_SQL = `(strftime('%Y-%m-%dT%H:%M:%f', 'now') || '000Z')`

/**
 * The updated_at an update stores: `now`, or a microsecond past `stored` when the millisecond clock hasn't moved past
 * it. Every accepted write then changes a row's stamp, which the app's conflict check (exact equality with the version
 * it last saw) and its pull cursor (`updated_at > cursor`) rely on. Both arguments are SQL expressions.
 */
export const laterStamp = (stored: string, now: string) =>
  `(CASE WHEN ${now} > ${stored} THEN ${now} ` +
  `ELSE substr(${stored}, 1, 20) || printf('%06d', CAST(substr(${stored}, 21, 6) AS INTEGER) + 1) || 'Z' END)`

/**
 * A timestamp from the app in the stored form, or null. Accepts what the app's SyncDate.parse accepts: 0 or more
 * fractional digits (truncated to six), `T` or a space, and `Z`, `z`, `±hh`, `±hhmm`, `±hh:mm` or no offset (UTC).
 */
export function normalizeTimestamp(raw: string): string | null {
  const m = PATTERN.exec(raw)
  if (!m) return null
  const [year, month, day, hour, minute, second] = m.slice(1, 7).map(Number)
  if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 60) return null
  const offset = offsetSeconds(m[8])
  if (offset === null) return null
  const micros = BigInt(`${m[7] ?? ''}000000`.slice(0, 6))
  const seconds = BigInt(Date.UTC(year, month - 1, day, hour, minute, second) / 1000) - BigInt(offset)
  return format(seconds * 1_000_000n + micros)
}

function offsetSeconds(raw: string | undefined): number | null {
  if (raw === undefined || raw === 'Z' || raw === 'z') return 0
  const sign = raw.startsWith('-') ? -1 : 1
  const digits = raw.slice(1).replace(':', '')
  const hours = Number(digits.slice(0, 2))
  const minutes = digits.length > 2 ? Number(digits.slice(2)) : 0
  if (!Number.isInteger(hours) || !Number.isInteger(minutes)) return null
  return sign * (hours * 3_600 + minutes * 60)
}

function format(totalMicros: bigint): string | null {
  let seconds = totalMicros / 1_000_000n
  let micros = totalMicros % 1_000_000n
  if (micros < 0n) {
    micros += 1_000_000n
    seconds -= 1n
  }
  const iso = new Date(Number(seconds) * 1000).toISOString()
  if (!/^\d{4}-/.test(iso)) return null
  return `${iso.slice(0, 19)}.${micros.toString().padStart(6, '0')}Z`
}
