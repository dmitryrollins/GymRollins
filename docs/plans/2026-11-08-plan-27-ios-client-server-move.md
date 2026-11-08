# Plan 27: iOS client and server move

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or
> superpowers:executing-plans to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app signs in, syncs and deletes its account against the local Cloudflare Worker that plan 26 built. When
the API changes, its next launch hands the phone's data to the next account that signs in and uploads all of it. A copy
of the owner's phone store reaches the local Worker intact.

**Architecture:**
- **`ApiClient`** (GymSync) is URLSession with an ephemeral, cookie-less configuration. It sends the stored Better Auth
  token as `Authorization: Bearer` and throws `ApiError` (the server's `{"error": {"code", "message"}}` plus the
  status). A 401 to the stored token forgets it and tells `AuthService`.
- **`AuthService`** keeps its public surface (`state`, `onExternalChange`, the sign-in, sign-out, restore and delete
  calls) but talks to `/api/auth/*` and `/v1/account`. The session lives in a `SessionStore`: the Keychain in the app.
- **`ApiSyncTransport`** implements `SyncTransport` against `/v1/sync/*`. Gyms and proposals aren't on the API yet, so
  it says so (`servesGyms`, `servesProposals`) and the engine leaves them out of the round.
- **The server move** is `SyncStore.moveToServer(_:)` in GymData. The app runs it once at launch, before the session is
  restored, with `ApiConfig.origin`.
- **The integration and UI suites** start a throwaway Worker on port 8788 with its own state folder, and make every
  account fresh by email.

**Tech stack:** Swift 6.2, SwiftUI, SwiftData, Swift Testing, XCUITest, URLSession, Security (Keychain); the plan 26
Worker (Hono 4.13.17, Better Auth 1.7.18, wrangler 4.158.0 with local D1); bash and Node 22 for the scripts.

**Spec:** `docs/specs/2026-11-07-cloudflare-backend-design.md`, sections 3, 4 (Sync, Sign-in, Server move), 6, 7, 8
(iOS) and 9. Plan 26's Outcome ("Passed to later plans → Plan 27").

**Branch:** `feat-cloudflare`, after plan 26.
- No push.
- Local only: never run `wrangler login`, `wrangler deploy`, or any `wrangler` command without `--local`.
- Never install anything on the owner's iPhone; simulators only. Don't run `scripts/test-db.sh` (it resets local
  Supabase), and don't stop any Docker or Supabase container.
- Commit messages have no `Co-Authored-By`, `Generated with` or `Claude-Session` trailers; the owner forbids them.

**Not in this plan:**
- Gyms and listings in sync, photos and R2, the catalogue and moderation, `ApiGymCatalogTransport` (plan 28).
- Proposals, Claude's grants and revoke, the MCP server, the connector URL `<API_URL>/mcp` (plan 29).
- Deleting `Supabase*` files, `supabase-swift`, `SUPABASE_*` settings and the parked suites (plan 30).

---

## Decisions this plan makes

1. **The session token.** The probe (see "Facts checked for this plan") showed Better Auth hands it out twice: the bearer
   plugin's `set-auth-token` header (the token signed, `<token>.<base64 signature>`) and `token` in the sign-in body
   (the raw token). Both work as the bearer.
   - The app keeps the header's value and falls back to the body's.
   - It is stored with the user id and email (`StoredSession`), so a launch without network still knows who is signed
     in, as the Supabase SDK's stored session did.
   - In the app it is one Keychain item, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`: readable in the
     background, never synced to iCloud or restored to another phone. UI tests use a UserDefaults store that
     `-resetStore` wipes, as today.
   - Renewing a session moves its expiry only (checked in Better Auth's `get-session`), so the token never changes.
2. **What "signed out" looks like.**
   - `/v1` answers `401 signed_out`. `ApiClient` forgets the token, but only if it is still the one it sent, so a 401
     to an old request can't end a session signed in since. Only when it forgot it does it signal `AuthService`, which
     goes `.signedOut` and calls `onExternalChange`. The coordinator drops the engine and keeps the data and its owner, as with a revoked
     Supabase session.
   - `get-session` answers **200 `null`**, not 401, for a dead or unknown token. `restore()` treats that as signed out
     and forgets the token.
   - `sign-out` answers 200 whatever the token, but 415 to a POST with no body, so the app sends `{}`. The app forgets
     the token first, then tells the server.
3. **No cookies.** The URLSession is ephemeral with `httpCookieStorage = nil`, `httpShouldSetCookies = false`, cookies
   refused, and no URL cache. The app sends only `Authorization: Bearer` (plan 26: `/v1` refuses the cookie anyway),
   and follows no redirect, so the bearer never leaves the API.
4. **Offline.** URLError, 5xx and 429 are `ApiError.isOffline`. `badURL` and `unsupportedURL` aren't: they are the
   app's bugs.
   - `SyncEngine` shows `.offline` for them. Today a PostgREST 5xx showed `.error`; the spec's rule (section 6) is now
     the engine's too.
   - `restore()` keeps the stored account signed in.
   - `AuthFailure` says "Check your connection" for network errors, "Too many attempts" for 429, and the generic words
     for 5xx, as it did with Supabase.
5. **`AuthFailure` reads `ApiError`, code first, then status.** The codes are the ones the probe saw:

   | Code | Message |
   |---|---|
   | `invalid_email_or_password`, `invalid_password`, `credential_account_not_found` | Wrong email or password. |
   | `user_already_exists`, `user_already_exists_use_another_email` | An account with this email already exists… |
   | `password_too_short` | That password is too weak… |
   | `signed_out`, `session_expired` | Your session has expired… |
   | `email_password_disabled`, `email_password_sign_up_disabled`, `provider_not_found`, `id_token_not_supported` | This sign-in method isn't available right now. |
   | `photos_remain` | the existing photo messages |
   | any code with status 429 | Too many attempts… |

   Apple's token refused (`invalid_token`: audience, nonce, signature or expiry) keeps the generic "Couldn't sign in".
6. **Refused rows.** `ApiSyncTransport` turns three answers into `SyncRecordRejected`, which the engine records for that
   row before syncing the rest:
   - `422` (`row_rejected`: a CHECK, NOT NULL or foreign key failure, or a wrong type), as SQLSTATE 22/23 were.
   - `403 not_allowed`: the row's id belongs to another account. With Supabase, RLS's 42501 ended the round, but on
     `/v1` a 403 can only mean that (401 covers the session), so one foreign id no longer blocks every round. The
     message is the one gyms already use: "This belongs to another account and can't be synced."
   - `413 too_large`: the batch is retried row by row.
   Anything else ends the round, as before.
7. **Workout pages of 50.** Each page carries every entry and set. The owner averages 6 entries and 18 sets a workout,
   so 50 workouts are about a thousand rows a request, which stays small for the free plan's CPU limit. Other tables
   page by 500, as before.
8. **`API_URL` and `ApiConfig`.**
   - `ios/Config/Base.xcconfig` sets `API_URL = http://127.0.0.1:8787` (the local Worker). `project.yml` puts it in
     Info.plist. In DEBUG, an `API_URL` environment variable wins, as `SUPABASE_URL` did.
   - Only an origin is accepted: scheme, host and port, no path, user, query or fragment. `origin` is lowercased, with
     no trailing slash and no default port, so the same API always gives the same text.
   - **Spec correction:** the spec says the app stores the API *host*. The local Supabase (`127.0.0.1:55421`) and the
     local Worker (`127.0.0.1:8787`) share a host, so the plan stores the **origin**.
9. **What stays on Supabase until later plans.** `SupabaseConfig`, `SUPABASE_URL` and `SUPABASE_ANON_KEY` stay. Exercise
   photo hosting (`PhotoHosting`, R2 in plan 28) and Claude's connector URL (plan 29) still read them.
   `SupabaseTransport`, `SupabaseGymCatalogTransport` and `supabase-swift` keep compiling, but the app no longer builds
   them. Plan 30 deletes them.
10. **Gyms and proposals between plans 27 and 28/29.** Nothing ships between plans, but every round must still finish.
    - `SyncTransport` gains `servesGyms` and `servesProposals`, true by default. `ApiSyncTransport` answers false for
      both, so the engine skips `pushGyms`, `pullGyms`, `pushProposals` and `pullProposals`. Synced gyms and listings
      stay dirty until plan 28; Account counts them as waiting. No proposal is pulled or resolved.
    - The shared catalogue uses `UnavailableGymCatalogTransport` (reads offline, writes signed out). The Supabase one
      can't use the API's session.
    - Claude's last use reads "never" and Disconnect revokes 0 grants (the protocol's defaults). Claude has no access to
      the API until plan 29. Its connector URL is still Supabase's.
11. **Photo deletion in between.** Account deletion keeps its two photo steps, detach then remove, before
    `DELETE /v1/account`.
    - Until plan 28 they run on `UnavailableGymCatalogTransport`, where they now succeed and do nothing. Nothing writes
      `photo_objects` before plan 28, so the Worker holds no photos.
    - The server still refuses with `photos_remain` if a row exists.
    - Objects in the old Supabase Storage are left alone: the spec moves no old data.
12. **Gym links in the window.** The server's gym-link rules drop links to gyms it can't see, and in plan 27 it sees
    none. The app does not overwrite its local links with that null:
    - On the way out, `SyncStore.sendable` sends a synced gym's id only once the server has acknowledged the gym. After
      the move none has, so workouts go up without links.
    - On the way back, `SyncStore.resolved` keeps the local gym and listing when the server's are nil or unknown (the
      existing test `aPullWithNoLinkKeepsTheLocalOne`).
    - Task 5 adds a test of exactly this after a move.
    - So **plan 27's server-move check is scoped to counts, plus the phone's records unchanged (its gym links
      included)**. D1's `gym_id`/`gym_equipment_id` are checked when plan 28 re-runs the check with a fresh copy.
    - The real cutover isn't affected: `pushGyms` runs before workouts in the same round. The owner's copy has no gym
      links anyway (its one gym is "This phone only").
