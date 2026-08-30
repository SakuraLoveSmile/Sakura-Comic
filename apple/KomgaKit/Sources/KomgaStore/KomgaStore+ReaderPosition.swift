import Foundation
import GRDB

// MARK: - `reader_position` — what the screen was showing (schema v8)
//
// This is NOT `read_progress`. `read_progress.page` is the value that syncs to
// Komga and is subject to the Stage 6 conflict rules; `reader_position` is local
// display state — the page the reader landed on plus the mode and direction it
// was rendered with — and it is never uploaded.
//
// Keeping them apart is what makes restore exact: opening a book that was closed
// on a double-page spread in RTL must come back as that spread in RTL, not as
// page N in whatever the global default is.
//
// Mirror of Rust `store::position`.

public struct ReaderPositionRecord: Sendable, Equatable {
    public var page: Int64
    /// `single` / `double` / `webtoon` — the layout text, parsed by the reader.
    public var mode: String
    /// `ltr` / `rtl` / `vertical`.
    public var direction: String
    public var updatedAt: String

    public init(page: Int64, mode: String, direction: String, updatedAt: String) {
        self.page = page
        self.mode = mode
        self.direction = direction
        self.updatedAt = updatedAt
    }
}

public extension KomgaStore {
    /// One row per (server, book); a later save overwrites the earlier one.
    func saveReaderPosition(
        serverID: String,
        bookID: String,
        page: Int64,
        mode: String,
        direction: String,
        now: String
    ) throws {
        try dbQueue.write { db in
            try Self.saveReaderPosition(
                db,
                serverID: serverID,
                bookID: bookID,
                page: page,
                mode: mode,
                direction: direction,
                now: now
            )
        }
    }

    func readerPosition(serverID: String, bookID: String) throws -> ReaderPositionRecord? {
        try dbQueue.read { db in
            try Self.readerPosition(db: db, serverID: serverID, bookID: bookID)
        }
    }

    @discardableResult
    func deleteReaderPosition(serverID: String, bookID: String) throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM reader_position WHERE server_id = ? AND book_id = ?",
                arguments: [serverID, bookID]
            )
            return db.changesCount
        }
    }

    // MARK: - Connection-scoped halves

    static func saveReaderPosition(
        _ db: GRDB.Database,
        serverID: String,
        bookID: String,
        page: Int64,
        mode: String,
        direction: String,
        now: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO reader_position (server_id, book_id, page, mode, direction, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(server_id, book_id) DO UPDATE SET page = excluded.page,
                                                           mode = excluded.mode,
                                                           direction = excluded.direction,
                                                           updated_at = excluded.updated_at
            """,
            arguments: [serverID, bookID, page, mode, direction, now]
        )
    }

    static func readerPosition(
        db: GRDB.Database,
        serverID: String,
        bookID: String
    ) throws -> ReaderPositionRecord? {
        try Row.fetchOne(
            db,
            sql: """
            SELECT page, mode, direction, updated_at FROM reader_position
             WHERE server_id = ? AND book_id = ?
            """,
            arguments: [serverID, bookID]
        ).map { row in
            let page: Int64? = row["page"]
            let mode: String? = row["mode"]
            let direction: String? = row["direction"]
            let updatedAt: String? = row["updated_at"]
            return ReaderPositionRecord(
                page: page ?? 0,
                mode: mode ?? "",
                direction: direction ?? "",
                updatedAt: updatedAt ?? ""
            )
        }
    }
}
