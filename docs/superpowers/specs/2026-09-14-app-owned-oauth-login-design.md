# App-Owned OAuth Login — Design

- **Date:** 2026-09-14
- **Status:** Awaiting user review.
- **Supersedes:** `2026-07-02-keychain-prompt-reduction-design.md` (that design only lowers prompts to one per token rotation; this one removes the shared keychain read entirely).

## Problem

The app reads Claude Code's keychain item `"Claude Code-credentials"` to get an access token. macOS ties "Always Allow" grants to the item *instance*, and Claude Code rewrites the item on every token rotation, so the user is re-prompted several times a day. As long as the app reads that item at all, at least one prompt per rotation is unavoidable. The app also cannot refresh the token itself: when it expires, the UI is stuck on "open Claude Code to refresh".

**Goal:** the app signs in on its own, holds its own tokens, refreshes them itself, and never touches Claude Code's keychain item. Zero keychain prompts, no dependency on Claude Code being installed or recently used.

## How Claude Code logs in (read from the 2.1.270 binary)

Claude Code uses a standard OAuth 2.0 authorization-code flow with PKCE and a **public client** (no secret). Everything the app needs is public:

| | Value |
|---|---|
| Authorize URL | `https://claude.com/cai/oauth/authorize` |
| Token URL | `https://platform.claude.com/v1/oauth/token` |
| Client ID | `9d1c250a-e61b-44d9-88ed-5944d1962f5e` |
| Redirect URI | `http://localhost:<port>/callback` (any port; Claude Code picks one at random) |
| Authorize query | `code=true`, `client_id`, `response_type=code`, `redirect_uri`, `scope` (space-separated), `code_challenge`, `code_challenge_method=S256`, `state` |
| Exchange body | JSON: `grant_type=authorization_code`, `code`, `redirect_uri`, `client_id`, `code_verifier`, `state` |
| Refresh body | JSON: `grant_type=refresh_token`, `refresh_token`, `client_id`, `scope` |
| Token response | `access_token`, `refresh_token` (may be absent on refresh — keep the old one), `expires_in` (seconds), `scope`, optional `account { uuid, email_address }` |

Claude Code requests `org:create_api_key user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload`. This app requests **`user:profile` only** — the scope gating account-info endpoints — and never `user:inference`. Whether `user:profile` alone satisfies `/api/oauth/usage` is verified as the first implementation step (see Open items).

**Risk, stated once:** this reuses Anthropic's Claude Code client ID from an unofficial app. Anthropic has pushed back on third-party tools using it for inference. Requesting only `user:profile` keeps this app on the "read my own account" side, but it remains unofficial and could be cut off — the same risk class as the undocumented usage endpoint the app already depends on. If it is cut off, the app degrades to "Sign-in failed" and keeps working once the user can sign in again.

## Design

All new types live in `ClaudeUsageCore` except the URL opener, which the app supplies. The existing `CredentialsProviding` seam is kept so `UsageViewModel` changes stay small.

### `OAuthConfiguration` (struct, constants)

`authorizeURL`, `tokenURL`, `clientID`, `scopes = ["user:profile"]`, `callbackPath = "/callback"`, `signInTimeout = 300 s`, `refreshLeeway = 60 s`. Single source of truth; tests reference it.

### `PKCE` (pure)