13. **The server move** (`SyncStore.moveToServer`, run by the app's sync factory before the session is restored):
    - It runs when the stored `gymrollins.sync.server` is missing or differs from `ApiConfig.origin`, and the data
      carries an owner, a pull cursor, or a record with a server version. Either way the origin is then stored.
    - It clears the owner, every pull cursor and the recorded sync failures (the old server's verdicts).
    - It clears `serverUpdatedAt` and sets `dirty` on every record that syncs with the account: profile, custom
      exercises, preferences, routines, weekdays, targets, body weight, workouts, and synced gyms and listings.
    - Synced listings forget `remotePhotoPath`, the old server's photo name; a picture on this phone uploads again.
    - Pending proposals are deleted. Resolutions not yet sent count as sent, because the new server never had those
      proposals.
    - Untouched: edit times (`updatedAt`, so last-write-wins still compares real edits), "This phone only" gyms and
      listings, their demoted-owner markers, the shared catalogue's cache (plan 28 decides), Health's state.
    - The store is saved before anything in UserDefaults changes, so a failed move can run again. If it throws, sync
      stays off for that launch. Data still marked as the old server's must not meet a new account, whose account-switch
      prompt would offer to remove it.
    - After a move, the factory also forgets the stored session.
    - It runs for the `.configured` and `.uiTestLocal` backends only.
14. **The spec's move, plus three things.** Clearing sync failures, marking unsent resolutions sent, and forgetting the
    session are not in spec section 4. Each follows from "the old server is gone" (decision 13).
15. **Tests never touch the dev data.** `scripts/test-server.sh` starts its own Worker:
    - `wrangler dev --local --persist-to <temp> --port 8788`, after `d1 migrations apply --local --persist-to <temp>`,
      and removes the folder on exit. `server/.wrangler/state` and the dev Worker on 8787 are never touched.
    - Accounts are made fresh per test by email and password: `sync-<uuid>@test.local` in the integration suites,
      `ui-<uuid>@test.local` in the UI tests, `move-<uuid>@test.local` in the move check. `server/.dev.vars` must say
      `ALLOW_PASSWORD_AUTH=1`; it already does.
16. **Supabase-only suites are parked.** Seven integration suites sign in with the Supabase client the app no longer
    has. They move to `Tests/GymSyncIntegrationTests/SupabaseParked/` and the target excludes that folder, so they stay
    as the reference plans 28 and 29 port:
    - gyms, photos and moderation (plan 28): `GymAccountPhotosIntegrationTests`, `GymCatalogE2ETests`,
      `GymCatalogIntegrationTests`, `GymModerationIntegrationTests`, `GymPrivateIntegrationTests`,
    - proposals and Claude's grants (plan 29): `OAuthGrantTransportTests`, `ProposalTransportTests`.
    `GYM_E2E` is parked too, and `ProposalSyncUITests` stays skipped until plan 29.
17. **The server-move check** runs in a throwaway simulator, created and deleted by `scripts/server-move-check.sh`:
    - The app runs as `-uiTesting -uiTestingBackend local -diskStore -noSeed`, so Health is off (its UI-test defaults)
      and nothing is seeded. The store copy goes in the disk store's place, the settings copy in the app's Preferences.
    - Every copy lives in a work folder outside the repo, and the script refuses paths inside it.
    - Records are compared by id, dates to the microsecond (`scripts/compare-stores.mjs`).
    - **Spec correction:** the spec expects 24 body weights. The owner's store copy
      (`phone-backup-p25-1794090751`) holds **23**: 18 synced and 5 Apple Health imports never synced. The check
      compares D1 with the copy's own counts and prints the spec's numbers beside them.
18. **The app target doesn't build between Tasks 6 and 7.** Task 6 replaces `AuthService(client:)`, and Task 7 changes the
    app to match. Run them back to back. Every package suite builds and passes after each task.
19. **Code style** matches GymSync: doc comments that say why, `Sendable` structs, `@MainActor` services, NSLock-guarded
    `@unchecked Sendable` stores (like `InMemoryAuthStorage`), lines up to 120 characters. Scripts follow
    `scripts/test-sync-integration.sh`.

### Facts checked for this plan

Checked on 2026-11-08 against the plan 26 Worker (head `163f76d`) through `authHandler`. The method: a throwaway Vitest
file in a scratchpad copy of `server/` (its `node_modules` linked, in-memory D1), never committed, plus a throwaway
`wrangler dev --local --persist-to <scratch> --port 8788`.

| Call | Answer |
|---|---|
| `POST /api/auth/sign-up/email` `{email, password, name}` | 200, header `set-auth-token: <token>.<sig>`, body `{"token":"<token>","user":{"id":"<uuid>","email":…,"name":…}}` |
| …with `name: ""` / without `name` | 200 / 400 `validation_error` (a name is required, an empty one is fine) |
| …again with the same email | 422 `user_already_exists_use_another_email` |
| …with a 5-character password | 400 `password_too_short` |
| …with `ALLOW_PASSWORD_AUTH=0` | 400 `email_password_sign_up_disabled` (sign-in: `email_password_disabled`) |
| `POST /api/auth/sign-in/email`, wrong password or unknown email | 401 `invalid_email_or_password` |
| `POST /api/auth/sign-in/email` | 200, `set-auth-token`, body `{"redirect":false,"token":…,"user":{…}}` |
| `POST /api/auth/sign-in/social` (Apple, raw nonce, SHA-256 claim) | 200, `set-auth-token`, same body shape; `user.email` the relay address |
| …wrong nonce or another audience | 401 `invalid_token` |
| …an Apple token without an `email` claim | 401 `user_email_not_found` |
| `GET /api/auth/get-session` with either token form | 200 `{"session":{…,"token":…},"user":{"id":…,"email":…}}` |
| …with a dead, garbage or missing token | 200 `null` |
| `POST /api/auth/sign-out` (Vitest, no body) with a live, dead, garbage or no token | 200 `{"success":true}` |
| …from URLSession with no body (`Content-Length: 0`, no `Content-Type`) | 415 `unsupported_media_type` (with `{}` and JSON: 200) |
| `/v1/*` with no, a garbage or a signed-out token | 401 `{"error":{"code":"signed_out","message":"Sign in required."}}` |
| `DELETE /v1/account` | 204, empty body |
| `GET /v1/sync/workouts/<unknown>` | 404 `not_found` |
| `POST /v1/sync/routines` with a bad row / `{"rows": 1}` | 422 `row_rejected` (`rows[0].policy is required`) / 400 `bad_request` |
| `GET /v1/sync/gyms` | 404 `not_found` ("No synced table gyms.") |
| `wrangler d1 execute gymrollins --local --persist-to <dir> --json` while that Worker runs | `[{"results":[{"n":1}],…}]` |
| Killing `npm exec wrangler dev` | workerd stops too; the port closes |
| `strftime(…,'now')` in one `INSERT … SELECT … RETURNING` (sqlite3 3.51) | one stamp for every row |

The plan's Swift for Tasks 1–6 was also compiled and run in a scratch copy of the three packages, never committed:
- GymSync: `Test run with 181 tests in 24 suites passed`.
- GymData: 363 tests in 49 suites. The one issue was `LibraryTests` missing the app's `exercises.json` beside the copy,
  not this plan.
- The 15 integration tests passed against a throwaway Worker on 8788.
  - The first run found the 415 on a body-less sign-out (row above); the plan sends `{}`.
- `scripts/compare-stores.mjs` and its test (Task 10) passed there too.
Not run ahead: Task 7 (the app target) and the scripts of Tasks 8–10 end to end. Their wrangler flags and the D1
query were (rows above).

## File map

| File | Change |
|---|---|
| `ios/Packages/GymSync/Sources/GymSync/ApiError.swift` | Create: the API's error, `isOffline` |
| `ios/Packages/GymSync/Sources/GymSync/SessionStore.swift` | Create: `StoredSession`, `SessionStore`, `InMemorySessionStore` |
| `ios/Packages/GymSync/Sources/GymSync/ApiClient.swift` | Create: URLSession, bearer, JSON, 401 signal |
| `ios/Packages/GymSync/Sources/GymSync/ApiConfig.swift` | Create: `API_URL`, `origin` |
| `ios/Packages/GymSync/Sources/GymSync/ApiClient+Auth.swift` | Create: the Better Auth calls and `DELETE /v1/account` |
| `ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport.swift` | Create: `/v1/sync/*` |
| `ios/Packages/GymSync/Sources/GymSync/KeychainSessionStore.swift` | Create |
| `ios/Packages/GymSync/Sources/GymSync/AuthService.swift` | Rewrite on `ApiClient` |
| `ios/Packages/GymSync/Sources/GymSync/AuthFailure.swift` | Read `ApiError` |
| `ios/Packages/GymSync/Sources/GymSync/SyncTransport.swift` | `servesGyms`, `servesProposals` |
| `ios/Packages/GymSync/Sources/GymSync/SyncEngine.swift`, `SyncEngine+Rounds.swift` | Offline mapping; skip what the server lacks |
| `ios/Packages/GymSync/Sources/GymSync/KeysetPager.swift` | `PageKey.decode` reads `{"rows": […]}` too |
| `ios/Packages/GymSync/Package.swift` | Exclude `SupabaseParked` |
| `ios/Packages/GymSync/Tests/GymSyncTests/StubURLProtocol.swift` | Create: a stub API per test |
| `ios/Packages/GymSync/Tests/GymSyncTests/ApiClientTests.swift`, `ApiConfigTests.swift`, `ApiSyncTransportTests.swift`, `SyncEngineServerScopeTests.swift`, `SupabaseConfigTests.swift` | Create |
| `ios/Packages/GymSync/Tests/GymSyncTests/AuthServiceTests.swift` | Rewrite |
| `ios/Packages/GymSync/Tests/GymSyncTests/AuthEventTests.swift`, `FakeTransport.swift`, `KeysetPagerTests.swift` | Modify |
| `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/IntegrationSupport.swift`, `AuthIntegrationTests.swift` | Rewrite for the Worker |
| `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/SupabaseTransportTests.swift` → `WorkerTransportTests.swift` | Move and modify |
| `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/PagingAndRejectionTests.swift`, `SyncRoundTripTests.swift` | Modify |
| `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/SupabaseParked/` | Seven suites moved here |
| `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+ServerMove.swift` | Create |
| `ios/Packages/GymData/Tests/GymDataTests/SyncStoreServerMoveTests.swift` | Create |
| `ios/Config/Base.xcconfig`, `ios/project.yml` | `API_URL` |
| `ios/GymRollins/App/SyncCoordinator+Factory.swift` | The API, the session store, the move |
| `ios/GymRollins/App/DebugSyncSupport.swift` | `UITestSessionStore` |
| `ios/GymRollins/App/AppEnvironment+GymCatalog.swift` | The catalogue unavailable until plan 28 |
| `ios/GymRollins/App/LaunchOptions.swift`, `ios/GymRollins/Features/Account/AppleSignIn.swift` | Comments |
| `ios/GymRollinsTests/KeychainSessionStoreTests.swift`, `ServerMoveLaunchTests.swift` | Create |
| `ios/GymRollinsTests/GymWipeEnvironmentTests.swift`, `SyncAccountSafetyTests.swift` | `AuthService(api:)` |
| `ios/GymRollinsUITests/SyncUITests.swift`, `ProposalSyncUITests.swift` | The Worker; the move check |
| `scripts/test-server.sh` | Create: the throwaway test Worker |
| `scripts/test-sync-integration.sh`, `scripts/ios-test-sync.sh` | Rewrite for the Worker |
| `scripts/server-move-check.sh`, `scripts/compare-stores.mjs`, `scripts/compare-stores.test.mjs` | Create |
| `scripts/test-all.sh`, `scripts/test-gym-e2e.sh`, `server/README.md` | Modify |

## How to run things

```bash
cd ios/Packages/GymSync && swift test --filter GymSyncTests   # unit tests: fake transport and a stub URLProtocol
cd ios/Packages/GymData && swift test                         # or --filter SyncStoreServerMoveTests
scripts/test-sync-integration.sh                              # GymSyncIntegrationTests on a throwaway Worker (:8788)
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' scripts/ios-test-sync.sh   # SyncUITests, same Worker
```

`swift test` prints its result as `Test run with N tests in M suites passed`. Before this plan:
- GymSyncTests: 143 tests in 20 suites.
- GymData: 355 tests in 48 suites.

`swift test --filter` builds every test target of the package, so `GymSyncIntegrationTests` must compile at the end of
every task. Its suites skip themselves without `API_URL`.

**One app test class** (from `ios/`, one `xcodebuild` at a time; the Mac runs short on memory):

```bash
xcodegen generate --quiet
xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' \
  -only-testing:GymRollinsTests/ServerMoveLaunchTests \
  -resultBundlePath build/TestResults-one-$(date +%s).xcresult -quiet
xcrun xcresulttool get test-results summary --path "$(ls -td build/TestResults-one-*.xcresult | head -1)"
```

A new file needs `xcodegen generate` first, because the project is generated. The full app UI suite takes about an
hour, so this plan runs targeted classes.

---

### Task 1: `ApiError`, the session store and `ApiClient`

**Files:**
- Create: `ios/Packages/GymSync/Sources/GymSync/ApiError.swift`, `SessionStore.swift`, `ApiClient.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/StubURLProtocol.swift`, `ApiClientTests.swift`

- [ ] **Step 1: Write the stub API for tests**

`ios/Packages/GymSync/Tests/GymSyncTests/StubURLProtocol.swift`:

```swift
import Foundation
@testable import GymSync

/// One canned answer from the stub API.
struct StubAnswer: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func json(_ status: Int, _ text: String, headers: [String: String] = [:]) -> StubAnswer {
        StubAnswer(status: status, headers: ["Content-Type": "application/json"].merging(headers) { _, new in new },
                   body: Data(text.utf8))
    }

    /// Where a 3xx with a `Location` points, resolved against the request's URL.
    func redirect(from url: URL) -> URL? {
        guard (300..<400).contains(status), let location = headers["Location"] else { return nil }
        return URL(string: location, relativeTo: url)?.absoluteURL
    }
}

/// A request as the stub saw it. URLSession hands a protocol the body as a stream; it is read here.
struct SeenRequest: Sendable {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    var path: String { url.path() }

    var query: [String: String] {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
    }

    func json() throws -> Any { try JSONSerialization.jsonObject(with: body ?? Data()) }
}

/// Answers URLSession requests in tests. Each `StubServer` registers under a host of its own, so tests running in
/// parallel never see each other's requests.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (SeenRequest) throws -> StubAnswer

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]

    static func register(host: String, _ handler: @escaping Handler) { lock.withLock { handlers[host] = handler } }
    static func unregister(host: String) { _ = lock.withLock { handlers.removeValue(forKey: host) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let handler = Self.lock.withLock({ Self.handlers[url.host() ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let seen = SeenRequest(method: request.httpMethod ?? "GET", url: url,
                               headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        do {
            let answer = try handler(seen)
            guard let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1",
                                                 headerFields: answer.headers)
            else { throw URLError(.badServerResponse) }
            if let target = answer.redirect(from: url) {
                // URLSession asks its delegate whether to follow; a refusal delivers this answer as the response.
                var next = request
                next.url = target
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: answer.body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A fake API for one test: a host of its own, the requests it saw, and clients pointed at it. Keep it alive for as
/// long as its clients are used (its `deinit` unregisters the host).
final class StubServer: @unchecked Sendable {
    let host = "api-\(UUID().uuidString.lowercased()).test"
    private let lock = NSLock()
    private var seen: [SeenRequest] = []

    init(_ handler: @escaping StubURLProtocol.Handler) {
        StubURLProtocol.register(host: host) { [weak self] request in
            self?.record(request)
            return try handler(request)
        }
    }

    deinit { StubURLProtocol.unregister(host: host) }

    var baseURL: URL { URL(string: "http://\(host)")! }
    var requests: [SeenRequest] { lock.withLock { seen } }

    func client(sessions: any SessionStore = InMemorySessionStore()) -> ApiClient {
        ApiClient(baseURL: baseURL, sessions: sessions,
                  urlSession: ApiClient.makeURLSession(protocolClasses: [StubURLProtocol.self]))
    }

    private func record(_ request: SeenRequest) { lock.withLock { seen.append(request) } }
}
```

- [ ] **Step 2: Write the failing tests**

`ios/Packages/GymSync/Tests/GymSyncTests/ApiClientTests.swift`:

```swift
import Foundation
import Testing
@testable import GymSync

/// `ApiClient` against a stub: the bearer, JSON, `ApiError`, the offline cases and the 401 signal.
@Suite struct ApiClientTests {
    private let session = StoredSession(token: "t1.sig", userId: UUID(), email: "a@test.local")
    private let signedOut = #"{"error": {"code": "signed_out", "message": "Sign in required."}}"#

    @Test func sendsTheStoredTokenAsABearerAndJSON() async throws {
        let server = StubServer { _ in .json(200, #"{"ok": true}"#) }
        let api = server.client(sessions: InMemorySessionStore(session))
        let _: [String: Bool] = try await api.post("/v1/sync/routines", ["rows": [String]()])
        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "\(server.baseURL.absoluteString)/v1/sync/routines")
        #expect(request.headers["Authorization"] == "Bearer t1.sig")
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(try request.json() as? [String: [String]] == ["rows": []])
    }

    /// Read off the client's own session: URLSession runs no cookie handling or cache for a stub URLProtocol, so a
    /// round trip through the stub can't show either.
    @Test func neverSendsOrKeepsCookies() {
        let configuration = ApiClient(baseURL: URL(string: "http://127.0.0.1:9")!, sessions: InMemorySessionStore())
            .configuration
        #expect(configuration.httpCookieStorage == nil)
        #expect(!configuration.httpShouldSetCookies)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCache == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test func clearSaysWhetherItForgotASession() throws {
        let sessions = InMemorySessionStore(session)
        #expect(!sessions.clear(ifToken: "t2.sig"))
        #expect(sessions.load() == session)
        #expect(sessions.clear(ifToken: session.token))
        #expect(sessions.load() == nil)
        #expect(!sessions.clear(ifToken: nil), "nothing left to forget")
        try sessions.save(session)
        #expect(sessions.clear(ifToken: nil))
    }

    @Test func anErrorAnswerBecomesApiErrorWithItsCodeAndStatus() async throws {
        let server = StubServer { _ in
            .json(422, #"{"error": {"code": "row_rejected", "message": "rows[0].policy is required"}}"#)
        }
        await #expect(throws: ApiError(status: 422, code: "row_rejected", message: "rows[0].policy is required")) {
            let _: [String: String] = try await server.client().get("/v1/sync/routines")
        }
    }

    @Test func anAnswerInAnotherShapeStillGivesTheStatus() async throws {
        let server = StubServer { _ in
            StubAnswer(status: 502, headers: ["Content-Type": "text/html"], body: Data("<html>".utf8))
        }
        do {
            let _: [String: String] = try await server.client().get("/v1/sync/routines")
            Issue.record("expected an error")
        } catch let error as ApiError {
            #expect(error.status == 502)
            #expect(error.code == "http_502")
            #expect(error.isTemporary)
        }
    }

    @Test func networkFailuresRateLimitsAndServerErrorsAreOffline() {
        #expect(ApiError.isOffline(URLError(.notConnectedToInternet)))
        #expect(ApiError.isOffline(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
        for status in [429, 500, 503] { #expect(ApiError.isOffline(ApiError(status: status, code: "x", message: ""))) }
        for status in [400, 401, 403, 404, 409, 413, 422] {
            #expect(!ApiError.isOffline(ApiError(status: status, code: "x", message: "")))
        }
    }

    @Test(.timeLimit(.minutes(1))) func a401ToTheStoredTokenForgetsItAndSaysSo() async throws {
        let answer = signedOut
        let server = StubServer { _ in .json(401, answer) }
        let sessions = InMemorySessionStore(session)
        let api = server.client(sessions: sessions)
        await #expect(throws: ApiError(status: 401, code: "signed_out", message: "Sign in required.")) {
            let _: [String: String] = try await api.get("/v1/sync/routines")
        }
        #expect(sessions.load() == nil)
        var signals = api.unauthorized.makeAsyncIterator()
        #expect(await signals.next() != nil)
    }

    @Test func a401ToAnOlderTokenLeavesASessionSignedInSince() async throws {
        let sessions = InMemorySessionStore(session)
        let newer = StoredSession(token: "t2.sig", userId: session.userId, email: nil)
        let answer = signedOut
        let server = StubServer { _ in
            try sessions.save(newer) // a sign-in finishing while the old request was on the wire
            return .json(401, answer)
        }
        await #expect(throws: ApiError.self) {
            let _: [String: String] = try await server.client(sessions: sessions).get("/v1/sync/routines")
        }
        #expect(sessions.load() == newer)
    }

    @Test func a401ToAnOlderTokenSendsNoSignal() async throws {
        let sessions = InMemorySessionStore(session)
        let newer = StoredSession(token: "t2.sig", userId: session.userId, email: nil)
        let answer = signedOut
        let server = StubServer { _ in
            try sessions.save(newer)
            return .json(401, answer)
        }
        let api = server.client(sessions: sessions)
        await #expect(throws: ApiError.self) {
            let _: [String: String] = try await api.get("/v1/sync/routines")
        }
        #expect(await !signalled(api), "the session signed in since stays signed in")
    }

    @Test func a401ToASignInLeavesTheStoreAloneAndSendsNoSignal() async throws {
        let server = StubServer { _ in
            .json(401, #"{"error": {"code": "invalid_email_or_password", "message": "Invalid email or password"}}"#)
        }
        let sessions = InMemorySessionStore(session)
        let api = server.client(sessions: sessions)
        await #expect(throws: ApiError.self) {
            _ = try await api.data("POST", "/api/auth/sign-in/email", body: Data("{}".utf8), bearer: .anonymous)
        }
        #expect(sessions.load() == session)
        #expect(await !signalled(api))
    }

    @Test func a401ToASignOutLeavesTheStoreAloneAndSendsNoSignal() async throws {
        let answer = signedOut
        let server = StubServer { _ in .json(401, answer) }
        let sessions = InMemorySessionStore(session)
        let api = server.client(sessions: sessions)
        let token = session.token
        await #expect(throws: ApiError.self) {
            _ = try await api.data("POST", "/api/auth/sign-out", body: Data("{}".utf8), bearer: .token(token))
        }
        #expect(sessions.load() == session, "even when the token it carried is the stored one")
        #expect(await !signalled(api))
    }

    @Test func aRedirectComesBackAsItIsAndTheBearerStaysHome() async throws {
        let elsewhere = StubServer { _ in .json(200, "{}") }
        let target = elsewhere.baseURL.appending(path: "/v1/sync/routines").absoluteString
        let server = StubServer { _ in .json(302, "{}", headers: ["Location": target]) }
        let api = server.client(sessions: InMemorySessionStore(session))
        let error = await #expect(throws: ApiError.self) {
            let _: [String: String] = try await api.get("/v1/sync/routines")
        }
        #expect(error?.status == 302)
        #expect(server.requests.count == 1)
        #expect(elsewhere.requests.isEmpty, "the bearer never follows a redirect")
    }

    @Test func aRequestTheAppBuiltWrongIsNotOffline() {
        #expect(!ApiError.isOffline(URLError(.badURL)))
        #expect(!ApiError.isOffline(URLError(.unsupportedURL)))
        #expect(!ApiError.isOffline(NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL)))
        #expect(ApiError.isOffline(URLError(.cancelled)), "a cancelled request is tried again later")
    }

    @Test func aSessionOrABearerNeverShowsItsToken() {
        let bearer = ApiClient.Bearer.token(session.token)
        var printed = ""
        print(session, bearer, to: &printed)
        var dumped = ""
        dump(session, to: &dumped)
        dump(bearer, to: &dumped)
        let shown = [printed, dumped, "\(session)", "\(bearer)", String(reflecting: session), String(reflecting: bearer)]
        for text in shown {
            #expect(!text.contains(session.token), "\(text)")
            #expect(text.contains("<redacted>"), "\(text)")
        }
    }

    @Test func aRequestWithoutASessionCarriesNoAuthorization() async throws {
        let server = StubServer { _ in .json(200, "{}") }
        let _: [String: String] = try await server.client().get("/api/auth/get-session")
        #expect(server.requests.first?.headers["Authorization"] == nil)
    }

    @Test func aPlusInTheQueryReachesTheServerAsAPlus() async throws {
        let server = StubServer { _ in .json(200, "{}") }
        let _: [String: String] = try await server.client().get("/v1/sync/exercise-prefs",
                                                                query: [URLQueryItem(name: "after", value: "a+b")])
        let request = try #require(server.requests.first)
        #expect(request.url.query(percentEncoded: true) == "after=a%2Bb")
        #expect(request.query["after"] == "a+b")
    }
}

/// Whether `api.unauthorized` yields within a moment. The client buffers a signal before it throws, so one arrives at
/// once; without one the wait wins.
private func signalled(_ api: ApiClient) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            var signals = api.unauthorized.makeAsyncIterator()
            return await signals.next() != nil
        }
        group.addTask {
            try? await Task.sleep(for: .milliseconds(200))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd ios/Packages/GymSync && swift test --filter ApiClientTests`
Expected: the build fails with `cannot find type 'SessionStore' in scope` and `cannot find 'ApiClient' in scope`.

- [ ] **Step 4: Write `ApiError`**

`ios/Packages/GymSync/Sources/GymSync/ApiError.swift`:

```swift
import Foundation

/// An error answer from the GymRollins API: the HTTP status and the `{"error": {"code", "message"}}` body every error
/// carries (server/src/http/errors.ts). The codes keep the strings the app knew from Postgres (`row_rejected`,
/// `not_allowed`, `photos_remain`, …); Better Auth's arrive lowercased (`invalid_email_or_password`, …).
public struct ApiError: LocalizedError, Equatable, Sendable {
    public let status: Int
    public let code: String
    public let message: String

    public init(status: Int, code: String, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    /// A busy or rate-limited server (5xx, 429): nothing is wrong with the request, so the app tries again later.
    public var isTemporary: Bool { status == 429 || (500...599).contains(status) }

    /// Network failures (a cancelled request included), rate limits and server errors: what the app shows as offline
    /// and tries again. A URL the app built wrong is a bug, not the network, so it isn't one.
    public static func isOffline(_ error: Error) -> Bool {
        if let api = error as? ApiError { return api.isTemporary }
        let failure = error as NSError
        return failure.domain == NSURLErrorDomain && !malformed.contains(failure.code)
    }

    /// `URLError.badURL` and `.unsupportedURL`: trying again sends the same broken request.
    private static let malformed: Set<Int> = [NSURLErrorBadURL, NSURLErrorUnsupportedURL]

    /// Reads an error answer. A body in another shape (a proxy's HTML page, an empty 502) still gives the status, with
    /// the code `http_<status>`.
    static func from(status: Int, body: Data) -> ApiError {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: body) {
            return ApiError(status: status, code: envelope.error.code, message: envelope.error.message)
        }
        return ApiError(status: status, code: "http_\(status)",
                        message: HTTPURLResponse.localizedString(forStatusCode: status))
    }

    private struct Envelope: Decodable {
        struct Body: Decodable {
            let code: String
            let message: String
        }

        let error: Body
    }
}
```

- [ ] **Step 5: Write the session store**

`ios/Packages/GymSync/Sources/GymSync/SessionStore.swift`:

```swift
import Foundation

/// The signed-in session as the phone keeps it: Better Auth's bearer token, and whose it is, so a launch without
/// network still knows who is signed in.
public struct StoredSession: Codable, Equatable, Sendable {
    public let token: String
    public let userId: UUID
    public let email: String?

    public init(token: String, userId: UUID, email: String?) {
        self.token = token
        self.userId = userId
        self.email = email
    }
}

/// A session printed, dumped or put in a log line shows `<redacted>` for its token.
extension StoredSession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        "StoredSession(token: <redacted>, userId: \(userId), email: \(email.map { "\"\($0)\"" } ?? "nil"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["token": "<redacted>", "userId": userId, "email": email as Any], displayStyle: .struct)
    }
}

/// Where the session lives: the Keychain in the app (`KeychainSessionStore`), memory in tests.
public protocol SessionStore: Sendable {
    func load() -> StoredSession?
    func save(_ session: StoredSession) throws
    /// Forgets the session. With a token, only while the store still holds that one, so a 401 to an older request
    /// can't end a session signed in since. True when a session was forgotten.
    @discardableResult func clear(ifToken token: String?) -> Bool
}

extension SessionStore {
    public func clear() { clear(ifToken: nil) }
}

/// A process-local session store for tests and previews.
public final class InMemorySessionStore: SessionStore, @unchecked Sendable {
    private let lock = NSLock()
    private var session: StoredSession?

    public init(_ session: StoredSession? = nil) { self.session = session }

    public func load() -> StoredSession? { lock.withLock { session } }

    public func save(_ session: StoredSession) throws { lock.withLock { self.session = session } }

    @discardableResult public func clear(ifToken token: String?) -> Bool {
        lock.withLock {
            guard let held = session, token == nil || held.token == token else { return false }
            session = nil
            return true
        }
    }
}
```

- [ ] **Step 6: Write `ApiClient`**

`ios/Packages/GymSync/Sources/GymSync/ApiClient.swift`:

```swift
import Foundation

/// The GymRollins API (the Worker in `server/`) over URLSession. Requests carry the stored session token as
/// `Authorization: Bearer` and JSON bodies; an answer outside 2xx is thrown as `ApiError`, a network failure as
/// `URLError`. The session never sends or keeps cookies (the API takes only the bearer, spec section 7) and has no
/// URL cache, so one account's answers can't be served to another. No redirect is followed, so the bearer can't go
/// anywhere else: the API never redirects, and a 3xx is thrown as an `ApiError` like any answer outside 2xx.
///
/// A 401 to a request that carried the stored token means the server ended that session (signed out elsewhere, expired,
/// account deleted): the token is forgotten and `unauthorized` yields, which `AuthService` turns into a sign-out. The
/// local data stays. When the store already holds a newer session (a sign-in finished while the request was on the
/// wire), nothing is forgotten and nothing yields.
public struct ApiClient: Sendable {
    /// Which token a request carries. Printed, dumped or logged, a given token shows as `<redacted>`.
    enum Bearer: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        case stored
        case anonymous
        case token(String)

        var description: String {
            switch self {
            case .stored: "stored"
            case .anonymous: "anonymous"
            case .token: "token(<redacted>)"
            }
        }

        var debugDescription: String { description }

        var customMirror: Mirror { Mirror(self, children: [], displayStyle: .enum) }
    }

    /// The API's origin, e.g. `http://127.0.0.1:8787` (`ApiConfig.baseURL`).
    public let baseURL: URL
    let sessions: any SessionStore
    private let urlSession: URLSession
    /// One element per 401 that ended the stored session. `AuthService` is its only reader.
    let unauthorized: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation

    public init(baseURL: URL, sessions: any SessionStore, urlSession: URLSession = ApiClient.makeURLSession()) {
        self.baseURL = baseURL
        self.sessions = sessions
        self.urlSession = urlSession
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        unauthorized = stream
        signal = continuation
    }

    /// Ephemeral, with cookies and the URL cache off. Tests put their stub protocol in front.
    public static func makeURLSession(protocolClasses: [AnyClass] = []) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if !protocolClasses.isEmpty {
            configuration.protocolClasses = protocolClasses + (configuration.protocolClasses ?? [])
        }
        return URLSession(configuration: configuration)
    }

    /// The session's settings, for the tests.
    var configuration: URLSessionConfiguration { urlSession.configuration }

    /// `GET`, the answer decoded with `SyncJSON.decoder`.
    func get<Response: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> Response {
        let (body, _) = try await data("GET", path, query: query)
        return try SyncJSON.decoder.decode(Response.self, from: body)
    }

    /// `POST` with `payload` encoded by `SyncJSON.encoder`, the answer decoded with `SyncJSON.decoder`.
    func post<Payload: Encodable, Response: Decodable>(_ path: String, _ payload: Payload) async throws -> Response {
        let (body, _) = try await data("POST", path, body: SyncJSON.encoder.encode(payload))
        return try SyncJSON.decoder.decode(Response.self, from: body)
    }

    /// One exchange; the body and response of a 2xx answer.
    func data(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil,
              bearer: Bearer = .stored) async throws -> (body: Data, response: HTTPURLResponse) {
        var request = URLRequest(url: try url(path, query: query))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let token: String? = switch bearer {
        case .stored: sessions.load()?.token
        case .anonymous: nil
        case .token(let given): given
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (answer, response) = try await urlSession.data(for: request, delegate: RefusesRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            // Only when this 401 ended the stored session: a token since replaced leaves the newer one signed in.
            if http.statusCode == 401, case .stored = bearer, let token, sessions.clear(ifToken: token) {
                signal.yield()
            }
            throw ApiError.from(status: http.statusCode, body: answer)
        }
        return (answer, http)
    }

    private func url(_ path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)
        else { throw URLError(.badURL) }
        if !query.isEmpty {
            components.queryItems = query
            // URLComponents leaves "+" as it is, and a server reads it as a space.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw URLError(.badURL) }
        return url
    }
}

/// Answers every redirect with nil, so URLSession hands back the 3xx instead of following it with the bearer. It is
/// each request's own delegate, so a session passed to `ApiClient.init` refuses redirects too.
final class RefusesRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    static let shared = RefusesRedirects()

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
```

- [ ] **Step 7: Run the tests**

Run: `cd ios/Packages/GymSync && swift test --filter GymSyncTests`
Expected: `Test run with 159 tests in 21 suites passed`.

- [ ] **Step 8: Commit**

```bash
git add ios/Packages/GymSync
git commit -m "feat(sync): ApiClient with bearer sessions, API errors and a 401 signal"
```

- [ ] **Step 9: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** decisions 1–4 and spec sections 6–7.
2. **Quality:** the `code-reviewer` agent.
3. **Security:** the `security-reviewer` agent. The token reaches only the `Authorization` header, never a log, a URL or
   a cookie, and a 401 clears only the token that was sent.

Fix CRITICAL and HIGH findings in a follow-up commit and re-run Step 7.

- [ ] **Step 10: The review follow-ups (added after review)**

The code blocks above already include them. Commit: `fix(sync): a stale 401 signals nothing; no redirects, redacted tokens`.

**Changes:**
- **A stale 401 signals nothing (HIGH).** `SessionStore.clear(ifToken:)` returns whether it forgot a session
  (`@discardableResult`), and `ApiClient` yields `unauthorized` only then. Before, a 401 to a request sent with T1
  after a sign-in as T2 left T2 in the store but signed the UI out. Task 7's `KeychainSessionStore` and
  `UITestSessionStore` return it too.
- **The cookie test reads the configuration.** URLSession runs no cookie handling for a custom URLProtocol, so the
  two-request half of `neverSendsOrKeepsCookies` couldn't fail. The test now reads the client's own session through an
  internal `configuration`: no cookie storage, no cookies set or accepted, no URL cache, `.reloadIgnoringLocalCacheData`.
- **A bad URL isn't offline.** `URLError.badURL` and `.unsupportedURL` are the app's bugs, and trying again sends the
  same request. `.cancelled` still counts as offline.
- **Tokens are redacted.** `StoredSession` and `ApiClient.Bearer` show `<redacted>` for the token in `print`, `dump`,
  interpolation and `String(reflecting:)` (`CustomStringConvertible`, `CustomDebugStringConvertible`,
  `CustomReflectable`).
- **No redirects.** Every request's delegate is `RefusesRedirects`, which answers nil, so a 3xx comes back as an
  `ApiError` and the bearer never reaches the `Location`. It is the request's delegate rather than the session's, so a
  session passed to `ApiClient.init` refuses redirects too. `StubServer` redirects a 3xx that has a `Location`, through
  `wasRedirectedTo`: before the fix, the client followed it and the target got `Authorization: Bearer t1.sig`.

**Seven tests added to `ApiClientTests.swift`:**
- A 401 to an older token sends no signal (`signalled` races `next()` against a 200 ms sleep, and the sleep wins).
- A 401 to an `.anonymous` request (a wrong sign-in) and to a `.token` request (sign-out) leaves the store alone and
  sends no signal.
- `clear(ifToken:)` answers whether it forgot a session.
- A 302 comes back as it is, and its target sees no request.
- `badURL` and `unsupportedURL` aren't offline; `cancelled` is.
- No token in what a session or a bearer prints.

With them, Step 7 reads `Test run with 159 tests in 21 suites passed`. The counts in later tasks include the seven.

### Task 2: `ApiConfig` and the `API_URL` setting

**Files:**
- Create: `ios/Packages/GymSync/Sources/GymSync/ApiConfig.swift`
- Modify: `ios/Config/Base.xcconfig`, `ios/project.yml`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/ApiConfigTests.swift`

- [ ] **Step 1: Write the failing tests**

`ios/Packages/GymSync/Tests/GymSyncTests/ApiConfigTests.swift`:

```swift
import Foundation
import Testing
@testable import GymSync

/// `API_URL` from Info.plist or the environment, and the origin the server move compares.
@Suite struct ApiConfigTests {
    @Test func readsTheOriginFromInfo() throws {
        let config = try ApiConfig(info: ["API_URL": "http://127.0.0.1:8787"])
        #expect(config.baseURL == URL(string: "http://127.0.0.1:8787"))
        #expect(config.origin == "http://127.0.0.1:8787")
    }

    @Test func oneAPIHasOneOrigin() throws {
        for raw in ["https://GymRollins.Example.workers.dev", "https://gymrollins.example.workers.dev/",
                    "https://gymrollins.example.workers.dev:443", " https://gymrollins.example.workers.dev "] {
            #expect(try ApiConfig(info: ["API_URL": raw]).origin == "https://gymrollins.example.workers.dev")
        }
        #expect(try ApiConfig(info: ["API_URL": "http://127.0.0.1:55421"]).origin
            != ApiConfig(info: ["API_URL": "http://127.0.0.1:8787"]).origin, "the port tells the local servers apart")
    }

    @Test func rejectsAMissingOrEmptyURL() {
        #expect(throws: ApiConfigError.missing) { try ApiConfig(info: [:]) }
        #expect(throws: ApiConfigError.missing) { try ApiConfig(info: ["API_URL": "  "]) }
    }

    @Test func rejectsAnythingButAnHTTPOrigin() {
        // `http:/$()/host` in an xcconfig expands to `http://host`; an unexpanded build setting must not slip through.
        for raw in ["$(API_URL)", "127.0.0.1:8787", "ftp://example.com", "http://", "http://127.0.0.1:1@evil.example/",
                    "https://example.com/api", "https://example.com/?a=1", "https://example.com/#x"] {
            #expect(throws: ApiConfigError.invalidURL(raw)) { try ApiConfig(info: ["API_URL": raw]) }
        }
    }

    @Test func readsTheEnvironment() throws {
        #expect(try ApiConfig(environment: ["API_URL": "http://localhost:8788"]).origin == "http://localhost:8788")
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd ios/Packages/GymSync && swift test --filter ApiConfigTests`
Expected: the build fails with `cannot find 'ApiConfig' in scope`.

- [ ] **Step 3: Write `ApiConfig`**

`ios/Packages/GymSync/Sources/GymSync/ApiConfig.swift`:

```swift
import Foundation

public enum ApiConfigError: Error, Equatable, Sendable {
    case missing
    case invalidURL(String)
}

/// Where the GymRollins API lives. The app reads Info.plist key `API_URL`, filled from `ios/Config/Base.xcconfig` (the
/// local Worker, `http://127.0.0.1:8787`) or a `Local.xcconfig` override once a Worker is deployed. Only an origin is
/// accepted (scheme, host and port), so `origin` names one API exactly: the server move compares it.
public struct ApiConfig: Sendable, Equatable {
    public static let urlKey = "API_URL"

    /// `scheme://host[:port]`: lowercased, with no path and no default port.
    public let baseURL: URL

    /// Validates an Info.plist-style dictionary.
    public init(info: [String: Any]) throws {
        guard let raw = (info[Self.urlKey] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { throw ApiConfigError.missing }
        guard let parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/"
        else { throw ApiConfigError.invalidURL(raw) }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = parts.port == (scheme == "https" ? 443 : 80) ? nil : parts.port
        guard let url = origin.url else { throw ApiConfigError.invalidURL(raw) }
        baseURL = url
    }

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        try self.init(info: environment)
    }

    public static func fromBundle(_ bundle: Bundle = .main) throws -> ApiConfig {
        try ApiConfig(info: bundle.infoDictionary ?? [:])
    }

    /// What `SyncStore.syncedServer` keeps: the same text for the same API, different for any other.
    public var origin: String { baseURL.absoluteString }

    public func makeClient(sessions: any SessionStore) -> ApiClient {
        ApiClient(baseURL: baseURL, sessions: sessions)
    }
}
```

- [ ] **Step 4: Add `API_URL` to the build settings**

In `ios/Config/Base.xcconfig`, insert this block after the first line (`// Committed base settings. …`) and its blank line,
above the Supabase block:

```
// The GymRollins API (read by GymSync's ApiConfig from Info.plist): the Cloudflare Worker in server/. The default is the
// LOCAL Worker (scripts/server-up.sh). A deployed Worker's address goes in Local.xcconfig, once the owner approves the
// deploy (spec section 9).
API_URL = http:/$()/127.0.0.1:8787

```

In the same file, replace the Supabase block's first line,

```
// Supabase (read by GymSync's SupabaseConfig from Info.plist). Defaults point at the LOCAL stack
```

with

```
// Supabase (read by GymSync's SupabaseConfig from Info.plist) for exercise photo hosting and Claude's connector URL
// only, until plans 28 and 29 move them to the API (plan 30 removes it). Defaults point at the LOCAL stack
```

In `ios/project.yml`, under the app target's `info: properties:`, add above `SUPABASE_URL: $(SUPABASE_URL)`:

```yaml
        # The GymRollins API (Config/Base.xcconfig): sign-in and sync.
        API_URL: $(API_URL)
```

Run: `cd ios && xcodegen generate --quiet && /usr/libexec/PlistBuddy -c 'Print :API_URL' GymRollins/Info.plist`
Expected: `$(API_URL)`. (Info.plist is generated and gitignored.)

- [ ] **Step 5: Run the tests**

Run: `cd ios/Packages/GymSync && swift test --filter GymSyncTests`
Expected: `Test run with 164 tests in 22 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/GymSync ios/Config/Base.xcconfig ios/project.yml
git commit -m "feat(sync): API_URL and ApiConfig, one origin per API"
```

- [ ] **Step 7: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** decision 8 and spec section 9 step 2 (a deployed `API_URL` goes in `Local.xcconfig`).
2. **Quality:** the `code-reviewer` agent. `Local.xcconfig` is gitignored and must not be in the diff.

### Task 3: The engine leaves out what the server lacks, and reads 5xx and 429 as offline

**Files:**
- Modify: `ios/Packages/GymSync/Sources/GymSync/SyncTransport.swift`, `SyncEngine.swift`, `SyncEngine+Rounds.swift`
- Modify: `ios/Packages/GymSync/Tests/GymSyncTests/FakeTransport.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineServerScopeTests.swift`

- [ ] **Step 1: Let the fake server leave gyms or proposals out**

In `FakeTransport.swift`, after `private var heldDownload: CheckedContinuation<Void, Never>?` (and before the blank line
above `func fail(with error: URLError?)`), add:

```swift

    /// False makes the engine leave gyms (or proposals) out of the round, as with the API before plans 28 and 29.
    nonisolated let servesGyms: Bool
    nonisolated let servesProposals: Bool

    init(servesGyms: Bool = true, servesProposals: Bool = true) {
        self.servesGyms = servesGyms
        self.servesProposals = servesProposals
    }
```

- [ ] **Step 2: Write the failing tests**

`ios/Packages/GymSync/Tests/GymSyncTests/SyncEngineServerScopeTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// A server that keeps neither gyms nor proposals (the API until plans 28 and 29): the round leaves them out and syncs
/// the rest. A busy or rate-limited server reads as offline.
@MainActor
@Suite struct SyncEngineServerScopeTests {
    let f: EngineFixture
    init() throws { f = try EngineFixture() }

    @Test func gymsAndProposalsWaitForAServerThatKeepsThem() async throws {
        defer { f.tearDown() }
        let server = FakeTransport(servesGyms: false, servesProposals: false)
        let engine = SyncEngine(store: f.store, transport: server, now: { [clock = f.clock] in clock.now })
        let gyms = GymRepository(context: f.container.mainContext, now: { [clock = f.clock] in clock.now })
        let gym = try gyms.addPrivateGym(name: "Home", address: nil)
        try gyms.makeSynced(gym: gym.id)
        await server.seed(proposal: ProposalDTO(id: UUID(), createdAt: f.clock.now, summary: "Heavier bench", changes: [
            PlanChange(id: "c1", type: .weight, routineId: UUID().uuidString.lowercased(), exerciseId: "bench",
                       weightKg: 65),
        ]))
        let workout = Workout(startedAt: f.clock.now, endedAt: f.clock.now.addingTimeInterval(600), name: "Push")
        try f.workouts.save(workout)

        await engine.sync()

        #expect(engine.status == .idle)
        #expect(await server.callLog == ["push:workout", "pull:workouts"])
        #expect(await server.workouts[workout.id] != nil)
        #expect(try f.store.dirtyGyms().map(\.value.id) == [gym.id], "the gym waits, still unsynced")
        #expect(try f.store.pendingProposalIds().isEmpty, "no proposal was pulled")
    }

    @Test func aBusyOrRateLimitedServerReadsAsOffline() {
        #expect(SyncEngine.status(for: ApiError(status: 503, code: "http_503", message: "")) == .offline)
        #expect(SyncEngine.status(for: ApiError(status: 429, code: "rate_limited", message: "")) == .offline)
        #expect(SyncEngine.status(for: URLError(.notConnectedToInternet)) == .offline)
        #expect(SyncEngine.status(for: ApiError(status: 400, code: "bad_request", message: ""))
            == .error("Couldn't sync. Your data is safe on this iPhone; we'll try again later."))
    }
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `cd ios/Packages/GymSync && swift test --filter SyncEngineServerScopeTests`
Expected: 2 tests fail.
- The first sees `"push:gyms"` and `"pull:gyms"` in the call log, and a pulled proposal.
- The second sees `.error(…)` for 503 and 429.

- [ ] **Step 4: Add the two properties to `SyncTransport`**

In `SyncTransport.swift`, add as the first requirements of `public protocol SyncTransport: Sendable {`:

```swift
    /// Whether this server keeps private gyms, listings and their photos. When false the engine leaves them out of the
    /// round, and they stay dirty here until a server that keeps them (the API from plan 28).
    var servesGyms: Bool { get }
    /// Whether this server keeps Claude's proposals. When false the engine neither pulls nor resolves them (the API
    /// until plan 29).
    var servesProposals: Bool { get }

```

and as the first members of `extension SyncTransport {`:

```swift
    /// Supabase and the test doubles keep both.
    public var servesGyms: Bool { true }
    public var servesProposals: Bool { true }

```

- [ ] **Step 5: Skip them in the round**

In `SyncEngine+Rounds.swift`, `pushAll()`, replace

```swift
        try await pushGyms()
        try await pushProposals()
```

with

```swift
        if transport.servesGyms { try await pushGyms() }
        if transport.servesProposals { try await pushProposals() }
```

In `pullAll()`, replace `try await pullGyms()` with `if transport.servesGyms { try await pullGyms() }`, and
`try await pullProposals()` with `if transport.servesProposals { try await pullProposals() }`.

- [ ] **Step 6: Read 5xx and 429 as offline**

In `SyncEngine.swift`, replace `status(for:)` with:

```swift
    static func status(for error: Error) -> SyncStatus {
        // Network failures, a busy server (5xx) and rate limits (429) are worth trying again, not reporting.
        if ApiError.isOffline(error) { return .offline }
        return .error("Couldn't sync. Your data is safe on this iPhone; we'll try again later.")
    }
```

In the class's doc comment, replace `network failures leave local data untouched and report \`.offline\`` with
`network failures, a busy server and rate limits leave local data untouched and report \`.offline\``.

- [ ] **Step 7: Run the tests**

Run: `cd ios/Packages/GymSync && swift test --filter GymSyncTests`
Expected: `Test run with 166 tests in 23 suites passed`.

- [ ] **Step 8: Commit**

```bash
git add ios/Packages/GymSync
git commit -m "feat(sync): the round leaves out gyms or proposals a server lacks, and 5xx and 429 read as offline"
```

- [ ] **Step 9: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** decisions 4 and 10, and spec section 6's offline cases.
2. **Quality:** the `code-reviewer` agent. The push and pull orders are otherwise unchanged.

### Task 4: `ApiSyncTransport`

**Files:**
- Create: `ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport.swift`
- Modify: `ios/Packages/GymSync/Sources/GymSync/KeysetPager.swift`
- Modify: `ios/Packages/GymSync/Tests/GymSyncTests/KeysetPagerTests.swift`
- Test: `ios/Packages/GymSync/Tests/GymSyncTests/ApiSyncTransportTests.swift`

The bodies below are the server's (`server/src/sync/routes.ts`, `table-sync.ts`, `workouts.ts`, `entities.ts`):

| Call | Body | Answer |
|---|---|---|
| `POST /v1/sync/<entity>` | `{"rows": [DTO…]}` (at most 500; the app sends 200) | `{"acks": [{"id", "updated_at"}]}` for rows stored |
| `GET /v1/sync/<entity>?since&after&limit` | `limit` 1–1000; `after` needs `since`, and is a whole number for weekdays | `{"rows": [DTO + updated_at (+ user_id on the profile)]}` |
| `POST /v1/sync/workouts` | the `WorkoutDTO` itself, with `entries[].sets[]`, `base_updated_at`, `force` | `{"status": "ok"\|"stale", "updated_at"}` |
| `GET /v1/sync/workouts[?…]` | as above, `limit` counts workouts | `{"rows": [workout + entries[].sets[]]}` |
| `GET /v1/sync/workouts/:id` | | the workout, or 404 `not_found` |

The entities are `profile`, `custom-exercises`, `exercise-prefs`, `routines`, `weekdays`, `muscle-targets`,
`bodyweight`. Their tiebreaks are `user_id`, `id`, `exercise_id`, `id`, `weekday`, `muscle`, `id`; `id` for workouts.
The profile's ack id is the account's id, and the weekday's is `"1"`…`"7"`.

- [ ] **Step 1: Write the failing tests**

`ios/Packages/GymSync/Tests/GymSyncTests/ApiSyncTransportTests.swift`:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// `ApiSyncTransport` against a stub of `/v1/sync`: the bodies, queries and answers of server/src/sync/routes.ts.
@Suite struct ApiSyncTransportTests {
    private let t0 = SyncDate.parse("2026-09-27T08:00:00.123456Z")!

    private func rows(_ request: SeenRequest) -> [[String: Any]] {
        ((try? request.json()) as? [String: Any])?["rows"] as? [[String: Any]] ?? []
    }

    @Test func rowsGoUpUnderRowsAndComeBackAsAcks() async throws {
        let routine = Routine(name: "Push", exercises: [])
        let id = routine.id.uuidString.lowercased()
        let answer = #"{"acks": [{"id": "\#(id)", "updated_at": "2026-11-08T10:00:00.123000Z"}]}"#
        let server = StubServer { _ in .json(200, answer) }
        let dto = RoutineDTO(SyncRow(value: RoutineSnapshot(routine: routine, position: 0), clientUpdatedAt: t0))

        let acks = try await ApiSyncTransport(api: server.client()).push(routines: [dto])

        #expect(acks == [RowAck(id: id, updatedAt: SyncDate.parse("2026-11-08T10:00:00.123Z")!)])
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/v1/sync/routines")
        #expect(rows(request).first?["name"] as? String == "Push")
        #expect(rows(request).first?["client_updated_at"] as? String == "2026-09-27T08:00:00.123456Z")
    }

    @Test func everyTablePullsFromItsOwnPath() async throws {
        let server = StubServer { _ in .json(200, #"{"rows": []}"#) }
        let transport = ApiSyncTransport(api: server.client())
        _ = try await transport.pullProfile(since: nil)
        _ = try await transport.pullCustomExercises(since: nil)
        _ = try await transport.pullExercisePrefs(since: nil)
        _ = try await transport.pullRoutines(since: nil)
        _ = try await transport.pullWeekdays(since: nil)
        _ = try await transport.pullMuscleTargets(since: nil)
        _ = try await transport.pullBodyweight(since: nil)
        _ = try await transport.pullWorkouts(since: nil)
        #expect(server.requests.map(\.path) == [
            "/v1/sync/profile", "/v1/sync/custom-exercises", "/v1/sync/exercise-prefs", "/v1/sync/routines",
            "/v1/sync/weekdays", "/v1/sync/muscle-targets", "/v1/sync/bodyweight", "/v1/sync/workouts",
        ])
        #expect(server.requests.map { $0.query["limit"] ?? "" } == Array(repeating: "500", count: 7) + ["50"])
    }

    @Test func theProfileAckIsTheProfilesFixedId() async throws {
        let accountId = "b73f3bdc-18c8-400a-b492-4db321b4baee"
        let server = StubServer { _ in
            .json(200, #"{"acks": [{"id": "\#(accountId)", "updated_at": "2026-11-08T10:00:00.123000Z"}]}"#)
        }
        let profile = ProfileDTO(SyncRow(value: ProfileSnapshot(), clientUpdatedAt: t0))
        #expect(try await ApiSyncTransport(api: server.client()).push(profile: profile)?.id == SyncStore.profileSyncID)
        #expect(server.requests.first?.path == "/v1/sync/profile")
        let keptNewer = StubServer { _ in .json(200, #"{"acks": []}"#) }
        #expect(try await ApiSyncTransport(api: keptNewer.client()).push(profile: profile) == nil)
    }

    @Test func pushesGoUpTwoHundredRowsAtATime() async throws {
        let server = StubServer { _ in .json(200, #"{"acks": []}"#) }
        let entries = (0..<450).map {
            BodyweightDTO(SyncRow(value: BodyweightEntry(date: t0 + Double($0), weightKg: 80), clientUpdatedAt: t0))
        }
        _ = try await ApiSyncTransport(api: server.client()).push(bodyweight: entries)
        #expect(server.requests.map { rows($0).count } == [200, 200, 50])
        #expect(server.requests.allSatisfy { $0.path == "/v1/sync/bodyweight" })
    }

    @Test func pullsPageBySinceAfterAndLimitUntilAShortPage() async throws {
        // Five weigh-ins, the first three written by one statement (one stamp), served in the server's keyset order.
        let stamps = ["2026-11-08T10:00:00.100000Z", "2026-11-08T10:00:00.100000Z", "2026-11-08T10:00:00.100000Z",
                      "2026-11-08T10:00:00.200000Z", "2026-11-08T10:00:00.300000Z"]
        let ids = (1...5).map { String(format: "00000000-0000-4000-8000-%012d", $0) }
        let stored = Array(zip(ids, stamps))
        let server = StubServer { request in
            let since = request.query["since"], after = request.query["after"]
            let limit = Int(request.query["limit"] ?? "") ?? 500
            let page = stored.filter { id, at in
                guard let since else { return true }
                guard let after else { return at > since }
                return at > since || (at == since && id > after)
            }.prefix(limit).map { id, at in
                #"{"id": "\#(id)", "measured_at": "2026-09-27T08:00:00.000000Z", "w_kg": 80, "bf_pct": null, "t": null, "#
                    + #""source": null, "health_sample_id": null, "health_fat_sample_id": null, "#
                    + #""client_updated_at": "2026-09-27T08:00:00.000000Z", "deleted_at": null, "updated_at": "\#(at)"}"#
            }
            return .json(200, #"{"rows": [\#(page.joined(separator: ","))]}"#)
        }

        let pulled = try await ApiSyncTransport(api: server.client(), pageSize: 2).pullBodyweight(since: nil)

        #expect(pulled.map { $0.id.uuidString.lowercased() } == ids)
        #expect(server.requests.map(\.query) == [
            ["limit": "2"],
            ["limit": "2", "since": stamps[1], "after": ids[1]],
            ["limit": "2", "since": stamps[3], "after": ids[3]],
        ])
    }

    @Test func theWeekdayTiebreakGoesUpAsANumber() async throws {
        let server = StubServer { request in
            let rows = request.query["after"] == nil
                ? #"[{"weekday": 3, "routine_id": null, "client_updated_at": "2026-09-27T08:00:00.000000Z", "#
                    + #""updated_at": "2026-11-08T10:00:00.100000Z"}]"#
                : "[]"
            return .json(200, #"{"rows": \#(rows)}"#)
        }
        _ = try await ApiSyncTransport(api: server.client(), pageSize: 1).pullWeekdays(since: nil)
        #expect(server.requests.last?.query["after"] == "3")
    }

    @Test func aWorkoutGoesUpAloneWithItsBaseVersionAndEntries() async throws {
        let server = StubServer { _ in .json(200, #"{"status": "stale", "updated_at": "2026-11-08T10:00:00.100000Z"}"#) }
        let workout = Workout(startedAt: t0, endedAt: t0 + 600, name: "Push", entries: [
            WorkoutEntry(exerciseId: "bench", sets: [WorkoutSet(weightKg: 60, reps: 8, done: true)]),
        ])
        let base = SyncDate.parse("2026-11-07T09:00:00.000001Z")!
        let dto = WorkoutDTO(SyncRow(value: WorkoutSnapshot(workout: workout, records: [], volumeKg: 480),
                                     clientUpdatedAt: t0 + 600, serverUpdatedAt: base))

        let result = try await ApiSyncTransport(api: server.client()).push(workout: dto)

        #expect(result == .stale(updatedAt: SyncDate.parse("2026-11-08T10:00:00.1Z")!))
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/v1/sync/workouts")
        let body = try #require(try request.json() as? [String: Any])
        #expect(body["id"] as? String == workout.id.uuidString)
        #expect(body["base_updated_at"] as? String == "2026-11-07T09:00:00.000001Z")
        #expect(body["force"] as? Bool == false)
        let entries = try #require(body["entries"] as? [[String: Any]])
        #expect((entries.first?["sets"] as? [Any])?.count == 1)
    }

    @Test func fetchingAMissingWorkoutIsNil() async throws {
        let server = StubServer { _ in .json(404, #"{"error": {"code": "not_found", "message": "No such workout."}}"#) }
        let id = UUID()
        #expect(try await ApiSyncTransport(api: server.client()).fetchWorkout(id: id) == nil)
        #expect(server.requests.first?.path == "/v1/sync/workouts/\(id.uuidString.lowercased())")
    }

    @Test func refusedRowsBecomeRowRejectionsAndTheRestEndsTheRound() async throws {
        let row = BodyweightDTO(SyncRow(value: BodyweightEntry(date: t0, weightKg: 500), clientUpdatedAt: t0))
        func push(_ status: Int, _ code: String, _ message: String) async throws {
            let server = StubServer { _ in .json(status, #"{"error": {"code": "\#(code)", "message": "\#(message)"}}"#) }
            _ = try await ApiSyncTransport(api: server.client()).push(bodyweight: [row])
        }
        await #expect(throws: SyncRecordRejected(code: "row_rejected",
                                                 message: "CHECK constraint failed: w_kg BETWEEN 30 AND 300")) {
            try await push(422, "row_rejected", "CHECK constraint failed: w_kg BETWEEN 30 AND 300")
        }
        await #expect(throws: SyncRecordRejected(code: "not_allowed",
                                                 message: "This belongs to another account and can't be synced.")) {
            try await push(403, "not_allowed", "That row belongs to another account.")
        }
        await #expect(throws: SyncRecordRejected(code: "too_large", message: "The request body is too large.")) {
            try await push(413, "too_large", "The request body is too large.")
        }
        await #expect(throws: ApiError(status: 401, code: "signed_out", message: "Sign in required.")) {
            try await push(401, "signed_out", "Sign in required.")
        }
        await #expect(throws: ApiError(status: 503, code: "server_error", message: "Something went wrong.")) {
            try await push(503, "server_error", "Something went wrong.")
        }
    }

    @Test func itServesNeitherGymsNorProposalsYet() async throws {
        let server = StubServer { _ in .json(500, "{}") }
        let transport = ApiSyncTransport(api: server.client())
        #expect(!transport.servesGyms && !transport.servesProposals)
        #expect(try await transport.pendingProposals().isEmpty)
        #expect(server.requests.isEmpty)
    }
}
```

At the end of the `KeysetPagerTests` suite in `KeysetPagerTests.swift` (after `keyRowDecodesUUIDAndIntTiebreaks`), add:

```swift

    @Test func keyRowsAlsoComeFromTheAPIsRowsObject() throws {
        let page = Data(#"{"rows": [{"user_id": "b73f3bdc-18c8-400a-b492-4db321b4baee", "updated_at": "2026-11-08T10:00:00.123000Z"}]}"#.utf8)
        #expect(try PageKey.decode(page, tiebreak: "user_id").first?.tiebreak == "b73f3bdc-18c8-400a-b492-4db321b4baee")
        #expect(try PageKey.decode(Data(#"{"rows": []}"#.utf8), tiebreak: "id").isEmpty)
    }
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd ios/Packages/GymSync && swift test --filter 'ApiSyncTransportTests|KeysetPagerTests'`
Expected: the build fails with `cannot find 'ApiSyncTransport' in scope`.

- [ ] **Step 3: Read the API's page shape in `PageKey.decode`**

In `KeysetPager.swift`, replace

```swift
    /// Reads each row's `updated_at` and tiebreak column from a PostgREST response (other columns are ignored).
    static func decode(_ data: Data, tiebreak column: String) throws -> [PageKey] {
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
```

with

```swift
    /// Reads each row's `updated_at` and tiebreak column from a pulled page: the API's `{"rows": [...]}` or PostgREST's
    /// bare array. Other columns are ignored.
    static func decode(_ data: Data, tiebreak column: String) throws -> [PageKey] {
        let page = try JSONSerialization.jsonObject(with: data)
        guard let rows = (page as? [[String: Any]]) ?? ((page as? [String: Any])?["rows"] as? [[String: Any]]) else {
```

- [ ] **Step 4: Write `ApiSyncTransport`**

`ios/Packages/GymSync/Sources/GymSync/ApiSyncTransport.swift`:

```swift
import Foundation
import GymData

/// `SyncTransport` over the API's `/v1/sync` (server/src/sync/routes.ts; spec section 3, "Routes"). The server scopes
/// every call to the session's account.
/// - Rows go up as `POST /v1/sync/<entity>` `{"rows": [...]}`, 200 a request, and the answer acks the rows stored. A row
///   the server's last-write-wins skipped gets no ack, as with `lww_guard`.
/// - Pulls are keyset pages, `GET /v1/sync/<entity>?since&after&limit` answered `{"rows": [...]}`: `since` alone means
///   newer than it; with `after`, the rows after `(since, after)` in `(updated_at, tiebreak)` order.
/// - A workout goes up alone, with its entries, sets and base version, and is answered `{"status", "updated_at"}`.
///   Pulled workouts carry `entries[].sets[]`, so their pages are smaller.
///
/// Gyms, listings, their photos and Claude's proposals aren't on the API until plans 28 and 29, so `servesGyms` and
/// `servesProposals` are false and the engine leaves them out. Claude's last use and grants keep the protocol's
/// defaults (never used, nothing to revoke) until plan 29.
public struct ApiSyncTransport: SyncTransport {
    public static let defaultPageSize = 500
    /// A workout page carries every entry and set. The owner averages 6 entries and 18 sets a workout, so 50 workouts
    /// are about a thousand rows: small enough for one request within the Worker's free-plan CPU time.
    public static let defaultWorkoutPageSize = 50
    static let pushBatchSize = 200
    /// What a refused row says when another account holds its id (403 `not_allowed`).
    static let notYoursMessage = "This belongs to another account and can't be synced."

    let api: ApiClient
    private let pageSize: Int
    private let workoutPageSize: Int

    /// The page sizes are for tests, which use small ones to exercise paging.
    public init(api: ApiClient, pageSize: Int = ApiSyncTransport.defaultPageSize,
                workoutPageSize: Int = ApiSyncTransport.defaultWorkoutPageSize) {
        self.api = api
        self.pageSize = max(1, pageSize)
        self.workoutPageSize = max(1, workoutPageSize)
    }

    public var servesGyms: Bool { false }
    public var servesProposals: Bool { false }

    // MARK: Push

    public func push(profile: ProfileDTO) async throws -> RowAck? {
        // The server's ack id is the account's id; the engine knows the profile by its fixed id.
        try await push([profile], to: "profile").first.map { RowAck(id: SyncStore.profileSyncID, updatedAt: $0.updatedAt) }
    }

    public func push(customExercises: [CustomExerciseDTO]) async throws -> [RowAck] {
        try await push(customExercises, to: "custom-exercises")
    }

    public func push(exercisePrefs: [ExercisePrefDTO]) async throws -> [RowAck] {
        try await push(exercisePrefs, to: "exercise-prefs")
    }

    public func push(routines: [RoutineDTO]) async throws -> [RowAck] {
        try await push(routines, to: "routines")
    }

    public func push(weekdays: [WeekdayDTO]) async throws -> [RowAck] {
        try await push(weekdays, to: "weekdays")
    }

    public func push(muscleTargets: [MuscleTargetDTO]) async throws -> [RowAck] {
        try await push(muscleTargets, to: "muscle-targets")
    }

    public func push(bodyweight: [BodyweightDTO]) async throws -> [RowAck] {
        try await push(bodyweight, to: "bodyweight")
    }

    public func push(workout: WorkoutDTO) async throws -> WorkoutPushResult {
        try await Self.mappingRejections { try await api.post("/v1/sync/workouts", workout) }
    }

    // MARK: Pull

    public func pullProfile(since: Date?) async throws -> [ProfileDTO] {
        try await pull("profile", tiebreak: "user_id", since: since)
    }

    public func pullCustomExercises(since: Date?) async throws -> [CustomExerciseDTO] {
        try await pull("custom-exercises", tiebreak: "id", since: since)
    }

    public func pullExercisePrefs(since: Date?) async throws -> [ExercisePrefDTO] {
        try await pull("exercise-prefs", tiebreak: "exercise_id", since: since)
    }

    public func pullRoutines(since: Date?) async throws -> [RoutineDTO] {
        try await pull("routines", tiebreak: "id", since: since)
    }

    public func pullWeekdays(since: Date?) async throws -> [WeekdayDTO] {
        try await pull("weekdays", tiebreak: "weekday", since: since)
    }

    public func pullMuscleTargets(since: Date?) async throws -> [MuscleTargetDTO] {
        try await pull("muscle-targets", tiebreak: "muscle", since: since)
    }

    public func pullBodyweight(since: Date?) async throws -> [BodyweightDTO] {
        try await pull("bodyweight", tiebreak: "id", since: since)
    }

    public func pullWorkouts(since: Date?) async throws -> [WorkoutDTO] {
        try await pull("workouts", tiebreak: "id", pageSize: workoutPageSize, since: since)
    }

    public func fetchWorkout(id: UUID) async throws -> WorkoutDTO? {
        do {
            return try await api.get("/v1/sync/workouts/\(id.uuidString.lowercased())")
        } catch let error as ApiError where error.status == 404 {
            return nil
        }
    }

    // MARK: Not on the API yet (plan 29)

    /// Never called while `servesProposals` is false.
    public func pendingProposals() async throws -> [PulledProposal] { [] }

    /// Never called while `servesProposals` is false; if it were, the resolution would stay unsent rather than count
    /// as sent.
    public func resolveProposal(id: UUID, status: String, appliedChangeIds: [String], at: Date) async throws {
        throw ApiError(status: 404, code: "not_found", message: "Proposals aren't on this server yet.")
    }

    // MARK: - Helpers

    private func push<Row: Encodable>(_ rows: [Row], to entity: String) async throws -> [RowAck] {
        var acks: [RowAck] = []
        for start in stride(from: 0, to: rows.count, by: Self.pushBatchSize) {
            let batch = Array(rows[start..<min(start + Self.pushBatchSize, rows.count)])
            let answer: AckList = try await Self.mappingRejections {
                try await api.post("/v1/sync/\(entity)", RowList(rows: batch))
            }
            acks += answer.acks.map { RowAck(id: $0.id, updatedAt: $0.updatedAt) }
        }
        return acks
    }

    private func pull<Row: Decodable>(_ entity: String, tiebreak: String, pageSize: Int? = nil,
                                      since: Date?) async throws -> [Row] {
        try await KeysetPager.collect(pageSize: pageSize ?? self.pageSize, since: since) { after, since, limit in
            var query = [URLQueryItem(name: "limit", value: String(limit))]
            if let after {
                query.append(URLQueryItem(name: "since", value: SyncDate.format(after.updatedAt)))
                query.append(URLQueryItem(name: "after", value: after.tiebreak))
            } else if let since {
                query.append(URLQueryItem(name: "since", value: SyncDate.format(since)))
            }
            let (body, _) = try await api.data("GET", "/v1/sync/\(entity)", query: query)
            let rows = try SyncJSON.decoder.decode(RowList<Row>.self, from: body).rows
            let keys = try PageKey.decode(body, tiebreak: tiebreak)
            guard rows.count == keys.count else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Page keys don't match rows"))
            }
            return Array(zip(rows, keys)).map { (row: $0, key: $1) }
        }
    }

    /// A row refused for its values (422, `row_rejected`: a CHECK, a foreign key or a wrong type), for an id another
    /// account holds (403 `not_allowed`), or for being too big (413 `too_large`) is about that row alone: the engine
    /// records it and syncs the rest, as with SQLSTATE 22/23. Anything else (signed out, server trouble) ends the round.
    static func mappingRejections<R>(_ call: () async throws -> R) async throws -> R {
        do {
            return try await call()
        } catch let error as ApiError {
            switch error.code {
            case "not_allowed": throw SyncRecordRejected(code: error.code, message: notYoursMessage)
            case "row_rejected", "too_large": throw SyncRecordRejected(code: error.code, message: error.message)
            default: throw error.status == 422 ? SyncRecordRejected(code: error.code, message: error.message) : error
            }
        }
    }
}

/// `{"rows": [...]}`: what a push sends and a pull answers.
private struct RowList<Row> {
    let rows: [Row]
}

extension RowList: Encodable where Row: Encodable {}
extension RowList: Decodable where Row: Decodable {}

/// `{"acks": [{"id", "updated_at"}]}`.
private struct AckList: Decodable {
    struct Ack: Decodable {
        let id: String
        let updatedAt: Date

        enum CodingKeys: String, CodingKey { case id, updatedAt = "updated_at" }
    }

    let acks: [Ack]
}
```

- [ ] **Step 5: Run the tests**

Run: `cd ios/Packages/GymSync && swift test --filter GymSyncTests`
Expected: `Test run with 177 tests in 24 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add ios/Packages/GymSync
git commit -m "feat(sync): ApiSyncTransport on /v1/sync, with workouts paged by 50"
```

- [ ] **Step 7: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** decisions 6, 7 and 10. Check every path, body, query and answer against `server/src/sync/` and
   `server/test/sync-rows.test.ts`, `sync-workouts.test.ts`. The server is the source of truth.
2. **Quality:** the `code-reviewer` agent.

### Task 5: The server move in GymData

**Files:**
- Create: `ios/Packages/GymData/Sources/GymData/Sync/SyncStore+ServerMove.swift`
- Test: `ios/Packages/GymData/Tests/GymDataTests/SyncStoreServerMoveTests.swift`

Where the state lives, which the move clears:
- Owner and recorded refusals: UserDefaults `gymrollins.sync.owner` and `gymrollins.sync.failures`
  (`SyncStore+Ownership.swift`).
- Pull cursors: `gymrollins.sync.cursor.<entity>` (`SyncStore.swift`).
- `serverUpdatedAt` and `dirty`: on every `SyncTracked` record (`SyncStore.swift`, `SyncStore+Preferences.swift`).
- Listings' `remotePhotoPath` (`GymRecords.swift`) and proposals' `dirty` and `serverUpdatedAt` (`ProposalRecord.swift`).

- [ ] **Step 1: Write the failing tests**

`ios/Packages/GymData/Tests/GymDataTests/SyncStoreServerMoveTests.swift`:

```swift
import Foundation
import GymCore
import SwiftData
import Testing
@testable import GymData

/// The server move (spec section 4): a launch against another API hands the data to the next account that signs in and
/// marks every synced record unsynced, deleting nothing but Claude's pending proposals.
@MainActor
@Suite struct SyncStoreServerMoveTests {
    let f: SyncFixture
    init() throws { f = try SyncFixture() }

    private let old = "http://127.0.0.1:55421"
    private let new = "http://127.0.0.1:8787"

    private var gyms: GymRepository { GymRepository(context: f.context, now: { [clock = f.clock] in clock.now }) }
    private var proposals: ProposalRepository {
        ProposalRepository(context: f.context, now: { [clock = f.clock] in clock.now })
    }

    /// What a finished round on the old server leaves: every dirty row acknowledged with a server version.
    private func syncEverything() throws {
        let s = f.store
        let at = f.clock.now
        if let row = try s.dirtyProfile() {
            try s.markSynced(.profile, id: SyncStore.profileSyncID, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyCustomExercises() {
            try s.markSynced(.customExercises, id: row.value.id, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: at)
        }
        for row in try s.dirtyExercisePreferences() {
            try s.markSynced(.exercisePreferences, id: row.value.exerciseId, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyRoutines() {
            try s.markSynced(.routines, id: row.value.routine.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyWeekdays() {
            try s.markSynced(.weekSchedule, id: String(row.value.weekday), clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyMuscleTargets() {
            try s.markSynced(.muscleTargets, id: row.value.group.rawValue, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyGyms() {
            try s.markSynced(.gyms, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt, serverUpdatedAt: at)
        }
        for row in try s.dirtyGymListings() {
            try s.markSynced(.gymListings, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyBodyweight() {
            try s.markSynced(.bodyweight, id: row.value.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
        for row in try s.dirtyWorkouts() {
            try s.markSynced(.workouts, id: row.value.workout.id.uuidString, clientUpdatedAt: row.clientUpdatedAt,
                             serverUpdatedAt: at)
        }
    }

    private func dirtyCount() throws -> Int {
        let s = f.store
        var count = try s.dirtyProfile() == nil ? 0 : 1
        count += try s.dirtyCustomExercises().count
        count += try s.dirtyExercisePreferences().count
        count += try s.dirtyRoutines().count
        count += try s.dirtyWeekdays().count
        count += try s.dirtyMuscleTargets().count
        count += try s.dirtyGyms().count
        count += try s.dirtyGymListings().count
        count += try s.dirtyBodyweight().count
        count += try s.dirtyWorkouts().count
        return count
    }

    /// One of everything that syncs, synced to the old server by `owner`, with every cursor set.
    @discardableResult
    private func syncedAccount(owner: UUID = UUID()) throws -> Workout {
        try f.profiles.save(Profile(unit: .kg))
        let routine = sampleRoutine()
        try f.routines.upsert(routine)
        try f.routines.setSchedule(weekday: 1, routineId: routine.id)
        _ = try f.custom.create(name: "Sled", bodyPart: "legs", equipment: "sled", target: "quads", mode: .reps,
                                bilateral: false)
        try ExercisePreferenceRepository(context: f.context, now: { [clock = f.clock] in clock.now })
            .set(.more, for: "bench")
        try MuscleTargetRepository(context: f.context, now: { [clock = f.clock] in clock.now })
            .set(.chest, SetTargetRange(min: 12, max: 18))
        try f.body.add(BodyweightEntry(date: f.clock.now, weightKg: 81))
        let workout = sampleWorkout(at: f.clock.now)
        try f.workouts.save(workout)
        try syncEverything()
        f.store.ownerUserId = owner
        for entity in SyncEntity.allCases { f.store.setCursor(f.clock.now, for: entity) }
        f.store.syncedServer = old
        return workout
    }

    private func listingRecord(_ id: UUID) throws -> GymListingRecord {
        try #require(try f.context.fetch(FetchDescriptor<GymListingRecord>(predicate: #Predicate { $0.id == id })).first)
    }

    @Test func aFirstLaunchWithNothingFromAServerOnlyRemembersIt() throws {
        defer { f.tearDown() }
        try f.routines.upsert(sampleRoutine()) // made before ever signing in: dirty, no owner, no server version
        #expect(try !f.store.moveToServer(new))
        #expect(f.store.syncedServer == new)
        #expect(try f.store.dirtyRoutines().count == 1)
    }

    @Test func theSameServerChangesNothing() throws {
        defer { f.tearDown() }
        let owner = UUID()
        try syncedAccount(owner: owner)
        f.store.syncedServer = new
        #expect(try !f.store.moveToServer(new))
        #expect(f.store.ownerUserId == owner)
        #expect(f.store.cursor(for: .workouts) != nil)
        #expect(try dirtyCount() == 0)
    }

    @Test func anotherServerHandsTheDataToTheNextAccountAndDeletesNothing() throws {
        defer { f.tearDown() }
        let workout = try syncedAccount()
        let edited = try #require(try f.context.fetch(FetchDescriptor<WorkoutRecord>()).first?.updatedAt)
        f.store.recordSyncFailure(SyncFailure(entity: .routines, id: UUID().uuidString, clientUpdatedAt: f.clock.now,
                                              message: "refused"))
        #expect(try dirtyCount() == 0)

        #expect(try f.store.moveToServer(new))

        #expect(f.store.ownerUserId == nil)
        #expect(SyncEntity.allCases.allSatisfy { f.store.cursor(for: $0) == nil })
        #expect(f.store.syncFailures().isEmpty)
        #expect(f.store.syncedServer == new)
        #expect(try dirtyCount() == 8, "profile, custom exercise, preference, routine, weekday, target, weigh-in, workout")
        let row = try #require(try f.store.dirtyWorkouts().first)
        #expect(row.value.workout.id == workout.id)
        #expect(row.serverUpdatedAt == nil, "it goes up with no base version, as a new workout")
        #expect(row.clientUpdatedAt == edited, "the edit time stays, so last-write-wins compares real edits")
        #expect(try f.workouts.workout(workout.id) != nil)
    }

    @Test func noRecordedServerCountsAsAnother() throws {
        defer { f.tearDown() }
        try syncedAccount()
        f.store.syncedServer = nil // the owner's phone today: synced to Supabase, which recorded nothing
        #expect(try f.store.moveToServer(new))
        #expect(f.store.ownerUserId == nil)
    }

    @Test func syncedGymsAndListingsMoveAndThisPhoneOnlyOnesStayPut() throws {
        defer { f.tearDown() }
        let synced = try gyms.addPrivateGym(name: "Home", address: nil)
        let listing = try gyms.addListing(NewListing(gymId: synced.id, kindId: "cable-stack", photoFile: "p.jpg"))
        try gyms.makeSynced(listing: listing.id)
        let phoneOnly = try gyms.addPrivateGym(name: "Garage", address: nil)
        let kept = try gyms.addListing(NewListing(gymId: phoneOnly.id, kindId: "cable-stack"))
        try syncEverything()
        try f.store.setRemotePhotoPath(listingId: listing.id, path: "old-server.jpg")
        f.store.ownerUserId = UUID()
        let before = try listingRecord(kept.id)
        let keptState = (before.dirty, before.updatedAt, before.visibilityRaw)

        #expect(try f.store.moveToServer(new))

        #expect(try f.store.dirtyGyms().map(\.value.id) == [synced.id])
        let moved = try #require(try f.store.dirtyGymListings().first)
        #expect(moved.value.id == listing.id)
        #expect(moved.serverUpdatedAt == nil)
        #expect(moved.value.remotePhotoPath == nil, "the picture uploads again to the new server")
        #expect(moved.value.photoFile == "p.jpg")
        let after = try listingRecord(kept.id)
        #expect(after.dirty == keptState.0 && after.updatedAt == keptState.1 && after.visibilityRaw == keptState.2)
    }

    @Test func pendingProposalsGoAndResolutionsCountAsSent() throws {
        defer { f.tearDown() }
        let pending = Proposal(id: UUID(), createdAt: f.clock.now, summary: "Heavier bench", changes: [
            PlanChange(id: "c1", type: .weight, routineId: UUID().uuidString.lowercased(), exerciseId: "bench",
                       weightKg: 65),
        ])
        let dismissed = Proposal(id: UUID(), createdAt: f.clock.now, summary: "Fewer sets", changes: [
            PlanChange(id: "c1", type: .sets, routineId: UUID().uuidString.lowercased(), exerciseId: "bench", sets: 2),
        ])
        try f.store.applyRemote(proposals: [pending, dismissed])
        try proposals.dismiss(dismissed.id) // resolved here, not yet sent
        f.store.ownerUserId = UUID()

        #expect(try f.store.moveToServer(new))

        #expect(try f.store.pendingProposalIds().isEmpty)
        #expect(try f.store.dirtyProposals().isEmpty, "the new server never had it to resolve")
        #expect(try proposals.proposal(dismissed.id)?.status == .dismissed)
    }

    @Test func aWorkoutAtAMovedGymGoesUpWithoutItsLinkAndKeepsItHere() throws {
        defer { f.tearDown() }
        let gym = try gyms.addPrivateGym(name: "Home", address: nil)
        try gyms.makeSynced(gym: gym.id)
        let workout = sampleWorkout(at: f.clock.now).with(gymId: gym.id)
        try f.workouts.save(workout)
        try syncEverything()
        f.store.ownerUserId = UUID()

        try f.store.moveToServer(new)

        let sent = try #require(try f.store.dirtyWorkouts().first)
        #expect(sent.value.workout.gymId == nil, "the new server hasn't got the gym yet")
        try f.store.markSynced(.workouts, id: workout.id.uuidString, clientUpdatedAt: sent.clientUpdatedAt,
                               serverUpdatedAt: f.clock.now)
        let echoed = SyncRow(value: WorkoutSnapshot(workout: workout.with(gymId: nil), records: [], volumeKg: 0),
                             clientUpdatedAt: sent.clientUpdatedAt, serverUpdatedAt: f.clock.now)
        try f.store.applyRemote(workouts: [echoed])
        #expect(try f.workouts.workout(workout.id)?.gymId == gym.id, "the server's null doesn't replace the local link")
    }

    @Test func theMoveRunsOnce() throws {
        defer { f.tearDown() }
        try syncedAccount()
        #expect(try f.store.moveToServer(new))
        try syncEverything()
        f.store.ownerUserId = UUID() // the account that signed in afterwards
        #expect(try !f.store.moveToServer(new))
        #expect(f.store.ownerUserId != nil)
        #expect(try dirtyCount() == 0)
    }
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd ios/Packages/GymData && swift test --filter SyncStoreServerMoveTests`
Expected: the build fails with `value of type 'SyncStore' has no member 'syncedServer'` and
`… no member 'moveToServer'`.

- [ ] **Step 3: Write the move**

`ios/Packages/GymData/Sources/GymData/Sync/SyncStore+ServerMove.swift`:

```swift
import Foundation
import SwiftData

// The server move (docs/specs/2026-11-07-cloudflare-backend-design.md, section 4): when this build talks to another API
// than the one the data last synced with, the local copy goes to the next account that signs in, and every record that
// synced goes up again. Nothing is deleted except Claude's pending proposals, which only the old server could resolve.
extension SyncStore {
    private static let serverKey = "gymrollins.sync.server"

    /// The API this phone's data last synced with (`ApiConfig.origin`); nil until a launch records one.
    public var syncedServer: String? {
        get { defaults.string(forKey: Self.serverKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.serverKey) }
            else { defaults.removeObject(forKey: Self.serverKey) }
        }
    }

    /// Run at launch, before the session is restored, with the API this build talks to. When another server (or none)
    /// is recorded and the data carries an owner, a pull cursor or a server version, the move runs:
    /// - the owner, the cursors and the recorded refusals are forgotten;
    /// - every record that syncs with the account loses its server version and goes dirty, keeping its edit time;
    /// - synced listings forget the old server's photo names, so pictures on this phone upload again;
    /// - pending proposals go, and resolutions not yet sent count as sent.
    /// Then `server` is recorded. The store is saved before anything in `defaults` changes, so a move that fails runs
    /// again at the next launch. Returns whether the move ran.
    @discardableResult
    public func moveToServer(_ server: String) throws -> Bool {
        guard syncedServer != server else { return false }
        let moves = try hasServerState()
        if moves {
            try markEverythingUnsynced()
            for entity in SyncEntity.allCases { clearCursor(for: entity) }
            forgetOwnershipAndFailures()
        }
        syncedServer = server
        return moves
    }

    /// An owner, a pull cursor, or a record holding a server version.
    private func hasServerState() throws -> Bool {
        if ownerUserId != nil || SyncEntity.allCases.contains(where: { cursor(for: $0) != nil }) { return true }
        return try accountRecords().contains { $0.serverUpdatedAt != nil }
    }

    private func markEverythingUnsynced() throws {
        for record in try accountRecords() {
            record.serverUpdatedAt = nil
            record.dirty = true
        }
        let synced = GymVisibility.synced.rawValue
        for listing in try context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.visibilityRaw == synced })) {
            listing.remotePhotoPath = nil
        }
        let pending = ProposalStatus.pending.rawValue
        for proposal in try context.fetch(FetchDescriptor<ProposalRecord>()) {
            if proposal.statusRaw == pending {
                context.delete(proposal)
            } else {
                proposal.dirty = false
                proposal.serverUpdatedAt = nil
            }
        }
        try context.save()
    }

    /// Every record that syncs with the account: the aggregate roots, and the gyms and listings synced to it ("This
    /// phone only" rows and the shared catalogue's are left alone).
    private func accountRecords() throws -> [any SyncTracked] {
        let synced = GymVisibility.synced.rawValue
        var records: [any SyncTracked] = []
        records += try every(ProfileRecord.self)
        records += try every(CustomExerciseRecord.self)
        records += try every(ExercisePreferenceRecord.self)
        records += try every(RoutineRecord.self)
        records += try every(WeekdayRecord.self)
        records += try every(MuscleTargetRecord.self)
        records += try every(BodyweightRecord.self)
        records += try every(WorkoutRecord.self)
        records += try context.fetch(FetchDescriptor<GymRecord>(predicate: #Predicate { $0.visibilityRaw == synced }))
            .map { $0 as any SyncTracked }
        records += try context.fetch(FetchDescriptor<GymListingRecord>(
            predicate: #Predicate { $0.visibilityRaw == synced })).map { $0 as any SyncTracked }
        return records
    }

    private func every<T: PersistentModel & SyncTracked>(_ type: T.Type) throws -> [any SyncTracked] {
        try context.fetch(FetchDescriptor<T>()).map { $0 as any SyncTracked }
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `cd ios/Packages/GymData && swift test`
Expected: `Test run with 363 tests in 49 suites passed`.

- [ ] **Step 5: Commit**

```bash
git add ios/Packages/GymData
git commit -m "feat(data): the server move hands the phone's data to the next account and marks it unsynced"
```

- [ ] **Step 6: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** spec section 4 "Server move", and decisions 12–14. Nothing is deleted but pending proposals.
   "This phone only" rows and edit times are untouched. The store is saved before UserDefaults changes.
2. **Quality:** the `code-reviewer` agent.

### Task 6: `AuthService` on Better Auth, and the integration suites follow it

**Files:**
- Create: `ios/Packages/GymSync/Sources/GymSync/ApiClient+Auth.swift`
- Rewrite: `ios/Packages/GymSync/Sources/GymSync/AuthService.swift`, `AuthFailure.swift`
- Rewrite: `ios/Packages/GymSync/Tests/GymSyncTests/AuthServiceTests.swift`
- Create: `ios/Packages/GymSync/Tests/GymSyncTests/SupabaseConfigTests.swift`
- Modify: `ios/Packages/GymSync/Tests/GymSyncTests/AuthEventTests.swift`
- Modify: `ios/Packages/GymSync/Package.swift`
- Move: seven integration suites to `ios/Packages/GymSync/Tests/GymSyncIntegrationTests/SupabaseParked/`
- Rewrite: `GymSyncIntegrationTests/IntegrationSupport.swift`, `AuthIntegrationTests.swift`
- Move: `GymSyncIntegrationTests/SupabaseTransportTests.swift` → `WorkerTransportTests.swift`
- Modify: `GymSyncIntegrationTests/PagingAndRejectionTests.swift`, `SyncRoundTripTests.swift`

After this task the app target doesn't build until Task 7 (decision 18). Every package suite builds and passes.

- [ ] **Step 1: Write the failing tests**

Move the Supabase settings tests out of the file about to be rewritten. Create
`ios/Packages/GymSync/Tests/GymSyncTests/SupabaseConfigTests.swift` with the `SupabaseConfigTests` suite exactly as
it stands in `AuthServiceTests.swift` today (lines 78–108), its `import`s reduced to

```swift
import Foundation
import Testing
@testable import GymSync
```

and with this test added at the end of the suite (it was `AuthServiceTests.inMemoryStorageRoundTrips`):

```swift

    @Test func inMemoryStorageRoundTrips() throws {
        let storage = InMemoryAuthStorage()
        try storage.store(key: "k", value: Data([1, 2]))
        #expect(try storage.retrieve(key: "k") == Data([1, 2]))
        try storage.remove(key: "k")
        #expect(try storage.retrieve(key: "k") == nil)
    }
```

Replace `ios/Packages/GymSync/Tests/GymSyncTests/AuthServiceTests.swift` with:

```swift
import Foundation
import GymData
import Testing
@testable import GymSync

/// A log that photo steps and the stub server both write to, in order.
final class StepLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    var items: [String] { lock.withLock { entries } }
    func add(_ item: String) { lock.withLock { entries.append(item) } }
}

private let userId = UUID(uuidString: "b73f3bdc-18c8-400a-b492-4db321b4baee")!
/// Better Auth 1.7.18's answers as plan 27's probe recorded them, trimmed.
private let signInBody = #"{"redirect": false, "token": "raw-token", "user": {"id": "b73f3bdc-18c8-400a-b492-4db321b4baee", "#
    + #""email": "a@test.local", "name": "", "emailVerified": true}}"#
private let sessionBody = #"{"session": {"token": "raw-token", "userId": "b73f3bdc-18c8-400a-b492-4db321b4baee"}, "#
    + #""user": {"id": "b73f3bdc-18c8-400a-b492-4db321b4baee", "email": "a@test.local", "name": ""}}"#
private let signedOutBody = #"{"error": {"code": "signed_out", "message": "Sign in required."}}"#
/// The bearer plugin's `set-auth-token`: the token and its signature, as sent.
private let signedToken = "raw-token.c2lnbmF0dXJl+/="
private let stored = StoredSession(token: signedToken, userId: userId, email: "a@test.local")

@Suite struct AuthFailureTests {
    private func api(_ status: Int, _ code: String) -> ApiError { ApiError(status: status, code: code, message: "no") }

    @Test func networkErrorsAskToCheckTheConnection() {
        #expect(AuthFailure(URLError(.notConnectedToInternet), during: .signIn).message
            == "Couldn't sign in. Check your connection and try again.")
        #expect(AuthFailure(URLError(.timedOut), during: .signUp).message
            == "Couldn't create your account. Check your connection and try again.")
        #expect(AuthFailure(URLError(.cannotConnectToHost), during: .deleteAccount).message
            == "Couldn't delete your account. Check your connection and try again.")
        let nsError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)
        #expect(AuthFailure(nsError, during: .signIn).message
            == "Couldn't sign in. Check your connection and try again.")
    }

    @Test func wrongCredentials() {
        #expect(AuthFailure(api(401, "invalid_email_or_password"), during: .signIn).message == "Wrong email or password.")
    }

    @Test func existingAccount() {
        let expected = "An account with this email already exists. Sign in instead."
        #expect(AuthFailure(api(422, "user_already_exists_use_another_email"), during: .signUp).message == expected)
        #expect(AuthFailure(api(422, "user_already_exists"), during: .signUp).message == expected)
    }

    @Test func weakPassword() {
        #expect(AuthFailure(api(400, "password_too_short"), during: .signUp).message
            == "That password is too weak. Use at least 8 characters.")
    }

    @Test func rateLimited() {
        #expect(AuthFailure(api(429, "auth_failed"), during: .signIn).message
            == "Too many attempts. Wait a minute and try again.")
    }

    @Test func expiredSession() {
        let expected = "Your session has expired. Please sign in again."
        #expect(AuthFailure.sessionExpired.message == expected)
        #expect(AuthFailure(api(401, "signed_out"), during: .deleteAccount).message == expected)
        #expect(AuthFailure(api(401, "session_expired"), during: .restore).message == expected)
    }

    @Test func disabledMethod() {
        let expected = "This sign-in method isn't available right now."
        #expect(AuthFailure(api(400, "email_password_disabled"), during: .signIn).message == expected)
        #expect(AuthFailure(api(400, "email_password_sign_up_disabled"), during: .signUp).message == expected)
        #expect(AuthFailure(api(404, "provider_not_found"), during: .signIn).message == expected)
    }

    @Test func anythingElseIsGeneric() {
        struct Boom: Error {}
        #expect(AuthFailure(Boom(), during: .signIn).message == "Couldn't sign in. Please try again.")
        #expect(AuthFailure(api(401, "invalid_token"), during: .signIn).message == "Couldn't sign in. Please try again.",
                "Apple's token refused: audience, nonce, signature or expiry")
        #expect(AuthFailure(api(500, "server_error"), during: .signUp).message
            == "Couldn't create your account. Please try again.")
        #expect(AuthFailure(Boom(), during: .signOut).message == "Couldn't sign out. Please try again.")
        #expect(AuthFailure(Boom(), during: .deleteAccount).message == "Couldn't delete your account. Please try again.")
    }

    @Test func alreadyMappedFailuresPassThrough() {
        let failure = AuthFailure(message: "Custom")
        #expect(AuthFailure(failure, during: .signIn) == failure)
        #expect(failure.errorDescription == "Custom")
    }
}

/// `AuthService` against a stub of the Better Auth routes and `/v1/account`.
@MainActor
@Suite struct AuthServiceTests {
    private func service(_ server: StubServer, sessions: InMemorySessionStore = InMemorySessionStore()) -> AuthService {
        AuthService(api: server.client(sessions: sessions))
    }

    /// Signed in, against a server that still holds the session. Keep the server: its host goes with it.
    private func signedIn() async -> (AuthService, StubServer) {
        let server = StubServer { _ in .json(200, sessionBody) }
        let auth = service(server, sessions: InMemorySessionStore(stored))
        await auth.restore()
        return (auth, server)
    }

    private func steps(_ calls: StepLog, detach: (@Sendable () async throws -> Void)? = nil,
                       remove: (@Sendable () async throws -> Void)? = nil) -> AccountPhotoSteps {
        AccountPhotoSteps(detach: { try await detach?(); calls.add("detach") },
                          remove: { try await remove?(); calls.add("remove") })
    }

    @Test func startsSignedOut() {
        let server = StubServer { _ in .json(500, "{}") }
        #expect(service(server).state == .signedOut)
    }

    @Test func signInWithAppleSendsTheTokenAndNonceAndKeepsTheSession() async throws {
        let server = StubServer { _ in .json(200, signInBody, headers: ["set-auth-token": signedToken]) }
        let sessions = InMemorySessionStore()
        let auth = service(server, sessions: sessions)
        try await auth.signInWithApple(idToken: "apple.id.token", nonce: "raw-nonce")
        #expect(auth.state == .signedIn(userId: userId, email: "a@test.local"))
        #expect(sessions.load() == stored, "the signed token from set-auth-token")
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/api/auth/sign-in/social")
        #expect(request.headers["Authorization"] == nil)
        let body = try #require(try request.json() as? [String: Any])
        #expect(body["provider"] as? String == "apple")
        #expect(body["idToken"] as? [String: String] == ["token": "apple.id.token", "nonce": "raw-nonce"])
    }

    @Test func theBodysTokenStandsInWhenTheHeaderIsMissing() async throws {
        let server = StubServer { _ in .json(200, signInBody) }
        let sessions = InMemorySessionStore()
        try await service(server, sessions: sessions).signIn(email: "a@test.local", password: "correct-horse")
        #expect(sessions.load()?.token == "raw-token")
        #expect(server.requests.first?.path == "/api/auth/sign-in/email")
    }

    @Test func signUpSendsTheEmptyNameBetterAuthRequires() async throws {
        let server = StubServer { _ in .json(200, signInBody, headers: ["set-auth-token": signedToken]) }
        let auth = service(server)
        try await auth.signUp(email: "a@test.local", password: "correct-horse")
        #expect(auth.state.userId == userId)
        #expect(server.requests.first?.path == "/api/auth/sign-up/email")
        let body = try #require(try server.requests.first?.json() as? [String: String])
        #expect(body == ["email": "a@test.local", "password": "correct-horse", "name": ""])
    }

    @Test func aRefusedSignInSaysWhyAndKeepsNothing() async throws {
        let server = StubServer { _ in
            .json(401, #"{"error": {"code": "invalid_email_or_password", "message": "Invalid email or password"}}"#)
        }
        let sessions = InMemorySessionStore()
        let auth = service(server, sessions: sessions)
        await #expect(throws: AuthFailure(message: "Wrong email or password.")) {
            try await auth.signIn(email: "a@test.local", password: "nope-nope-nope")
        }
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
    }

    @Test func restoreAsksTheServerWithTheStoredToken() async throws {
        let server = StubServer { _ in .json(200, sessionBody) }
        let auth = service(server, sessions: InMemorySessionStore(stored))
        await auth.restore()
        #expect(auth.state == .signedIn(userId: userId, email: "a@test.local"))
        #expect(server.requests.map(\.path) == ["/api/auth/get-session"])
        #expect(server.requests.first?.headers["Authorization"] == "Bearer \(signedToken)")
    }

    @Test func restoreForgetsASessionTheServerNoLongerHolds() async throws {
        let server = StubServer { _ in .json(200, "null") }
        let sessions = InMemorySessionStore(stored)
        let auth = service(server, sessions: sessions)
        await auth.restore()
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
    }

    @Test func restoreOfflineOrWithTheServerBusyKeepsTheStoredAccount() async throws {
        for answer in [nil, StubAnswer.json(503, "{}")] {
            let server = StubServer { _ in
                guard let answer else { throw URLError(.notConnectedToInternet) }
                return answer
            }
            let sessions = InMemorySessionStore(stored)
            let auth = service(server, sessions: sessions)
            await auth.restore()
            #expect(auth.state == .signedIn(userId: userId, email: "a@test.local"))
            #expect(sessions.load() == stored)
        }
    }

    @Test func restoreWithoutAStoredSessionStaysSignedOutWithoutAsking() async throws {
        let server = StubServer { _ in .json(200, sessionBody) }
        let auth = service(server)
        await auth.restore()
        #expect(auth.state == .signedOut)
        #expect(server.requests.isEmpty)
    }

    @Test func signOutForgetsTheSessionThenTellsTheServer() async throws {
        let sessions = InMemorySessionStore(stored)
        let log = StepLog()
        let server = StubServer { _ in
            log.add(sessions.load() == nil ? "already forgotten" : "still stored")
            return .json(200, #"{"success": true}"#)
        }
        let auth = service(server, sessions: sessions)
        try await auth.signOut()
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
        #expect(log.items == ["already forgotten"])
        let request = try #require(server.requests.first)
        #expect(request.method == "POST" && request.path == "/api/auth/sign-out")
        #expect(request.headers["Authorization"] == "Bearer \(signedToken)")
        #expect(request.headers["Content-Type"] == "application/json", "Better Auth refuses a body-less POST with 415")
    }

    @Test func signOutOfflineStillSignsOut() async throws {
        let server = StubServer { _ in throw URLError(.notConnectedToInternet) }
        let sessions = InMemorySessionStore(stored)
        let auth = service(server, sessions: sessions)
        try await auth.signOut()
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
    }

    @Test func signOutWithoutASessionIsANoOp() async throws {
        let server = StubServer { _ in .json(200, "{}") }
        try await service(server).signOut()
        #expect(server.requests.isEmpty)
    }

    @Test func a401FromTheAPISignsOutAndSaysSo() async throws {
        let server = StubServer { request in
            request.path == "/api/auth/get-session" ? .json(200, sessionBody) : .json(401, signedOutBody)
        }
        let sessions = InMemorySessionStore(stored)
        let auth = service(server, sessions: sessions)
        var seen: [AuthState] = []
        auth.onExternalChange = { seen.append($0) }
        await auth.restore()
        await #expect(throws: ApiError.self) { _ = try await auth.api.data("GET", "/v1/sync/profile") }
        try await waitFor { auth.state == .signedOut }
        #expect(seen == [.signedOut])
        #expect(sessions.load() == nil)
    }

    @Test func deleteAccountWhileSignedOutFailsWithoutCallingTheServer() async throws {
        let server = StubServer { _ in StubAnswer(status: 204, headers: [:], body: Data()) }
        await #expect(throws: AuthFailure(message: "Your session has expired. Please sign in again.")) {
            try await service(server).deleteAccount()
        }
        #expect(server.requests.isEmpty)
    }

    @Test func deleteAccountChecksTheSessionThenRemovesPhotosThenDeletes() async throws {
        let log = StepLog()
        let server = StubServer { request in
            log.add("\(request.method) \(request.path)")
            return request.path == "/api/auth/get-session"
                ? .json(200, sessionBody) : StubAnswer(status: 204, headers: [:], body: Data())
        }
        let sessions = InMemorySessionStore(stored)
        let auth = service(server, sessions: sessions)
        await auth.restore()
        try await auth.deleteAccount(photos: AccountPhotoSteps(detach: { log.add("detach") }, remove: { log.add("remove") }))
        #expect(log.items == ["GET /api/auth/get-session", "GET /api/auth/get-session", "detach", "remove",
                              "DELETE /v1/account"])
        #expect(auth.state == .signedOut)
        #expect(sessions.load() == nil)
    }

    @Test func aSessionTheServerNoLongerHoldsStopsDeletionBeforeThePhotos() async throws {
        let log = StepLog()
        let server = StubServer { _ in .json(200, "null") }
        let auth = service(server, sessions: InMemorySessionStore(stored))
        await #expect(throws: AuthFailure(message: "Your session has expired. Please sign in again.")) {
            try await auth.deleteAccount(photos: AccountPhotoSteps(detach: { log.add("detach") },
                                                                   remove: { log.add("remove") }))
        }
        #expect(log.items.isEmpty)
        #expect(server.requests.map(\.path) == ["/api/auth/get-session"])
    }

    @Test func aFailedDetachChangesNothingAndSaysSo() async throws {
        let (auth, server) = await signedIn()
        let calls = StepLog()
        struct Refused: Error {}
        let before = auth.state
        let failure = await #expect(throws: AuthFailure.self) {
            try await auth.deleteAccount(photos: steps(calls, detach: { throw Refused() })) { calls.add("server") }
        }
        #expect(calls.items.isEmpty, "no photo is removed and the account is not deleted")
        #expect(auth.state == before, "and the user stays signed in")
        #expect(failure?.message == "Couldn't delete your account. Check your connection and try again.")
        #expect(server.requests.count == 2, "restore, then the session check")
    }

    @Test func photosGoneButTheAccountStaysIsToldPlainly() async throws {
        let (auth, server) = await signedIn()
        let before = auth.state
        let expected = "Your photos were removed, but your account wasn't deleted. Check your connection and try again."
        struct NoPhotos: Error {}
        for failure in [URLError(.notConnectedToInternet) as Error, GymCatalogError.offline, NoPhotos()] {
            let calls = StepLog()
            let thrown = await #expect(throws: AuthFailure.self) {
                try await auth.deleteAccount(photos: steps(calls, remove: { throw failure })) { calls.add("server") }
            }
            #expect(thrown?.message == expected)
            #expect(calls.items == ["detach"], "the server step never ran")
        }
        let calls = StepLog()
        let thrown = await #expect(throws: AuthFailure.self) {
            try await auth.deleteAccount(photos: steps(calls)) { throw URLError(.timedOut) }
        }
        #expect(thrown?.message == expected, "the same words when the server step fails after the photos")
        #expect(auth.state == before, "the user stays signed in")
        #expect(server.requests.count == 5, "restore, then one session check per attempt")
    }

    @Test func aPhotoStillUploadingReadsAsRetryable() async throws {
        let (auth, server) = await signedIn()
        let thrown = await #expect(throws: AuthFailure.self) {
            try await auth.deleteAccount(photos: steps(StepLog())) {
                throw ApiError(status: 422, code: "photos_remain", message: "Delete your gym photos first.")
            }
        }
        #expect(thrown?.message == "Your photos were removed, but a new one was still uploading, so your account "
            + "wasn't deleted. Please try again.")
        #expect(server.requests.count == 2)
    }

    @Test func aRefusalForRemainingPhotosWithoutThePhotoStepKeepsTheOlderWords() {
        let refused = ApiError(status: 422, code: "photos_remain", message: "Delete your gym photos first.")
        #expect(AuthFailure(refused, during: .deleteAccount).message
            == "Couldn't delete your account because some photos are still being removed. Please try again.")
    }
}
```

In `AuthEventTests.swift`, replace the body of `service()` with:

```swift
        let (stream, continuation) = AsyncStream<AuthEvent>.makeStream()
        let api = ApiClient(baseURL: URL(string: "http://127.0.0.1:9")!, sessions: InMemorySessionStore())
        return (AuthService(api: api, events: stream), continuation)
```

- [ ] **Step 2: Run them to see them fail**

Run: `cd ios/Packages/GymSync && swift test --filter 'AuthServiceTests|AuthFailureTests|AuthEventTests'`
Expected: the build fails: `AuthService` has no `init(api:events:)` and no member `api`, and `AuthFailure` has no
member `sessionExpired`.

- [ ] **Step 3: Write the Better Auth calls**

`ios/Packages/GymSync/Sources/GymSync/ApiClient+Auth.swift`:

```swift
import Foundation

// The Better Auth routes the app uses (server/src/auth/routes.ts lets only these five through), and DELETE /v1/account.
// What Better Auth 1.7.18 answers behind authHandler (checked in plan 27):
// - The sign-ins answer `{token, user}` (plus `redirect: false`) and the bearer plugin's `set-auth-token` header: the
//   same token, signed (`<token>.<signature>`). Either works as the bearer; the header's is kept.
// - `get-session` answers `{session, user}`, or `null` (status 200) when the token no longer holds. Renewing a session
//   moves its expiry only, so the token never changes.
// - `sign-out` answers 200 whatever the token.
// - Errors come in the API's shape, with Better Auth's codes lowercased (`invalid_email_or_password`, …).
extension ApiClient {
    func signInWithApple(idToken: String, nonce: String) async throws -> StoredSession {
        try await signIn("/api/auth/sign-in/social",
                         payload: AppleSignIn(provider: "apple", idToken: .init(token: idToken, nonce: nonce)))
    }

    #if DEBUG
    func signIn(email: String, password: String) async throws -> StoredSession {
        try await signIn("/api/auth/sign-in/email", payload: EmailSignIn(email: email, password: password))
    }

    /// Better Auth requires a name, and the app has none to give.
    func signUp(email: String, password: String) async throws -> StoredSession {
        try await signIn("/api/auth/sign-up/email", payload: EmailSignUp(email: email, password: password, name: ""))
    }
    #endif

    /// Whose the stored token is, or nil when the server no longer holds that session.
    func currentUser() async throws -> AuthUser? {
        let (body, _) = try await data("GET", "/api/auth/get-session")
        return try SyncJSON.decoder.decode(SessionAnswer?.self, from: body)?.user
    }

    /// Ends the session on the server. Sent with the token the phone has just forgotten, and with an empty JSON body:
    /// Better Auth answers a body-less POST from URLSession (`Content-Length: 0`) with 415.
    func signOut(token: String) async throws {
        _ = try await data("POST", "/api/auth/sign-out", body: Data("{}".utf8), bearer: .token(token))
    }

    /// `DELETE /v1/account`: 204, or 422 `photos_remain` while a photo of the account is stored.
    func deleteAccountOnServer() async throws {
        _ = try await data("DELETE", "/v1/account")
    }

    private func signIn<Payload: Encodable>(_ path: String, payload: Payload) async throws -> StoredSession {
        let (body, response) = try await data("POST", path, body: SyncJSON.encoder.encode(payload), bearer: .anonymous)
        let answer = try SyncJSON.decoder.decode(SignInAnswer.self, from: body)
        guard let token = response.value(forHTTPHeaderField: "set-auth-token") ?? answer.token, !token.isEmpty else {
            throw ApiError(status: response.statusCode, code: "no_session", message: "The server gave no session.")
        }
        return StoredSession(token: token, userId: answer.user.id, email: answer.user.email)
    }
}

/// Whose a session is. Better Auth's user ids are UUIDs (server/src/auth/auth.ts makes them).
struct AuthUser: Decodable, Sendable {
    let id: UUID
    let email: String?
}

private struct SignInAnswer: Decodable {
    let token: String?
    let user: AuthUser
}

private struct SessionAnswer: Decodable {
    let user: AuthUser
}

private struct AppleSignIn: Encodable {
    struct IdToken: Encodable {
        let token: String
        let nonce: String
    }

    let provider: String
    let idToken: IdToken
}

#if DEBUG
private struct EmailSignIn: Encodable {
    let email: String
    let password: String
}

private struct EmailSignUp: Encodable {
    let email: String
    let password: String
    let name: String
}
#endif
```

- [ ] **Step 4: Rewrite `AuthService`**

Replace `ios/Packages/GymSync/Sources/GymSync/AuthService.swift` with:

```swift
import Foundation
import Observation

public enum AuthState: Equatable, Sendable {
    case signedOut
    case signedIn(userId: UUID, email: String?)

    public var userId: UUID? {
        if case .signedIn(let id, _) = self { return id }
        return nil
    }
}

/// An auth change from outside the service's own calls: the API answered 401 to the stored session (signed out
/// elsewhere, expired, the account deleted). Tests drive their own.
public enum AuthEvent: Sendable, Equatable {
    case signedIn(userId: UUID, email: String?)
    case signedOut
}

/// The photo steps of account deletion, kept apart so a failure can say which one broke. `detach` clears the photo
/// names on the server and on the phone, and changes nothing else; once it has succeeded the photos are as good as gone
/// for the user, so `remove` (deleting the objects) and the server step that follows say so when they fail.
public struct AccountPhotoSteps: Sendable {
    public let detach: @Sendable () async throws -> Void
    public let remove: @Sendable () async throws -> Void

    public init(detach: @escaping @Sendable () async throws -> Void, remove: @escaping @Sendable () async throws -> Void) {
        self.detach = detach
        self.remove = remove
    }
}

/// Sign-in on the API's Better Auth: Sign in with Apple with the id token the app gets (plus email and password in
/// DEBUG builds, for tests), sign-out, account deletion and session restore. Every failure is thrown as an
/// `AuthFailure` with a user-facing message. The session (Better Auth's bearer token, and whose it is) lives in
/// `api.sessions`, the Keychain on the phone, so `restore()` works offline. A 401 that ends it (to a call that carried
/// it, while it is still the stored one) signs the service out and is reported through `onExternalChange`; the local
/// data stays.
@MainActor @Observable
public final class AuthService {
    public private(set) var state: AuthState = .signedOut

    @ObservationIgnored public let api: ApiClient
    /// Called when an auth event (not one of this service's own calls) changed `state`.
    @ObservationIgnored public var onExternalChange: (@MainActor (AuthState) -> Void)?
    @ObservationIgnored private var observer: Task<Void, Never>?

    /// `events` replaces the API's 401 signal (tests inject their own).
    public init(api: ApiClient, events: AsyncStream<AuthEvent>? = nil) {
        self.api = api
        let stream = events ?? Self.events(from: api)
        observer = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                self.handle(event)
            }
        }
    }

    isolated deinit { observer?.cancel() }

    func handle(_ event: AuthEvent) {
        let next: AuthState
        switch event {
        case .signedOut: next = .signedOut
        case let .signedIn(userId, email): next = .signedIn(userId: userId, email: email)
        }
        guard next != state else { return }
        state = next
        onExternalChange?(next)
    }

    /// Every 401 that ended the stored session; the client has already forgotten the token.
    private static func events(from api: ApiClient) -> AsyncStream<AuthEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in api.unauthorized { continuation.yield(.signedOut) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Restores the stored session on launch. The server says whether it still holds it (`get-session` answers `null`
    /// when it doesn't). Offline, or with the server busy, the stored account stays signed in, and sync reports
    /// `.offline` until the server answers. An answer the app can't read signs out for this launch and keeps the token.
    public func restore() async {
        guard let stored = api.sessions.load() else {
            state = .signedOut
            return
        }
        do {
            if let user = try await api.currentUser() {
                state = .signedIn(userId: user.id, email: user.email)
            } else {
                api.sessions.clear(ifToken: stored.token)
                state = .signedOut
            }
        } catch where ApiError.isOffline(error) {
            state = .signedIn(userId: stored.userId, email: stored.email)
        } catch {
            state = .signedOut
        }
    }

    public func signInWithApple(idToken: String, nonce: String) async throws {
        try await authenticate(.signIn) { try await self.api.signInWithApple(idToken: idToken, nonce: nonce) }
    }

    #if DEBUG
    /// Email/password sign-in, for tests and the local Worker only (the server takes it with ALLOW_PASSWORD_AUTH=1).
    public func signIn(email: String, password: String) async throws {
        try await authenticate(.signIn) { try await self.api.signIn(email: email, password: password) }
    }

    /// Email/password sign-up, for tests only.
    public func signUp(email: String, password: String) async throws {
        try await authenticate(.signUp) { try await self.api.signUp(email: email, password: password) }
    }
    #endif

    /// Signs out. The phone forgets the session before telling the server, so it is signed out even when that request
    /// fails (offline, say); the server's copy then just expires. Better Auth answers 200 even for a session already
    /// gone.
    public func signOut() async throws {
        let stored = api.sessions.load()
        api.sessions.clear()
        state = .signedOut
        guard let stored else { return }
        do {
            try await api.signOut(token: stored.token)
        } catch where ApiError.isOffline(error) {
            // Forgotten here; the server's copy expires on its own.
        } catch {
            throw AuthFailure(error, during: .signOut)
        }
    }

    /// Detaches and removes the user's photos through `photos`, then deletes the account and all its data on the
    /// server (`DELETE /v1/account`, which refuses with `photos_remain` while a photo is left), then forgets the
    /// session. A failure leaves the account and the session, so the user can try again; the message says whether the
    /// photos are already gone.
    public func deleteAccount(photos: AccountPhotoSteps? = nil) async throws {
        try await deleteAccount(photos: photos) { try await self.api.deleteAccountOnServer() }
    }

    func deleteAccount(photos: AccountPhotoSteps?, onServer: () async throws -> Void) async throws {
        guard api.sessions.load() != nil else { throw AuthFailure.sessionExpired }
        // A session the server no longer holds would fail only after the photos are gone.
        let holds: Bool
        do {
            holds = try await api.currentUser() != nil
        } catch {
            throw AuthFailure(error, during: .deleteAccount)
        }
        guard holds else { throw AuthFailure.sessionExpired }
        if let photos { try await removePhotos(photos) }
        do {
            try await onServer()
        } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw photos == nil ? AuthFailure(error, during: .deleteAccount) : AuthFailure.afterPhotos(error)
        }
        // The account is gone, and its sessions with it.
        api.sessions.clear()
        state = .signedOut
    }

    /// Detach, then remove. A failed detach changed nothing; a failed remove has already detached, which the message
    /// owns up to.
    private func removePhotos(_ photos: AccountPhotoSteps) async throws {
        do { try await photos.detach() } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw AuthFailure.detachFailed
        }
        do { try await photos.remove() } catch let cancelled as CancellationError {
            throw cancelled
        } catch {
            throw AuthFailure.afterPhotos(error)
        }
    }

    private func authenticate(_ action: AuthAction, _ call: () async throws -> StoredSession) async throws {
        do {
            let session = try await call()
            try api.sessions.save(session)
            state = .signedIn(userId: session.userId, email: session.email)
        } catch {
            throw AuthFailure(error, during: action)
        }
    }
}
```

- [ ] **Step 5: Map `ApiError` in `AuthFailure`**

In `ios/Packages/GymSync/Sources/GymSync/AuthFailure.swift`:
- Replace the three `import`s with `import Foundation`.
- Below `static let detachFailed = …`, add:

```swift

    /// The stored session is missing, or the server no longer holds it.
    static let sessionExpired = AuthFailure(message: Messages.sessionExpired)
```

- Replace everything from `private static func isPhotosRemain` down to the end of `message(for:)`, just above
  `private enum Messages`, with the block below. `message(for:)` goes; `isNetwork` stays as it is.

```swift
    private static func isPhotosRemain(_ error: Error) -> Bool {
        (error as? ApiError)?.code == "photos_remain"
    }

    static func isNetwork(_ error: Error) -> Bool {
        error is URLError || (error as NSError).domain == NSURLErrorDomain
    }

    /// The API's codes, Better Auth's lowercased by the server (the ones plan 27's probe saw), then the status.
    private static func knownMessage(for error: Error) -> String? {
        guard let failure = error as? ApiError else { return nil }
        switch failure.code {
        case "invalid_email_or_password", "invalid_password", "credential_account_not_found":
            return Messages.wrongCredentials
        case "user_already_exists", "user_already_exists_use_another_email":
            return Messages.accountExists
        case "password_too_short":
            return Messages.weakPassword
        case "signed_out", "session_expired":
            return Messages.sessionExpired
        case "email_password_disabled", "email_password_sign_up_disabled", "provider_not_found", "id_token_not_supported":
            return Messages.methodUnavailable
        default:
            return failure.status == 429 ? Messages.rateLimited : nil
        }
    }
```

- [ ] **Step 6: Park the Supabase-only integration suites**

Run:

```bash
(cd ios/Packages/GymSync/Tests/GymSyncIntegrationTests && mkdir SupabaseParked \
  && git mv GymAccountPhotosIntegrationTests.swift GymCatalogE2ETests.swift GymCatalogIntegrationTests.swift \
       GymModerationIntegrationTests.swift GymPrivateIntegrationTests.swift OAuthGrantTransportTests.swift \
       ProposalTransportTests.swift SupabaseParked/ \
  && git mv SupabaseTransportTests.swift WorkerTransportTests.swift)
```

In `ios/Packages/GymSync/Package.swift`, replace the `GymSyncIntegrationTests` target with:

```swift
        // The Supabase-only suites (gyms, photos, moderation, proposals, Claude's grants) sign in with the Supabase
        // client the app no longer has. They stay as the reference plans 28 and 29 port to the API, unbuilt meanwhile.
        .testTarget(name: "GymSyncIntegrationTests", dependencies: [
            "GymSync", "GymCore", "GymData",
            .product(name: "Supabase", package: "supabase-swift"),
        ], exclude: ["SupabaseParked"]),
```

- [ ] **Step 7: Point the integration support at the Worker**

Replace `GymSyncIntegrationTests/IntegrationSupport.swift` with:

```swift
import Foundation
import GymCore
import GymData
import SwiftData
import Testing
@testable import GymSync

/// Integration suites run only against a local Worker (`scripts/test-sync-integration.sh` sets API_URL).
let apiConfigured = ProcessInfo.processInfo.environment["API_URL"] != nil

enum IntegrationEnv {
    static let password = "sync-test-password-1"

    static func config() throws -> ApiConfig { try ApiConfig(environment: ProcessInfo.processInfo.environment) }

    static func uniqueEmail() -> String { "sync-\(UUID().uuidString.lowercased())@test.local" }

    /// Hands deleted user ids to the shell script, which checks in D1 that no rows survived.
    static func recordDeletedUser(_ id: UUID) {
        guard let path = ProcessInfo.processInfo.environment["SYNC_DELETED_USERS_FILE"],
              let line = (id.uuidString.lowercased() + "\n").data(using: .utf8),
              let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }
}

/// A signed-in user on one simulated device (its own client and session store).
@MainActor
struct Account {
    let email: String
    let auth: AuthService
    var transport: ApiSyncTransport { ApiSyncTransport(api: auth.api) }
    var userId: UUID { auth.state.userId! }

    static func signUp() async throws -> Account {
        let account = try fresh(email: IntegrationEnv.uniqueEmail())
        try await account.auth.signUp(email: account.email, password: IntegrationEnv.password)
        return account
    }

    /// The same user signing in on another device.
    func onAnotherDevice() async throws -> Account {
        let other = try Account.fresh(email: email)
        try await other.auth.signIn(email: email, password: IntegrationEnv.password)
        return other
    }

    /// The Worker holds no photos before plan 28, so there are no photo steps.
    func deleteAccount() async throws {
        let id = userId
        try await auth.deleteAccount()
        IntegrationEnv.recordDeletedUser(id)
    }

    static func fresh(email: String) throws -> Account {
        let api = try IntegrationEnv.config().makeClient(sessions: InMemorySessionStore())
        return Account(email: email, auth: AuthService(api: api))
    }
}

/// Polls until `condition` holds (two seconds at most).
@MainActor
func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for condition")
}

@MainActor
final class DeviceClock {
    var now: Date
    init(_ iso: String) { now = SyncDate.parse(iso)! }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// A fresh in-memory SwiftData store + SyncEngine talking to the local Worker as `account`.
@MainActor
struct Device {
    let container: ModelContainer
    let clock: DeviceClock
    let suiteName = "sync-it-\(UUID())"
    let store: SyncStore
    let engine: SyncEngine

    init(_ account: Account, clock: DeviceClock) throws {
        container = try GymStore.container(inMemory: true)
        self.clock = clock
        let defaults = UserDefaults(suiteName: suiteName)!
        store = SyncStore(context: container.mainContext, defaults: defaults, now: { clock.now })
        engine = SyncEngine(store: store, transport: account.transport, now: { clock.now })
    }

    var routines: RoutineRepository { RoutineRepository(context: container.mainContext, now: { [clock] in clock.now }) }
    var workouts: WorkoutRepository { WorkoutRepository(context: container.mainContext, now: { [clock] in clock.now }) }
    var prefs: ExercisePreferenceRepository {
        ExercisePreferenceRepository(context: container.mainContext, now: { [clock] in clock.now })
    }
    var body: BodyRepository { BodyRepository(context: container.mainContext, now: { [clock] in clock.now }) }
    var profiles: ProfileRepository { ProfileRepository(context: container.mainContext, now: { [clock] in clock.now }) }

    func tearDown() { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
}

/// A finished three-set bench session; `startedAt` is on the microsecond grid so it round-trips exactly.
func finishedWorkout(id: UUID = UUID(), name: String, at start: Date) -> Workout {
    let done = start.addingTimeInterval(600.25)
    return Workout(id: id, startedAt: start, endedAt: start.addingTimeInterval(3_000.5), pausedSeconds: 42.5,
                   name: name, entries: [
                       WorkoutEntry(exerciseId: "bench", sets: [
                           WorkoutSet(weightKg: 60, reps: 8, done: true, rir: 2, completedAt: done),
                           WorkoutSet(weightKg: 61.234567, reps: 8, done: true, rpe: 8.5, completedAt: done),
                           WorkoutSet(weightKg: 62.5, reps: 7, done: true, completedAt: done),
                       ], note: "felt strong"),
                   ], note: "push day")
}

let benchRecords = [
    PersonalRecord(exerciseId: "bench", kind: .e1RM, valueKg: 76.47, reps: nil, weightKg: nil, previousKg: 74.1),
    PersonalRecord(exerciseId: "bench", kind: .repsAtWeight, valueKg: nil, reps: 8, weightKg: 61.234567,
                   previousKg: nil),
]
```

Replace `GymSyncIntegrationTests/AuthIntegrationTests.swift` with:

```swift
import Foundation
import GymCore
import GymData
import Testing
@testable import GymSync

/// `AuthService` against the local Worker's Better Auth (email/password is DEBUG-only and on only with
/// ALLOW_PASSWORD_AUTH=1; the app uses Sign in with Apple).
@MainActor
@Suite(.enabled(if: apiConfigured, "Set API_URL to run against a local Worker (scripts/test-sync-integration.sh)"))
struct AuthIntegrationTests {
    @Test func signUpSignOutSignInAndRestore() async throws {
        let user = try await Account.signUp()
        guard case .signedIn(let id, let email) = user.auth.state else {
            Issue.record("expected signed in after sign-up")
            return
        }
        #expect(email == user.email)

        try await user.auth.signOut()
        #expect(user.auth.state == .signedOut)
        await user.auth.restore()
        #expect(user.auth.state == .signedOut)

        try await user.auth.signIn(email: user.email, password: IntegrationEnv.password)
        #expect(user.auth.state.userId == id)
        await user.auth.restore()  // from the stored session
        #expect(user.auth.state.userId == id)

        await #expect(throws: AuthFailure(message: "An account with this email already exists. Sign in instead.")) {
            try await Account.fresh(email: user.email).auth.signUp(email: user.email, password: IntegrationEnv.password)
        }
        try await user.deleteAccount()
    }

    @Test func wrongPasswordIsAFriendlyMessage() async throws {
        let user = try await Account.signUp()
        let other = try Account.fresh(email: user.email)
        await #expect(throws: AuthFailure(message: "Wrong email or password.")) {
            try await other.auth.signIn(email: user.email, password: "not-the-password")
        }
        #expect(other.auth.state == .signedOut)
        try await user.deleteAccount()
    }

    /// A session ended on the server (here, signed out by another client) signs the phone out at its next call.
    @Test func aSessionEndedElsewhereSignsOutAtTheNextCall() async throws {
        let user = try await Account.signUp()
        let token = try #require(user.auth.api.sessions.load()?.token)
        try await IntegrationEnv.config().makeClient(sessions: InMemorySessionStore()).signOut(token: token)

        await #expect(throws: ApiError.self) { _ = try await user.transport.pullRoutines(since: nil) }
        try await waitUntil { user.auth.state == .signedOut }
        #expect(user.auth.api.sessions.load() == nil)
        await user.auth.restore()
        #expect(user.auth.state == .signedOut)

        try await user.auth.signIn(email: user.email, password: IntegrationEnv.password)
        try await user.deleteAccount()
    }

    /// Deleting the account removes the user and every row they own (the script re-checks D1).
    @Test func deleteAccountRemovesUserAndData() async throws {
        let user = try await Account.signUp()
        let phone = try Device(user, clock: DeviceClock("2026-09-27T07:00:00Z"))
        defer { phone.tearDown() }
        try phone.profiles.save(Profile(unit: .kg))
        try phone.routines.upsert(Routine(name: "Push"))
        try phone.body.add(BodyweightEntry(date: phone.clock.now, weightKg: 81))
        try phone.workouts.save(finishedWorkout(name: "Push", at: phone.clock.now))
        await phone.engine.sync()
        #expect(phone.engine.status == .idle)
        let transport = user.transport
        let deletedId = user.userId

        try await user.deleteAccount()
        #expect(user.auth.state == .signedOut)
        #expect(user.auth.api.sessions.load() == nil)
        // Signed out, the same client gets nothing.
        await #expect(throws: ApiError(status: 401, code: "signed_out", message: "Sign in required.")) {
            _ = try await transport.pullWorkouts(since: nil)
        }

        await #expect(throws: AuthFailure(message: "Wrong email or password.")) {
            try await Account.fresh(email: user.email).auth.signIn(email: user.email, password: IntegrationEnv.password)
        }
        // The email is free again, and the new account starts empty.
        let reborn = try Account.fresh(email: user.email)
        try await reborn.auth.signUp(email: user.email, password: IntegrationEnv.password)
        #expect(reborn.auth.state.userId != nil)
        #expect(reborn.auth.state.userId != deletedId)
        #expect(try await reborn.transport.pullWorkouts(since: nil).isEmpty)
        #expect(try await reborn.transport.pullRoutines(since: nil).isEmpty)
        try await reborn.deleteAccount()
    }
}
```

- [ ] **Step 8: Point the other three suites at the Worker**

In each of `WorkerTransportTests.swift`, `PagingAndRejectionTests.swift` and `SyncRoundTripTests.swift`, replace

```swift
@Suite(.enabled(if: supabaseConfigured, "Set SUPABASE_URL and SUPABASE_ANON_KEY to run against local Supabase"))
```

with

```swift
@Suite(.enabled(if: apiConfigured, "Set API_URL to run against a local Worker (scripts/test-sync-integration.sh)"))
```

Then, in `WorkerTransportTests.swift`:

| Replace | With |
|---|---|
| ``/// `SupabaseTransport` against the local stack: the PostgREST/RPC behaviors the sync engine relies on.`` | ``/// `ApiSyncTransport` against the local Worker: the /v1/sync behaviours the sync engine relies on.`` |
| `struct SupabaseTransportTests {` | `struct WorkerTransportTests {` |
| ``/// Profile and week schedule upsert with `on_conflict` columns absent from the body (`user_id` comes from the`` and the next line, ``/// column default `auth.uid()`), and a push older than the stored edit is skipped with no ack.`` | `/// Profile and week schedule are keyed by the session's account (the body has no user_id), and a push older than` and ``/// the stored edit is skipped with no ack.`` |
| `// numeric[] -> JSON numbers, exact` | `// JSON numbers, exact` |
| `/// Upserts ack only the rows the LWW trigger let through; acked` | `/// Upserts ack only the rows last-write-wins let through; acked` |
| ``/// `upsert_workout` stores the aggregate, answers `stale` for an older edit, and its `updated_at` matches the pull.`` | ``/// A workout push stores the aggregate, answers `stale` for an older edit, and its `updated_at` matches the pull.`` |
| `@Test func workoutRPCStoresAggregateAndReportsStale()` | `@Test func workoutPushStoresAggregateAndReportsStale()` |

In `PagingAndRejectionTests.swift`:

| Replace | With |
|---|---|
| `/// Keyset-paged pulls and row rejections against the local stack.` | `/// Keyset-paged pulls and row rejections against the local Worker.` |
| `let small = SupabaseTransport(client: user.auth.client, pageSize: 3)` | `let small = ApiSyncTransport(api: user.auth.api, pageSize: 3, workoutPageSize: 3)` |
| `let later = BodyweightEntry(date: t0 + 30 * 86_400, weightKg: 85)` | `try await Task.sleep(for: .milliseconds(5)) // the server's clock moves in milliseconds` and, on the next line, `let later = BodyweightEntry(date: t0 + 30 * 86_400, weightKg: 85)` |
| `// Workouts (nested select, rpc-written) page the same way.` | `// Workouts (entries and sets nested) page the same way.` |
| `#expect(rejected.code == "23514")` | `#expect(rejected.code == "row_rejected")` |
| `#expect(rejected.message.contains("check constraint"))` | `#expect(rejected.message.contains("CHECK constraint failed"))` |

In `SyncRoundTripTests.swift`:

| Replace | With |
|---|---|
| ``/// Full `SyncEngine` rounds: real in-memory SwiftData stores, `SupabaseTransport`, local Supabase.`` | ``/// Full `SyncEngine` rounds: real in-memory SwiftData stores, `ApiSyncTransport`, the local Worker.`` |
| `/// RLS: a second user syncs nothing of the first user's data and can't overwrite it.` | `/// Isolation: a second user syncs nothing of the first user's data and can't overwrite it.` |
| `// Writing onto the owner's ids is rejected (RLS / RPC ownership check) and changes nothing.` | `// Writing onto the owner's ids is refused (403 not_allowed) and changes nothing.` |

Run: `grep -rn "supabase\|Supabase\|auth.client" ios/Packages/GymSync/Tests/GymSyncIntegrationTests --include='*.swift' | grep -v SupabaseParked`
Expected: no output.

- [ ] **Step 9: Run the tests**

Run: `cd ios/Packages/GymSync && swift test --filter GymSyncTests`
Expected: `Test run with 188 tests in 24 suites passed`. The integration target builds too, and its suites skip without
`API_URL`; Task 8 runs them.

- [ ] **Step 10: Commit**

```bash
git add -A ios/Packages/GymSync
git commit -m "feat(sync): AuthService on Better Auth with a Keychain-ready session store; integration suites on the API"
```

- [ ] **Step 11: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** spec section 4 "Sign-in" and acceptance criterion 4, decisions 1, 2, 5, 16 and 18. The public
   surface the app uses is unchanged except `client` → `api`: `state`, `onExternalChange`, `restore`,
   `signInWithApple`, DEBUG `signIn`/`signUp`, `signOut`, `deleteAccount(photos:)`, `AuthEvent`.
2. **Quality:** the `code-reviewer` agent.
3. **Security:** the `security-reviewer` agent.
   - The token reaches only the bearer header and the session store.
   - Sign-ins send no stale bearer.
   - A failed sign-in stores nothing.
   - Sign-out forgets locally first.
   - Deletion checks the session before touching photos.
   - Email/password stays DEBUG-only on the client, as on the server.

### Task 7: The app on the API

**Files:**
- Create: `ios/Packages/GymSync/Sources/GymSync/KeychainSessionStore.swift`
- Rewrite: `ios/GymRollins/App/SyncCoordinator+Factory.swift`
- Modify: `ios/GymRollins/App/DebugSyncSupport.swift`, `AppEnvironment+GymCatalog.swift`, `LaunchOptions.swift`
- Modify: `ios/GymRollins/Features/Account/AppleSignIn.swift`
- Modify: `ios/GymRollinsTests/GymWipeEnvironmentTests.swift`, `SyncAccountSafetyTests.swift`
- Test: `ios/GymRollinsTests/KeychainSessionStoreTests.swift`, `ServerMoveLaunchTests.swift`

- [ ] **Step 1: Write the failing tests**

`ios/GymRollinsTests/KeychainSessionStoreTests.swift`:

```swift
import Foundation
import GymSync
import Testing

/// The app's session in the Keychain: saved, read back, replaced, and cleared only for the token a 401 answered.
@Suite struct KeychainSessionStoreTests {
    private let store = KeychainSessionStore(service: "com.rollins.gymrollins.test-session-\(UUID().uuidString)")

    @Test func savesReadsReplacesAndClears() throws {
        defer { store.clear() }
        #expect(store.load() == nil)
        let first = StoredSession(token: "t1.sig", userId: UUID(), email: "a@test.local")
        try store.save(first)
        #expect(store.load() == first)
        let second = StoredSession(token: "t2.sig", userId: first.userId, email: nil)
        try store.save(second)
        #expect(store.load() == second)
        #expect(!store.clear(ifToken: "t1.sig"))
        #expect(store.load() == second, "a 401 to the older token leaves the newer session")
        #expect(store.clear(ifToken: "t2.sig"))
        #expect(store.load() == nil)
        #expect(!store.clear(ifToken: nil), "nothing left to forget")
    }

    @Test func twoServicesDontShareASession() throws {
        let other = KeychainSessionStore(service: "com.rollins.gymrollins.test-session-\(UUID().uuidString)")
        defer {
            store.clear()
            other.clear()
        }
        try store.save(StoredSession(token: "mine", userId: UUID(), email: nil))
        #expect(other.load() == nil)
    }
}
```

`ios/GymRollinsTests/ServerMoveLaunchTests.swift`:

```swift
import Foundation
import GymData
import GymSync
import SwiftData
import Testing
@testable import GymRollins

/// The launch moves the data to the API it talks to, before any session is restored (spec section 4, "Server move").
@MainActor
@Suite struct ServerMoveLaunchTests {
    let container: ModelContainer
    let suite = "server-move-launch-\(UUID())"
    let defaults: UserDefaults

    init() throws {
        container = try GymStore.container(inMemory: true)
        defaults = UserDefaults(suiteName: suite)!
    }

    private var store: SyncStore { SyncStore(context: container.mainContext, defaults: defaults, now: Date.init) }

    private func launch(_ arguments: [String]) -> SyncCoordinator {
        let options = LaunchOptions(arguments: arguments, environment: ["API_URL": "http://127.0.0.1:9"])
        return SyncCoordinator.make(options: options, store: store, now: Date.init)
    }

    @Test func aLaunchAgainstAnotherAPIMovesTheDataBeforeAnyoneSignsIn() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        store.ownerUserId = UUID()
        store.syncedServer = "http://127.0.0.1:55421"
        let sync = launch(["-uiTesting", "-uiTestingBackend", "local", "-forgetSession"])
        #expect(sync.isAvailable)
        #expect(store.ownerUserId == nil)
        #expect(store.syncedServer == "http://127.0.0.1:9")
    }

    @Test func aHermeticLaunchLeavesTheDataAlone() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let owner = UUID()
        store.ownerUserId = owner
        store.syncedServer = "http://127.0.0.1:55421"
        let sync = launch(["-uiTesting"])
        #expect(!sync.isAvailable)
        #expect(store.ownerUserId == owner)
        #expect(store.syncedServer == "http://127.0.0.1:55421")
    }
}
```

- [ ] **Step 2: Write the Keychain store**

`ios/Packages/GymSync/Sources/GymSync/KeychainSessionStore.swift`:

```swift
import Foundation
import Security

/// The session in the Keychain: one generic-password item holding `StoredSession` as JSON. It is readable after the
/// first unlock (sync runs in the background) and never leaves this device: no iCloud Keychain, no restore to another
/// phone.
public final class KeychainSessionStore: SessionStore, @unchecked Sendable {
    private let service: String
    private let lock = NSLock()

    /// `service` names the item; tests use their own.
    public init(service: String = "com.rollins.gymrollins.api-session") {
        self.service = service
    }

    public func load() -> StoredSession? {
        lock.withLock { read() }
    }

    public func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        try lock.withLock {
            SecItemDelete(query as CFDictionary)
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw KeychainError(status: status) }
        }
    }

    @discardableResult public func clear(ifToken token: String?) -> Bool {
        lock.withLock {
            if let token, read()?.token != token { return false }
            return SecItemDelete(query as CFDictionary) == errSecSuccess
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "session"]
    }

    private func read() -> StoredSession? {
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(StoredSession.self, from: data)
    }
}

/// The Keychain refused to store the session.
public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
}
```

- [ ] **Step 3: Rewrite the sync factory**

Replace `ios/GymRollins/App/SyncCoordinator+Factory.swift` with:

```swift
import Foundation
import GymData
import GymSync

extension SyncCoordinator {
    /// Builds the coordinator for the launch's `SyncBackend`. A missing or invalid `API_URL` disables sync (logged)
    /// instead of failing the launch: the app works fully offline. Before anything signs in, the data moves to this API
    /// if it last synced with another one (`SyncStore.moveToServer`, spec section 4 "Server move").
    static func make(options: LaunchOptions, store: SyncStore, now: @escaping () -> Date) -> SyncCoordinator {
        switch options.syncBackend {
        case .disabled:
            return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in nil })
        case .seededConflict:
            #if DEBUG
            let fake = SeededConflictTransport()
            return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in fake })
            #else
            return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in nil })
            #endif
        case .configured, .uiTestLocal:
            guard let config = apiConfig(options) else {
                return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in nil })
            }
            let sessions = sessionStore(options)
            guard moveIfNeeded(store, to: config, sessions: sessions) else {
                return SyncCoordinator(auth: nil, store: store, now: now, makeTransport: { _ in nil })
            }
            let auth = AuthService(api: config.makeClient(sessions: sessions))
            let offline = options.simulateOffline
            return SyncCoordinator(auth: auth, store: store, now: now, makeTransport: { auth in
                guard let auth else { return nil }
                #if DEBUG
                if offline { return OfflineTransport() }
                #endif
                return ApiSyncTransport(api: auth.api)
            })
        }
    }

    /// The server move, before the session is restored. False when it failed: sync stays off for this launch, because
    /// data still marked as the old server's must not meet a new account (the account-switch prompt would offer to
    /// remove it). The next launch tries again.
    private static func moveIfNeeded(_ store: SyncStore, to config: ApiConfig, sessions: any SessionStore) -> Bool {
        do {
            if try store.moveToServer(config.origin) {
                sessions.clear() // a session the old server gave means nothing here
                log.notice("Moved this phone's data to \(config.origin, privacy: .public); it uploads after the next sign-in")
            }
            return true
        } catch {
            log.error("Server move failed, sync off for this launch: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The MCP connector URL Claude needs (`<SUPABASE_URL>/functions/v1/mcp`), nil without a Supabase config. Claude's
    /// server stays on Supabase until plan 29 makes it `<API_URL>/mcp`.
    static func connectorURL(options: LaunchOptions) -> String? {
        supabaseConfig(options).map { $0.url.appending(path: "functions/v1/mcp").absoluteString }
    }

    private static func apiConfig(_ options: LaunchOptions) -> ApiConfig? {
        #if DEBUG
        if let fromEnvironment = try? ApiConfig(environment: options.environment) { return fromEnvironment }
        #endif
        do { return try ApiConfig.fromBundle() }
        catch {
            log.error("Sync disabled, bad API_URL: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static func supabaseConfig(_ options: LaunchOptions) -> SupabaseConfig? {
        #if DEBUG
        if let fromEnvironment = try? SupabaseConfig(environment: options.environment) { return fromEnvironment }
        #endif
        return try? SupabaseConfig.fromBundle()
    }

    private static func sessionStore(_ options: LaunchOptions) -> any SessionStore {
        #if DEBUG
        if options.syncBackend == .uiTestLocal {
            if options.resetStore || options.forgetSession { UITestSessionStore.wipe() }
            return UITestSessionStore()
        }
        #endif
        return KeychainSessionStore()
    }
}
```

- [ ] **Step 4: The UI tests' session store**

In `ios/GymRollins/App/DebugSyncSupport.swift`, delete the line `import Supabase`, and replace the `UITestAuthStorage`
class and its doc comment (the last declaration in the file, above `#endif`) with:

```swift
/// DEBUG-only session store for UI tests against the local Worker: it survives relaunches like the Keychain, but
/// `-resetStore` and `-forgetSession` wipe it, so a relaunch can act as a fresh install or a revoked session.
final class UITestSessionStore: SessionStore, @unchecked Sendable {
    static let suiteName = "com.rollins.gymrollins.uitest-auth"
    private static let key = "session"
    private let defaults = UserDefaults(suiteName: UITestSessionStore.suiteName) ?? .standard
    private let lock = NSLock()

    static func wipe() { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }

    func load() -> StoredSession? { lock.withLock { read() } }

    func save(_ session: StoredSession) throws {
        let data = try JSONEncoder().encode(session)
        lock.withLock { defaults.set(data, forKey: Self.key) }
    }

    @discardableResult func clear(ifToken token: String?) -> Bool {
        lock.withLock {
            if let token, read()?.token != token { return false }
            let held = defaults.data(forKey: Self.key) != nil
            defaults.removeObject(forKey: Self.key)
            return held
        }
    }

    private func read() -> StoredSession? {
        defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(StoredSession.self, from: $0) }
    }
}
```

- [ ] **Step 5: The catalogue stays unavailable until plan 28**

In `ios/GymRollins/App/AppEnvironment+GymCatalog.swift`:
- Delete the line `import Supabase`.
- Replace `/// Stands in when the build has no Supabase config: reads find nothing, writes need an account.` with:

```swift
/// Stands in while there is no catalogue server: a build without a backend, or the API before plan 28 adds the
/// catalogue. Reads find nothing and writes need an account. Neither holds any of the account's photos, so account
/// deletion's photo steps have nothing to detach or remove.
```

- In `UnavailableGymCatalogTransport`, replace `func deleteAllPhotos() async throws { throw GymCatalogError.signedOut }`
  with `func deleteAllPhotos() async throws {}`, and `func detachAllPhotos() async throws { throw GymCatalogError.signedOut }`
  with `func detachAllPhotos() async throws {}`.
- In `makeGymSharing`, replace

```swift
        let transport: any GymCatalogTransport = sync.auth.map { SupabaseGymCatalogTransport(client: $0.client) }
            ?? UnavailableGymCatalogTransport()
```

with

```swift
        // The shared catalogue isn't on the API until plan 28, and the Supabase one can't use the API's session.
        let transport: any GymCatalogTransport = UnavailableGymCatalogTransport()
```

- [ ] **Step 6: Comments that named Supabase for sign-in**

In `ios/GymRollins/App/LaunchOptions.swift`, replace

```swift
    /// The Supabase project from Info.plist (in DEBUG, `SUPABASE_URL`/`SUPABASE_ANON_KEY` env vars win).
    case configured
    /// DEBUG/UI-test only (`-uiTesting -uiTestingBackend local`): like `configured`, but the auth session is kept
    /// in a test-only store that `-resetStore` wipes, so a relaunch can simulate a fresh install.
```

with

```swift
    /// The API from Info.plist's `API_URL` (in DEBUG, an `API_URL` environment variable wins).
    case configured
    /// DEBUG/UI-test only (`-uiTesting -uiTestingBackend local`): like `configured`, but the session is kept in a
    /// test-only store that `-resetStore` wipes, so a relaunch can simulate a fresh install.
```

and `/// The process environment (DEBUG builds read the Supabase URL/key overrides from it).` with

```swift
    /// The process environment (DEBUG builds read `API_URL` from it, and the Supabase overrides that photo hosting and
    /// Claude's connector still use).
```

In `ios/GymRollins/Features/Account/AppleSignIn.swift`, replace

```swift
/// Nonce for Sign in with Apple via Supabase: Apple gets the SHA-256 hash in the request, Supabase gets the raw
/// value with the identity token and checks that they match (replay protection).
```

with

```swift
/// Nonce for Sign in with Apple: Apple gets the SHA-256 hash in the request, the API's Better Auth gets the raw value
/// with the identity token and checks that they match (replay protection).
```

and `/// "Sign in with Apple" wired to Supabase: generates a fresh nonce per attempt and hands the identity token plus`
with `/// "Sign in with Apple" for the API's Better Auth: generates a fresh nonce per attempt and hands the identity token plus`.

- [ ] **Step 7: The two app tests that build an `AuthService`**

In `ios/GymRollinsTests/GymWipeEnvironmentTests.swift`, replace

```swift
        let client = SupabaseConfig(url: URL(string: "http://127.0.0.1:9")!, anonKey: "anon")
            .makeClient(storage: InMemoryAuthStorage())
        let auth = AuthService(client: client, events: stream)
```

with

```swift
        let api = ApiClient(baseURL: URL(string: "http://127.0.0.1:9")!, sessions: InMemorySessionStore())
        let auth = AuthService(api: api, events: stream)
```

and in `ios/GymRollinsTests/SyncAccountSafetyTests.swift` the same three lines, which end in `events: events)` there:

```swift
        let api = ApiClient(baseURL: URL(string: "http://127.0.0.1:9")!, sessions: InMemorySessionStore())
        let auth = AuthService(api: api, events: events)
```

Run: `grep -rn "import Supabase\|AuthService(client\|UITestAuthStorage" ios/GymRollins ios/GymRollinsTests`
Expected: no output.

- [ ] **Step 8: Run the tests**

Run, from `ios/`:

```bash
xcodegen generate --quiet
xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' \
  -only-testing:GymRollinsTests/KeychainSessionStoreTests -only-testing:GymRollinsTests/ServerMoveLaunchTests \
  -only-testing:GymRollinsTests/SyncAccountSafetyTests -only-testing:GymRollinsTests/LocalResetSessionTests \
  -only-testing:GymRollinsTests/GymWipeEnvironmentTests -only-testing:GymRollinsTests/AccountDeletionTests \
  -resultBundlePath build/TestResults-p27-app-$(date +%s).xcresult -quiet
xcrun xcresulttool get test-results summary --path "$(ls -td build/TestResults-p27-app-*.xcresult | head -1)"
```

Expected: `"result" : "Passed"`, `failedTests` 0, and `passedTests` equal to `totalTestCount`. The new suites add 4 tests.

Then run the package suites again: `(cd Packages/GymSync && swift test --filter GymSyncTests)`.
Expected: `Test run with 188 tests in 24 suites passed`. The Keychain store is tested in the app, where the simulator's
Keychain works.

- [ ] **Step 9: Commit**

```bash
git add ios
git commit -m "feat(app): sign in and sync with the API, Keychain session, and the server move at launch"
```

- [ ] **Step 10: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** decisions 9–11, 13 and 17. The move runs before `start()` restores the session; a failed move
   leaves sync off; the connector URL and photo hosting still read Supabase.
2. **Quality:** the `code-reviewer` agent.
3. **Security:** the `security-reviewer` agent, for `KeychainSessionStore` (accessibility class, no synchronizable flag,
   no logging) and the factory (the old session forgotten after a move; the DEBUG-only stores and env overrides
   compiled out of Release).

### Task 8: The integration suites on a throwaway Worker

**Files:**
- Create: `scripts/test-server.sh`
- Rewrite: `scripts/test-sync-integration.sh`
- Modify: `scripts/test-all.sh`, `scripts/test-gym-e2e.sh`, `server/README.md`

- [ ] **Step 1: Write the test Worker helper**

`scripts/test-server.sh` (sourced, not run; no `chmod`):

```bash
# Sourced by the iOS test scripts: a throwaway local Worker for tests, on its own port with its own state folder, so the
# development data (server/.wrangler/state, the Worker on 8787) is never touched. Local only: every wrangler command
# has --local. The caller sets ROOT. TEST_API_STATE may name the state folder (the server-move check keeps it in its
# work folder), outside the repo; otherwise a temporary one is made. stop_test_server removes it either way, with the
# accounts and rows the tests made.
TEST_API_PORT="${TEST_API_PORT:-8788}"
TEST_API_URL="http://127.0.0.1:$TEST_API_PORT"
TEST_API_PID=""

start_test_server() {
  local server="$ROOT/server"
  [[ -f "$server/.dev.vars" ]] || {
    echo "Missing server/.dev.vars: copy server/.dev.vars.example and set BETTER_AUTH_SECRET." >&2; return 1; }
  grep -qx 'ALLOW_PASSWORD_AUTH=1' "$server/.dev.vars" || {
    echo "server/.dev.vars needs ALLOW_PASSWORD_AUTH=1: the tests make their accounts by email." >&2; return 1; }
  if curl -s -o /dev/null --max-time 2 "$TEST_API_URL/"; then
    echo "Something already answers on $TEST_API_URL; stop it or set TEST_API_PORT." >&2; return 1
  fi
  TEST_API_STATE="${TEST_API_STATE:-$(mktemp -d -t gymrollins-test-api)}"
  case "$TEST_API_STATE/" in
    "$ROOT"/*) echo "TEST_API_STATE ($TEST_API_STATE) must be outside the repo." >&2; return 1 ;;
  esac
  mkdir -p "$TEST_API_STATE"
  local log="$TEST_API_STATE.log"
  (cd "$server" && { [[ -d node_modules ]] || npm ci; } \
    && npx wrangler d1 migrations apply gymrollins --local --persist-to "$TEST_API_STATE" < /dev/null) > "$log" 2>&1 || {
    echo "Migrating the test D1 failed; see $log" >&2; return 1; }
  (cd "$server" && exec npx wrangler dev --local --persist-to "$TEST_API_STATE" --ip 127.0.0.1 \
    --port "$TEST_API_PORT" --show-interactive-dev-session=false) >> "$log" 2>&1 &
  TEST_API_PID=$!
  for _ in $(seq 1 90); do
    [[ "$(curl -s -o /dev/null -w '%{http_code}' "$TEST_API_URL/v1/sync/profile")" == "401" ]] && return 0
    kill -0 "$TEST_API_PID" 2>/dev/null || break
    sleep 1
  done
  echo "The test Worker didn't come up on $TEST_API_URL; see $log" >&2
  return 1
}

# Stops the Worker (killing npm's wrangler stops workerd too) and removes its state.
stop_test_server() {
  if [[ -n "$TEST_API_PID" ]]; then
    kill "$TEST_API_PID" 2>/dev/null || true
    wait "$TEST_API_PID" 2>/dev/null || true
    TEST_API_PID=""
  fi
  if [[ -n "${TEST_API_STATE:-}" ]]; then
    rm -rf "$TEST_API_STATE" "$TEST_API_STATE.log"
  fi
}

# One number from the test Worker's D1: the SQL selects one column named n.
test_d1_count() {
  (cd "$ROOT/server" && npx wrangler d1 execute gymrollins --local --persist-to "$TEST_API_STATE" --json \
    --command "$1" 2>/dev/null) | node -e '
      let text = ""
      process.stdin.on("data", (chunk) => { text += chunk })
      process.stdin.on("end", () => console.log(JSON.parse(text)[0].results[0].n))'
}
```

- [ ] **Step 2: Rewrite `scripts/test-sync-integration.sh`**

Replace `scripts/test-sync-integration.sh` with:

```bash
#!/usr/bin/env bash
# GymSync integration tests against a throwaway LOCAL Worker (scripts/test-server.sh): port 8788 and a state folder of
# its own, removed afterwards, so server/.wrangler/state (the development data) is never touched. Every test makes its
# accounts fresh, as sync-<uuid>@test.local by email and password (ALLOW_PASSWORD_AUTH=1 in server/.dev.vars). The
# Supabase-only suites (gyms, proposals, Claude's grants) are parked until plans 28 and 29.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"

DELETED_FILE="$(mktemp -t gymsync-deleted-users)"
cleanup() {
  local status=$?
  rm -f "$DELETED_FILE"
  stop_test_server
  exit "$status"
}
trap cleanup EXIT
start_test_server

export API_URL="$TEST_API_URL" SYNC_DELETED_USERS_FILE="$DELETED_FILE"
(cd "$ROOT/ios/Packages/GymSync" && swift test --filter GymSyncIntegrationTests)

# Every account the tests deleted must have left no user, no session and no rows behind.
ids=$(sort -u "$DELETED_FILE" | grep -E '^[0-9a-f-]{36}$' | sed "s/.*/'&'/" | paste -sd, -)
[[ -n "$ids" ]] || { echo "No deleted accounts were recorded" >&2; exit 1; }
left=$(test_d1_count "select
    (select count(*) from \"user\" where id in ($ids))
  + (select count(*) from session where userId in ($ids))
  + (select count(*) from account where userId in ($ids))
  + (select count(*) from profiles where user_id in ($ids))
  + (select count(*) from custom_exercises where user_id in ($ids))
  + (select count(*) from exercise_prefs where user_id in ($ids))
  + (select count(*) from routines where user_id in ($ids))
  + (select count(*) from week_schedule where user_id in ($ids))
  + (select count(*) from muscle_targets where user_id in ($ids))
  + (select count(*) from workouts where user_id in ($ids))
  + (select count(*) from workout_entries where user_id in ($ids))
  + (select count(*) from workout_sets where user_id in ($ids))
  + (select count(*) from bodyweight where user_id in ($ids)) as n")
if [[ "$left" != "0" ]]; then
  echo "Account deletion left $left user/data rows behind" >&2
  exit 1
fi
echo "Account deletion verified: $(echo "$ids" | tr ',' '\n' | wc -l | tr -d ' ') deleted users, 0 rows left"
```

- [ ] **Step 3: Park the gym E2E and run the sync suites in `test-all.sh`**

In `scripts/test-gym-e2e.sh`, after `set -euo pipefail`, add:

```bash
# Parked until plan 28: its Swift suite (GymCatalogE2ETests) signs in with the Supabase client, which the app no longer
# has since plan 27 (ios/Packages/GymSync/Tests/GymSyncIntegrationTests/SupabaseParked).
echo "Parked until plan 28 moves the shared gym catalogue to the Worker." >&2
exit 1
```

In `scripts/test-all.sh`, replace

```bash
# E2E sync against the local Supabase stack (needs Docker): opt in with SYNC_E2E=1.
if [[ "${SYNC_E2E:-0}" == "1" ]]; then
  echo "==> iOS sync E2E (local Supabase)"
  "$ROOT/scripts/ios-test-sync.sh"
fi
```

with

```bash
# Sync against a throwaway local Worker (no Docker; needs server/.dev.vars): opt in with SYNC_E2E=1.
if [[ "${SYNC_E2E:-0}" == "1" ]]; then
  echo "==> GymSync integration and iOS sync E2E (throwaway local Worker on :8788)"
  "$ROOT/scripts/test-sync-integration.sh"
  "$ROOT/scripts/ios-test-sync.sh"
fi
```

and replace

```bash
# Gyms shared between two users and an anonymous client, against the local stack (needs Docker): opt in with GYM_E2E=1.
if [[ "${GYM_E2E:-0}" == "1" ]]; then
  echo "==> Shared gym catalogue E2E (local Supabase)"
  "$ROOT/scripts/test-gym-e2e.sh"
fi
```

with

```bash
# Gyms shared between two users: its Swift suite is parked until plan 28 moves the catalogue to the Worker.
if [[ "${GYM_E2E:-0}" == "1" ]]; then
  echo "==> Shared gym catalogue E2E: parked until plan 28"
fi
```

In the GymSync line near the top, replace `integration tests: scripts/test-sync-integration.sh)` with
`integration tests: scripts/test-sync-integration.sh, on a throwaway local Worker)`.

- [ ] **Step 4: Say so in the server README**

Append to `server/README.md`:

```markdown

The iOS integration and UI tests start a Worker of their own (`scripts/test-server.sh`): port 8788, a state folder that
is removed afterwards, and email accounts each test makes fresh (`ALLOW_PASSWORD_AUTH=1` in `.dev.vars`). They never
touch `.wrangler/state` or the Worker on 8787.
```

- [ ] **Step 5: Run the integration suites**

Run: `scripts/test-sync-integration.sh`. Leave the dev Worker alone; the script needs port 8788 free.
Expected:
- `Test run with 15 tests in 4 suites passed`.
- Then `Account deletion verified: 17 deleted users, 0 rows left`.
- `server/.wrangler/state` keeps its modification time: `stat -f %m server/.wrangler/state` before and after.

If a suite fails, fix the app side unless the server breaks a rule spec section 4 states. In that case, fix the server
in its own commit with a Vitest test first. Record each such fix in this task, as plan 26 recorded its review fixes.

- [ ] **Step 6: Commit**

```bash
git add scripts/test-server.sh scripts/test-sync-integration.sh scripts/test-all.sh scripts/test-gym-e2e.sh server/README.md
git commit -m "test(sync): integration suites on a throwaway local Worker, with D1 checked after account deletion"
```

- [ ] **Step 7: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** spec section 8 ("GymSyncIntegrationTests … run against `wrangler dev`"; "Tests run on their
   own local state folder") and decision 15.
2. **Quality:** the `code-reviewer` agent. Every `wrangler` call has `--local`, and the cleanup runs on every exit.

### Task 9: The sync UI tests on the Worker

**Files:**
- Modify: `ios/GymRollinsUITests/SyncUITests.swift`, `ios/GymRollinsUITests/ProposalSyncUITests.swift`
- Rewrite: `scripts/ios-test-sync.sh`

- [ ] **Step 1: Point `SyncUITests` at the Worker, and add the server-move check's UI part**

In `ios/GymRollinsUITests/SyncUITests.swift`, replace everything from the first line through the closing brace of
`setUpWithError()` with:

```swift
import XCTest

/// End-to-end sync against a throwaway LOCAL Worker (run via `scripts/ios-test-sync.sh`, which passes its URL as
/// `TEST_RUNNER_API_URL`; Xcode hands it to the runner as `API_URL`). Skipped otherwise, so the hermetic suite
/// (`scripts/ios-test.sh`) never touches the network. Each test makes its accounts fresh by email (DEBUG builds only).
@MainActor
final class SyncUITests: XCTestCase {
    static let password = "Passw0rd!"
    static let fixedNow = "2026-09-26T09:00:00Z"

    private var backend: [String: String] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let url = env["API_URL"], !url.isEmpty else {
            throw XCTSkip("No local Worker; run scripts/ios-test-sync.sh")
        }
        backend = ["API_URL": url]
    }
```

Above `    // MARK: Helpers`, add:

```swift
    /// The server-move check (spec section 8), run only by `scripts/server-move-check.sh`, which first puts a copy of
    /// the owner's phone store and settings into a throwaway simulator. The launch moves the data to the Worker, a new
    /// account signs in and adopts it, and the first sync uploads all of it. The script then compares D1's counts and
    /// the store with the copy.
    func testThePhonesDataMovesToTheWorker() throws {
        guard ProcessInfo.processInfo.environment["SERVER_MOVE_CHECK"] == "1" else {
            throw XCTSkip("Run by scripts/server-move-check.sh with a copy of the phone's store")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-uiTestingBackend", "local", "-diskStore", "-noSeed", "-forgetSession"]
        app.launchEnvironment = backend
        app.launch()
        app.tabBars.buttons["Log"].tap()
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'log.workout.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 20), "the copied store isn't in the app")
        openAccount(app)
        // An owner the move failed to clear would bring up the account-switch prompt instead of the email label.
        submitCredentials(app, email: "move-\(UUID().uuidString.lowercased())@test.local", button: "account.signUp")
        waitForLabel(app.staticTexts["account.status"], "Up to date", timeout: 600)
        app.terminate()
    }

```

In `ios/GymRollinsUITests/ProposalSyncUITests.swift`, replace
``/// End-to-end proposal flow against the LOCAL Supabase stack (run via `scripts/ios-test-sync.sh`; skipped otherwise):``
with ``/// End-to-end proposal flow against the LOCAL Supabase stack (skipped unless SUPABASE_URL is set; plan 29 moves it):``,
and `throw XCTSkip("Local Supabase not configured; run scripts/ios-test-sync.sh")` with
`throw XCTSkip("Proposals stay on Supabase until plan 29")`.

- [ ] **Step 2: Rewrite `scripts/ios-test-sync.sh`**

Replace `scripts/ios-test-sync.sh` with:

```bash
#!/usr/bin/env bash
# E2E sync UI tests (GymRollinsUITests/SyncUITests) against a throwaway LOCAL Worker (scripts/test-server.sh): port
# 8788 and a state folder of its own, removed afterwards. Only the Worker's local URL reaches the tests, as
# TEST_RUNNER_API_URL (Xcode hands it to the UI test runner without the prefix; the tests pass it to the app via
# launchEnvironment). Each test signs up fresh ui-<uuid>@test.local accounts by email (DEBUG builds only).
# ProposalSyncUITests stays on Supabase until plan 29, and the server-move test runs only from server-move-check.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.2}"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"
trap stop_test_server EXIT
start_test_server

cd "$ROOT/ios"
xcodegen generate --quiet
TEST_RUNNER_API_URL="$TEST_API_URL" \
  xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins -destination "$DEST" \
  -only-testing:GymRollinsUITests/SyncUITests \
  -resultBundlePath "$ROOT/ios/build/TestResults-sync-$(date +%s).xcresult" -quiet "$@"
```

- [ ] **Step 3: Run the sync UI tests**

Run:

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' scripts/ios-test-sync.sh
xcrun xcresulttool get test-results summary --path "$(ls -td ios/build/TestResults-sync-*.xcresult | head -1)"
```

Expected: `"result" : "Passed"`, `passedTests` 4, `skippedTests` 1 (the server-move test), `failedTests` 0.

- [ ] **Step 4: Commit**

```bash
git add ios/GymRollinsUITests scripts/ios-test-sync.sh
git commit -m "test(app): sync UI tests on a throwaway local Worker, and the server move's UI step"
```

- [ ] **Step 5: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** spec section 8 ("the sync UI tests run against `wrangler dev`, with the same suites").
2. **Quality:** the `code-reviewer` agent. Nothing but the local URL reaches the runner.

### Task 10: The server-move check with a copy of the owner's store

**Files:**
- Create: `scripts/compare-stores.mjs`, `scripts/compare-stores.test.mjs`, `scripts/server-move-check.sh`
- Modify: `scripts/test-all.sh`

The owner's store copy is at
`<scratchpad>/phone-backup-p25-1794090751/`
(the app container's `Library`). It is the owner's personal data:
- Never commit it, copy it into the repo, or paste its values anywhere. Only counts go into this plan's Outcome.
- Work on copies in a folder outside the repo; the script refuses one inside it.

- [ ] **Step 1: Write the failing test for the store comparison**

`scripts/compare-stores.test.mjs`:

```js
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { test } from 'node:test'
import { compareStores } from './compare-stores.mjs'

const id = (n) => Buffer.from(n.toString(16).padStart(32, '0'), 'hex')
const hexId = (n) => n.toString(16).padStart(32, '0')

/** A store holding only weigh-ins, laid out as Core Data lays out ZBODYWEIGHTRECORD. */
function store(dir, name, rows) {
  const file = path.join(dir, name)
  const db = new DatabaseSync(file)
  db.exec(`CREATE TABLE ZBODYWEIGHTRECORD (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZDIRTY INTEGER,
    ZDATE TIMESTAMP, ZSERVERUPDATEDAT TIMESTAMP, ZWEIGHTKG FLOAT, ZID BLOB)`)
  const insert = db.prepare('INSERT INTO ZBODYWEIGHTRECORD VALUES (?, 1, ?, ?, ?, ?, ?, ?)')
  for (const r of rows) insert.run(r.pk, r.opt ?? 1, r.dirty ?? 0, r.date, r.server ?? null, r.kg, id(r.id))
  db.close()
  return file
}

function inTemp(body) {
  const dir = mkdtempSync(path.join(tmpdir(), 'compare-stores-test-'))
  try {
    body(dir)
  } finally {
    rmSync(dir, { recursive: true, force: true })
  }
}

test('sync state and sub-microsecond noise are not differences', () => inTemp((dir) => {
  const before = store(dir, 'before', [{ pk: 1, id: 1, date: 800000000.1234567, kg: 81.4, server: 799999999 }])
  const after = store(dir, 'after', [{ pk: 9, id: 1, date: 800000000.123457, kg: 81.4, opt: 4, dirty: 1 }])
  assert.deepEqual(compareStores(before, after), [])
}))

test('a changed value, a missing record and a new one are', () => inTemp((dir) => {
  const before = store(dir, 'before', [{ pk: 1, id: 1, date: 800000000, kg: 81.4 }, { pk: 2, id: 2, date: 800000100, kg: 82 }])
  const after = store(dir, 'after', [{ pk: 1, id: 1, date: 800000000, kg: 82 }, { pk: 3, id: 3, date: 800000200, kg: 80 }])
  assert.deepEqual(compareStores(before, after), [
    `ZBODYWEIGHTRECORD ${hexId(1)}.ZWEIGHTKG: 81.4 -> 82`,
    `ZBODYWEIGHTRECORD ${hexId(2)}: missing after`,
    `ZBODYWEIGHTRECORD ${hexId(3)}: new after`,
  ])
}))
```

Run: `node --test scripts/compare-stores.test.mjs`
Expected: FAIL, `Cannot find module …/scripts/compare-stores.mjs`.

- [ ] **Step 2: Write the store comparison**

`scripts/compare-stores.mjs`:

```js
#!/usr/bin/env node
// Compares two copies of the app's SwiftData store and prints every record that differs in anything but sync state.
// scripts/server-move-check.sh runs it on the owner's store before and after the server move and the first upload, to
// show that nothing else changed (spec section 8). It never opens the files it is given: each store (with its -wal and
// -shm) is copied to a temporary folder first.
//
//   node scripts/compare-stores.mjs <before.store> <after.store>
//
// Records are matched by their own id, because a pull writes a workout's entries and sets afresh (new Z_PK). Dates are
// compared to the microsecond the server keeps, a profile's day fields by calendar day, and JSON blobs by value. Exits
// 1 and lists the differences when there are any.
import { copyFileSync, existsSync, mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { fileURLToPath } from 'node:url'

/** Core Data's bookkeeping and the sync state, which the move and the upload are meant to change. */
const SYNC_STATE = new Set(['Z_PK', 'Z_ENT', 'Z_OPT', 'ZDIRTY', 'ZSERVERUPDATEDAT'])
/** Core Data stores dates as seconds since 2001-01-01. */
const REFERENCE_DATE_MS = Date.UTC(2001, 0, 1)

/**
 * The tables compared, each keyed by the record's own id. `parents` are to-one columns, compared by the parent's id;
 * `skip` are columns the move changes on purpose, or caches; `days` are calendar days; `mayGo` says which records the
 * move may delete.
 */
export const TABLES = [
  { table: 'ZWORKOUTRECORD', key: 'ZID', skip: ['ZENTRIESDATA'] },
  { table: 'ZWORKOUTENTRYRECORD', key: 'ZID', parents: { ZWORKOUT: 'ZWORKOUTRECORD' } },
  { table: 'ZSETRECORD', key: 'ZID', parents: { ZENTRY: 'ZWORKOUTENTRYRECORD' } },
  { table: 'ZROUTINERECORD', key: 'ZID' },
  { table: 'ZROUTINEEXERCISERECORD', key: 'ZID', parents: { ZROUTINE: 'ZROUTINERECORD' } },
  { table: 'ZWEEKDAYRECORD', key: 'ZWEEKDAY' },
  { table: 'ZMUSCLETARGETRECORD', key: 'ZMUSCLE' },
  { table: 'ZEXERCISEPREFERENCERECORD', key: 'ZID' },
  { table: 'ZCUSTOMEXERCISERECORD', key: 'ZID' },
  { table: 'ZBODYWEIGHTRECORD', key: 'ZID' },
  { table: 'ZPROFILERECORD', key: 'ZID', days: ['ZGOALDATE', 'ZLIMITSUNTIL'] },
  { table: 'ZGYMRECORD', key: 'ZID' },
  // The move forgets the old server's photo names, so a picture on the phone uploads again.
  { table: 'ZGYMLISTINGRECORD', key: 'ZID', skip: ['ZREMOTEPHOTOPATH'] },
  { table: 'ZEQUIPMENTITEMRECORD', key: 'ZID' },
  // The move drops pending proposals: only the old server could resolve them.
  { table: 'ZPROPOSALRECORD', key: 'ZID', mayGo: (row) => row.ZSTATUSRAW === 'pending' },
]

function openCopy(file) {
  const dir = mkdtempSync(path.join(tmpdir(), 'compare-stores-'))
  for (const suffix of ['', '-wal', '-shm']) {
    if (existsSync(file + suffix)) copyFileSync(file + suffix, path.join(dir, `store${suffix}`))
  }
  return { db: new DatabaseSync(path.join(dir, 'store')), dir }
}

const hex = (value) => (value instanceof Uint8Array ? Buffer.from(value).toString('hex') : value)

const sorted = (value) => {
  if (Array.isArray(value)) return value.map(sorted)
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, sorted(value[key])]))
  }
  return value
}

/** A blob as its JSON with sorted keys when it is JSON, else its bytes in hex. */
function blob(value) {
  const bytes = Buffer.from(value)
  try {
    return JSON.stringify(sorted(JSON.parse(bytes.toString('utf8'))))
  } catch {
    return bytes.toString('hex')
  }
}

function localDay(seconds) {
  const day = new Date(REFERENCE_DATE_MS + seconds * 1000)
  const pad = (n) => String(n).padStart(2, '0')
  return `${day.getFullYear()}-${pad(day.getMonth() + 1)}-${pad(day.getDate())}`
}

/** One column's value, ready to compare: `{ time }` in microseconds, or `{ value }`. */
function cell(value, type, isDay) {
  if (value === null || value === undefined) return { value: null }
  if (type === 'TIMESTAMP') return isDay ? { value: localDay(value) } : { time: Math.round(value * 1e6) }
  if (value instanceof Uint8Array) return { value: blob(value) }
  return { value }
}

const same = (a, b) =>
  a.time !== undefined && b.time !== undefined ? Math.abs(a.time - b.time) <= 1 : a.value === b.value
const shown = (c) => (c.time !== undefined ? `${c.time}µs` : JSON.stringify(c.value))

function hasTable(db, table) {
  return db.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(table) !== undefined
}

/** One table's records by their key, each with its row and its cells by column. */
function records(db, spec) {
  const out = new Map()
  if (!hasTable(db, spec.table)) return out
  const parents = new Map(Object.entries(spec.parents ?? {}).map(([column, table]) => {
    const key = TABLES.find((t) => t.table === table).key
    const keys = db.prepare(`SELECT Z_PK AS pk, ${key} AS k FROM ${table}`).all().map((r) => [r.pk, hex(r.k)])
    return [column, new Map(keys)]
  }))
  const columns = db.prepare(`PRAGMA table_info(${spec.table})`).all()
    .filter((c) => !SYNC_STATE.has(c.name) && !(spec.skip ?? []).includes(c.name))
  for (const row of db.prepare(`SELECT * FROM ${spec.table}`).all()) {
    const cells = new Map(columns.map(({ name, type }) => [
      name,
      parents.has(name)
        ? { value: parents.get(name).get(row[name]) ?? null }
        : cell(row[name], String(type).toUpperCase(), (spec.days ?? []).includes(name)),
    ]))
    out.set(String(hex(row[spec.key])), { row, cells })
  }
  return out
}

/** Every difference between the two stores, one line each; empty when the records match. */
export function compareStores(beforeFile, afterFile) {
  const before = openCopy(beforeFile)
  const after = openCopy(afterFile)
  try {
    const problems = []
    for (const spec of TABLES) {
      const was = records(before.db, spec)
      const is = records(after.db, spec)
      for (const [key, { row, cells }] of was) {
        const now = is.get(key)
        if (!now) {
          if (!spec.mayGo?.(row)) problems.push(`${spec.table} ${key}: missing after`)
          continue
        }
        for (const [column, value] of cells) {
          const other = now.cells.get(column) ?? { value: null }
          if (!same(value, other)) problems.push(`${spec.table} ${key}.${column}: ${shown(value)} -> ${shown(other)}`)
        }
      }
      for (const key of is.keys()) if (!was.has(key)) problems.push(`${spec.table} ${key}: new after`)
    }
    return problems
  } finally {
    before.db.close()
    after.db.close()
    rmSync(before.dir, { recursive: true, force: true })
    rmSync(after.dir, { recursive: true, force: true })
  }
}

if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  const [beforeFile, afterFile] = process.argv.slice(2)
  if (!beforeFile || !afterFile) {
    console.error('usage: node scripts/compare-stores.mjs <before.store> <after.store>')
    process.exit(2)
  }
  const problems = compareStores(beforeFile, afterFile)
  for (const line of problems) console.log(line)
  console.log(problems.length === 0 ? 'Stores match apart from sync state.' : `${problems.length} differences.`)
  process.exit(problems.length === 0 ? 0 : 1)
}
```

Run: `node --test scripts/compare-stores.test.mjs`
Expected: `# pass 2`, `# fail 0` (and a `node:sqlite` ExperimentalWarning on stderr, which is fine).

Before committing, the comparison was tried on a scratch copy of the owner's store:
- the copy against itself: "Stores match apart from sync state";
- with every workout's sync state changed and every weigh-in's date moved 0.4 µs: still matches;
- with one routine's `paused` flipped: exactly that one difference.

- [ ] **Step 3: Write the check**

`scripts/server-move-check.sh` (then `chmod +x scripts/server-move-check.sh`):

```bash
#!/usr/bin/env bash
# The server-move check (spec section 8, iOS; acceptance criterion 7). A COPY of the owner's phone store goes into a
# throwaway simulator, the app moves it to a throwaway local Worker, a new account signs in, and the first sync uploads
# it. Then D1's counts must equal the copy's, and the phone's records must be unchanged apart from sync state.
#
#   scripts/server-move-check.sh <phone-backup-dir> <work-dir>
#
# <phone-backup-dir> holds the app container's Library: Library/Application Support/default.store (with its -wal and
# -shm) and Library/Preferences/com.rollins.gymrollins.plist. It is only read. <work-dir> gets every copy, the build and
# the D1 state. Both must be outside the repo, because this is the owner's personal data. The simulator and the D1
# state are deleted at the end; delete <work-dir> once the numbers are noted. Local only: no Cloudflare account,
# nothing on a phone.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKUP="$(cd "${1:?usage: server-move-check.sh <phone-backup-dir> <work-dir>}" && pwd)"
mkdir -p "${2:?usage: server-move-check.sh <phone-backup-dir> <work-dir>}"
WORK="$(cd "$2" && pwd)"
for dir in "$BACKUP" "$WORK"; do
  case "$dir/" in
    "$ROOT"/*) echo "Refusing: $dir is inside the repo, and the owner's data stays out of it." >&2; exit 1 ;;
  esac
done
STORE="$BACKUP/Library/Application Support/default.store"
PREFS="$BACKUP/Library/Preferences/com.rollins.gymrollins.plist"
[[ -f "$STORE" && -f "$PREFS" ]] || { echo "No store or settings under $BACKUP/Library" >&2; exit 1; }

# The copies: `before` is the reference the comparison reads, `count` is the one sqlite3 counts.
mkdir -p "$WORK/before" "$WORK/count" "$WORK/after"
for suffix in "" -wal -shm; do
  if [[ -f "$STORE$suffix" ]]; then
    cp "$STORE$suffix" "$WORK/before/default.store$suffix"
    cp "$STORE$suffix" "$WORK/count/default.store$suffix"
  fi
done
cp "$PREFS" "$WORK/before/com.rollins.gymrollins.plist"

export TEST_API_STATE="$WORK/d1"
# shellcheck source=scripts/test-server.sh
source "$ROOT/scripts/test-server.sh"
UDID="$(xcrun simctl create "GymRollins server move $(date +%s)" \
  com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro-Max com.apple.CoreSimulator.SimRuntime.iOS-26-2)"
cleanup() {
  local status=$?
  stop_test_server
  xcrun simctl shutdown "$UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$UDID" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
start_test_server
xcrun simctl bootstatus "$UDID" -b >/dev/null

# Build, install, then put the copies where a `-uiTesting -diskStore` launch reads them.
cd "$ROOT/ios"
xcodegen generate --quiet
xcodebuild build-for-testing -project GymRollins.xcodeproj -scheme GymRollins -destination "id=$UDID" \
  -derivedDataPath "$WORK/DerivedData" -quiet
xcrun simctl install "$UDID" "$WORK/DerivedData/Build/Products/Debug-iphonesimulator/GymRollins.app"
DATA="$(xcrun simctl get_app_container "$UDID" com.rollins.gymrollins data)"
mkdir -p "$DATA/tmp" "$DATA/Library/Preferences"
for suffix in "" -wal -shm; do
  if [[ -f "$WORK/before/default.store$suffix" ]]; then
    cp "$WORK/before/default.store$suffix" "$DATA/tmp/gymrollins-uitest.store$suffix"
  fi
done
cp "$WORK/before/com.rollins.gymrollins.plist" "$DATA/Library/Preferences/com.rollins.gymrollins.plist"

TEST_RUNNER_API_URL="$TEST_API_URL" TEST_RUNNER_SERVER_MOVE_CHECK=1 \
  xcodebuild test-without-building -project GymRollins.xcodeproj -scheme GymRollins -destination "id=$UDID" \
  -derivedDataPath "$WORK/DerivedData" \
  -only-testing:GymRollinsUITests/SyncUITests/testThePhonesDataMovesToTheWorker \
  -resultBundlePath "$WORK/TestResults-server-move.xcresult" -quiet

for suffix in "" -wal -shm; do
  if [[ -f "$DATA/tmp/gymrollins-uitest.store$suffix" ]]; then
    cp "$DATA/tmp/gymrollins-uitest.store$suffix" "$WORK/after/default.store$suffix"
  fi
done

# name | the copy's count (active workouts never sync) | D1's count (only the move's account is in this D1)
CHECKS=(
  "workouts|select count(*) from ZWORKOUTRECORD where ZISACTIVE = 0|select count(*) as n from workouts"
  "entries|select count(*) from ZWORKOUTENTRYRECORD e join ZWORKOUTRECORD w on e.ZWORKOUT = w.Z_PK where w.ZISACTIVE = 0|select count(*) as n from workout_entries"
  "sets|select count(*) from ZSETRECORD s join ZWORKOUTENTRYRECORD e on s.ZENTRY = e.Z_PK join ZWORKOUTRECORD w on e.ZWORKOUT = w.Z_PK where w.ZISACTIVE = 0|select count(*) as n from workout_sets"
  "routines|select count(*) from ZROUTINERECORD|select count(*) as n from routines"
  "body weights|select count(*) from ZBODYWEIGHTRECORD|select count(*) as n from bodyweight"
  "custom exercises|select count(*) from ZCUSTOMEXERCISERECORD|select count(*) as n from custom_exercises"
  "week days|select count(*) from ZWEEKDAYRECORD|select count(*) as n from week_schedule"
  "profile|select count(*) from ZPROFILERECORD|select count(*) as n from profiles"
  "exercise preferences|select count(*) from ZEXERCISEPREFERENCERECORD|select count(*) as n from exercise_prefs"
  "muscle targets|select count(*) from ZMUSCLETARGETRECORD|select count(*) as n from muscle_targets"
)
failed=0
printf '%-22s %8s %8s\n' "" "phone" "D1"
for check in "${CHECKS[@]}"; do
  IFS='|' read -r name copy_sql d1_sql <<< "$check"
  mine="$(sqlite3 "$WORK/count/default.store" "$copy_sql")"
  theirs="$(test_d1_count "$d1_sql")"
  printf '%-22s %8s %8s\n' "$name" "$mine" "$theirs"
  [[ "$mine" == "$theirs" ]] || failed=1
done
echo "(Spec section 8 lists 148 workouts, 836 entries, 2,685 sets, 6 routines and 24 body weights; the copy is the reference.)"

unsynced="$(sqlite3 "$WORK/after/default.store" "select
    (select count(*) from ZWORKOUTRECORD where ZISACTIVE = 0 and (ZDIRTY = 1 or ZSERVERUPDATEDAT is null))
  + (select count(*) from ZBODYWEIGHTRECORD where ZDIRTY = 1)
  + (select count(*) from ZROUTINERECORD where ZDIRTY = 1)
  + (select count(*) from ZCUSTOMEXERCISERECORD where ZDIRTY = 1)
  + (select count(*) from ZWEEKDAYRECORD where ZDIRTY = 1)
  + (select count(*) from ZPROFILERECORD where ZDIRTY = 1)
  + (select count(*) from ZEXERCISEPREFERENCERECORD where ZDIRTY = 1)
  + (select count(*) from ZMUSCLETARGETRECORD where ZDIRTY = 1)")"
echo "Records still unsynced on the phone: $unsynced"
[[ "$unsynced" == "0" ]] || failed=1

node "$ROOT/scripts/compare-stores.mjs" "$WORK/before/default.store" "$WORK/after/default.store" || failed=1
if [[ "$failed" != "0" ]]; then
  echo "Server move check FAILED" >&2
  exit 1
fi
echo "Server move verified."
```

- [ ] **Step 4: Add the comparison's test to `test-all.sh`**

In `scripts/test-all.sh`, after the seed generator block (its last line is
`node "$ROOT/scripts/gen-exercise-seed.mjs" --check`), add:

```bash

echo "==> Store comparison for the server-move check (node test)"
node --test "$ROOT/scripts/compare-stores.test.mjs"
```

- [ ] **Step 5: Run the check**

Close other simulators first if memory is short; the script boots one more and deletes it at the end. Run:

```bash
scripts/server-move-check.sh \
  <scratchpad>/phone-backup-p25-1794090751 \
  <scratchpad>/server-move-check
```

It takes 15–25 minutes: the build is most of it, and the upload is 148 workout requests plus the row batches. Expected:
- Phone and D1 equal on every line. From the copy: workouts 148, entries 836, sets 2,685, routines 6, body weights 23,
  custom exercises 42, week days 4, profile 1, exercise preferences 0, muscle targets 0.
- `Records still unsynced on the phone: 0`.
- `Stores match apart from sync state.`
- `Server move verified.`

If the UI test fails at "the copied store isn't in the app", Xcode's own install replaced the app's data. Then, in the
script, run the same `test-without-building` command once without `TEST_RUNNER_SERVER_MOVE_CHECK` right after
`simctl install` (the test skips itself), so Xcode installs before the copies go in. Re-run, and record the change in
this task.

Write the printed counts (numbers only) into this plan's Outcome. Then remove the work folder:
`rm -rf <scratchpad>/server-move-check`.

- [ ] **Step 6: Commit**

```bash
git status --short   # only the three scripts and test-all.sh; nothing from the copy
git add scripts/compare-stores.mjs scripts/compare-stores.test.mjs scripts/server-move-check.sh scripts/test-all.sh
git commit -m "test(app): the server-move check with a copy of the phone's store, compared record by record"
```

- [ ] **Step 7: Review**

A fresh reviewer reads `git diff HEAD~1`:
1. **Spec compliance:** spec section 8's server-move check, acceptance criterion 7, and decisions 12 and 17. The check
   is scoped to counts plus unchanged local records; D1's gym links wait for plan 28.
2. **Quality:** the `code-reviewer` agent.
3. **Security:** the `security-reviewer` agent, for the copies' paths (outside the repo, refused inside it), the
   simulator and D1 state deleted on every exit, and nothing printed but counts and record keys.

### Task 11: Finish

**Files:**
- Modify: this plan (the Outcome)

- [ ] **Step 1: Run everything this plan touched**

Run, one at a time:

```bash
(cd ios/Packages/GymCore && swift test)
(cd ios/Packages/GymData && swift test)
(cd ios/Packages/GymSync && swift test --filter GymSyncTests)
scripts/test-sync-integration.sh
node --test scripts/compare-stores.test.mjs
(cd server && npx vitest run && npx tsc --noEmit)
cd ios && xcodegen generate --quiet && xcodebuild test -project GymRollins.xcodeproj -scheme GymRollins \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' -only-testing:GymRollinsTests \
  -only-testing:GymRollinsUITests/ConflictUITests -only-testing:GymRollinsUITests/SettingsUITests \
  -only-testing:GymRollinsUITests/OnboardingUITests \
  -resultBundlePath build/TestResults-p27-final-$(date +%s).xcresult -quiet; cd ..
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.2' scripts/ios-test-sync.sh
```

Expected:
- GymCore unchanged.
- GymData: `Test run with 363 tests in 49 suites passed`.
- GymSync: `Test run with 188 tests in 24 suites passed`.
- Integration: `Test run with 15 tests in 4 suites passed`, then `Account deletion verified: 17 deleted users, 0 rows
  left`.
- Store comparison: `# pass 2`.
- Server unchanged: `Test Files  11 passed (11)`, `Tests  160 passed (160)`, no `tsc` output.
- App: every unit test and the three hermetic UI classes pass.
- Sync UI: 4 passed, 1 skipped.

- [ ] **Step 2: Review the whole plan's diff**

Have a separate reviewer read `git diff 163f76d...HEAD -- ios scripts server/README.md`:
- The `code-reviewer` agent, with the `swift` skill loaded for Swift 6.2 concurrency.
- The `security-reviewer` agent for `ApiClient`, `ApiClient+Auth`, `AuthService`, `KeychainSessionStore`,
  `SyncCoordinator+Factory`, `scripts/test-server.sh` and `scripts/server-move-check.sh`.

Fix CRITICAL and HIGH findings in their own commits, and re-run Step 1.

- [ ] **Step 3: Write the Outcome**

Append `## Outcome` to this plan:
- the commits per task,
- the final test counts,
- the server-move check's counts (numbers only),
- every place the build differed from this plan,
- what wasn't run.

Commit it as `docs: plan 27 outcome`.

## Handed to later plans

- **Plan 28 (gyms, photos, moderation):**
  - `ApiSyncTransport.servesGyms` becomes true, with gyms, listings and private photos on `/v1`.
  - `ApiGymCatalogTransport` replaces `UnavailableGymCatalogTransport`, including account deletion's two photo steps.
    `GymCatalogErrors.map` reads `ApiError`.
  - Exercise photo hosting moves from Supabase Storage to R2.
  - Extend the server move to the shared catalogue's cache: maps gyms' `remoteId` and `catalogRefreshedAt`, shared
    listings, items, the share outbox. They name the old server's catalogue.
  - Workouts that went up before their gym did keep the server's null until edited. The cutover never hits this
    (`pushGyms` runs first in the round), but test it.
  - Un-park the five gym suites, and `scripts/test-gym-e2e.sh`.
  - Re-run `scripts/server-move-check.sh` with a fresh copy, adding D1's `gym_id`/`gym_equipment_id` against the
    phone's links.
- **Plan 29 (Claude):**
  - `servesProposals` becomes true, on the proposal routes.
  - `lastMcpUse` and `revokeOAuthGrants` move to `/v1/claude/*`.
  - The connector URL becomes `<API_URL>/mcp`.
  - Un-park `ProposalTransportTests` and `OAuthGrantTransportTests`, and move `ProposalSyncUITests` to the Worker.
- **Plan 30 (remove Supabase):** delete `SupabaseConfig`, `SupabaseTransport*`, `SupabaseGymCatalogTransport*`,
  `InMemoryAuthStorage`, `SyncRecordRejected.isRowRejection`, `supabase-swift`, `SUPABASE_*` in `Base.xcconfig` and
  `project.yml`, the `SupabaseParked` folder if anything is left in it, and the Supabase half of `scripts/test-all.sh`.
- **Before the deploy (the owner's steps, spec section 9):**
  - Better Auth refuses an Apple id token without an `email` claim (`user_email_not_found`). The app asks for
    `.email`, so real tokens should carry it, but a real Apple token is first used at the cutover. If one doesn't, the
    server needs Better Auth's `mapProfileToUser` with a placeholder email.
  - Set `API_URL` in `Local.xcconfig` before installing on the phone: the move runs on that first launch.
