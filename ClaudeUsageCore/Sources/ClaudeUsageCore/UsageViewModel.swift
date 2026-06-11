import Foundation
import Combine

@MainActor
public final class UsageViewModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case loading
        case loaded
        case degraded(String)
    }

    @Published public private(set) var snapshot: UsageSnapshot?
    @Published public private(set) var fetchedAt: Date?
    @Published public private(set) var phase: Phase = .loading

    public static let refreshInterval: TimeInterval = 300

    private let credentials: CredentialsProviding
    private var fetcher: UsageFetching
    private let now: () -> Date
    private var autoRefreshTask: Task<Void, Never>?

    public init(credentials: CredentialsProviding,
                fetcher: UsageFetching,
                now: @escaping () -> Date = Date.init) {
        self.credentials = credentials
        self.fetcher = fetcher
        self.now = now
    }

    deinit {
        autoRefreshTask?.cancel()
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
        let token: String
        do {
            token = try credentials.read(now: now()).accessToken
        } catch let error as CredentialsError {
            phase = .degraded(Self.message(for: error))
            return
        } catch {
            phase = .degraded("Couldn't read credentials")
            return
        }
        do {
            snapshot = try await fetcher.fetch(accessToken: token)
            fetchedAt = now()
            phase = .loaded
        } catch UsageError.unauthorized {
            phase = .degraded("Token rejected — open Claude Code to refresh")
        } catch {
            phase = .degraded("Couldn't reach Anthropic")
        }
    }

    static func message(for error: CredentialsError) -> String {
        switch error {
        case .notLoggedIn: return "Claude Code not logged in"
        case .accessDenied: return "Keychain access denied — re-allow in prompt"
        case .expired: return "Token expired — open Claude Code to refresh"
        case .malformed, .keychain: return "Couldn't read credentials"
        }
    }

    func setFetcherForTesting(_ fetcher: UsageFetching) {
        self.fetcher = fetcher
    }
}
