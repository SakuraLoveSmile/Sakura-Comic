import Foundation
import GRDB

// MARK: - Delete propagation (mirror of Rust `store/prune.rs`)

/// What a prune pass removed: the mirrored rows plus the cover files that
/// became orphans (the caller deletes those from disk).
public struct Pruned: Equatable {
    public let ids: [String]
    public let coverPaths: [String]

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    public init(ids: [String] = [], coverPaths: [String] = []) {
        self.ids = ids
        self.coverPaths = coverPaths
    }
}
//
// Komga has no "deleted ids" endpoint, so deletions are discovered by
// Reconcile: sweep the remote id set for an entity type, then remove every
// local row that the server no longer reports. The mirrored row is hard
// deleted (children cascade), and a tombstone is left behind so a late SSE
// event or a stale Outbox mutation can be recognised as pointing at
// something that is gone.
//
// Cascade rules: `specs/contracts/delete-propagation/README.md`.

public extension KomgaStore {
    // MARK: Diff inputs

    /// Local remote-ids for one entity type (the diff input for prune),
    /// ordered by id — the same order the sweeps walk.
    func localIDs(serverID: String, entityType: String) throws -> [String] {
        try dbQueue.read { db in try localIDs(db, serverID: serverID, entityType: entityType) }
    }

    /// Local book ids scoped to one series (books are swept per series).
    func localBookIDs(serverID: String, seriesID: String) throws -> [String] {
        try dbQueue.read { db in try localBookIDs(db, serverID: serverID, seriesID: seriesID) }
    }

