-- Claude's approval codes (docs/specs/2026-11-07-cloudflare-backend-design.md section 4, "Claude's connection";
-- plan 29). /connect stores one row per browser and sign-in; the app approves or denies it by its code.
CREATE TABLE connect_requests (
  code TEXT PRIMARY KEY CHECK (length(code) = 8),
  -- SHA-256 (hex) of the secret cookie on the browser that showed the code: only that browser can continue.
  browser_hash TEXT NOT NULL UNIQUE CHECK (length(browser_hash) = 64),
  client_id TEXT NOT NULL REFERENCES oauthClient(clientId) ON DELETE CASCADE,
  redirect_host TEXT NOT NULL,
  -- The authorize request's parameters without Better Auth's signature (checked when /connect first saw them).
  query TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'waiting' CHECK (status IN ('waiting','approved','denied','used')),
  -- Who approved or denied it, and the browser session an approval created (Disconnect Claude ends it).
  user_id TEXT REFERENCES "user"(id) ON DELETE CASCADE,
  session_id TEXT,
  created_at TEXT NOT NULL,
  expires_at TEXT NOT NULL
);
CREATE INDEX connect_requests_user ON connect_requests (user_id);

-- Codes typed in the app, kept for 10 minutes: an account may get 5 wrong (a right one doesn't count).
CREATE TABLE connect_attempts (
  id INTEGER PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES "user"(id) ON DELETE CASCADE,
  at TEXT NOT NULL
);
CREATE INDEX connect_attempts_user_at ON connect_attempts (user_id, at);
