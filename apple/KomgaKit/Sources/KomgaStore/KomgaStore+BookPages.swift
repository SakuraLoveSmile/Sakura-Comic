import Foundation
import GRDB

// MARK: - `book_pages` — the mirrored page manifest (schema v8)
//
// Local-first applies to pixels too: once a book's page list has been seen it
// lives here, so opening the book again is a database read and a book that was
// opened once can be re-read with the server unreachable.
//
// Mirror of Rust `store::pages`. The row shape belongs to the store; the reader's
// normalized `PageDescriptor` is what it becomes on the way out.

/// One mirrored page. `number` is the canonical 1-based position the manifest
/// stored, not whatever the server reported.
public struct BookPageRow: Sendable, Equatable {
    public var number: Int64
    public var fileName: String
    public var mediaType: String
    public var width: Int64
    public var height: Int64
    public var sizeBytes: Int64

    public init(
        number: Int64,
        fileName: String,
        mediaType: String,
        width: Int64,
        height: Int64,
        sizeBytes: Int64
    ) {
        self.number = number
        self.fileName = fileName
        self.mediaType = mediaType
        self.width = width
        self.height = height
        self.sizeBytes = sizeBytes
    }
}

public extension KomgaStore {
    /// Replace the whole manifest for one book. The manifest has no partial
    /// updates — a page list is only meaningful as a set, and a half-written one
    /// would shift every canonical number.
    @discardableResult
    func replaceBookPages(
        serverID: String,
        bookID: String,
        rows: [BookPageRow],
        now: String
    ) throws -> Int {
        try dbQueue.write { db in
            try Self.replaceBookPages(
                db, serverID: serverID, bookID: bookID, rows: rows, now: now
            )
        }
    }

    /// The mirrored manifest in reading order, or empty when never fetched.
    func bookPages(serverID: String, bookID: String) throws -> [BookPageRow] {
        try dbQueue.read { db in
            try Self.bookPages(db: db, serverID: serverID, bookID: bookID)
        }
    }

    func bookPageCount(serverID: String, bookID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM book_pages WHERE server_id = ? AND book_id = ?",
                arguments: [serverID, bookID]
            ) ?? 0
        }
    }

    /// When this mirror was last refreshed, for a staleness policy.
    func bookPagesFetchedAt(serverID: String, bookID: String) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT MAX(fetched_at) FROM book_pages WHERE server_id = ? AND book_id = ?
                """,
                arguments: [serverID, bookID]
            )
        }
    }

    @discardableResult
    func deleteBookPages(serverID: String, bookID: String) throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM book_pages WHERE server_id = ? AND book_id = ?",
                arguments: [serverID, bookID]
            )
            return db.changesCount
        }
    }

    // MARK: - Connection-scoped halves

    static func replaceBookPages(
        _ db: GRDB.Database,
        serverID: String,
        bookID: String,
        rows: [BookPageRow],
        now: String
    ) throws -> Int {
        try db.execute(
            sql: "DELETE FROM book_pages WHERE server_id = ? AND book_id = ?",
            arguments: [serverID, bookID]
        )
        var inserted = 0
        for row in rows {
            try db.execute(
                sql: """
                INSERT INTO book_pages (server_id, book_id, number, file_name, media_type,
                                       width, height, size_bytes, fetched_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    serverID, bookID, row.number, row.fileName, row.mediaType,
                    row.width, row.height, row.sizeBytes, now,
                ]
            )
            inserted += 1
        }
        return inserted
    }

    static func bookPages(db: GRDB.Database, serverID: String, bookID: String) throws -> [BookPageRow] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT number, file_name, media_type, width, height, size_bytes
              FROM book_pages WHERE server_id = ? AND book_id = ? ORDER BY number ASC
            """,
            arguments: [serverID, bookID]
        ).map { row in
            let number: Int64? = row["number"]
            let width: Int64? = row["width"]
            let height: Int64? = row["height"]
            let sizeBytes: Int64? = row["size_bytes"]
            let fileName: String? = row["file_name"]
            let mediaType: String? = row["media_type"]
            return BookPageRow(
                number: number ?? 0,
                fileName: fileName ?? "",
                mediaType: mediaType ?? "",
                width: width ?? 0,
                height: height ?? 0,
                sizeBytes: sizeBytes ?? 0
            )
        }
    }
}
