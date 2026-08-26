import Foundation
import GRDB
import KomgaAPI

// MARK: - FTS5 search helpers (mirror of Rust `store/fts.rs`)

enum FTS {
    /// Build a safe FTS5 MATCH expression: whitespace-separated terms become
    /// `"term"* AND ...` (quotes/metacharacters stripped, CJK kept).
    static func matchQuery(_ raw: String) -> String {
        let terms = raw
            .split(whereSeparator: \.isWhitespace)
            .map { term in String(term.filter(\.isLetterOrDigit)) }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return "" }
        return terms.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    /// Incremental series FTS upsert; records the rowid on `series`.
    static func upsertSeries(
        _ db: GRDB.Database,
        serverID: String,
        seriesID: String,
        ftsRowid: Int64?,
        name: String,
        sortName: String,
        authors: String,
        publisher: String,
        tags: String,
        summary: String
    ) throws {
        let rowid: Int64
        if let ftsRowid {
            try db.execute(
                sql: "UPDATE series_fts SET name=?, sort_name=?, authors=?, publisher=?, tags=?, summary=? WHERE rowid=?",
                arguments: [name, sortName, authors, publisher, tags, summary, ftsRowid]
            )
            rowid = ftsRowid
        } else {
            try db.execute(
                sql: "INSERT INTO series_fts(server_id, name, sort_name, authors, publisher, tags, summary) VALUES (?,?,?,?,?,?,?)",
                arguments: [serverID, name, sortName, authors, publisher, tags, summary]
            )
            rowid = db.lastInsertedRowID
        }
        try db.execute(
            sql: "UPDATE series SET fts_rowid = ? WHERE server_id = ? AND remote_id = ?",
            arguments: [rowid, serverID, seriesID]
        )
    }

    /// Incremental book FTS upsert; records the rowid on `books`.
    static func upsertBook(
        _ db: GRDB.Database,
        serverID: String,
        bookID: String,
        ftsRowid: Int64?,
        title: String,
        authors: String,
        tags: String,
        summary: String
    ) throws {
        let rowid: Int64
        if let ftsRowid {
            try db.execute(
                sql: "UPDATE book_fts SET title=?, authors=?, tags=?, summary=? WHERE rowid=?",
                arguments: [title, authors, tags, summary, ftsRowid]
            )
            rowid = ftsRowid
        } else {
            try db.execute(
                sql: "INSERT INTO book_fts(server_id, title, authors, tags, summary) VALUES (?,?,?,?,?)",
                arguments: [serverID, title, authors, tags, summary]
            )
            rowid = db.lastInsertedRowID
        }
        try db.execute(
            sql: "UPDATE books SET fts_rowid = ? WHERE server_id = ? AND remote_id = ?",
            arguments: [rowid, serverID, bookID]
        )
    }
}

private extension Character {
    var isLetterOrDigit: Bool {
        isLetter || isNumber
    }
}

// MARK: - Media library store (mirror of Rust store modules)

public extension KomgaStore {
    // MARK: Series batch (full metadata + children + FTS)

