-- Plan 29, added after review: where the /connect page that shows a code was opened, so the app's Approve a
-- connection sheet can show "Opened 2 min ago · Toronto, CA · Safari" (created_at is when). Cloudflare's
-- cf-ipcountry and cf-ipcity headers and the browser's User-Agent, without control characters and cut to
-- these lengths (src/claude/connect-requests.ts); null when a header is absent, as the cf- ones are locally.
ALTER TABLE connect_requests ADD COLUMN opener_country TEXT CHECK (length(opener_country) <= 8);
ALTER TABLE connect_requests ADD COLUMN opener_city TEXT CHECK (length(opener_city) <= 64);
ALTER TABLE connect_requests ADD COLUMN opener_user_agent TEXT CHECK (length(opener_user_agent) <= 256);
