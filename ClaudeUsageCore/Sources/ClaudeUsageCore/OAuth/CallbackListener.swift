import Foundation
import Network

public protocol CallbackListening: Sendable {
    /// Binds the loopback port and returns it. `expectedState` is checked
    /// against the browser redirect.
    func start(expectedState: String) async throws -> UInt16
    /// Resolves with the authorization code, or throws a `SignInError`.
    func waitForCallback(timeout: TimeInterval) async throws -> String
    func stop()
}

/// One-shot HTTP listener on 127.0.0.1 that receives the OAuth redirect.
/// All mutable state is confined to `queue`.
public final class CallbackListener: CallbackListening, @unchecked Sendable {
    private let callbackPath: String
    private let queue = DispatchQueue(label: "ee.pixelchain.Claude-Usage.callback-listener")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var expectedState = ""
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?

    public init(callbackPath: String = OAuthConfiguration.claude.callbackPath) {
        self.callbackPath = callbackPath
    }

    public func start(expectedState: String) async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw SignInError.listenerFailed
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.expectedState = expectedState
                self.listener = listener
                var resumed = false
                listener.stateUpdateHandler = { state in
                    guard !resumed else { return }
                    switch state {
                    case .ready:
                        resumed = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed, .cancelled:
                        resumed = true
                        continuation.resume(throwing: SignInError.listenerFailed)
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { connection in
                    self.accept(connection)
                }
                listener.start(queue: self.queue)
            }
        }
    }

    public func waitForCallback(timeout: TimeInterval) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await self.awaitResult() }
            group.addTask {
                do { try await Task.sleep(for: .seconds(timeout)) } catch { throw SignInError.cancelled }
                throw SignInError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    public func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.connections.forEach { $0.cancel() }
            self.connections.removeAll()
            self.finish(.failure(SignInError.cancelled))
        }
    }

    // MARK: - Internals (all on `queue`)

    private func awaitResult() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let result = self.result {
                        continuation.resume(with: result)
                    } else {
                        self.continuation = continuation
                    }
                }
            }
        } onCancel: {
            queue.async { self.finish(.failure(SignInError.cancelled)) }
        }
    }

    /// Delivers the outcome once: to a waiting continuation, or buffered
    /// for the next `waitForCallback`. Later calls are ignored.
    private func finish(_ outcome: Result<String, Error>) {
        if let continuation {
            self.continuation = nil
            continuation.resume(with: outcome)
        } else if result == nil {
            result = outcome
        }
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.connections.removeAll { $0 === connection }
            default:
                break
            }
        }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, error in
            guard let self else { return }
            guard error == nil, let data, let text = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }
            let requestLine = text.components(separatedBy: .newlines).first ?? ""
            self.handle(requestLine: requestLine, on: connection)
        }
    }

    private func handle(requestLine: String, on connection: NWConnection) {
        switch CallbackRequestParser.parse(requestLine: requestLine, callbackPath: callbackPath) {
        case .notCallback:
            respond(connection, status: "404 Not Found", body: Self.page(title: "Not found", message: ""))
        case .denied(let error):
            respond(connection, status: "200 OK",
                    body: Self.page(title: "Sign-in cancelled",
                                    message: "You can close this tab and try again from the app."))
            finish(.failure(SignInError.denied(error)))
        case .success(let code, let state):
            guard state == expectedState else {
                respond(connection, status: "400 Bad Request",
                        body: Self.page(title: "Sign-in failed",
                                        message: "This response didn't match the sign-in attempt. Try again from the app."))
                finish(.failure(SignInError.stateMismatch))
                return
            }
            respond(connection, status: "200 OK",
                    body: Self.page(title: "Signed in to Claude Usage", message: "You can close this tab."))
            finish(.success(code))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func page(title: String, message: String) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"><title>\(title)</title>"
            + "<style>body{font-family:-apple-system,system-ui,sans-serif;margin:15vh auto;max-width:28em;text-align:center;color:#333}</style>"
            + "</head><body><h2>\(title)</h2><p>\(message)</p></body></html>"
    }
}
