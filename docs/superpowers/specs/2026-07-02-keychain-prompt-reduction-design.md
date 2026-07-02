# Keychain Prompt Reduction — Design

- **Date:** 2026-07-02
- **Status:** Awaiting user review. Approach #1 (lazy reads + in-memory cache) was selected per Claude's recommendation while the user was away; variants 2 and 3 below remain available as follow-ups.

## Problem

The app polls the usage API every 300 seconds (`UsageViewModel.refreshInterval`), and every cycle re-reads Claude Code's keychain item `"Claude Code-credentials"` via `SecItemCopyMatching` (`KeychainCredentialsStore` → `SystemKeychain`). That is ~288 protected keychain reads per day for a token that only changes every several hours.

macOS attaches "Always Allow" ACL grants to the keychain item *instance*, not its name. When Claude Code rotates its OAuth token it rewrites the item in a way that discards the ACL, so the app's next poll after any rewrite triggers a fresh approval prompt. The user sees prompts a few times a day despite clicking "Always Allow".

**Unavoidable floor:** one prompt per genuine token rotation, as long as the app reads Claude Code's item at all. Nothing on the app side can preserve an ACL across Claude Code's rewrites.

**Goal:** hit that floor — eliminate every keychain read (and therefore every prompt) that is not strictly required to obtain a token the app doesn't already hold.

## Design

### New: `CachedCredentialsStore` (ClaudeUsageCore)

A caching decorator around any `CredentialsProviding`:

- Final class holding the last good `Credentials` in memory; mutable state guarded by `NSLock`; conforms to `@unchecked Sendable`.
- `read(now:)`: if cached credentials exist and `expiresAt > now + leeway`, return them without touching the wrapped store. Otherwise delegate to the wrapped store, cache on success, and propagate errors (a failed delegate read does not poison or clear an existing cache entry; the cache was already stale/absent in that path).
- `leeway` is 60 seconds: re-read slightly before nominal expiry so a token that would expire mid-request is not used. The wrapped store's own `expiresAt > now` check is unchanged.
- `invalidate()`: clears the cached value.

### New protocol: `CredentialsCaching`

```swift
public protocol CredentialsCaching: CredentialsProviding {
    func invalidate()
}
```

`CachedCredentialsStore` conforms. This lets `UsageViewModel` invalidate on API-level auth failures without knowing the concrete type.

### Changed: `UsageViewModel`

- Init parameter type changes from `CredentialsProviding` to `CredentialsCaching` (test mocks gain an empty/recording `invalidate()`).
- `refresh()` flow on `UsageError.unauthorized`: call `credentials.invalidate()`, re-read credentials (this is the one legitimate keychain touch at a rotation boundary), and retry the fetch **once**. If the retry is also unauthorized, fall through to the existing degraded message ("Token rejected — open Claude Code to refresh"). The single-retry guard prevents prompt loops when the token is persistently rejected.
- All other behavior (5-minute cadence, degraded messages, expiry message) unchanged.

### Changed: `Claude_UsageApp`

Wire `CachedCredentialsStore(wrapping: KeychainCredentialsStore())` into the view model.

## Expected outcome

| | Before | After |
|---|---|---|
| Keychain reads/day | ~288 | ~2–3 (per expiry/401 only) |
| Prompts | one per Claude Code item rewrite | one per token rotation the app actually needs to cross |

Steady state touches the keychain zero times; intermediate Claude Code rewrites that don't invalidate the held token no longer cause any prompt.

## Error handling

- All `CredentialsError` cases pass through unchanged when the cache delegates.
- An expired token in the keychain still surfaces "Token expired — open Claude Code to refresh".
- Keychain denial still surfaces "Keychain access denied — re-allow in prompt".

## Testing

- `CachedCredentialsStore`: returns cached value without delegating before expiry; delegates once cached value is within leeway of expiry; `invalidate()` forces delegation; delegate errors propagate; successful delegate read repopulates the cache; wrapped-store call counts verified via a counting fake.
- `UsageViewModel`: 401 triggers `invalidate()` + exactly one retry; success on retry recovers to `.loaded`; second consecutive 401 yields the degraded message.

## Out of scope (documented follow-ups)

- **Variant 2 — app-owned mirror item:** persist the last good token in an app-owned keychain item so app relaunches never touch Claude Code's item while the mirror is valid.
- **Variant 3 — prompt-on-demand UX:** attempt non-interactive reads; when interaction is required, show an "Authorize" state in the popover and only prompt on user click.
