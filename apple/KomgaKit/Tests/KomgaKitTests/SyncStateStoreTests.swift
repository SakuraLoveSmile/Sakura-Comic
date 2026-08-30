import XCTest
import GRDB
@testable import KomgaAPI
@testable import KomgaStore
@testable import KomgaSync

/// Stage 5 sync-state contract: one `sync_state` row per
/// `(serverID, entityType)`, resume cursors that survive a failure, and the
/// v5 → v6 rebuild that turns the old single row into the `full` rollup.
final class SyncStateStoreTests: XCTestCase {
    func testPerEntityRowsAreIndependent() throws {
        let store = try KomgaStore()
        try store.beginEntity(serverID: "srv-1", entityType: SyncEntity.series)
        try store.checkpointEntity(serverID: "srv-1", entityType: SyncEntity.series, cursor: "page=3")
        try store.completeEntity(serverID: "srv-1", entityType: SyncEntity.books)

        let series = try XCTUnwrap(store.entityState(serverID: "srv-1", entityType: SyncEntity.series))
        XCTAssertEqual(series.syncCursor, "page=3")
        XCTAssertEqual(series.syncStatus, SyncStatus.syncing)
        XCTAssertNotNil(series.lastSyncAt)
        XCTAssertTrue(try store.isResumable(serverID: "srv-1", entityType: SyncEntity.series))
        XCTAssertFalse(try store.stepIsComplete(serverID: "srv-1", entityType: SyncEntity.series))

        let books = try XCTUnwrap(store.entityState(serverID: "srv-1", entityType: SyncEntity.books))
        XCTAssertEqual(books.syncStatus, SyncStatus.idle)
        XCTAssertNil(books.syncCursor)
        XCTAssertFalse(try store.isResumable(serverID: "srv-1", entityType: SyncEntity.books))
        XCTAssertTrue(try store.stepIsComplete(serverID: "srv-1", entityType: SyncEntity.books))

        // Untouched entity types have no row at all.
        XCTAssertNil(try store.entityState(serverID: "srv-1", entityType: SyncEntity.readlists))
        XCTAssertEqual(try store.listEntityStates(serverID: "srv-1").count, 2)
    }

    func testFailureKeepsTheResumeCursor() throws {
        let store = try KomgaStore()
        try store.checkpointEntity(serverID: "srv-1", entityType: SyncEntity.books, cursor: "series-2|page=1")
        try store.failEntity(serverID: "srv-1", entityType: SyncEntity.books, error: "boom")

        let books = try XCTUnwrap(store.entityState(serverID: "srv-1", entityType: SyncEntity.books))
        XCTAssertEqual(books.syncStatus, SyncStatus.error)
        XCTAssertEqual(books.syncCursor, "series-2|page=1")
        XCTAssertEqual(books.lastError, "boom")
        XCTAssertTrue(try store.isResumable(serverID: "srv-1", entityType: SyncEntity.books))
    }

    func testMultiServerIsolation() throws {
        let store = try KomgaStore()
        try store.checkpointEntity(serverID: "srv-1", entityType: SyncEntity.series, cursor: "page=2")
        try store.checkpointEntity(serverID: "srv-2", entityType: SyncEntity.series, cursor: "page=7")
        XCTAssertEqual(try store.resumeCursor(serverID: "srv-1", entityType: SyncEntity.series), "page=2")
        XCTAssertEqual(try store.resumeCursor(serverID: "srv-2", entityType: SyncEntity.series), "page=7")
    }

    func testRollupRowCarriesTheSyncHistory() throws {
        let store = try KomgaStore()
        XCTAssertNil(try store.syncState(serverID: "srv-1"))

        let full = try store.recordFullSync(serverID: "srv-1")
        XCTAssertEqual(full.syncStatus, SyncStatus.idle)
        XCTAssertNotNil(full.lastFullSync)
        XCTAssertEqual(full.lastSuccessfulSync, full.lastFullSync)
        // The rollup stamp is what reconcile throttling reads.
        XCTAssertEqual(try store.lastSyncedAt(serverID: "srv-1"), full.lastFullSync)
        let row = try XCTUnwrap(store.entityState(serverID: "srv-1", entityType: SyncEntity.full))
        XCTAssertEqual(row.entityType, SyncEntity.full)
        XCTAssertNil(row.syncCursor)

        try store.recordFailedSync(serverID: "srv-1", error: "network")
        XCTAssertEqual(try store.syncState(serverID: "srv-1")?.syncStatus, SyncStatus.error)
        XCTAssertEqual(try store.syncState(serverID: "srv-1")?.lastError, "network")
        // A later success clears the error and keeps the full-sync history.
        _ = try store.recordSuccessfulSync(serverID: "srv-1")
        let recovered = try XCTUnwrap(store.syncState(serverID: "srv-1"))
        XCTAssertEqual(recovered.syncStatus, SyncStatus.idle)
        XCTAssertNil(recovered.lastError)
        XCTAssertNotNil(recovered.lastFullSync)
    }

    func testFreshStartDropsStepCursorsButKeepsTheRollup() throws {
        let store = try KomgaStore()
        try store.checkpointEntity(serverID: "srv-1", entityType: SyncEntity.series, cursor: "page=4")
        try store.completeEntity(serverID: "srv-1", entityType: SyncEntity.libraries)
        _ = try store.recordFullSync(serverID: "srv-1")

        try store.clearSyncProgress(serverID: "srv-1")
        XCTAssertNil(try store.entityState(serverID: "srv-1", entityType: SyncEntity.series))
        XCTAssertNil(try store.entityState(serverID: "srv-1", entityType: SyncEntity.libraries))
        XCTAssertNotNil(try store.entityState(serverID: "srv-1", entityType: SyncEntity.full))
    }

