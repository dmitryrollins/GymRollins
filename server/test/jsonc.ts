/**
 * JSON with comments, as wrangler reads wrangler.jsonc: `//` and `/* *\/` comments and trailing commas are dropped,
 * never inside a string (`"http://..."` keeps its slashes).
 */
export function parseJsonc(text: string): unknown {
  return JSON.parse(withoutTrailingCommas(withoutComments(text)))
}

/** The index just past the string that opens at `start` (a `"`), escapes included. */
function stringEnd(text: string, start: number): number {
  for (let i = start + 1; i < text.length; i++) {
    if (text[i] === '\\') i++
    else if (text[i] === '"') return i + 1
  }
  throw new Error('unterminated string')
}

function withoutComments(text: string): string {
  let out = ''
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '"') {
      const end = stringEnd(text, i)
      out += text.slice(i, end)
      i = end - 1
    } else if (text.startsWith('//', i)) {
      const end = text.indexOf('\n', i)
      i = (end < 0 ? text.length : end) - 1
    } else if (text.startsWith('/*', i)) {
      const end = text.indexOf('*/', i + 2)
      if (end < 0) throw new Error('unterminated comment')
      i = end + 1
    } else {
      out += text[i]
    }
  }
  return out
}

function withoutTrailingCommas(text: string): string {
  let out = ''
  for (let i = 0; i < text.length; i++) {
    if (text[i] === '"') {
      const end = stringEnd(text, i)
      out += text.slice(i, end)
      i = end - 1
    } else if (text[i] !== ',' || !/^\s*[}\]]/.test(text.slice(i + 1))) {
      out += text[i]
    }
  }
  return out
}
