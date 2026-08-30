import Foundation
import GRDB

// MARK: - Reader-facing store halves (schema v8, mirror of `store::read_progress`
// and `store::app_state`)
//
// The reader must be able to commit "position + progress + one coalesced outbox
// row" in a single transaction, which is not what the existing public
// `setReadProgress` / `markRead` / `markUnread` offer — those each open their own
// write. These are the connection-scoped mirrors of the Rust functions the
// session calls, so both platforms put exactly one transaction behind a page
// turn.
//
// Reader settings live as one JSON document under an `app_state` key, so adding a
// knob is an encoding change rather than a migration.

public extension KomgaStore {
    // MARK: - app_state (single-value local state)

    static func appStateValue(db: GRDB.Database, key: String) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT value FROM app_state WHERE key = ?",
            arguments: [key]
        )
    }

    static func putAppStateValue(_ db: GRDB.Database, key: String, value: String) throws {
        try db.execute(
            sql: """
            INSERT INTO app_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """,
            arguments: [key, value]
        )
    }

    func appStateValue(key: String) throws -> String? {
        try dbQueue.read { db in try Self.appStateValue(db: db, key: key) }
    }

    func putAppStateValue(key: String, value: String) throws {
        try dbQueue.write { db in
            try Self.putAppStateValue(db, key: key, value: value)
        }
    }

    // MARK: - read_progress, inside a caller's transaction

    /// The locally stored page/completed pair for one book (`page` NULL reads 0).
    static func storedReadProgress(
        db: GRDB.Database,
        serverID: String,
        bookID: String
    ) throws -> (page: Int64, completed: Bool)? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
            SELECT COALESCE(page, 0), completed FROM read_progress
             WHERE server_id = ? AND book_id = ?
            """,
            arguments: [serverID, bookID]
        ) else { return nil }
        let page: Int64? = row[0]
        let completed: Int64? = row[1]
        return (page ?? 0, (completed ?? 0) != 0)
    }

    func storedReadProgress(serverID: String, bookID: String) throws -> (page: Int64, completed: Bool)? {
        try dbQueue.read { db in
            try Self.storedReadProgress(db: db, serverID: serverID, bookID: bookID)
        }
    }

    /// Mutation type still queued for this book in the progress family, if any.
    static func pendingMutationType(
        db: GRDB.Database,
        serverID: String,
        bookID: String
    ) throws -> String? {
        try String.fetchOne(
            db,
            sql: """
            SELECT mutation_type FROM pending_mutations
             WHERE server_id = ? AND entity_id = ?
               AND mutation_type IN ('MARK_READ', 'MARK_UNREAD', 'READ_PROGRESS')
             ORDER BY created_at DESC LIMIT 1
            """,
            arguments: [serverID, bookID]
        )
    }

    /// Local page update: write the local row + an outbox row (READ_PROGRESS).
    static func upsertLocalReadProgress(
        _ db: GRDB.Database,
        serverID: String,
        bookID: String,
        page: Int64,
        completed: Bool,
        now: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO read_progress (server_id, book_id, page, completed, local_updated_at, mutation_pending)
            VALUES (?, ?, ?, ?, ?, 1)
            ON CONFLICT(server_id, book_id) DO UPDATE SET
              page = excluded.page, completed = excluded.completed,
              local_updated_at = excluded.local_updated_at, mutation_pending = 1
            """,
            arguments: [serverID, bookID, page, completed, now]
        )
        try enqueueReaderMutation(
            db,
            serverID: serverID,
            bookID: bookID,
            mutationType: "READ_PROGRESS",
            payload: readProgressPayload(bookID: bookID, page: page, completed: completed),
            createdAt: now
        )
    }

    /// Explicit mark-read. The payload carries no page on purpose: an explicit
    /// mark must not rewrite the server's page.
    static func markReadProgressRead(
        _ db: GRDB.Database,
        serverID: String,
        bookID: String,
        now: String
    ) throws {
        try localReaderMutation(
            db, serverID: serverID, bookID: bookID,
            mutationType: "MARK_READ", completed: true, page: nil, now: now
        )
    }

    /// Explicit mark-unread: cannot be overridden by max(page)-style merges.
    static func markReadProgressUnread(
        _ db: GRDB.Database,
        serverID: String,
        bookID: String,
        now: String
    ) throws {
        try localReaderMutation(
            db, serverID: serverID, bookID: bookID,
            mutationType: "MARK_UNREAD", completed: false, page: 0, now: now
        )
    }

    /// One write transaction: the local row plus its coalesced outbox row.
    func upsertLocalReadProgress(
        serverID: String,
        bookID: String,
        page: Int64,
        completed: Bool,
        now: String
    ) throws {
        try dbQueue.write { db in
            try Self.upsertLocalReadProgress(
                db, serverID: serverID, bookID: bookID,
                page: page, completed: completed, now: now
            )
        }
    }

    /// The same for an explicit mark-read, inside one transaction.
    func markReadProgressRead(serverID: String, bookID: String, now: String) throws {
        try dbQueue.write { db in
            try Self.markReadProgressRead(db, serverID: serverID, bookID: bookID, now: now)
        }
    }

    func markReadProgressUnread(serverID: String, bookID: String, now: String) throws {
        try dbQueue.write { db in
            try Self.markReadProgressUnread(db, serverID: serverID, bookID: bookID, now: now)
        }
    }

    private static func localReaderMutation(
        _ db: GRDB.Database,
        serverID: String,
        bookID: String,
        mutationType: String,
        completed: Bool,
        page: Int64?,
        now: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO read_progress (server_id, book_id, page, completed, local_updated_at, mutation_pending)
            VALUES (?, ?, ?, ?, ?, 1)
            ON CONFLICT(server_id, book_id) DO UPDATE SET
              -- `page` is nil for MARK_READ: keep the page already mirrored,
              -- because the wire body omits it too and the mirror must not drift
              -- ahead of what the server is being told.
              page = COALESCE(excluded.page, read_progress.page),
              completed = excluded.completed,
              local_updated_at = excluded.local_updated_at, mutation_pending = 1
            """,
            arguments: [serverID, bookID, page, completed, now]
        )
        try enqueueReaderMutation(
            db,
            serverID: serverID,
            bookID: bookID,
            mutationType: mutationType,
            payload: markPayload(bookID: bookID, completed: completed),
            createdAt: now
        )
    }

    /// Queue one mutation after coalescing away anything it supersedes.
    static func enqueueReaderMutation(
        _ db: GRDB.Database,
        serverID: String,
        bookID: String,
        mutationType: String,
        payload: String,
        createdAt: String
    ) throws {
        // Same statement as the instance-side `coalesceOutbox`: the user's newest
        // statement wins over anything queued in the same family.
        try db.execute(
            sql: """
            DELETE FROM pending_mutations
             WHERE server_id = ? AND entity_id = ? AND mutation_type IN (?, ?, ?)
            """,
            arguments: [serverID, bookID, OutboxFamily.all[0], OutboxFamily.all[1], OutboxFamily.all[2]]
        )
        try db.execute(
            sql: """
            INSERT INTO pending_mutations (id, server_id, entity_id, mutation_type, payload, created_at, retry_count)
            VALUES (?, ?, ?, ?, ?, ?, 0)
            """,
            arguments: [UUID().uuidString, serverID, bookID, mutationType, payload, createdAt]
        )
    }
}