    // MARK: - Cursors

    func testCursorRoundTrip() {
        XCTAssertEqual(FullSync.parsePage("page=3"), 3)
        XCTAssertEqual(FullSync.parsePage("nonsense"), 0)
        XCTAssertEqual(FullSync.pageCursor(7), "page=7")
        XCTAssertEqual(FullSync.bookCursor(seriesID: "s2", page: 1), "series=s2|page=1")
        let parsed = try? XCTUnwrap(FullSync.parseBookCursor("series=s2|page=1"))
        XCTAssertEqual(parsed?.seriesID, "s2")
        XCTAssertEqual(parsed?.page, 1)
        XCTAssertNil(FullSync.parseBookCursor("page=1"))
        XCTAssertNil(FullSync.parseBookCursor("series=s2"))
    }

    // MARK: - Reconcile triggering

    func testShouldReconcileOnlyThrottlesBackgroundTriggers() throws {
        let store = try KomgaStore()
        let now = Date()
        // Never synced: the first chance is the right chance.
        XCTAssertTrue(try ReconcileSync.shouldRun(
            store: store, serverID: "srv-1", trigger: .appLaunch, now: now
        ))

        _ = try store.recordFullSync(serverID: "srv-1")
        let stamp = try XCTUnwrap(store.lastSyncedAt(serverID: "srv-1"))
        let syncedAt = try XCTUnwrap(ReconcileSync.parseTimestamp(stamp))

        // Ten seconds after a completed mirror, a foreground launch waits.
        XCTAssertFalse(try ReconcileSync.shouldRun(
            store: store, serverID: "srv-1", trigger: .didBecomeActive, now: syncedAt.addingTimeInterval(10)
        ))
        // Once the window has passed it runs again.
        XCTAssertTrue(try ReconcileSync.shouldRun(
            store: store, serverID: "srv-1", trigger: .appLaunch,
            now: syncedAt.addingTimeInterval(minReconcileIntervalSeconds)
        ))
        // Explicit triggers never wait.
        for trigger in [ReconcileTrigger.networkRecovered, .sseReconnected, .manualRefresh] {
            XCTAssertTrue(try ReconcileSync.shouldRun(
                store: store, serverID: "srv-1", trigger: trigger, now: syncedAt
            ))
        }
        // An unreadable stamp re-syncs rather than staying stale.
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE sync_state SET last_sync_at = 'not-a-date' WHERE entity_type = 'full'"
            )
        }
        XCTAssertTrue(try ReconcileSync.shouldRun(
            store: store, serverID: "srv-1", trigger: .appLaunch, now: now
        ))
    }

    func testTriggerNamesMatchTheContract() {
        XCTAssertEqual(ReconcileTrigger.appLaunch.rawValue, "app_launch")
        XCTAssertEqual(ReconcileTrigger.didBecomeActive.rawValue, "did_become_active")
        XCTAssertEqual(ReconcileTrigger.networkRecovered.rawValue, "network_recovered")
        XCTAssertEqual(ReconcileTrigger.sseReconnected.rawValue, "sse_reconnected")
        XCTAssertEqual(ReconcileTrigger.manualRefresh.rawValue, "manual_refresh")
    }

    // MARK: - v5 → v6 migration

    func testSchemaV6RebuildsSyncStateKeepingTheRollup() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("komga-v5-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temp) }

        // A v5-shaped database: one row per server, no entity_type column.
        let db = try DatabaseQueue(path: temp.path)
        try db.write { write in
            try write.execute(sql: """
            CREATE TABLE sync_state (
              server_id TEXT PRIMARY KEY,
              last_full_sync TEXT,
              last_successful_sync TEXT,
              last_error TEXT,
              sync_status TEXT NOT NULL DEFAULT 'idle'
            )
            """)
            try write.execute(
                sql: """
                INSERT INTO sync_state (server_id, last_full_sync, last_successful_sync, last_error, sync_status)
                VALUES ('srv-1', '2025-01-01T00:00:00.000Z', '2025-01-02T00:00:00.000Z', 'boom', 'syncing')
                """
            )
        }

        let store = try KomgaStore(path: temp.path)
        XCTAssertEqual(try store.schemaVersion(), Schema.currentVersion)
        XCTAssertEqual(try store.schemaVersion(), 8)
        XCTAssertTrue(try store.columnNames(table: "sync_state").contains("entity_type"))
        XCTAssertTrue(try store.columnNames(table: "deleted_entities").contains("cause"))

        // The old single row became the `full` rollup, timestamps intact.
        let row = try XCTUnwrap(store.entityState(serverID: "srv-1", entityType: SyncEntity.full))
        XCTAssertEqual(row.lastFullSync, "2025-01-01T00:00:00.000Z")
        XCTAssertEqual(row.lastSuccessfulSync, "2025-01-02T00:00:00.000Z")
        XCTAssertEqual(row.lastError, "boom")
        XCTAssertEqual(row.syncStatus, "syncing")
        XCTAssertEqual(row.lastSyncAt, "2025-01-02T00:00:00.000Z")
        XCTAssertNil(try store.entityState(serverID: "srv-1", entityType: SyncEntity.series))
    }
}
