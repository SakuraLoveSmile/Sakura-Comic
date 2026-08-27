import Foundation
import GRDB

// MARK: - Sync state (mirror of Rust `store/sync_state.rs`)
//
// One `sync_state` row per `(server_id, entity_type)`: Bootstrap writes a
// cursor checkpoint after every committed page, so an interrupted run resumes
// from that page instead of re-downloading the library; a failure keeps the
// cursor and flags `error` so the next attempt can recover.
//
// Naming map to Rust: `recordSuccessfulSync` = `touch_successful_sync`,
// `recordFullSync` = `record_full_sync`, `recordFailedSync` =
// `touch_failed_sync`, `syncState` = `get_sync_state`.

public extension KomgaStore {
    /// Mark a step as running, keeping any resume cursor it already has.
    func beginEntity(serverID: String, entityType: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (server_id, entity_type, sync_status)
                VALUES (?, ?, ?)
                ON CONFLICT(server_id, entity_type) DO UPDATE SET sync_status = excluded.sync_status
                """,
                arguments: [serverID, entityType, SyncStatus.syncing]
            )
        }
    }

    /// Commit a resume point: the cursor of the next page still to fetch.
    func checkpointEntity(serverID: String, entityType: String, cursor: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (server_id, entity_type, last_sync_at, sync_cursor, sync_status)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(server_id, entity_type) DO UPDATE SET
                  last_sync_at = excluded.last_sync_at,
                  sync_cursor = excluded.sync_cursor,
                  sync_status = excluded.sync_status
                """,
                arguments: [serverID, entityType, Self.rfc3339Text(Date()), cursor, SyncStatus.syncing]
            )
        }
    }

    /// Mark a step done: cursor cleared, timestamp stamped, status idle.
    func completeEntity(serverID: String, entityType: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (server_id, entity_type, last_sync_at, sync_cursor, sync_status, last_error)
                VALUES (?, ?, ?, NULL, ?, NULL)
                ON CONFLICT(server_id, entity_type) DO UPDATE SET
                  last_sync_at = excluded.last_sync_at,
                  sync_cursor = NULL,
                  sync_status = excluded.sync_status,
                  last_error = NULL
                """,
                arguments: [serverID, entityType, Self.rfc3339Text(Date()), SyncStatus.idle]
            )
        }
    }

    /// Mark a step failed. The resume cursor stays so the next attempt can
    /// pick up where this one stopped.
    func failEntity(serverID: String, entityType: String, error: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (server_id, entity_type, sync_status, last_error)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(server_id, entity_type) DO UPDATE SET
                  sync_status = excluded.sync_status,
                  last_error = excluded.last_error
                """,
                arguments: [serverID, entityType, SyncStatus.error, error]
            )
        }
    }

    /// The `sync_state` row for one step, if any.
    func entityState(serverID: String, entityType: String) throws -> EntitySyncState? {
        try dbQueue.read { db in
            try Self.entityState(
                db,
                sql: "SELECT * FROM sync_state WHERE server_id = ? AND entity_type = ?",
                arguments: [serverID, entityType]
            )
        }
    }

    /// Every sync-state row for one server, oldest checkpoint first.
    func listEntityStates(serverID: String) throws -> [EntitySyncState] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM sync_state WHERE server_id = ?
                 ORDER BY last_sync_at IS NULL, last_sync_at, entity_type
                """,
                arguments: [serverID]
            ).map(Self.entityState(from:))
        }
    }

    /// The stored resume cursor, if a previous run was interrupted mid-sweep.
    func resumeCursor(serverID: String, entityType: String) throws -> String? {
        try entityState(serverID: serverID, entityType: entityType)?.syncCursor
    }

    /// True when a step is mid-sweep (interrupted or crashed run) and has
    /// work left to do — Bootstrap resumes it instead of skipping it.
    func isResumable(serverID: String, entityType: String) throws -> Bool {
        try entityState(serverID: serverID, entityType: entityType)?.syncCursor != nil
    }

    /// True when a step completed in an earlier run and needs no work now.
    func stepIsComplete(serverID: String, entityType: String) throws -> Bool {
        guard let state = try entityState(serverID: serverID, entityType: entityType) else {
            return false
        }
        return state.syncCursor == nil && state.syncStatus == SyncStatus.idle
    }

    /// Timestamp of the last completed full mirror, for reconcile throttling.
    func lastSyncedAt(serverID: String) throws -> String? {
        try entityState(serverID: serverID, entityType: SyncEntity.full)?.lastSyncAt
    }

    /// Record a failed sync: status + error message on the rollup row.
    func recordFailedSync(serverID: String, error: String) throws {
        try failEntity(serverID: serverID, entityType: SyncEntity.full, error: error)
    }

    /// Drop every step cursor + completion stamp (what `StartAt.fresh` does).
    /// The `full` rollup row survives: it is history, not progress.
    func clearSyncProgress(serverID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM sync_state WHERE server_id = ? AND entity_type != ?",
                arguments: [serverID, SyncEntity.full]
            )
        }
    }

    // MARK: - Row mapping

    static func entityState(
        _ db: GRDB.Database,
        sql: String,
        arguments: StatementArguments = StatementArguments()
    ) throws -> EntitySyncState? {
        try Row.fetchOne(db, sql: sql, arguments: arguments).map(entityState(from:))
    }

    static func entityState(from row: Row) -> EntitySyncState {
        let lastSyncAt: String? = row["last_sync_at"]
        let syncCursor: String? = row["sync_cursor"]
        let lastError: String? = row["last_error"]
        let lastFullSync: String? = row["last_full_sync"]
        let lastSuccessfulSync: String? = row["last_successful_sync"]
        return EntitySyncState(
            serverID: row["server_id"],
            entityType: row["entity_type"],
            lastSyncAt: lastSyncAt,
            syncCursor: syncCursor,
            syncStatus: row["sync_status"],
            lastError: lastError,
            lastFullSync: lastFullSync,
            lastSuccessfulSync: lastSuccessfulSync
        )
    }
}
