import Foundation
import GRDB

// MARK: - Credential verdict (mirror of Rust `store::auth_state`)
//
// Three sentences look alike from a phone and mean opposite things: "the server
// rejected your key", "the server was unreachable", "we have never asked". Only
// the first means the user has something to do, so only the first is allowed to
// say so — which is why this takes a verdict rather than an error, and why a
// transport failure must not reach it at all.
//
// Stored in the existing `app_state` key/value table under one key per server:
// no new table, no schema version to negotiate, nothing to migrate. The value is
// the same compact JSON the Rust side writes, so the two mirrors of this store
// describe a verdict the same way.

public enum CredentialVerdict: String, Sendable, Equatable {
    /// A request that carried the credential was accepted.
    case accepted
    /// The server answered 401 or 403 to a request that carried it.
    case rejected
}

public enum CredentialState: String, Sendable, Equatable {
    /// Never observed, or the stored note could not be read.
    case unknown
    case valid
    case expired
}

/// A verdict and the moment it was earned, so the banner can say "since 12:04"
/// instead of asserting that a key is bad right now.
public struct CredentialReport: Sendable, Equatable {
    public var state: CredentialState
    public var at: String?

    public init(state: CredentialState, at: String? = nil) {
        self.state = state
        self.at = at
    }
}

public extension KomgaStore {
    static let credentialKeyPrefix = "auth_state:"

    private struct StoredNote: Codable {
        var state: String
        var at: String
    }

    static func credentialKey(serverID: String) -> String {
        "\(credentialKeyPrefix)\(serverID)"
    }

    func credentialState(serverID: String) throws -> CredentialReport {
        try dbQueue.read { db in try Self.credentialState(db: db, serverID: serverID) }
    }

    static func credentialState(db: GRDB.Database, serverID: String) throws -> CredentialReport {
        guard let raw = try appStateValue(db: db, key: credentialKey(serverID: serverID)) else {
            return CredentialReport(state: .unknown, at: nil)
        }
        // An unreadable value is `unknown` rather than `expired`: only this code
        // writes the key, so arriving here means a different era's build left it,
        // and a client that cannot read the note has to fall back to "ask the
        // server" — not to "your password is wrong".
        guard let data = raw.data(using: .utf8),
              let note = try? JSONDecoder().decode(StoredNote.self, from: data),
              let state = CredentialState(rawValue: note.state)
        else {
            return CredentialReport(state: .unknown, at: nil)
        }
        return CredentialReport(state: state, at: note.at)
    }

    @discardableResult
    func noteCredential(serverID: String, verdict: CredentialVerdict, at: String) throws -> CredentialState {
        try dbQueue.write { db in
            try Self.noteCredential(db, serverID: serverID, verdict: verdict, at: at)
        }
    }

    @discardableResult
    static func noteCredential(
        _ db: GRDB.Database,
        serverID: String,
        verdict: CredentialVerdict,
        at: String
    ) throws -> CredentialState {
        let state: CredentialState = verdict == .accepted ? .valid : .expired
        let note = StoredNote(state: state.rawValue, at: at)
        let payload = String(data: try JSONEncoder().encode(note), encoding: .utf8) ?? ""
        try putAppStateValue(db, key: credentialKey(serverID: serverID), value: payload)
        return state
    }

    /// Forget a verdict: when the credential itself is replaced, and when the
    /// server is deleted.
    func clearCredentialState(serverID: String) throws {
        try dbQueue.write { db in try Self.clearCredentialState(db, serverID: serverID) }
    }

    static func clearCredentialState(_ db: GRDB.Database, serverID: String) throws {
        try db.execute(
            sql: "DELETE FROM app_state WHERE key = ?",
            arguments: [credentialKey(serverID: serverID)]
        )
    }
}