    /// `remote_id → last_modified` for one mirror table, so Added / Changed can
    /// be told apart without a per-row query. Unknown entity types have no
    /// stamp column and report nothing.
    func localStamps(serverID: String, entityType: String) throws -> [String: String?] {
        guard let (table, column) = Self.stampColumn(entityType) else { return [:] }
        return try dbQueue.read { db in
            var stamps: [String: String?] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT remote_id, \(column) FROM \(table) WHERE server_id = ?",
                arguments: [serverID]
            ) {
                let remoteID: String = row["remote_id"]
                let stamp: String? = row[column]
                stamps[remoteID] = stamp
            }
            return stamps
        }
    }

    /// `bookID → (page, completed, server_updated_at)` currently stored, so a
    /// sweep can tell "the server says what we already have" from a real
    /// progress change (which does *not* bump the book's own lastModified).
    /// Mirror of Rust `reconcile::local_progress`.
    func localReadProgress(
        serverID: String
    ) throws -> [String: (page: Int64?, completed: Bool, serverUpdatedAt: String?)] {
        try dbQueue.read { db in
            var stored: [String: (page: Int64?, completed: Bool, serverUpdatedAt: String?)] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                SELECT book_id, page, completed, server_updated_at FROM read_progress WHERE server_id = ?
                """,
                arguments: [serverID]
            ) {
                let bookID: String = row["book_id"]
                let page: Int64? = row["page"]
                let completed: Int? = row["completed"]
                let serverUpdatedAt: String? = row["server_updated_at"]
                stored[bookID] = (page: page, completed: (completed ?? 0) != 0, serverUpdatedAt: serverUpdatedAt)
            }
            return stored
        }
    }

    /// The mirrored series columns a sweep can compare against. `booksCount`
    /// and the read counters move without Komga ever touching
    /// `series.lastModified`, so the stamp alone would miss them (mirror of Rust
    /// `local_series_projection`).
    func localSeriesProjection(serverID: String) throws -> [String: (
        lastModified: String?, booksCount: Int?, booksReadCount: Int?,
        booksUnreadCount: Int?, booksInProgressCount: Int?
    )] {
        try dbQueue.read { db in
            var projected: [String: (
                lastModified: String?, booksCount: Int?, booksReadCount: Int?,
                booksUnreadCount: Int?, booksInProgressCount: Int?
            )] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                SELECT remote_id, last_modified, books_count, books_read_count,
                       books_unread_count, books_in_progress_count
                  FROM series WHERE server_id = ?
                """,
                arguments: [serverID]
            ) {
                let remoteID: String = row["remote_id"]
                let lastModified: String? = row["last_modified"]
                let booksCount: Int? = row["books_count"]
                let booksReadCount: Int? = row["books_read_count"]
                let booksUnreadCount: Int? = row["books_unread_count"]
                let booksInProgressCount: Int? = row["books_in_progress_count"]
                projected[remoteID] = (
                    lastModified: lastModified, booksCount: booksCount,
                    booksReadCount: booksReadCount, booksUnreadCount: booksUnreadCount,
                    booksInProgressCount: booksInProgressCount
                )
            }
            return projected
        }
    }

    /// `collectionID → members` as currently mirrored. Membership is a set, so
    /// both sides are compared sorted (mirror of Rust `local_collection_members`).
    func localCollectionMembers(serverID: String) throws -> [String: [String]] {
        try dbQueue.read { db in
            var members: [String: [String]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: "SELECT collection_id, series_id FROM collection_series WHERE server_id = ?",
                arguments: [serverID]
            ) {
                let collectionID: String = row["collection_id"]
                let seriesID: String = row["series_id"]
                members[collectionID, default: []].append(seriesID)
            }
            for collectionID in Array(members.keys) { members[collectionID]?.sort() }
            return members
        }
    }

    /// `readlistID → books` in mirrored order — a readlist is ordered, so the
    /// sequence itself is the data (mirror of Rust `local_readlist_books`).
    func localReadlistBooks(serverID: String) throws -> [String: [String]] {
        try dbQueue.read { db in
            var books: [String: [String]] = [:]
            for row in try Row.fetchAll(
                db,
                sql: """
                SELECT readlist_id, book_id FROM readlist_books WHERE server_id = ?
                 ORDER BY readlist_id, position
                """,
                arguments: [serverID]
            ) {
                let readlistID: String = row["readlist_id"]
                let bookID: String = row["book_id"]
                books[readlistID, default: []].append(bookID)
            }
            return books
        }
    }

    // MARK: Tombstones

    /// Record that an entity is gone. Idempotent (re-deleting refreshes the
    /// stamp) and scoped to one (server, entity type, id).
    func recordTombstone(
        serverID: String,
        entityType: String,
        remoteID: String,
        cause: String
    ) throws {
        try dbQueue.write { db in
            try recordTombstone(
                db, serverID: serverID, entityType: entityType, remoteID: remoteID, cause: cause
            )
        }
    }

    /// True when one server/entity type has any tombstone at all. A
    /// steady-state sweep has none, and checking once beats issuing
    /// `remoteIDs.count` deletes (mirror of Rust `has_tombstones`).
    func hasTombstones(serverID: String, entityType: String) throws -> Bool {
        try dbQueue.read { db in
            try hasTombstones(db, serverID: serverID, entityType: entityType)
        }
    }

    /// Clear the tombstones of the ids one sweep page saw. Cheap by design: a
    /// steady-state sweep has no tombstone at all, and that is answered with a
    /// single `EXISTS` query instead of one delete per id (mirror of Rust
    /// `clear_tombstones`).
    func clearTombstones(serverID: String, entityType: String, remoteIDs: [String]) throws {
        guard !remoteIDs.isEmpty else { return }
        try dbQueue.write { db in
            guard try hasTombstones(db, serverID: serverID, entityType: entityType) else { return }
            for remoteID in remoteIDs {
                try clearTombstone(
                    db, serverID: serverID, entityType: entityType, remoteID: remoteID
                )
            }
        }
    }

    /// A re-added entity (same id back on the server) clears its tombstone.
    func clearTombstone(serverID: String, entityType: String, remoteID: String) throws {
        try dbQueue.write { db in
            try clearTombstone(db, serverID: serverID, entityType: entityType, remoteID: remoteID)
        }
    }

    func listTombstones(serverID: String, entityType: String) throws -> [Tombstone] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM deleted_entities WHERE server_id = ? AND entity_type = ?
                 ORDER BY deleted_at, remote_id
                """,
                arguments: [serverID, entityType]
            ).map { row in
                let remoteID: String = row["remote_id"]
                let deletedAt: String = row["deleted_at"]
                return Tombstone(
                    serverID: row["server_id"],
                    entityType: row["entity_type"],
                    remoteID: remoteID,
                    deletedAt: deletedAt,
                    cause: row["cause"]
                )
            }
        }
    }

    func countTombstones(serverID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM deleted_entities WHERE server_id = ?",
                arguments: [serverID]
            ) ?? 0
        }
    }

    // MARK: Deletes

    /// Delete a book's mirror rows (children + search index + cover records +
    /// Outbox entries). Returns the cover file paths that became orphaned.
    @discardableResult
    func deleteBook(serverID: String, bookID: String) throws -> [String] {
        try dbQueue.write { db in try deleteBook(db, serverID: serverID, bookID: bookID) }
    }

    /// Delete a series and everything hanging off it (its books cascade first).
    @discardableResult
    func deleteSeries(serverID: String, seriesID: String) throws -> [String] {
        try dbQueue.write { db in try deleteSeries(db, serverID: serverID, seriesID: seriesID) }
    }

    /// Delete a collection (membership rows go with it).
    func deleteCollection(serverID: String, collectionID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM collection_series WHERE server_id = ? AND collection_id = ?",
                arguments: [serverID, collectionID]
            )
            try db.execute(
                sql: "DELETE FROM collections WHERE server_id = ? AND remote_id = ?",
                arguments: [serverID, collectionID]
            )
        }
    }

    /// Delete a readlist (ordered book links go with it).
    func deleteReadlist(serverID: String, readlistID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM readlist_books WHERE server_id = ? AND readlist_id = ?",
                arguments: [serverID, readlistID]
            )
            try db.execute(
                sql: "DELETE FROM readlists WHERE server_id = ? AND remote_id = ?",
                arguments: [serverID, readlistID]
            )
        }
    }

    /// Delete a library row. Its series/books are removed by the series sweep
    /// (they disappear from the server together with the library).
    func deleteLibrary(serverID: String, libraryID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM libraries WHERE server_id = ? AND remote_id = ?",
                arguments: [serverID, libraryID]
            )
        }
    }

    /// Delete one entity of a known type, leaving a tombstone. Returns the
    /// cover file paths that became orphaned.
    @discardableResult
    func deleteEntity(
        serverID: String,
        entityType: String,
        remoteID: String,
        cause: String
    ) throws -> [String] {
        try dbQueue.write { db in
            try deleteEntity(db, serverID: serverID, entityType: entityType, remoteID: remoteID, cause: cause)
        }
    }

    /// Remove local rows the server no longer reports.
    @discardableResult
    func prune(
        serverID: String,
        entityType: String,
        remoteIDs: Set<String>,
        cause: String
    ) throws -> Pruned {
        try dbQueue.write { db in
            let missing = try localIDs(db, serverID: serverID, entityType: entityType)
                .filter { !remoteIDs.contains($0) }
            var covers: [String] = []
            for id in missing {
                covers += try deleteEntity(
                    db, serverID: serverID, entityType: entityType, remoteID: id, cause: cause
                )
            }
            return Pruned(ids: missing, coverPaths: covers)
        }
    }

    /// Book prune scoped to the series actually swept in this pass: local books
    /// under a series we did not visit stay untouched (they are not evidence of
    /// a remote deletion yet).
    @discardableResult
    func pruneBooksForSweptSeries(
        serverID: String,
        swept: [String: Set<String>],
        cause: String
    ) throws -> Pruned {
        try dbQueue.write { db in
            var missing: [String] = []
            var covers: [String] = []
            for seriesID in swept.keys.sorted() {
                for bookID in try localBookIDs(db, serverID: serverID, seriesID: seriesID) {
                    if !(swept[seriesID] ?? []).contains(bookID) {
                        covers += try deleteEntity(
                            db, serverID: serverID, entityType: SyncEntity.books,
                            remoteID: bookID, cause: cause
                        )
                        missing.append(bookID)
                    }
                }
            }
            return Pruned(ids: missing, coverPaths: covers)
        }
    }

    // MARK: Mirror probes (what the sync contract compares the server against)

    /// Row count of one mirror/search table for one server. Unknown tables
    /// report zero rather than reaching for arbitrary SQL.
    func mirrorRowCount(serverID: String, table: String) throws -> Int {
        guard Self.mirrorTables.contains(table) else { return 0 }
        return try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM \(table) WHERE server_id = ?",
                arguments: [serverID]
            ) ?? 0
        }
    }

    /// Membership rows of one collection, exactly as stored: the server may
    /// still report a series id whose local row was cascaded away, and the next
    /// collection sweep brings it back.
    func collectionMemberIDs(serverID: String, collectionID: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT series_id FROM collection_series WHERE server_id = ? AND collection_id = ?",
                arguments: [serverID, collectionID]
            )
        }
    }

    /// Ordered book list of one readlist, exactly as stored.
    func readlistBookIDs(serverID: String, readlistID: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: """
                SELECT book_id FROM readlist_books WHERE server_id = ? AND readlist_id = ?
                 ORDER BY position
                """,
                arguments: [serverID, readlistID]
            )
        }
    }

    /// Book ids that carry a read-progress row.
    func readProgressBookIDs(serverID: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT book_id FROM read_progress WHERE server_id = ? ORDER BY book_id",
                arguments: [serverID]
            )
        }
    }

    /// Books whose parent series row is gone — the cascade must keep this at 0.
    func orphanBookCount(serverID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                SELECT COUNT(*) FROM books b WHERE b.server_id = ? AND NOT EXISTS
                  (SELECT 1 FROM series s WHERE s.server_id = b.server_id AND s.remote_id = b.series_id)
                """,
                arguments: [serverID]
            ) ?? 0
        }
    }

    private static let mirrorTables: Set<String> = [
        "libraries", "series", "books", "collections", "readlists", "read_progress",
        "series_fts", "book_fts",
    ]
}

