# Workout link page

What a workout link opens when the app doesn't take it. It isn't published yet, because the domain doesn't exist.

The steps for when it does are in `docs/specs/2026-11-01-shared-workout-design.md`, section 10. In short:

1. Publish `w/` at `/w` on any static host.
2. Copy `apple-app-site-association.template` to `/.well-known/apple-app-site-association`, with `TEAM_ID` replaced by the
   Apple team id. Serve it as `application/json`, with no redirect.
3. Set `SHARE_LINK_HOST` in `ios/Config/Base.xcconfig`, and add the associated domain to `ios/project.yml`.
4. Set `APP_STORE_URL` in `w/open.mjs` once the app is released.

The host should send these as headers, which a page can't set for itself: `Content-Security-Policy: frame-ancestors 'none'`
and `X-Content-Type-Options: nosniff`.

The host must serve `.mjs` as JavaScript, or the browser won't run `open.mjs`.

Test: `node --test web/share/share.test.mjs`
