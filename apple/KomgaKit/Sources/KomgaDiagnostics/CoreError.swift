import Foundation

/// What kind of failure this was, at the boundary the UI reads.
///
/// Mirror of Rust `crate::ffi::error::ErrorCode`. The names and the two policy
/// bits are pinned by `specs/contracts/fixtures/errors/codes.json`, which
/// `DiagnosticsContractTests` loads — the same file the Rust and Dart suites
/// load, so a rename on one platform turns the other two red rather than
/// quietly degrading a message the UI acts on into `unknown`.
public enum CoreErrorCode: String, CaseIterable, Codable, Sendable, Equatable {
    /// 401 or 403: the server rejected the credential. The only code whose fix
    /// is something the user has to type.
    case authExpired
    /// No route, refused, timed out, or a stream that stopped mid-body.
    case networkUnavailable
    /// 404 or 410: the server no longer has that entity.
    case notFound
    /// 409: the server already holds a different answer for this write.
    case conflict
    /// 429: back off and come back on the existing schedule.
    case rateLimited
    /// Any other 4xx/5xx the taxonomy has no finer name for.
    case serverError
    /// This build's transport contract does not cover that server.
    case contractUnsupported
    /// The caller asked for something malformed, or the URL is not a URL.
    case invalidInput
    /// A response arrived and is not the shape `specs/openapi` documents.
    case decodeFailed
    /// SQLite said no, for any reason other than a lock.
    case databaseFailure
    /// Another connection held the write lock past `busy_timeout`.
    case databaseBusy
    /// The filesystem refused a write the client had already been told to make.
    case storageFailure
    /// A bounded event-stream read saw no frame. Normal, never a reschedule.
    case idle
    /// Anything this build cannot name, including a code from a newer client.
    case unknown

    /// The fixture order, which is the order the contract test compares against.
    public static let contractOrder: [CoreErrorCode] = [
        .authExpired, .networkUnavailable, .notFound, .conflict, .rateLimited,
        .serverError, .contractUnsupported, .invalidInput, .decodeFailed,
        .databaseFailure, .databaseBusy, .storageFailure, .idle, .unknown,
    ]

    /// Whether a later automatic attempt can plausibly succeed with nothing in
    /// between. The UI shows a spinner for `true` and a message for `false`.
    public var isRetryable: Bool {
        switch self {
        case .networkUnavailable, .rateLimited, .databaseBusy, .serverError:
            return true
        default:
            return false
        }
    }

    /// Whether the user has to act before this can work. Exactly one code, and
    /// that is the whole reason the bit is worth carrying.
    public var needsUser: Bool {
        self == .authExpired
    }
}

/// An error as the boundary sees it: what kind, what it said, and the two
/// decisions the UI has to make.
///
/// Swift's counterpart to Rust `CoreError`. The Apple side has no FFI, so the
/// type crosses a module boundary instead of a language one — which is why it
/// lives in a dependency-free target: `KomgaAPI` maps transport failures into
/// it, `KomgaStore` maps GRDB failures, and the app reads one taxonomy either
/// way.
public struct CoreError: Error, Sendable, Equatable, Codable, CustomStringConvertible {
    public var code: CoreErrorCode
    /// The client's own diagnostic text. Never a parse target: wording is free
    /// to change, which is exactly why the code exists next to it.
    public var message: String
    /// Derived from `code`, so a construction site cannot claim
    /// `authExpired, retryable: true` and split the UI's decision in two.
    public var retryable: Bool
    public var needsUser: Bool

    public init(code: CoreErrorCode, message: String) {
        self.code = code
        self.message = message
        self.retryable = code.isRetryable
        self.needsUser = code.needsUser
    }

    /// Decode-tolerant form for a payload that may name a code this build has
    /// never heard of. An unknown code keeps its message and degrades to
    /// `unknown`; it must not fail to decode, because that would turn a
    /// diagnostic into a crash on the way to reporting one.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent(String.self, forKey: .code) ?? "unknown"
        code = CoreErrorCode(rawValue: raw) ?? .unknown
        message = try container.decodeIfPresent(String.self, forKey: .message) ?? ""
        // Re-derived rather than trusted, so a payload that disagrees with the
        // table cannot win.
        retryable = code.isRetryable
        needsUser = code.needsUser
    }

    public enum CodingKeys: String, CodingKey {
        case code, message, retryable, needsUser
    }

    public var description: String { "[\(code.rawValue)] \(message)" }

    public static func unknown(_ message: String) -> CoreError {
        CoreError(code: .unknown, message: message)
    }
}
