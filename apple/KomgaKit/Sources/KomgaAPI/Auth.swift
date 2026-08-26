import Foundation

/// Authentication method for Komga requests.
///
/// Primary: API Key (`X-API-Key`); Basic is kept as a compatibility fallback.
/// Secrets never persist in this type — construct it at request time from
/// platform credential storage, and never log it (use `redactedDescription`).
public enum AuthMethod: Sendable, Equatable {
    case apiKey(String)
    case basic(username: String, password: String)

    /// HTTP headers to attach to a request. Do not log this — it contains
    /// secret material.
    public var headerFields: [String: String] {
        switch self {
        case .apiKey(let key):
            return ["X-API-Key": key]
        case .basic(let username, let password):
            let token = Data("\(username):\(password)".utf8).base64EncodedString()
            return ["Authorization": "Basic \(token)"]
        }
    }

    /// Attach authentication headers to a URLRequest.
    public func apply(to request: inout URLRequest) {
        for (field, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: field)
        }
    }

    /// Safe for logs: contains no secret material.
    public var redactedDescription: String {
        switch self {
        case .apiKey: return "apiKey(***)"
        case .basic: return "basic(***)"
        }
    }
}
