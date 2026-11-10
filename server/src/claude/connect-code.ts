// Approval codes (spec section 4, step 3): 8 characters from Crockford's 32-letter alphabet (no I, L, O or
// U), shown as XXXX-XXXX and typed case-insensitively in the app. Each browser that shows one gets a secret
// cookie; D1 keeps only the secret's SHA-256.

export const CODE_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ'
const CODE = /^[0-9A-HJKMNP-TV-Z]{8}$/

/** 8 random characters: each byte's low 5 bits, so every character is equally likely. */
export function newCode(): string {
  return [...crypto.getRandomValues(new Uint8Array(8))].map((b) => CODE_ALPHABET[b & 31]).join('')
}

/**
 * What the owner typed, as a stored code, or null: case, spaces and dashes don't matter, and O/I/L read as
 * 0/1/1.
 */
export function normalizeCode(typed: string): string | null {
  const code = typed.toUpperCase().replace(/[\s-]/g, '').replace(/O/g, '0').replace(/[IL]/g, '1')
  return CODE.test(code) ? code : null
}

export const displayCode = (code: string): string => `${code.slice(0, 4)}-${code.slice(4)}`

/** The browser's secret: 32 random bytes as hex. */
export function newBrowserSecret(): string {
  return [...crypto.getRandomValues(new Uint8Array(32))].map((b) => b.toString(16).padStart(2, '0')).join('')
}

export async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('')
}