// MARK: - Transaction-scoped helpers

private extension KomgaStore {
    static func entityTable(_ entityType: String) -> String? {
        switch entityType {
        case SyncEntity.libraries: "libraries"
        case SyncEntity.series: "series"
        case SyncEntity.books: "books"
        case SyncEntity.collections: "collections"
        case SyncEntity.readlists: "readlists"
        // Entity types without a mirror table have nothing to diff and nothing
        // to prune — an empty set can only ever delete zero rows.
        default: nil
        }
    }

    /// Table + `lastModified` column per swept entity type (Added / Changed
    /// classification input).
    static func stampColumn(_ entityType: String) -> (table: String, column: String)? {
        switch entityType {
        case SyncEntity.series: ("series", "last_modified")
        case SyncEntity.books: ("books", "last_modified")
        case SyncEntity.collections: ("collections", "last_modified_date")
        case SyncEntity.readlists: ("readlists", "last_modified_date")
        default: nil
        }
    }

    func localIDs(_ db: GRDB.Database, serverID: String, entityType: String) throws -> [String] {
        guard let table = Self.entityTable(entityType) else { return [] }
        return try String.fetchAll(
            db,
            sql: "SELECT remote_id FROM \(table) WHERE server_id = ? ORDER BY remote_id",
            arguments: [serverID]
        )
    }

