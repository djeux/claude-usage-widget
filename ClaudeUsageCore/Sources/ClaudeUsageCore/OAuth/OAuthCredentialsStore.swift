import Foundation

/// Owns the app's OAuth grant: loads it once from the keychain, hands out
/// the access token while it is fresh, refreshes it when it is not, and
/// runs the interactive sign-in. Serialised by the actor; concurrent reads
/// during a refresh share one network call.
public actor OAuthCredentialsStore: SessionManaging {
    private let store: TokenStoring
    private let tokens: TokenExchanging
    private let flow: SignInFlow
    private let leeway: TimeInterval
    private var cached: TokenSet?
    private var loaded = false
    private var refreshTask: Task<TokenSet, Error>?

    public init(store: TokenStoring,
                tokens: TokenExchanging,
                config: OAuthConfiguration = .claude,
                flow: SignInFlow? = nil) {
        self.store = store
        self.tokens = tokens
        self.flow = flow ?? SignInFlow(config: config, tokens: tokens)
        self.leeway = config.refreshLeeway
    }

    public func read(now: Date) async throws -> Credentials {
        guard let current = try loadIfNeeded() else { throw CredentialsError.notLoggedIn }
        if current.expiresAt > now.addingTimeInterval(leeway) {
            return Credentials(accessToken: current.accessToken, expiresAt: current.expiresAt)
        }
        let fresh = try await refresh(current)
        return Credentials(accessToken: fresh.accessToken, expiresAt: fresh.expiresAt)
    }

    public func invalidate() {
        guard var current = cached else { return }
        current.expiresAt = .distantPast
        cached = current
    }

    public func signIn(openURL: @escaping @Sendable (URL) -> Void) async throws {
        let fresh = try await flow.run(openURL: openURL)
        do {
            try store.save(fresh)
        } catch {
            throw SignInError.storeFailed
        }
        cached = fresh
        loaded = true
    }

    public func signOut() {
        try? store.clear()
        cached = nil
        loaded = true
    }

    // MARK: - Internals

    private func loadIfNeeded() throws -> TokenSet? {
        if !loaded {
            cached = try store.load()
            loaded = true
        }
        return cached
    }

    private func refresh(_ current: TokenSet) async throws -> TokenSet {
        if let inFlight = refreshTask {
            return try await inFlight.value
        }
        let task = Task { try await self.performRefresh(current) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func performRefresh(_ current: TokenSet) async throws -> TokenSet {
        let fresh: TokenSet
        do {
            fresh = try await tokens.refresh(refreshToken: current.refreshToken)
        } catch TokenError.invalidGrant {
            try? store.clear()
            cached = nil
            throw CredentialsError.notLoggedIn
        } catch {
            throw CredentialsError.refreshFailed
        }
        // The refresh token rotates on every refresh, so keep the fresh set in
        // memory even if persisting it fails; otherwise the grant would be lost.
        cached = fresh
        try store.save(fresh)
        return fresh
    }
}
