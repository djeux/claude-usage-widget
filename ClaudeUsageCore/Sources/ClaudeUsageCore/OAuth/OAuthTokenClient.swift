import Foundation

public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public protocol TokenExchanging: Sendable {
    func exchange(code: String, codeVerifier: String, state: String, redirectURI: String) async throws -> TokenSet
    func refresh(refreshToken: String) async throws -> TokenSet
}

/// Talks to the token endpoint. Bodies are JSON, exactly as Claude Code sends them.
public struct OAuthTokenClient: TokenExchanging {
    private let config: OAuthConfiguration
    private let transport: HTTPTransport
    private let now: @Sendable () -> Date

    public static let urlSessionTransport: HTTPTransport = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TokenError.network("non-HTTP response") }
        return (data, http)
    }

    public init(config: OAuthConfiguration = .claude,
                transport: @escaping HTTPTransport = OAuthTokenClient.urlSessionTransport,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.config = config
        self.transport = transport
        self.now = now
    }

    public func exchange(code: String, codeVerifier: String, state: String, redirectURI: String) async throws -> TokenSet {
        try await post([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": config.clientID,
            "code_verifier": codeVerifier,
            "state": state,
        ], previousRefreshToken: nil)
    }

    public func refresh(refreshToken: String) async throws -> TokenSet {
        try await post([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID,
            "scope": config.scopes.joined(separator: " "),
        ], previousRefreshToken: refreshToken)
    }

    private struct RawResponse: Decodable {
        struct Account: Decodable { let email_address: String? }
        let access_token: String
        let refresh_token: String?
        let expires_in: Double?
        let scope: String?
        let account: Account?
    }

    private struct RawError: Decodable { let error: String? }

    private func post(_ body: [String: String], previousRefreshToken: String?) async throws -> TokenSet {
        var request = URLRequest(url: config.tokenURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as TokenError {
            throw error
        } catch {
            throw TokenError.network(error.localizedDescription)
        }

        switch response.statusCode {
        case 200:
            break
        case 401 where previousRefreshToken != nil:
            throw TokenError.invalidGrant
        case 400, 401:
            if (try? JSONDecoder().decode(RawError.self, from: data))?.error == "invalid_grant" {
                throw TokenError.invalidGrant
            }
            throw TokenError.http(response.statusCode)
        default:
            throw TokenError.http(response.statusCode)
        }

        guard let raw = try? JSONDecoder().decode(RawResponse.self, from: data) else { throw TokenError.decoding }
        guard let refreshToken = raw.refresh_token ?? previousRefreshToken else { throw TokenError.decoding }
        return TokenSet(accessToken: raw.access_token,
                        refreshToken: refreshToken,
                        expiresAt: now().addingTimeInterval(raw.expires_in ?? 3600),
                        scopes: (raw.scope ?? "").split(separator: " ").map(String.init),
                        accountEmail: raw.account?.email_address)
    }
}
