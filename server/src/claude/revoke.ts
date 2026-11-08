// Disconnect Claude (spec section 4, "Tokens"; POST /v1/claude/revoke): every grant and token of the account
// goes in one batch, so Claude's next call is refused, its refresh token is dead, and an unredeemed code
// can't be swapped.

/** The number of Claude connections (consents) removed. */
export async function revokeClaude(db: D1Database, userId: string): Promise<number> {
  const results = await db.batch([
    db.prepare('DELETE FROM oauthAccessToken WHERE userId = ?1').bind(userId),
    db.prepare('DELETE FROM oauthRefreshToken WHERE userId = ?1').bind(userId),
    db.prepare('DELETE FROM oauthConsent WHERE userId = ?1').bind(userId),
    db.prepare(
      "DELETE FROM verification WHERE json_valid(value) AND json_extract(value, '$.type') = " +
        "'authorization_code' " +
        "AND json_extract(value, '$.userId') = ?1",
    ).bind(userId),
    // The /connect browser sessions, by their mark (src/auth/connect-plugin.ts; added after review): every
    // one connectSignIn made, whatever its connect_requests row recorded. The app's own sessions are 0.
    db.prepare('DELETE FROM session WHERE userId = ?1 AND claudeConnect = 1').bind(userId),
    db.prepare('DELETE FROM connect_requests WHERE user_id = ?1').bind(userId),
  ])
  return results[2]!.meta.changes
}
