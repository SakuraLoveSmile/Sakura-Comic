import Foundation
import GRDB
import KomgaAPI
import KomgaDiagnostics

// MARK: - One read of everything the client knows about itself
//
// Mirror of Rust `App::diagnostics_snapshot`. Field names are pinned by
// `specs/contracts/fixtures/diagnostics/snapshot.json`, which both platforms'
// test suites flatten out of their own encoded snapshot and compare: the
// support export is the same document whichever client produced it, and a
// rename on one side turns the other one red.
//
// Two deliberate differences from the Rust aggregate:
//
//   * The fixture lists the fields **both** builds can compute today. Rust also
//     reports the in-memory image cache and the download tree's byte walk, which
//     are `memory*` / `openReaders` / `storage` there; those arrive on this side
//     with the offline-download port, and until then the honest answer is that
//     the field does not exist rather than that it is zero.
//   * It reports and never repairs: no sweep, no reconcile, no eviction and no
//     credential write happens here, so asking the question cannot change the
//     answer.

public struct SnapshotOutbox: Codable, Equatable, Sendable {
    public var serverId: String
    public var pending: Int
    public var waiting: Int
    public var failed: Int
    public var total: Int
}

public struct SnapshotSyncRow: Codable, FetchableRecord, Equatable, Sendable {
    /// Encoding is written out rather than synthesised, for one reason: a
    /// synthesised Swift encoder *drops* a nil key, while Rust writes null.
    /// The contract names `sync[].lastError`, and a row that has never
    /// failed must still say so — otherwise "no error recorded" and "this
    /// platform reports no errors" are the same document, and the difference
    /// is the whole content of a diagnostics screen. `encode` (not
    /// `encodeIfPresent`) is what keeps the key with a null value.
    private enum CodingKeys: String, CodingKey {
        case serverId, entityType, syncStatus, syncCursor, lastSyncAt, lastError
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serverId, forKey: .serverId)
        try container.encode(entityType, forKey: .entityType)
        try container.encode(syncStatus, forKey: .syncStatus)
        try container.encode(syncCursor, forKey: .syncCursor)
        try container.encode(lastSyncAt, forKey: .lastSyncAt)
        try container.encode(lastError, forKey: .lastError)
    }

    public var serverId: String
    public var entityType: String
    public var syncStatus: String
    public var syncCursor: String?
    public var lastSyncAt: String?
    public var lastError: String?
}

public struct SnapshotCache: Codable, Equatable, Sendable {
    /// Bytes the reader actually looked at.
    public var pageBytes: Int
    /// Bytes the prefetcher guessed at and nobody has displayed yet.
    public var prefetchBytes: Int
    /// Everything the ledger claims, across every kind it knows.
    public var ledgerBytes: Int
    /// Distinct kinds accounted in the ledger — `thumbnail`, `page`,
    /// `prefetch`, and `download` once there is a writer for it.
    public var kinds: [String]
}

public struct SnapshotQueueRow: Codable, FetchableRecord, Equatable, Sendable {
    public var state: String
    public var books: Int
    public var pagesDone: Int
    public var pagesTotal: Int
    public var bytesDone: Int
    public var bytesTotal: Int
}

public struct SnapshotPolicy: Codable, Equatable, Sendable {
    public var contractVersion: String
    public var snapshotVersion: String
    public var minServerVersion: String
}

public struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
    public var serverId: String
    public var db: DatabaseHealth
    public var auth: SnapshotAuth
    public var outboxQueuedRows: Int
    public var sync: [SnapshotSyncRow]
    public var outbox: SnapshotOutbox
    public var cache: SnapshotCache
    public var queue: [SnapshotQueueRow]
    public var policy: SnapshotPolicy
    public var log: CoreLog.Stats
}

public struct SnapshotAuth: Codable, Equatable, Sendable {
    public var serverId: String
    public var state: String
    public var at: String
}