- `codeVerifier`: 32 random bytes, base64url without padding (43 chars, within RFC 7636's 43–128).
- `codeChallenge`: base64url(SHA-256(verifier)) via CryptoKit.
- `state`: 32 random bytes, base64url.
- `init()` draws from `SystemRandomNumberGenerator`; a second init takes explicit bytes for tests.

### `AuthorizationRequest` (pure)

`static func url(config:, pkce:, port:) -> URL` builds the authorize URL with exactly the query parameters in the table above, `redirect_uri = http://localhost:<port>/callback`.

### `CallbackListener` (Network framework)

One-shot HTTP listener that receives the browser redirect.

- `NWListener` bound to the **IPv4 loopback address only**, port `0` (ephemeral); exposes the assigned `port` after `start()`. Browsers that try `::1` first fall back to `127.0.0.1` on connection refused.
- `func waitForCallback(expectedState:, timeout:) async throws -> String` (returns the authorization code).
- Reads the first request line only. `CallbackRequestParser` (pure, tested separately) parses `GET /callback?code=…&state=… HTTP/1.1` into `.success(code:, state:)`, `.denied(error:)` (when `error=` is present), or `.notCallback` (any other path → respond 404 and keep listening).
- On a callback: compare `state` to `expectedState`; mismatch fails the sign-in (`SignInError.stateMismatch`). On match, respond `200 text/html` with a tiny static page ("Signed in to Claude Usage. You can close this tab.") that does **not** echo the code, then stop the listener.
- Timeout → `SignInError.timedOut`. Cancellation stops the listener.
- Never binds `0.0.0.0`; never stays open after the flow ends.

### `OAuthTokenClient` (`TokenExchanging` protocol)

```swift
public protocol TokenExchanging: Sendable {
    func exchange(code: String, codeVerifier: String, state: String, redirectURI: String) async throws -> TokenSet
    func refresh(refreshToken: String) async throws -> TokenSet
}
```

- `POST` JSON to `tokenURL`, `Content-Type: application/json`, 30 s timeout.
- Transport is an injected `HTTPTransport = (URLRequest) async throws -> (Data, HTTPURLResponse)`; production wraps `URLSession.shared`.
- Decodes `TokenSet { accessToken, refreshToken, expiresAt: Date, scopes: [String], accountEmail: String? }`. `expiresAt = now + expires_in`; if `expires_in` is absent, assume 1 hour (a wrong guess only costs one extra refresh on the next 401). On refresh, a missing `refresh_token` keeps the previous one.
- Errors: `TokenError.invalidGrant` (HTTP 400/401 whose JSON `error` is `invalid_grant`, or any 401 on refresh), `.http(status)`, `.network(String)`, `.decoding`.

### `KeychainTokenStore` (`TokenStoring` protocol)

```swift
public protocol TokenStoring: Sendable {
    func load() throws -> TokenSet?
    func save(_ tokens: TokenSet) throws
    func clear() throws
}
```

- Generic-password item in the login keychain: service `"Claude Usage"`, account `"claude.ai"`, data = JSON-encoded `TokenSet`.
- The app *creates* this item, so the ACL trusts the app's designated requirement. The project signs with Team ID `PFKADM33BC` (automatic signing), so the requirement is stable across rebuilds and reads never prompt. Claude Code's item is never read.
- `SystemKeychain` gains `set(data:service:account:)` (update-or-add) and `delete(service:account:)`; the existing `KeychainReading` protocol becomes `KeychainAccessing` with those three operations, so `CredentialsStoreTests`' fake keychain pattern still applies.

### `OAuthCredentialsStore` (actor, conforms to `CredentialsProviding`)

The central piece. Owns `TokenStoring`, `TokenExchanging`, an in-memory `TokenSet?` cache, and an optional in-flight `refreshTask`.

```swift
public protocol CredentialsProviding: Sendable {
    func read(now: Date) async throws -> Credentials   // now async
    func invalidate() async                            // force refresh on next read
}

public protocol SessionManaging: CredentialsProviding {
    func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws
    func signOut() async
}
```

`OAuthCredentialsStore` conforms to `SessionManaging`; `UsageViewModel` depends on `SessionManaging`. Tests fake both protocols in one type.

- `read(now:)`:
  1. Load from memory, else from `TokenStoring` (once). No tokens → throw `CredentialsError.notLoggedIn`.
  2. If `expiresAt > now + refreshLeeway` → return `Credentials(accessToken:, expiresAt:)` with no network call.
  3. Otherwise refresh. If a refresh is already in flight, await that task instead of starting another. On success: save to store and memory, return. On `TokenError.invalidGrant`: clear store and memory, throw `.notLoggedIn`. On any other `TokenError`: keep stored tokens untouched, throw `CredentialsError.refreshFailed`.
- `invalidate()`: marks the cached access token expired so the next `read` refreshes. Does not clear the store.
- `signIn(openURL:) async throws`: runs `SignInFlow`, saves the resulting `TokenSet`, populates memory.
- `signOut()`: clears store and memory.

### `SignInFlow`

Orchestrates one interactive login, injected with `TokenExchanging`, a listener factory, and `openURL: (URL) -> Void`:

1. `PKCE()` → start `CallbackListener` → build authorize URL with the assigned port → `openURL(url)`.
2. `await listener.waitForCallback(expectedState:, timeout:)` → code.
3. `exchange(code:, codeVerifier:, state:, redirectURI:)` → `TokenSet`.
4. Listener is stopped on every exit path (`defer`).

Errors: `SignInError.listenerFailed`, `.denied` (user cancelled in the browser), `.stateMismatch`, `.timedOut`, `.exchangeFailed(TokenError)`, `.cancelled`.

### `CredentialsError` (changed)

```swift
case notLoggedIn      // no tokens → sign-in prompt
case refreshFailed    // network/HTTP error during refresh; last data stays
case accessDenied     // keychain refused (only plausible for unsigned dev builds)
case malformed
case keychain(OSStatus)
```

`.expired` is removed; expiry is now handled by refresh.

### `UsageViewModel` (changed)

- `Phase` gains `.signedOut` and `.signingIn`; `.loading`, `.loaded`, `.degraded(String)` unchanged.
- New `@Published private(set) var signInError: String?` shown under the sign-in button.
- `refresh()`:
  - `CredentialsError.notLoggedIn` → `snapshot = nil`, `phase = .signedOut`.
  - `CredentialsError.refreshFailed` → `phase = .degraded("Couldn't reach Anthropic")`, snapshot kept (menu bar dims).
  - Other `CredentialsError` → degraded with the existing messages.
  - `UsageError.unauthorized` → `await credentials.invalidate()`, re-read (this refreshes), retry the fetch **once**. A second 401 means the freshly refreshed token is rejected: `signOut()`, `snapshot = nil`, `phase = .signedOut`, `signInError = "Anthropic rejected the token — sign in again"`.
  - While `phase == .signingIn`, `refresh()` returns immediately (the auto-refresh loop must not race the sign-in).
- `signIn()`: `phase = .signingIn`, `signInError = nil`; on success → `await refresh()`; on `SignInError` → `phase = .signedOut`, `signInError = message(for:)`. Idempotent: a second call while signing in is ignored.
- `cancelSignIn()`: cancels the in-flight sign-in task → `.signedOut`.
- `signOut()`: `await credentials.signOut()`, `snapshot = nil`, `phase = .signedOut`.
- Auto-refresh cadence unchanged (300 s). When signed out, each tick is a no-network `notLoggedIn` early return.
- Init takes `SessionManaging` plus `openURL: @escaping @Sendable (URL) -> Void`; the app passes `{ NSWorkspace.shared.open($0) }`. Tests pass a recording closure.

### `UsagePopoverView` / `MenuBarLabel` (app)

- `.signedOut`: replaces the limit rows with a short line ("Sign in with your Claude account to see usage") and a **Sign in** button; `signInError` (if any) renders in the existing orange warning label style.
- `.signingIn`: "Finish signing in in your browser…" with a **Cancel** button.
- Footer gains **Sign out** (hidden while signed out or signing in). Existing refresh button, launch-at-login toggle, and Quit unchanged.
- Menu bar shows `✽ –` whenever `snapshot` is nil (already the case), so signed-out reads as "no data".

### `Claude_UsageApp` wiring

```swift
UsageViewModel(
    credentials: OAuthCredentialsStore(store: KeychainTokenStore(),
                                       tokens: OAuthTokenClient()),
    fetcher: UsageClient(),
    openURL: { NSWorkspace.shared.open($0) })
```

### Removed

- `KeychainCredentialsStore`, its `RawCredentials` decoder, and `CredentialsStoreTests`' cases that cover them (replaced by `KeychainTokenStore` tests using the same fake-keychain pattern).
- All "open Claude Code to refresh" messages.

## Data flow

**First launch (or after sign-out):** `refresh()` → store empty → `.signedOut` → user clicks Sign in → `SignInFlow` opens the browser → user approves → browser hits `localhost:<port>/callback` → code exchanged → `TokenSet` saved to the app's keychain item → `refresh()` → `.loaded`.

**Steady state:** every 300 s `read(now:)` returns the cached access token with no keychain and no network access until it is within 60 s of expiry; then one refresh call, one keychain write.

**Token rejected:** 401 → invalidate → refresh → retry; second 401 → sign-out → `.signedOut` with an explanatory message.

**Offline:** refresh fails → `.degraded("Couldn't reach Anthropic")`, last snapshot kept and dimmed; next tick retries.

## Error handling summary

| Situation | Result |
|---|---|
| Listener can't bind | `signInError = "Couldn't start the local sign-in listener"` |
| User denies in browser (`error=access_denied`) | `signInError = "Sign-in was cancelled"` |
| `state` mismatch | `signInError = "Sign-in response didn't match — try again"` |
| No callback within 5 min | `signInError = "Sign-in timed out"` |
| Exchange HTTP error | `signInError = "Sign-in failed (HTTP nnn)"` |
| Exchange network error | `signInError = "Sign-in failed — couldn't reach Anthropic"` |
| Keychain write fails during sign-in | sign-in fails with `"Couldn't save the login to the keychain"`; nothing kept in memory |
| Refresh `invalid_grant` | tokens cleared → `.signedOut` |
| Refresh network/5xx | `.degraded("Couldn't reach Anthropic")`, tokens and snapshot kept |

## Security notes

- PKCE S256; `state` checked; listener loopback-only, ephemeral port, one-shot, closed on every exit path; the success page never echoes the code.
- Refresh token lives only in the app-owned keychain item and in the actor's memory. It is never logged or shown.
- Scope is `user:profile` only. The app cannot make inference calls with its token.
- No new network hosts beyond `claude.com` / `platform.claude.com` (login) and `api.anthropic.com` (usage).

## Testing

All in `ClaudeUsageCoreTests` unless noted.

- **PKCE:** verifier is 43 base64url chars; challenge matches RFC 7636 Appendix B (`dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk` → `E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM`); two inits differ.
- **AuthorizationRequest:** exact host/path and every query parameter, including `code=true` and `code_challenge_method=S256`.
- **CallbackRequestParser:** parses code and state; `error=` → `.denied`; other paths → `.notCallback`; malformed request lines don't crash.
- **CallbackListener** (integration, loopback): start, `URLSession` GET to `http://127.0.0.1:<port>/callback?code=x&state=y` → returns `x`, response is 200 and does not contain `x`; wrong state → `stateMismatch`; timeout with no request → `timedOut`.
- **OAuthTokenClient:** with a stub transport — exchange and refresh bodies are exactly the JSON in the table; response decoding incl. missing `refresh_token` and missing `expires_in`; `invalid_grant` → `.invalidGrant`; 500 → `.http(500)`.
- **KeychainTokenStore:** round-trip through a fake keychain; `clear` → `load` returns nil; corrupt data → `malformed`.
- **OAuthCredentialsStore:** valid token returned without touching exchanger; within leeway → refresh, save, return new token; concurrent reads during a refresh trigger exactly one refresh; `invalidGrant` clears store and throws `notLoggedIn`; network error throws `refreshFailed` and leaves store untouched; `invalidate()` forces a refresh; `signOut()` clears; `signIn` saves.
- **SignInFlow:** with fake listener + fake exchanger — success returns the token set; denied/timeout/mismatch map to the right `SignInError`; listener is stopped on failure.
- **UsageViewModel:** `notLoggedIn` → `.signedOut` and nil snapshot; `refreshFailed` keeps snapshot and degrades; 401 → one `invalidate` + one retry → `.loaded`; double 401 → `signOut` called, `.signedOut`, message set; `signIn` success → `.signingIn` then `.loaded`; `signIn` failure → `.signedOut` with `signInError`; `refresh()` is a no-op while `.signingIn`; `openURL` receives a URL whose host is `claude.com`.
- **Manual:** fresh install → Sign in → browser → back to `.loaded` with no keychain prompt; quit and relaunch → still signed in, no prompt; Sign out → `.signedOut`; wait past token expiry → refresh happens silently.

## README changes

- Requirements: drop "Claude Code installed and logged in"; needs a Claude subscription account.
- Install: replace the "Always Allow" step with "click Sign in and approve in the browser".
- Privacy: the app has its own login (same OAuth client as Claude Code, `user:profile` scope only), stores its tokens in its own keychain item, never reads Claude Code's keychain, and talks only to the login hosts and the usage endpoint.

## Open items (resolved during implementation, not before)

1. **Scope check:** the first implementation task is a throwaway script or test that completes the flow with `user:profile` and calls `/api/oauth/usage`. If the endpoint rejects that scope, widen `OAuthConfiguration.scopes` to the smallest set that works and record the result here. Nothing else in the design changes.
2. **Token response shape:** the decoder is written leniently (all fields except `access_token` optional) so an unexpected extra or missing field doesn't break sign-in.

## Out of scope

- Manual paste-a-code fallback (`platform.claude.com/oauth/code/callback`). Add only if the localhost listener proves unreliable.
- Multiple accounts / account switching beyond sign out + sign in.
- Data-protection keychain (`kSecUseDataProtectionKeychain`); the login keychain item is sufficient because the app creates it.
- Migrating the old "Always Allow" grant on Claude Code's item: nothing to do; the app simply stops reading it.