    func localBookIDs(_ db: GRDB.Database, serverID: String, seriesID: String) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT remote_id FROM books WHERE server_id = ? AND series_id = ? ORDER BY remote_id",
            arguments: [serverID, seriesID]
        )
    }

    func recordTombstone(
        _ db: GRDB.Database,
        serverID: String,
        entityType: String,
        remoteID: String,
        cause: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO deleted_entities (server_id, entity_type, remote_id, deleted_at, cause)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(server_id, entity_type, remote_id) DO UPDATE SET
              deleted_at = excluded.deleted_at,
              cause = excluded.cause
            """,
            arguments: [serverID, entityType, remoteID, Self.rfc3339Text(Date()), cause]
        )
    }

    func hasTombstones(
        _ db: GRDB.Database, serverID: String, entityType: String
    ) throws -> Bool {
        try Bool.fetchOne(
            db,
            sql: """
            SELECT EXISTS(SELECT 1 FROM deleted_entities WHERE server_id = ? AND entity_type = ?)
            """,
            arguments: [serverID, entityType]
        ) ?? false
    }

    func clearTombstone(
        _ db: GRDB.Database,
        serverID: String,
        entityType: String,
        remoteID: String
    ) throws {
        try db.execute(
            sql: "DELETE FROM deleted_entities WHERE server_id = ? AND entity_type = ? AND remote_id = ?",
            arguments: [serverID, entityType, remoteID]
        )
    }

    func deleteEntity(
        _ db: GRDB.Database,
        serverID: String,
        entityType: String,
        remoteID: String,
        cause: String
    ) throws -> [String] {
        try recordTombstone(
            db, serverID: serverID, entityType: entityType, remoteID: remoteID, cause: cause
        )
        switch entityType {
        case SyncEntity.series:
            return try deleteSeries(db, serverID: serverID, seriesID: remoteID)
        case SyncEntity.books:
            return try deleteBook(db, serverID: serverID, bookID: remoteID)
        case SyncEntity.collections:
            try deleteCollection(db, serverID: serverID, collectionID: remoteID)
            return []
        case SyncEntity.readlists:
            try deleteReadlist(db, serverID: serverID, readlistID: remoteID)
            return []
        case SyncEntity.libraries:
            try deleteLibrary(db, serverID: serverID, libraryID: remoteID)
            return []
        default:
            return []
        }
    }

    func deleteBook(_ db: GRDB.Database, serverID: String, bookID: String) throws -> [String] {
        let covers = try coverPaths(db, serverID: serverID, remoteID: bookID, variant: "book")
        try dropFTSRow(
            db, ftsTable: "book_fts", sourceTable: "books", serverID: serverID, remoteID: bookID
        )
        for sql in [
            "DELETE FROM book_metadata WHERE server_id = ? AND book_id = ?",
            "DELETE FROM book_tags WHERE server_id = ? AND book_id = ?",
            "DELETE FROM book_authors WHERE server_id = ? AND book_id = ?",
            "DELETE FROM readlist_books WHERE server_id = ? AND book_id = ?",
            "DELETE FROM read_progress WHERE server_id = ? AND book_id = ?",
        ] {
            try db.execute(sql: sql, arguments: [serverID, bookID])
        }
        try db.execute(
            sql: "DELETE FROM books WHERE server_id = ? AND remote_id = ?",
            arguments: [serverID, bookID]
        )
        try deleteThumbnails(db, serverID: serverID, remoteID: bookID, variant: "book")
        return covers
    }

    func deleteSeries(
        _ db: GRDB.Database,
        serverID: String,
        seriesID: String
    ) throws -> [String] {
        var covers: [String] = []
        for bookID in try localBookIDs(db, serverID: serverID, seriesID: seriesID) {
            try recordTombstone(
                db, serverID: serverID, entityType: SyncEntity.books,
                remoteID: bookID, cause: DeletionCause.cascade
            )
            covers += try deleteBook(db, serverID: serverID, bookID: bookID)
        }
        covers += try coverPaths(db, serverID: serverID, remoteID: seriesID, variant: "series")
        try dropFTSRow(
            db, ftsTable: "series_fts", sourceTable: "series", serverID: serverID, remoteID: seriesID
        )
        for sql in [
            "DELETE FROM series_metadata WHERE server_id = ? AND series_id = ?",
            "DELETE FROM series_tags WHERE server_id = ? AND series_id = ?",
            "DELETE FROM series_genres WHERE server_id = ? AND series_id = ?",
            "DELETE FROM series_authors WHERE server_id = ? AND series_id = ?",
            "DELETE FROM collection_series WHERE server_id = ? AND series_id = ?",
        ] {
            try db.execute(sql: sql, arguments: [serverID, seriesID])
        }
        try db.execute(
            sql: "DELETE FROM series WHERE server_id = ? AND remote_id = ?",
            arguments: [serverID, seriesID]
        )
        try deleteThumbnails(db, serverID: serverID, remoteID: seriesID, variant: "series")
        return covers
    }

    func deleteCollection(
        _ db: GRDB.Database, serverID: String, collectionID: String
    ) throws {
        try db.execute(
            sql: "DELETE FROM collection_series WHERE server_id = ? AND collection_id = ?",
            arguments: [serverID, collectionID]
        )
        try db.execute(
            sql: "DELETE FROM collections WHERE server_id = ? AND remote_id = ?",
            arguments: [serverID, collectionID]
        )
    }

    func deleteReadlist(_ db: GRDB.Database, serverID: String, readlistID: String) throws {
        try db.execute(
            sql: "DELETE FROM readlist_books WHERE server_id = ? AND readlist_id = ?",
            arguments: [serverID, readlistID]
        )
        try db.execute(
            sql: "DELETE FROM readlists WHERE server_id = ? AND remote_id = ?",
            arguments: [serverID, readlistID]
        )
    }

    func deleteLibrary(_ db: GRDB.Database, serverID: String, libraryID: String) throws {
        try db.execute(
            sql: "DELETE FROM libraries WHERE server_id = ? AND remote_id = ?",
            arguments: [serverID, libraryID]
        )
    }

    /// Cover file paths recorded for an entity (before the rows are deleted).
    func coverPaths(
        _ db: GRDB.Database, serverID: String, remoteID: String, variant: String
    ) throws -> [String] {
        try String.fetchAll(
            db,
            sql: "SELECT local_path FROM thumbnails WHERE server_id = ? AND remote_id = ? AND variant = ?",
            arguments: [serverID, remoteID, variant]
        )
    }

    func deleteThumbnails(
        _ db: GRDB.Database, serverID: String, remoteID: String, variant: String
    ) throws {
        try db.execute(
            sql: "DELETE FROM thumbnails WHERE server_id = ? AND remote_id = ? AND variant = ?",
            arguments: [serverID, remoteID, variant]
        )
    }

    /// Drop the entity's row from the search index through its recorded
    /// `fts_rowid` (derived data; a missing stamp means it was never indexed).
    func dropFTSRow(
        _ db: GRDB.Database,
        ftsTable: String,
        sourceTable: String,
        serverID: String,
        remoteID: String
    ) throws {
        let rowid = try Int64.fetchOne(
            db,
            sql: "SELECT fts_rowid FROM \(sourceTable) WHERE server_id = ? AND remote_id = ?",
            arguments: [serverID, remoteID]
        )
        if let rowid {
            try db.execute(sql: "DELETE FROM \(ftsTable) WHERE rowid = ?", arguments: [rowid])
        }
    }
}
