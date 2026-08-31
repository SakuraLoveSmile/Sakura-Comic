import Foundation
import KomgaDiagnostics

// MARK: - Transport failure → the code the UI branches on
//
// Mirror of Rust `crate::ffi::error::CoreError::from(ApiError)`. The mapping
// lives here, next to the taxonomy it reads, for the same reason the Rust one
// lives at the boundary rather than in `api`: the transport already knows what
// kind of failure it met, and everything above it only knows what to do about it.

public extension KomgaAPIError {
    var coreError: CoreError {
        switch self {
        case .authentication:
            return CoreError(code: .authExpired, message: String(describing: self))
        case .network:
            return CoreError(code: .networkUnavailable, message: String(describing: self))
        case let .server(statusCode):
            switch statusCode {
            case 401, 403: return CoreError(code: .authExpired, message: String(describing: self))
            case 404, 410: return CoreError(code: .notFound, message: String(describing: self))
            case 409: return CoreError(code: .conflict, message: String(describing: self))
            case 429: return CoreError(code: .rateLimited, message: String(describing: self))
            default: return CoreError(code: .serverError, message: String(describing: self))
            }
        case let .apiCompatibility(message):
            return CoreError(code: .contractUnsupported, message: message)
        case let .urlInvalid(message):
            return CoreError(code: .invalidInput, message: message)
        case let .decode(message):
            return CoreError(code: .decodeFailed, message: message)
        }
    }
}