    /// Batch upsert series with full metadata: row + series_metadata +
    /// normalized genres/tags/authors + incremental FTS row, in one
    /// transaction (mirror of Rust `save_series_batch`).
    @discardableResult
    public func upsertSeriesBatch(serverID: String, series: [SeriesDTO]) throws -> Int {
        try dbQueue.write { db in
            var written = 0
            for item in series {
                let metadata = item.metadata
                let sortName = metadata?.titleSort ?? item.name
                try db.execute(
                    sql: """
                    INSERT INTO series (server_id, remote_id, library_id, name, sort_name, status, created_at, last_modified,
                                        books_count, books_read_count, books_unread_count, books_in_progress_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(server_id, remote_id) DO UPDATE SET
                      library_id = excluded.library_id, name = excluded.name, sort_name = excluded.sort_name,
                      status = excluded.status, created_at = excluded.created_at, last_modified = excluded.last_modified,
                      books_count = excluded.books_count, books_read_count = excluded.books_read_count,
                      books_unread_count = excluded.books_unread_count, books_in_progress_count = excluded.books_in_progress_count
                    """,
                    arguments: [
                        serverID, item.id, item.libraryId, item.name, sortName,
                        metadata?.status, item.created, item.lastModified,
                        item.booksCount, item.booksReadCount, item.booksUnreadCount, item.booksInProgressCount,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO series_metadata (server_id, series_id, summary, publisher, reading_direction, language, age_rating, title_sort, total_book_count)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(server_id, series_id) DO UPDATE SET
                      summary = excluded.summary, publisher = excluded.publisher, reading_direction = excluded.reading_direction,
                      language = excluded.language, age_rating = excluded.age_rating, title_sort = excluded.title_sort,
                      total_book_count = excluded.total_book_count
                    """,
                    arguments: [
                        serverID, item.id, metadata?.summary, metadata?.publisher,
                        metadata?.readingDirection, metadata?.language, metadata?.ageRating,
                        metadata?.titleSort, metadata?.totalBookCount,
                    ]
                )
                let tags = metadata?.tags ?? []
                let genres = metadata?.genres ?? []
                var authors = metadata?.authors ?? []
                if authors.isEmpty {
                    // The list endpoint aggregates series authors under booksMetadata.
                    authors = item.booksMetadata?.authors ?? []
                }
                try db.execute(
                    sql: "DELETE FROM series_tags WHERE server_id = ? AND series_id = ?",
                    arguments: [serverID, item.id]
                )
                for tag in tags {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO series_tags (server_id, series_id, tag) VALUES (?, ?, ?)",
                        arguments: [serverID, item.id, tag]
                    )
                }
                try db.execute(
                    sql: "DELETE FROM series_genres WHERE server_id = ? AND series_id = ?",
                    arguments: [serverID, item.id]
                )
                for genre in genres {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO series_genres (server_id, series_id, genre) VALUES (?, ?, ?)",
                        arguments: [serverID, item.id, genre]
                    )
                }
                try db.execute(
                    sql: "DELETE FROM series_authors WHERE server_id = ? AND series_id = ?",
                    arguments: [serverID, item.id]
                )
                for author in authors {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO series_authors (server_id, series_id, name, role) VALUES (?, ?, ?, ?)",
                        arguments: [serverID, item.id, author.name, author.role ?? ""]
                    )
                }
                let ftsRowid = try Int64.fetchOne(
                    db,
                    sql: "SELECT fts_rowid FROM series WHERE server_id = ? AND remote_id = ?",
                    arguments: [serverID, item.id]
                )
                try FTS.upsertSeries(
                    db, serverID: serverID, seriesID: item.id, ftsRowid: ftsRowid,
                    name: item.name, sortName: sortName,
                    authors: authors.map(\.name).joined(separator: ", "),
                    publisher: metadata?.publisher ?? "",
                    tags: tags.joined(separator: ", "),
                    summary: metadata?.summary ?? ""
                )
                written += 1
            }
            return written
        }
    }

    // MARK: Books batch

    /// Batch upsert books with metadata + tags + authors + remote read
    /// progress + FTS, in one transaction (mirror of `save_books_batch`).
    @discardableResult
    public func upsertBooksBatch(serverID: String, books: [BookDTO]) throws -> Int {
        try dbQueue.write { db in
            var written = 0
            for item in books {
                let metadata = item.metadata
                let title = metadata?.title ?? item.name
                let number = metadata?.number ?? (item.number.map(String.init))
                let numberSort = metadata?.numberSort ?? item.number.map(Double.init)
                try db.execute(
                    sql: """
                    INSERT INTO books (server_id, remote_id, series_id, series_title, title, number, number_sort,
                                       file_size, media_type, pages_count, created_at, last_modified, oneshot)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(server_id, remote_id) DO UPDATE SET
                      series_id = excluded.series_id, series_title = excluded.series_title, title = excluded.title,
                      number = excluded.number, number_sort = excluded.number_sort, file_size = excluded.file_size,
                      media_type = excluded.media_type, pages_count = excluded.pages_count,
                      created_at = excluded.created_at, last_modified = excluded.last_modified, oneshot = excluded.oneshot
                    """,
                    arguments: [
                        serverID, item.id, item.seriesId, item.seriesTitle, title, number, numberSort,
                        item.sizeBytes, item.media?.mediaType, item.media?.pagesCount,
                        item.created, item.lastModified, item.oneshot ?? false,
                    ]
                )
                try db.execute(
                    sql: """
                    INSERT INTO book_metadata (server_id, book_id, summary, number, number_sort, isbn, release_date)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(server_id, book_id) DO UPDATE SET
                      summary = excluded.summary, number = excluded.number, number_sort = excluded.number_sort,
                      isbn = excluded.isbn, release_date = excluded.release_date
                    """,
                    arguments: [serverID, item.id, metadata?.summary, number, numberSort, metadata?.isbn, metadata?.releaseDate]
                )
                let tags = metadata?.tags ?? []
                let authors = metadata?.authors ?? []
                try db.execute(
                    sql: "DELETE FROM book_tags WHERE server_id = ? AND book_id = ?",
                    arguments: [serverID, item.id]
                )
                for tag in tags {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO book_tags (server_id, book_id, tag) VALUES (?, ?, ?)",
                        arguments: [serverID, item.id, tag]
                    )
                }
                try db.execute(
                    sql: "DELETE FROM book_authors WHERE server_id = ? AND book_id = ?",
                    arguments: [serverID, item.id]
                )
                for author in authors {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO book_authors (server_id, book_id, name, role) VALUES (?, ?, ?, ?)",
                        arguments: [serverID, item.id, author.name, author.role ?? ""]
                    )
                }
                // Remote read progress rides along on the BookDto.
                if let progress = item.readProgress {
                    try upsertSyncedReadProgress(
                        serverID: serverID,
                        bookID: item.id,
                        page: progress.page.map(Int64.init),
                        completed: progress.completed ?? false,
                        serverUpdatedAt: progress.lastModified,
                        in: db
                    )
                }
                let ftsRowid = try Int64.fetchOne(
                    db,
                    sql: "SELECT fts_rowid FROM books WHERE server_id = ? AND remote_id = ?",
                    arguments: [serverID, item.id]
                )
                try FTS.upsertBook(
                    db, serverID: serverID, bookID: item.id, ftsRowid: ftsRowid,
                    title: title,
                    authors: authors.map(\.name).joined(separator: ", "),
                    tags: tags.joined(separator: ", "),
                    summary: metadata?.summary ?? ""
                )
                written += 1
            }
            return written
        }
    }

    // MARK: Collections / readlists batches

    /// Batch upsert collections + replace membership (mirror of
    /// `save_collections_batch`).
    @discardableResult
    public func upsertCollectionsBatch(serverID: String, collections: [CollectionDTO]) throws -> Int {
        try dbQueue.write { db in
            var written = 0
            for item in collections {
                try db.execute(
                    sql: """
                    INSERT INTO collections (server_id, remote_id, name, ordered, filtered, created_date, last_modified_date)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(server_id, remote_id) DO UPDATE SET
                      name = excluded.name, ordered = excluded.ordered, filtered = excluded.filtered,
                      created_date = excluded.created_date, last_modified_date = excluded.last_modified_date
                    """,
                    arguments: [serverID, item.id, item.name, item.ordered ?? false, item.filtered ?? false, item.createdDate, item.lastModifiedDate]
                )
                try db.execute(
                    sql: "DELETE FROM collection_series WHERE server_id = ? AND collection_id = ?",
                    arguments: [serverID, item.id]
                )
                for seriesID in item.seriesIds ?? [] {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO collection_series (server_id, collection_id, series_id) VALUES (?, ?, ?)",
                        arguments: [serverID, item.id, seriesID]
                    )
                }
                written += 1
            }
            return written
        }
    }

    /// Batch upsert readlists + replace ordered membership (mirror of
    /// `save_readlists_batch`).
    @discardableResult
    public func upsertReadlistsBatch(serverID: String, readlists: [ReadListDTO]) throws -> Int {
        try dbQueue.write { db in
            var written = 0
            for item in readlists {
                try db.execute(
                    sql: """
                    INSERT INTO readlists (server_id, remote_id, name, summary, ordered, filtered, created_date, last_modified_date)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(server_id, remote_id) DO UPDATE SET
                      name = excluded.name, summary = excluded.summary, ordered = excluded.ordered,
                      filtered = excluded.filtered, created_date = excluded.created_date,
                      last_modified_date = excluded.last_modified_date
                    """,
                    arguments: [serverID, item.id, item.name, item.summary, item.ordered ?? false, item.filtered ?? false, item.createdDate, item.lastModifiedDate]
                )
                try db.execute(
                    sql: "DELETE FROM readlist_books WHERE server_id = ? AND readlist_id = ?",
                    arguments: [serverID, item.id]
                )
                for (position, bookID) in (item.bookIds ?? []).enumerated() {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO readlist_books (server_id, readlist_id, book_id, position) VALUES (?, ?, ?, ?)",
                        arguments: [serverID, item.id, bookID, position]
                    )
                }
                written += 1
            }
            return written
        }
    }

    // MARK: Read progress (本地优先 + Mutation Outbox)

    private func enqueueMutation(
        _ db: GRDB.Database,
        serverID: String,
        bookID: String,
        mutationType: String,
        payload: [String: Any],
        createdAt: String
    ) throws {
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        try db.execute(
            sql: """
            INSERT INTO pending_mutations (id, server_id, entity_id, mutation_type, payload, created_at, retry_count)
            VALUES (?, ?, ?, ?, ?, ?, 0)
            """,
            arguments: [UUID().uuidString, serverID, bookID, mutationType, String(data: payloadData, encoding: .utf8) ?? "{}", createdAt]
        )
    }

    /// Remote truth upsert (sync path): mutation_pending stays 0.
    public func upsertSyncedReadProgress(
        serverID: String,
        bookID: String,
        page: Int64?,
        completed: Bool,
        serverUpdatedAt: String?
    ) throws {
        try dbQueue.write { db in
            try upsertSyncedReadProgress(serverID: serverID, bookID: bookID, page: page, completed: completed, serverUpdatedAt: serverUpdatedAt, in: db)
        }
    }

    private func upsertSyncedReadProgress(
        serverID: String,
        bookID: String,
        page: Int64?,
        completed: Bool,
        serverUpdatedAt: String?,
        in db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO read_progress (server_id, book_id, page, completed, server_updated_at, mutation_pending)
            VALUES (?, ?, ?, ?, ?, 0)
            ON CONFLICT(server_id, book_id) DO UPDATE SET
              page = excluded.page, completed = excluded.completed,
              server_updated_at = excluded.server_updated_at, mutation_pending = 0
            """,
            arguments: [serverID, bookID, page, completed, serverUpdatedAt]
        )
    }

    /// Local page update: local row + READ_PROGRESS outbox row.
    public func setReadProgress(serverID: String, bookID: String, page: Int64, completed: Bool) throws {
        try dbQueue.write { db in
            let now = Self.rfc3339Text(Date())
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
            try enqueueMutation(
                db, serverID: serverID, bookID: bookID, mutationType: "READ_PROGRESS",
                payload: ["bookId": bookID, "page": page, "completed": completed], createdAt: now
            )
        }
    }

    /// Explicit mark-read (priority over passive progress; MARK_READ outbox).
    public func markRead(serverID: String, bookID: String) throws {
        try localMutation(serverID: serverID, bookID: bookID, mutationType: "MARK_READ", completed: true, page: nil)
    }

    /// Explicit mark-unread: cannot be overridden by max(page)-style merges.
    public func markUnread(serverID: String, bookID: String) throws {
        try localMutation(serverID: serverID, bookID: bookID, mutationType: "MARK_UNREAD", completed: false, page: 0)
    }

    private func localMutation(serverID: String, bookID: String, mutationType: String, completed: Bool, page: Int64?) throws {
        try dbQueue.write { db in
            let now = Self.rfc3339Text(Date())
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
            try enqueueMutation(
                db, serverID: serverID, bookID: bookID, mutationType: mutationType,
                payload: ["bookId": bookID, "completed": completed], createdAt: now
            )
        }
    }

    /// The continue-reading shelf (local only; 断网可用).
    public func continueReading(serverID: String, limit: Int64) throws -> [ContinueReadingRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT b.remote_id AS book_id, b.title AS book_title, b.number, b.series_id,
                       COALESCE(s.name, b.series_title) AS series_name,
                       rp.page, b.pages_count AS total_pages,
                       CASE WHEN b.pages_count IS NOT NULL AND b.pages_count > 0 AND rp.page IS NOT NULL
                            THEN (rp.page * 100 / b.pages_count) END AS progress_pct,
                       rp.local_updated_at
                  FROM read_progress rp
                  JOIN books b ON b.server_id = rp.server_id AND b.remote_id = rp.book_id
                  LEFT JOIN series s ON s.server_id = b.server_id AND s.remote_id = b.series_id
                 WHERE rp.server_id = ? AND rp.completed = 0 AND rp.page IS NOT NULL AND rp.page > 0
                 ORDER BY COALESCE(rp.local_updated_at, rp.server_updated_at) DESC
                 LIMIT ?
                """,
                arguments: [serverID, limit]
            ).map { row in
                ContinueReadingRecord(
                    bookID: row["book_id"], bookTitle: row["book_title"], number: row["number"],
                    seriesID: row["series_id"], seriesName: row["series_name"], page: row["page"],
                    totalPages: row["total_pages"], progressPercent: row["progress_pct"],
                    localUpdatedAt: row["local_updated_at"]
                )
            }
        }
    }

    // MARK: - Local queries (搜索/筛选/排序/分页全部 SQLite)

    /// Sort keys exposed by the UI (strings ride the same contract as Rust).
    public enum SeriesSort: String {
        case name, sortName, dateAdded, dateUpdated, booksCount
    }

    public enum BookSort: String {
        case number, title, dateAdded
    }

    public enum ReadStatus: String {
        case read, inProgress = "in_progress", unread
    }

    /// Paged series wall with search / filters / sort (mirror of
    /// `store::query::query_series`).
    public func querySeries(
        serverID: String,
        search: String? = nil,
        libraryID: String? = nil,
        status: String? = nil,
        tag: String? = nil,
        genre: String? = nil,
        sort: SeriesSort = .name,
        ascending: Bool = true,
        limit: Int64,
        offset: Int64
    ) throws -> PagedSeries {
        try dbQueue.read { db in
            let whereSQL = seriesWhere(search: search, libraryID: libraryID, status: status, tag: tag, genre: genre, serverID: serverID)
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM series s WHERE \(whereSQL.sql)",
                arguments: StatementArguments(whereSQL.args)
            ) ?? 0

            let order: String
            switch sort {
            case .name: order = "s.name COLLATE NOCASE"
            case .sortName: order = "COALESCE(s.sort_name, s.name) COLLATE NOCASE"
            case .dateAdded: order = "s.created_at"
            case .dateUpdated: order = "s.last_modified"
            case .booksCount: order = "s.books_count"
            }
            let dir = ascending ? "ASC" : "DESC"
            var args = whereSQL.args
            args.append(contentsOf: [limit, offset])
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM series s WHERE \(whereSQL.sql) ORDER BY \(order) \(dir) LIMIT ? OFFSET ?",
                arguments: StatementArguments(args)
            )
            return PagedSeries(items: rows.map(Self.mediaSeriesRecord(from:)), total: total)
        }
    }

    private func seriesWhere(
        search: String?, libraryID: String?, status: String?, tag: String?, genre: String?,
        serverID: String
    ) -> (sql: String, args: [any DatabaseValueConvertible & Sendable]) {
        var args: [any DatabaseValueConvertible & Sendable] = [serverID]
        var sql = "s.server_id = ?"
        if let libraryID {
            args.append(libraryID)
            sql += " AND s.library_id = ?\(args.count)"
        }
        if let status {
            args.append(status)
            sql += " AND s.status = ?\(args.count)"
        }
        if let tag {
            args.append(tag)
            sql += " AND EXISTS (SELECT 1 FROM series_tags st WHERE st.server_id = s.server_id AND st.series_id = s.remote_id AND st.tag = ?\(args.count))"
        }
        if let genre {
            args.append(genre)
            sql += " AND EXISTS (SELECT 1 FROM series_genres sg WHERE sg.server_id = s.server_id AND sg.series_id = s.remote_id AND sg.genre = ?\(args.count))"
        }
        if let search, !FTS.matchQuery(search).isEmpty {
            args.append(FTS.matchQuery(search))
            sql += " AND s.fts_rowid IN (SELECT rowid FROM series_fts WHERE series_fts MATCH ?\(args.count) AND server_id = ?1)"
        }
        return (sql, args)
    }

    /// Paged book list with read-status / tag filters (mirror of
    /// `store::query::query_books`).
    public func queryBooks(
        serverID: String,
        seriesID: String,
        search: String? = nil,
        readStatus: ReadStatus? = nil,
        tag: String? = nil,
        sort: BookSort = .number,
        ascending: Bool = true,
        limit: Int64,
        offset: Int64
    ) throws -> PagedBooks {
        try dbQueue.read { db in
            var args: [any DatabaseValueConvertible & Sendable] = [serverID, seriesID]
            var sql = "b.server_id = ?1 AND b.series_id = ?2"
            switch readStatus {
            case .read: sql += " AND rp.completed = 1"
            case .inProgress: sql += " AND rp.completed = 0 AND rp.page IS NOT NULL AND rp.page > 0"
            case .unread: sql += " AND (rp.book_id IS NULL OR (rp.completed = 0 AND (rp.page IS NULL OR rp.page = 0)))"
            case nil: break
            }
            if let tag {
                args.append(tag)
                sql += " AND EXISTS (SELECT 1 FROM book_tags bt WHERE bt.server_id = b.server_id AND bt.book_id = b.remote_id AND bt.tag = ?\(args.count))"
            }
            if let search, !FTS.matchQuery(search).isEmpty {
                args.append(FTS.matchQuery(search))
                sql += " AND b.fts_rowid IN (SELECT rowid FROM book_fts WHERE book_fts MATCH ?\(args.count) AND server_id = ?1)"
            }
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM books b LEFT JOIN read_progress rp ON rp.server_id = b.server_id AND rp.book_id = b.remote_id WHERE \(sql)",
                arguments: StatementArguments(args)
            ) ?? 0
            let dir = ascending ? "ASC" : "DESC"
            let order: String
            switch sort {
            case .number: order = "b.number_sort IS NULL, b.number_sort"
            case .title: order = "b.title COLLATE NOCASE"
            case .dateAdded: order = "b.created_at"
            }
            var pageArgs = args
            pageArgs.append(contentsOf: [limit, offset])
            let rows = try Row.fetchAll(
                db,
                sql: Self.bookSelect
                    + " WHERE \(sql) ORDER BY \(order) \(dir) LIMIT ? OFFSET ?",
                arguments: StatementArguments(pageArgs)
            )
            return PagedBooks(items: rows.map(Self.mediaBookRecord(from:)), total: total)
        }
    }

    // MARK: Details

    public func seriesDetail(serverID: String, seriesID: String) throws -> SeriesDetailRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM series WHERE server_id = ? AND remote_id = ?",
                arguments: [serverID, seriesID]
            ) else { return nil }
            let record = Self.mediaSeriesRecord(from: row)
            let metadata = try Row.fetchOne(
                db,
                sql: """
                SELECT summary, publisher, reading_direction, language, age_rating, total_book_count
                FROM series_metadata WHERE server_id = ? AND series_id = ?
                """,
                arguments: [serverID, seriesID]
            )
            let genres = try String.fetchAll(
                db,
                sql: "SELECT genre FROM series_genres WHERE server_id = ? AND series_id = ? ORDER BY genre COLLATE NOCASE",
                arguments: [serverID, seriesID]
            )
            let tags = try String.fetchAll(
                db,
                sql: "SELECT tag FROM series_tags WHERE server_id = ? AND series_id = ? ORDER BY tag COLLATE NOCASE",
                arguments: [serverID, seriesID]
            )
            let authors = try Row.fetchAll(
                db,
                sql: "SELECT name, role FROM series_authors WHERE server_id = ? AND series_id = ? ORDER BY name COLLATE NOCASE",
                arguments: [serverID, seriesID]
            ).map(Self.mediaAuthorRow(from:))
            let collections = try Row.fetchAll(
                db,
                sql: """
                SELECT c.remote_id, c.name FROM collection_series cs
                JOIN collections c ON c.server_id = cs.server_id AND c.remote_id = cs.collection_id
                WHERE cs.server_id = ? AND cs.series_id = ? ORDER BY c.name COLLATE NOCASE
                """,
                arguments: [serverID, seriesID]
            ).map { row in CollectionRef(remoteID: row["remote_id"], name: row["name"]) }
            return SeriesDetailRecord(
                serverID: record.serverID, remoteID: record.remoteID, libraryID: record.libraryID,
                name: record.name, sortName: record.sortName, status: record.status,
                createdAt: record.createdAt, lastModified: record.lastModified,
                booksCount: record.booksCount, booksReadCount: record.booksReadCount,
                booksUnreadCount: record.booksUnreadCount, booksInProgressCount: record.booksInProgressCount,
                summary: metadata?["summary"], publisher: metadata?["publisher"],
                readingDirection: metadata?["reading_direction"], language: metadata?["language"],
                ageRating: metadata?["age_rating"], totalBookCount: metadata?["total_book_count"],
                genres: genres, tags: tags, authors: authors, collections: collections
            )
        }
    }

    public func bookDetail(serverID: String, bookID: String) throws -> BookDetailRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: Self.bookSelect + " WHERE b.server_id = ? AND b.remote_id = ?",
                arguments: [serverID, bookID]
            ) else { return nil }
            let record = Self.mediaBookRecord(from: row)
            let metadata = try Row.fetchOne(
                db,
                sql: "SELECT summary, number, isbn, release_date FROM book_metadata WHERE server_id = ? AND book_id = ?",
                arguments: [serverID, bookID]
            )
            let tags = try String.fetchAll(
                db,
                sql: "SELECT tag FROM book_tags WHERE server_id = ? AND book_id = ? ORDER BY tag COLLATE NOCASE",
                arguments: [serverID, bookID]
            )
            let authors = try Row.fetchAll(
                db,
                sql: "SELECT name, role FROM book_authors WHERE server_id = ? AND book_id = ? ORDER BY name COLLATE NOCASE",
                arguments: [serverID, bookID]
            ).map(Self.mediaAuthorRow(from:))
            return BookDetailRecord(
                serverID: record.serverID, remoteID: record.remoteID, seriesID: record.seriesID,
                seriesTitle: record.seriesTitle, title: record.title,
                number: metadata?["number"] ?? record.number, numberSort: record.numberSort,
                summary: metadata?["summary"], isbn: metadata?["isbn"], releaseDate: metadata?["release_date"],
                mediaType: record.mediaType, pagesCount: record.pagesCount, fileSize: record.fileSize,
                createdAt: record.createdAt, lastModified: record.lastModified,
                tags: tags, authors: authors,
                progressPage: record.progressPage, progressCompleted: record.progressCompleted
            )
        }
    }

    // MARK: Collections / readlists

    public func listCollections(serverID: String, search: String? = nil, limit: Int64, offset: Int64) throws -> PagedCollections {
        try dbQueue.read { db in
            let (whereSQL, args) = collectionSearchClause(serverID: serverID, search: search, table: "collections", columns: ["name"])
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM collections \(whereSQL)",
                arguments: StatementArguments(args)
            ) ?? 0
            var pageArgs = args
            pageArgs.append(contentsOf: [limit, offset])
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM collections \(whereSQL) ORDER BY name COLLATE NOCASE LIMIT ? OFFSET ?",
                arguments: StatementArguments(pageArgs)
            )
            return PagedCollections(items: rows.map(Self.mediaCollectionRecord(from:)), total: total)
        }
    }

    public func collectionDetail(serverID: String, collectionID: String, limit: Int64, offset: Int64) throws -> CollectionDetailRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM collections WHERE server_id = ? AND remote_id = ?",
                arguments: [serverID, collectionID]
            ) else { return nil }
            let record = Self.mediaCollectionRecord(from: row)
            let whereSQL = "s.server_id = ?1 AND s.remote_id IN (SELECT series_id FROM collection_series WHERE server_id = ?1 AND collection_id = ?2)"
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM series s WHERE \(whereSQL)",
                arguments: [serverID, collectionID]
            ) ?? 0
            let members = try Row.fetchAll(
                db,
                sql: "SELECT * FROM series s WHERE \(whereSQL) ORDER BY s.name COLLATE NOCASE LIMIT ?3 OFFSET ?4",
                arguments: [serverID, collectionID, limit, offset]
            ).map(Self.mediaSeriesRecord(from:))
            return CollectionDetailRecord(
                remoteID: record.remoteID, name: record.name, ordered: record.ordered,
                filtered: record.filtered, createdDate: record.createdDate,
                lastModifiedDate: record.lastModifiedDate,
                members: PagedSeries(items: members, total: total)
            )
        }
    }

    public func listReadlists(serverID: String, search: String? = nil, limit: Int64, offset: Int64) throws -> PagedReadlists {
        try dbQueue.read { db in
            let (whereSQL, args) = collectionSearchClause(serverID: serverID, search: search, table: "readlists", columns: ["name", "summary"])
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM readlists \(whereSQL)",
                arguments: StatementArguments(args)
            ) ?? 0
            var pageArgs = args
            pageArgs.append(contentsOf: [limit, offset])
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM readlists \(whereSQL) ORDER BY name COLLATE NOCASE LIMIT ? OFFSET ?",
                arguments: StatementArguments(pageArgs)
            )
            return PagedReadlists(items: rows.map(Self.mediaReadlistRecord(from:)), total: total)
        }
    }

    public func readlistDetail(serverID: String, readlistID: String, limit: Int64, offset: Int64) throws -> ReadlistDetailRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM readlists WHERE server_id = ? AND remote_id = ?",
                arguments: [serverID, readlistID]
            ) else { return nil }
            let record = Self.mediaReadlistRecord(from: row)
            let total = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM readlist_books WHERE server_id = ? AND readlist_id = ?",
                arguments: [serverID, readlistID]
            ) ?? 0
            let books = try Row.fetchAll(
                db,
                sql: Self.bookSelect
                    + " JOIN readlist_books rb ON rb.server_id = b.server_id AND rb.book_id = b.remote_id"
                    + " WHERE b.server_id = ? AND rb.readlist_id = ? ORDER BY rb.position LIMIT ? OFFSET ?",
                arguments: [serverID, readlistID, limit, offset]
            ).map(Self.mediaBookRecord(from:))
            return ReadlistDetailRecord(
                remoteID: record.remoteID, name: record.name, summary: record.summary,
                ordered: record.ordered, filtered: record.filtered, createdDate: record.createdDate,
                lastModifiedDate: record.lastModifiedDate, books: PagedBooks(items: books, total: total)
            )
        }
    }

    private func collectionSearchClause(serverID: String, search: String?, table: String, columns: [String]) -> (String, [any DatabaseValueConvertible & Sendable]) {
        var args: [any DatabaseValueConvertible & Sendable] = [serverID]
        var sql = "WHERE server_id = ?1"
        if let term = search?.trimmingCharacters(in: .whitespacesAndNewlines), !term.isEmpty {
            let like = "%\(term)%"
            let parts = columns.map { _ in
                args.append(like)
                return " ?\(args.count)"
            }
            sql += " AND (\(parts.enumerated().map { "\(columns[$0.offset]) LIKE \($0.element) COLLATE NOCASE" }.joined(separator: " OR ")))"
        }
        _ = table
        return (sql, args)
    }

    // MARK: Filter options / library counts

    public func filterOptions(serverID: String) throws -> FilterOptions {
        try dbQueue.read { db in
            let tags = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT tag FROM series_tags WHERE server_id = ? ORDER BY tag COLLATE NOCASE",
                arguments: [serverID]
            )
            let genres = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT genre FROM series_genres WHERE server_id = ? ORDER BY genre COLLATE NOCASE",
                arguments: [serverID]
            )
            let statuses = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT status FROM series WHERE server_id = ? AND status IS NOT NULL AND status != '' ORDER BY status COLLATE NOCASE",
                arguments: [serverID]
            )
            return FilterOptions(tags: tags, genres: genres, statuses: statuses)
        }
    }

    public func libraryCounts(serverID: String) throws -> [LibraryCountRecord] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT l.remote_id, l.name, COUNT(s.remote_id) AS series_count
                  FROM libraries l
                  LEFT JOIN series s ON s.server_id = l.server_id AND s.library_id = l.remote_id
                 WHERE l.server_id = ?
                 GROUP BY l.remote_id, l.name
                 ORDER BY l.name COLLATE NOCASE
                """,
                arguments: [serverID]
            ).map { row in
                LibraryCountRecord(remoteID: row["remote_id"], name: row["name"], seriesCount: row["series_count"])
            }
        }
    }

    // MARK: Sync state

    /// Record a completed full mirror sync (last_full_sync + success stamp).
    @discardableResult
    public func recordFullSync(serverID: String) throws -> SyncStateRecord {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO sync_state (server_id, last_full_sync, last_successful_sync, sync_status)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(server_id) DO UPDATE SET
                  last_full_sync = excluded.last_full_sync,
                  last_successful_sync = excluded.last_successful_sync,
                  sync_status = excluded.sync_status,
                  last_error = NULL
                """,
                arguments: [serverID, Self.rfc3339Text(Date()), Self.rfc3339Text(Date()), "idle"]
            )
        }
        guard let row = try syncState(serverID: serverID) else {
            throw GRDB.DatabaseError(resultCode: .SQLITE_ERROR, message: "sync_state row missing")
        }
        return row
    }

    /// All distinct book remote_ids for one series (book-cover backfill list).
    public func listBooks(serverID: String, seriesID: String) throws -> [String] {
        try dbQueue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT remote_id FROM books WHERE server_id = ? AND series_id = ? ORDER BY number_sort, title COLLATE NOCASE",
                arguments: [serverID, seriesID]
            )
        }
    }

    // MARK: - Row mapping

    static let bookSelect = """
    SELECT b.server_id, b.remote_id, b.series_id, b.series_title, b.title,
           b.number, b.number_sort, b.file_size, b.media_type, b.pages_count,
           b.created_at, b.last_modified, b.fts_rowid,
           rp.page AS progress_page, COALESCE(rp.completed, 0) AS progress_completed
      FROM books b LEFT JOIN read_progress rp
        ON rp.server_id = b.server_id AND rp.book_id = b.remote_id
    """

    static func mediaSeriesRecord(from row: Row) -> SeriesRecord {
        SeriesRecord(
            serverID: row["server_id"], remoteID: row["remote_id"], libraryID: row["library_id"],
            name: row["name"], sortName: row["sort_name"], status: row["status"],
            createdAt: row["created_at"], lastModified: row["last_modified"],
            booksCount: row["books_count"], booksReadCount: row["books_read_count"],
            booksUnreadCount: row["books_unread_count"], booksInProgressCount: row["books_in_progress_count"]
        )
    }

    static func mediaBookRecord(from row: Row) -> BookRecord {
        BookRecord(
            serverID: row["server_id"], remoteID: row["remote_id"], seriesID: row["series_id"],
            seriesTitle: row["series_title"], title: row["title"], number: row["number"],
            numberSort: row["number_sort"], fileSize: row["file_size"], mediaType: row["media_type"],
            pagesCount: row["pages_count"], createdAt: row["created_at"], lastModified: row["last_modified"],
            progressPage: row["progress_page"], progressCompleted: row["progress_completed"]
        )
    }

    static func mediaAuthorRow(from row: Row) -> AuthorRow {
        AuthorRow(name: row["name"], role: row["role"])
    }

    static func mediaCollectionRecord(from row: Row) -> CollectionRecord {
        CollectionRecord(
            serverID: row["server_id"], remoteID: row["remote_id"], name: row["name"],
            ordered: row["ordered"], filtered: row["filtered"], createdDate: row["created_date"],
            lastModifiedDate: row["last_modified_date"]
        )
    }

    static func mediaReadlistRecord(from row: Row) -> ReadlistRecord {
        ReadlistRecord(
            serverID: row["server_id"], remoteID: row["remote_id"], name: row["name"],
            summary: row["summary"], ordered: row["ordered"], filtered: row["filtered"],
            createdDate: row["created_date"], lastModifiedDate: row["last_modified_date"]
        )
    }

    /// RFC 3339 with millisecond precision (matches the Swift store).
    static func rfc3339Text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
// MARK: - Test probes (also handy for debug surfaces)

public extension KomgaStore {
    /// The current `PRAGMA user_version` (migration state).
    func schemaVersion() throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(db, sql: "PRAGMA user_version") ?? 0
        }
    }

    /// Pending outbox rows for a server (mutation upload backlog).
    func pendingMutationCount(serverID: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM pending_mutations WHERE server_id = ?",
                arguments: [serverID]
            ) ?? 0
        }
    }
}
