import Foundation

/// Status vocabulary for `sync_state.sync_status` (mirror of Rust
/// `store::sync_state::STATUS_*`).
///
/// `idle` (nothing running / step complete) | `syncing` (in flight, or
/// interrupted with a resume point) | `error` (last attempt failed; the
/// cursor is still usable).
public enum SyncStatus {
    public static let idle = "idle"
    public static let syncing = "syncing"
    public static let error = "error"
}

/// Entity types tracked in `sync_state` (mirror of Rust `ENTITY_*`). `full`
/// is the server-level rollup written when a whole mirror run completes.
public enum SyncEntity {
    public static let libraries = "libraries"
    public static let series = "series"
    public static let books = "books"
    public static let collections = "collections"
    public static let readlists = "readlists"
    public static let readProgress = "read_progress"
    public static let full = "full"

    /// Bootstrap order from the initial-sync contract
    /// (`specs/contracts/initial-sync/README.md`).
    public static let bootstrapOrder: [String] = [
        libraries, series, books, collections, readlists, readProgress,
    ]
}

/// Cause vocabulary for `deleted_entities.cause` (mirror of Rust `CAUSE_*`).
public enum DeletionCause {
    /// Remote id missing from a completed Reconcile sweep.
    public static let reconcile = "reconcile"
    /// Removed because its parent entity went away.
    public static let cascade = "cascade"
    /// Removed on the strength of a single SSE event.
    public static let event = "event"
}

/// One `sync_state` row — the Stage 5 sync-state record: one row per
/// `(serverID, entityType)`. `syncCursor` is the resume point of an
/// interrupted sweep, so Bootstrap continues from that page instead of
/// re-downloading the library.
public struct EntitySyncState: Sendable, Equatable {
    public let serverID: String
    public let entityType: String
    public let lastSyncAt: String?
    public let syncCursor: String?
    public let syncStatus: String
    public let lastError: String?
    public let lastFullSync: String?
    public let lastSuccessfulSync: String?

    public init(
        serverID: String,
        entityType: String,
        lastSyncAt: String?,
        syncCursor: String?,
        syncStatus: String,
        lastError: String?,
        lastFullSync: String?,
        lastSuccessfulSync: String?
    ) {
        self.serverID = serverID
        self.entityType = entityType
        self.lastSyncAt = lastSyncAt
        self.syncCursor = syncCursor
        self.syncStatus = syncStatus
        self.lastError = lastError
        self.lastFullSync = lastFullSync
        self.lastSuccessfulSync = lastSuccessfulSync
    }
}

/// Server-level rollup view (the `full` row) — kept for the UI surfaces that
/// only care about "last synced".
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

    init(_ state: EntitySyncState) {
        self.init(
            serverID: state.serverID,
            lastFullSync: state.lastFullSync,
            lastSuccessfulSync: state.lastSuccessfulSync,
            lastError: state.lastError,
            syncStatus: state.syncStatus
        )
    }
}

/// One `deleted_entities` row: proof that the server no longer has this id.
public struct Tombstone: Sendable, Equatable {
    public let serverID: String
    public let entityType: String
    public let remoteID: String
    public let deletedAt: String
    public let cause: String

    public init(
        serverID: String,
        entityType: String,
        remoteID: String,
        deletedAt: String,
        cause: String
    ) {
        self.serverID = serverID
        self.entityType = entityType
        self.remoteID = remoteID
        self.deletedAt = deletedAt
        self.cause = cause
    }
}
