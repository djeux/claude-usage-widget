import Foundation

public enum UsageError: Error, Equatable, Sendable {
    case unauthorized
    case http(Int)
    case decoding
}

public protocol UsageFetching: Sendable {
    func fetch(accessToken: String) async throws -> UsageSnapshot
}

/// Calls the endpoint Claude Code's /usage command uses. Unofficial API —
/// the decoder is tolerant and the view model degrades gracefully if it changes.
public struct UsageClient: UsageFetching {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.endpoint)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UsageError.http(-1) }
        if http.statusCode == 401 { throw UsageError.unauthorized }
        guard http.statusCode == 200 else { throw UsageError.http(http.statusCode) }
        do {
            return try UsageResponseDecoder.decode(data)
        } catch {
            throw UsageError.decoding
        }
    }
}
