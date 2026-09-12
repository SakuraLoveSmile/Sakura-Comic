import Foundation

/// Centralized sanitizer for logs, error messages, URLs, and diagnostic exports.
/// Ensures that secrets, tokens, passwords, and server credentials are never exposed
/// in the UI or in diagnostic exports.
public enum DiagnosticsSanitizer {
    private static let rules: [(pattern: NSRegularExpression, template: String)] = [
        // Authorization headers (Bearer, Basic, raw token)
        (
            try! NSRegularExpression(
                pattern: #"(?i)Authorization\s*:\s*(?:Bearer\s+[A-Za-z0-9\-._~+/]+=*|Basic\s+[A-Za-z0-9+/=]+|[^\s\r\n]+)"#
            ),
            "Authorization: [REDACTED]"
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?i)\bBearer\s+[A-Za-z0-9\-._~+/]+=*"#
            ),
            "Bearer [REDACTED]"
        ),
        (
            try! NSRegularExpression(
                pattern: #"(?i)\bBasic\s+[A-Za-z0-9+/=]+"#
            ),
            "Basic [REDACTED]"
        ),

        // Custom authentication headers
        (
            try! NSRegularExpression(
                pattern: #"(?i)\b(X-API-Key|X-Auth-Token)\s*:\s*[^\s\r\n]+"#
            ),
            "$1: [REDACTED]"
        ),

        // Embedded URL credentials (e.g., http://user:pass@host)
        (
            try! NSRegularExpression(
                pattern: #"(?i)(https?://)[^:/\s]+:[^@/\s]+@"#
            ),
            "$1[REDACTED_AUTH]@"
        ),

        // URL query parameters (e.g., ?key=secret, &token=secret, ?api_key=secret)
        (
            try! NSRegularExpression(
                pattern: #"(?i)([?&](?:apikey|api_key|key|token|password|secret|auth)=)[^& \r\n"'\t]+"#
            ),
            "$1[REDACTED]"
        ),

        // Key-value credentials (e.g., apikey: xyz, token=xyz, password: xyz)
        (
            try! NSRegularExpression(
                pattern: #"(?i)\b(apikey|api_key|token|password|secret|key)\s*[:=]\s*[^\s,;&"']+"#
            ),
            "$1=[REDACTED]"
        )
    ]

    /// Sanitizes any free-form string (log message, URL, error string).
    public static func redact(_ input: String) -> String {
        var result = input
        for (regex, template) in rules {
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: template)
        }
        return result
    }

    /// Masks server identifier to prevent leaking specific internal host/infrastructure hashes.
    public static func redactServerID(_ id: String) -> String {
        if id.count <= 8 {
            return "***"
        }
        return String(id.prefix(8)) + "***"
    }

    /// Redacts a single CoreLog record.
    public static func redactRecord(_ record: CoreLog.Record) -> CoreLog.Record {
        CoreLog.Record(
            level: record.level,
            target: record.target,
            message: redact(record.message),
            at: record.at
        )
    }

    /// Fetches recent logs from CoreLog with all messages pre-sanitized.
    public static func redactedLogs(limit: Int = 100, minLevel: String? = nil) -> [CoreLog.Record] {
        CoreLog.shared.recent(limit: limit, minLevel: minLevel).map(redactRecord)
    }
}
