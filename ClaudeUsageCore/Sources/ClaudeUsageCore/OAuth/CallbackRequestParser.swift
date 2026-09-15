import Foundation

public enum CallbackRequest: Equatable, Sendable {
    case success(code: String, state: String)
    case denied(error: String)
    case notCallback
}

/// Interprets the first line of the HTTP request the browser sends to the
/// loopback listener after the user approves (or rejects) the login.
public enum CallbackRequestParser {
    public static func parse(requestLine: String, callbackPath: String) -> CallbackRequest {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let components = URLComponents(string: String(parts[1])),
              components.path == callbackPath else {
            return .notCallback
        }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        if let error = value("error") { return .denied(error: error) }
        guard let code = value("code"), let state = value("state") else { return .notCallback }
        return .success(code: code, state: state)
    }
}
