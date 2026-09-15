import Foundation
import Combine

@MainActor
public final class UsageViewModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case degraded(String)
        case signedOut
        case signingIn
    }

    @Published public private(set) var snapshot: UsageSnapshot?
    @Published public private(set) var fetchedAt: Date?
    @Published public private(set) var phase: Phase = .loading
    @Published public private(set) var signInError: String?

    public static let refreshInterval: TimeInterval = 300

    private let credentials: SessionManaging
    private let fetcher: UsageFetching
    private let openURL: @Sendable (URL) -> Void
    private let now: () -> Date
    private var autoRefreshTask: Task<Void, Never>?
    private var signInTask: Task<Void, Error>?

    public init(credentials: SessionManaging,
                fetcher: UsageFetching,
                openURL: @escaping @Sendable (URL) -> Void,
                now: @escaping () -> Date = Date.init) {
        self.credentials = credentials
        self.fetcher = fetcher
        self.openURL = openURL
        self.now = now
    }

    deinit {
        autoRefreshTask?.cancel()
        signInTask?.cancel()
    }

    /// The limit closest to its cap — what the menu bar shows.
    public var mostConstrained: LimitWindow? {
        snapshot?.windows.max(by: { $0.utilization < $1.utilization })
    }

    /// Refresh now and every `refreshInterval` seconds thereafter. Idempotent.
    public func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    public func refresh() async {
        guard phase != .signingIn else { return }
        let token: String
        do {
            token = try await credentials.read(now: now()).accessToken
        } catch CredentialsError.notLoggedIn {
            snapshot = nil
            phase = .signedOut
            return
        } catch let error as CredentialsError {
            phase = .degraded(Self.message(for: error))
            return
        } catch {
            phase = .degraded("Couldn't read credentials")
            return
        }
        do {
            try await fetchAndStore(token)
        } catch UsageError.unauthorized {
            await retryAfterUnauthorized()
        } catch {
            phase = .degraded("Couldn't reach Anthropic")
        }
    }

    /// Runs the browser login. Safe to call while one is in progress (joins it).
    public func signIn() async {
        if let signInTask {
            _ = try? await signInTask.value
            return
        }
        phase = .signingIn
        signInError = nil
        let task = Task { [credentials, openURL] in
            try await credentials.signIn(openURL: openURL)
        }
        signInTask = task
        defer { signInTask = nil }
        do {
            try await task.value
            phase = .loading
            await refresh()
        } catch let error as SignInError {
            phase = .signedOut
            signInError = Self.message(for: error)
        } catch is CancellationError {
            phase = .signedOut
        } catch {
            phase = .signedOut
            signInError = "Sign-in failed"
        }
    }

    public func cancelSignIn() {
        signInTask?.cancel()
    }

    public func signOut() async {
        signInTask?.cancel()
        await credentials.signOut()
        snapshot = nil
        fetchedAt = nil
        signInError = nil
        phase = .signedOut
    }

    private func fetchAndStore(_ token: String) async throws {
        snapshot = try await fetcher.fetch(accessToken: token)
        fetchedAt = now()
        phase = .loaded
    }

    /// One forced refresh + retry. A second 401 means the grant itself is
    /// bad, so the stored login is dropped and the user is asked to sign in.
    private func retryAfterUnauthorized() async {
        await credentials.invalidate()
        do {
            let token = try await credentials.read(now: now()).accessToken
            try await fetchAndStore(token)
        } catch UsageError.unauthorized {
            await credentials.signOut()
            snapshot = nil
            phase = .signedOut
            signInError = "Anthropic rejected the token — sign in again"
        } catch CredentialsError.notLoggedIn {
            snapshot = nil
            phase = .signedOut
        } catch let error as CredentialsError {
            phase = .degraded(Self.message(for: error))
        } catch {
            phase = .degraded("Couldn't reach Anthropic")
        }
    }

    static func message(for error: CredentialsError) -> String {
        switch error {
        case .notLoggedIn: return "Not signed in"
        case .refreshFailed: return "Couldn't reach Anthropic"
        case .accessDenied: return "Keychain access denied — re-allow in prompt"
        case .malformed, .keychain: return "Couldn't read credentials"
        }
    }

    static func message(for error: SignInError) -> String? {
        switch error {
        case .listenerFailed: return "Couldn't start the local sign-in listener"
        case .denied: return "Sign-in was cancelled"
        case .stateMismatch: return "Sign-in response didn't match — try again"
        case .timedOut: return "Sign-in timed out"
        case .exchangeFailed(.http(let status)): return "Sign-in failed (HTTP \(status))"
        case .exchangeFailed(.network): return "Sign-in failed — couldn't reach Anthropic"
        case .exchangeFailed: return "Sign-in failed"
        case .storeFailed: return "Couldn't save the login to the keychain"
        case .cancelled: return nil
        }
    }
}
