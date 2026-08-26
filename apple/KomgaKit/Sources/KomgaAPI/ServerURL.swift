import Foundation

/// Errors thrown while normalizing a server URL.
public enum ServerURLError: Error, Equatable {
    case empty
    case invalid(String)
    case unsupportedScheme(String)
    case hasQueryOrFragment
}

/// Server base URL normalization.
///
/// Accepted forms:
/// - `https://komga.example.com`
/// - `http://192.168.1.10:25600`
/// - `https://example.com/komga/`
public enum ServerURL {
    /// Returns a canonical base URL: http/https only, path preserved,
    /// trailing slashes stripped, no query or fragment.
    public static func normalized(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerURLError.empty }
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased() else {
            throw ServerURLError.invalid(trimmed)
        }
        guard scheme == "http" || scheme == "https" else {
            throw ServerURLError.unsupportedScheme(scheme)
        }
        guard components.query == nil, components.fragment == nil else {
            throw ServerURLError.hasQueryOrFragment
        }
        guard let host = components.host, !host.isEmpty else {
            throw ServerURLError.invalid(trimmed)
        }

        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }

        var out = "\(scheme)://\(host)"
        if let port = components.port {
            out += ":\(port)"
        }
        out += path
        return out
    }
}
