import Foundation
import GRDB
import KomgaDiagnostics

// MARK: - SQLite failure → the code the UI branches on
//
// The one distinction worth keeping is SQLITE_BUSY: it means "another
// connection is mid-write", which resolves itself on the next attempt, from
// every other database failure, which does not. Rust has to sniff its own error
// text for that pair; GRDB hands over the result code, so this side does not
// have to guess.
//
// Only the primary code is compared: a lock arrives with an extended code too,
// and the UI's decision — retry quietly, or tell somebody — is the same for
// every variant of a lock.

public extension DatabaseError {
    var coreError: CoreError {
        let text = message ?? "database error (\(resultCode.rawValue))"
        switch resultCode.primaryResultCode {
        case ResultCode.SQLITE_BUSY, ResultCode.SQLITE_LOCKED:
            return CoreError(code: .databaseBusy, message: text)
        default:
            return CoreError(code: .databaseFailure, message: text)
        }
    }
}
