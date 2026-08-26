import Foundation

/// One server's sync state: last sync timestamps + status.
///
/// Written by the sync engine (BootstrapSync touches it on success); read
/// by the UI for "last synced" surfaces. Status vocabulary:
/// `idle` | `syncing` | `error` (lowercase, matches the schema default).
public struct SyncStateRecord: Sendable, Equatable {
    public let serverID: String
    public let lastFullSync: String?
    public let lastSuccessfulSync: String?
    public let lastError: String?
    public let syncStatus: String

    public init(
        serverID: String,
        lastFullSync: String?,
        lastSuccessfulSync: String?,
        lastError: String?,
        syncStatus: String
    ) {
        self.serverID = serverID
        self.lastFullSync = lastFullSync
        self.lastSuccessfulSync = lastSuccessfulSync
        self.lastError = lastError
        self.syncStatus = syncStatus
    }
}