public extension KomgaStore {
    public func diagnosticsSnapshot(serverID: String) throws -> DiagnosticsSnapshot {
        try dbQueue.read { db in
            let report = try Self.credentialState(db: db, serverID: serverID)
            let syncRows = try SnapshotSyncRow.fetchAll(
                db,
                sql: """
                SELECT server_id AS serverId, entity_type AS entityType,
                       sync_status AS syncStatus, sync_cursor AS syncCursor,
                       last_sync_at AS lastSyncAt, last_error AS lastError
                FROM sync_state WHERE server_id = ? ORDER BY entity_type
                """,
                arguments: [serverID]
            )
            let outbox = try Self.snapshotOutbox(db: db, serverID: serverID)
            let queued = try Self.countRowsIfTable(db: db, table: "pending_mutations") ?? 0
            let cache = try Self.snapshotCache(db: db)
            let queue = try SnapshotQueueRow.fetchAll(
                db,
                sql: """
                SELECT state AS state,
                       count(*) AS books,
                       sum(pages_done) AS pagesDone,
                       sum(pages_total) AS pagesTotal,
                       sum(bytes_done) AS bytesDone,
                       sum(bytes_total) AS bytesTotal
                FROM downloads WHERE server_id = ? GROUP BY state ORDER BY state
                """,
                arguments: [serverID]
            )
            return DiagnosticsSnapshot(
                serverId: serverID,
                db: try Self.databaseHealth(db: db),
                auth: SnapshotAuth(
                    serverId: serverID,
                    state: report.state.rawValue,
                    at: report.at ?? ""
                ),
                outboxQueuedRows: queued,
                sync: syncRows,
                outbox: outbox,
                cache: cache,
                queue: queue,
                policy: SnapshotPolicy(
                    contractVersion: KomgaContract.contractVersion,
                    snapshotVersion: KomgaContract.snapshotVersion,
                    minServerVersion: Self.minServerVersionText
                ),
                log: CoreLog.shared.stats()
            )
        }
    }

    /// The contract's floor as text. Rust stores `(1, 26, 0)`; the Swift policy
    /// keeps only major and minor, and writes the patch as 0 rather than
    /// inventing a third number to agree about.
    static var minServerVersionText: String {
        let minimum = KomgaContract.minimumServerVersion
        return "\(minimum.major).\(minimum.minor).0"
    }

    static func snapshotOutbox(db: GRDB.Database, serverID: String) throws -> SnapshotOutbox {
        // `due` is what an upload pass would take now; `waiting` is what is
        // still sitting on a backoff deadline stored on disk.
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT state, count(*) AS n FROM pending_mutations
            WHERE server_id = ? GROUP BY state
            """,
            arguments: [serverID]
        )
        var outbox = SnapshotOutbox(serverId: serverID, pending: 0, waiting: 0, failed: 0, total: 0)
        for row in rows {
            let state: String = row["state"]
            let count: Int = row["n"]
            outbox.total += count
            if state == "failed" { outbox.failed += count }
        }
        // The split inside the queue is a deadline, not a state: `pending` is
        // what an upload pass would take now and `waiting` is what is still on
        // backoff — the same line Rust's `due_entries` draws, in one query.
        let now = outboxSecondText(Date()) ?? ""
        outbox.pending = (try Int.fetchOne(
            db,
            sql: """
            SELECT count(*) FROM pending_mutations
            WHERE server_id = ? AND state = 'pending'
              AND (next_retry_at IS NULL OR next_retry_at <= ?)
            """,
            arguments: [serverID, now]
        )) ?? 0
        outbox.waiting = (try Int.fetchOne(
            db,
            sql: """
            SELECT count(*) FROM pending_mutations
            WHERE server_id = ? AND state = 'pending'
              AND next_retry_at IS NOT NULL AND next_retry_at > ?
            """,
            arguments: [serverID, now]
        )) ?? 0
        return outbox
    }

    static func snapshotCache(db: GRDB.Database) throws -> SnapshotCache {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT kind, sum(size) AS bytes FROM cache_entries GROUP BY kind ORDER BY kind"
        )
        var page = 0, prefetch = 0, ledger = 0
        var kinds: [String] = []
        for row in rows {
            let kind: String = row["kind"]
            let bytes: Int = row["bytes"] ?? 0
            kinds.append(kind)
            ledger += bytes
            switch kind {
            case CacheKind.page: page += bytes
            case CacheKind.prefetch: prefetch += bytes
            default: break
            }
        }
        return SnapshotCache(
            pageBytes: page,
            prefetchBytes: prefetch,
            ledgerBytes: ledger,
            kinds: kinds
        )
    }
}
