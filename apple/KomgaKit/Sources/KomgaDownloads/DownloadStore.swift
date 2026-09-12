import Foundation
import GRDB
import KomgaStore

// MARK: - Every SQL the offline download queue speaks (mirror of Rust `downloads/store.rs`)
//
// Two shapes in here are the whole design, so they are stated once and pointed at
// from elsewhere rather than being rediscovered per query:
//
//   * a state change is an **optimistic** `UPDATE ... WHERE state = <expected>`,
//     and it reports whether it moved anything. That is how a user's pause, which
//     can land at any millisecond of a pass that is mid-book, wins without a
//     signal, a lock or a cancellation flag: the pass's next write simply changes
//     zero rows and it stops.
//   * `pages_done` / `bytes_done` are **derived**. Nothing in this module adds one
//     to a counter; every write path recomputes both from `download_pages`. A
//     bookkeeping row lost to a half-applied commit would otherwise leave a book
//     permanently one page short of finishing.
//
// Pure GRDB: no network, no filesystem, no async. One deliberate spelling
// difference from the Rust module: GRDB's own errors are propagated as
// themselves instead of being wrapped in a `QueueError.sql` case — the two
// refusals below are the only ones callers branch on, because they are the only
// ones the contract makes.

/// The refusals callers branch on. SQLite-level failures arrive as GRDB's own
/// errors; only the decisions the contract makes are enumerated here.
public enum QueueError: Error, Equatable {
    /// Refused by the contract table rather than by a constraint. Reported as an
    /// error and never silently dropped, because the only ways to reach one are a
    /// code change that ignored the table or a database somebody edited by hand.
    case illegalTransition(from: String, to: String, actor: String)
    /// No download row for the pair.
    case notFound(serverId: String, bookId: String)
    /// The derived `manifest.json` could not be written or read. Reported rather
    /// than swallowed: the third-party view of a download is the only thing about
    /// it that survives somebody deleting the database. (Raised by the engine,
    /// carried here so the whole queue speaks one error vocabulary.)
    case manifest(String)
}

/// One `downloads` row. `pages_total`/`pages_done` are nullable in the schema
/// because SQLite cannot change a live column's nullability, so every read of
/// them coalesces: a NULL is a zero, never a mystery.
public struct DownloadRow: Sendable, Equatable {
    public var serverId: String
    public var bookId: String
    public var manifestPath: String?
    public var state: String
    public var position: Int64
    public var pagesTotal: Int64
    public var pagesDone: Int64
    public var bytesTotal: Int64
    public var bytesDone: Int64
    public var createdAt: String
    public var updatedAt: String?
    public var lastError: String?
    public var nextRetryAt: String?
    public var remoteLastModified: String?
    public var bookTitle: String?
    public var seriesTitle: String?
    public var allowCellular: Bool

    /// The same seventeen columns Rust reads positionally, aliased so the names
    /// survive the COALESCE a NULL would otherwise hide behind.
    static let columns = """
        server_id, book_id, manifest_path, state, position,
        COALESCE(pages_total, 0) AS pages_total, COALESCE(pages_done, 0) AS pages_done,
        bytes_total, bytes_done, created_at, updated_at, last_error, next_retry_at,
        remote_last_modified, book_title, series_title, allow_cellular
        """

    init(_ row: Row) {
        serverId = row["server_id"] ?? ""
        bookId = row["book_id"] ?? ""
        manifestPath = row["manifest_path"]
        state = row["state"] ?? ""
        position = row["position"] ?? 0
        pagesTotal = row["pages_total"] ?? 0
        pagesDone = row["pages_done"] ?? 0
        bytesTotal = row["bytes_total"] ?? 0
        bytesDone = row["bytes_done"] ?? 0
        createdAt = row["created_at"] ?? ""
        updatedAt = row["updated_at"]
        lastError = row["last_error"]
        nextRetryAt = row["next_retry_at"]
        remoteLastModified = row["remote_last_modified"]
        bookTitle = row["book_title"]
        seriesTitle = row["series_title"]
        let rawAllowCellular: Int64? = row["allow_cellular"]
        allowCellular = (rawAllowCellular ?? 0) != 0
    }
}

/// One `download_pages` row.
public struct DownloadPageRow: Sendable, Equatable {
    public var serverId: String
    public var bookId: String
    public var number: Int
    public var filePath: String?
    public var state: String
    public var sizeBytes: Int64
    public var mediaType: String
    public var attempts: Int
    public var lastError: String?
    public var updatedAt: String?

    /// The ten columns Rust reads positionally as `PAGE_COLUMNS`.
    static let columns = """
        server_id, book_id, page_number, file_path, state, size_bytes,
        media_type, attempts, last_error, updated_at
        """

    init(_ row: Row) {
        serverId = row["server_id"] ?? ""
        bookId = row["book_id"] ?? ""
        let rawNumber: Int64? = row["page_number"]
        number = Int(rawNumber ?? 0)
        filePath = row["file_path"]
        state = row["state"] ?? ""
        sizeBytes = row["size_bytes"] ?? 0
        mediaType = row["media_type"] ?? ""
        let rawAttempts: Int64? = row["attempts"]
        attempts = Int(rawAttempts ?? 0)
        lastError = row["last_error"]
        updatedAt = row["updated_at"]
    }
}

/// What the caller knows when it asks for a job to be created.
public struct NewDownload: Sendable {
    public var serverId: String
    public var bookId: String
    public var pagesTotal: Int
    public var bytesTotal: Int64
    public var manifestPath: String
    public var remoteLastModified: String?
    public var bookTitle: String?
    public var seriesTitle: String?

    public init(
        serverId: String,
        bookId: String,
        pagesTotal: Int,
        bytesTotal: Int64,
        manifestPath: String,
        remoteLastModified: String?,
        bookTitle: String?,
        seriesTitle: String?
    ) {
        self.serverId = serverId
        self.bookId = bookId
        self.pagesTotal = pagesTotal
        self.bytesTotal = bytesTotal
        self.manifestPath = manifestPath
        self.remoteLastModified = remoteLastModified
        self.bookTitle = bookTitle
        self.seriesTitle = seriesTitle
    }
}

public enum DownloadStore {
    // MARK: - job rows

    /// Create or re-open the queue entry for one book, and lay out its page rows.
    ///
    /// Re-enqueuing a completed book is a fresh job: its page rows are rebuilt, which
    /// is what keeps the `completed -> waiting` transition legal under the contract
    /// (a user gesture clears the rows first, so the pump never decides to redo work).
    public static func enqueue(
        db: GRDB.Database,
        job: NewDownload,
        numbers: [Int],
        now: String
    ) throws -> DownloadRow {
        if !DownloadQueue.enqueueAllowed() {
            throw QueueError.illegalTransition(
                from: "(none)",
                to: BookState.waiting.rawValue,
                actor: QueueActor.user.rawValue
            )
        }
        // Re-tapping 下载 while a pass holds the book would rebuild the page rows
        // underneath it, so it is refused rather than merely discouraged. The same
        // gesture is also how a completed book starts over, and that one is legal —
        // see the `illegal` list in downloads/states.json.
        let existing = try get(db: db, serverId: job.serverId, bookId: job.bookId)
        if let existing,
            !DownloadQueue.transitionAllowed(
                from: existing.state, to: BookState.waiting.rawValue, actor: .user)
        {
            throw QueueError.illegalTransition(
                from: existing.state,
                to: BookState.waiting.rawValue,
                actor: QueueActor.user.rawValue
            )
        }
        // A re-tap on a book still in the queue keeps its place: moving it to the back
        // for pressing the button twice is the kind of thing a user never forgives.
        let keepPosition = existing?.state == BookState.waiting.rawValue
        var created: DownloadRow?
        try db.inTransaction {
            let position: Int64
            if keepPosition {
                position = existing?.position ?? 1
            } else {
                position = try Int64.fetchOne(
                    db,
                    sql: "SELECT COALESCE(MAX(position), 0) + 1 FROM downloads WHERE server_id = ?",
                    arguments: [job.serverId]
                ) ?? 1
            }
            try db.execute(
                sql: """
                INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done,
                                       state, created_at, updated_at, position, bytes_total, bytes_done,
                                       remote_last_modified, book_title, series_title)
                VALUES (?, ?, ?, ?, 0, ?, ?, ?, ?, ?, 0, ?, ?, ?)
                ON CONFLICT(server_id, book_id) DO UPDATE SET
                  manifest_path = excluded.manifest_path,
                  pages_total = excluded.pages_total,
                  bytes_total = excluded.bytes_total,
                  state = excluded.state,
                  updated_at = excluded.updated_at,
                  last_error = NULL,
                  next_retry_at = NULL,
                  remote_last_modified = excluded.remote_last_modified,
                  book_title = excluded.book_title,
                  series_title = excluded.series_title
                """,
                arguments: [
                    job.serverId, job.bookId, job.manifestPath, Int64(job.pagesTotal),
                    BookState.waiting.rawValue, now, now, position, job.bytesTotal,
                    job.remoteLastModified, job.bookTitle, job.seriesTitle,
                ]
            )
            try db.execute(
                sql: "DELETE FROM download_pages WHERE server_id = ? AND book_id = ?",
                arguments: [job.serverId, job.bookId]
            )
            for number in numbers {
                try db.execute(
                    sql: """
                    INSERT INTO download_pages (server_id, book_id, page_number, state, size_bytes,
                                                media_type, attempts, updated_at)
                    VALUES (?, ?, ?, ?, 0, '', 0, ?)
                    """,
                    arguments: [
                        job.serverId, job.bookId, Int64(number), PageState.pending.rawValue, now,
                    ]
                )
            }
            guard let row = try get(db: db, serverId: job.serverId, bookId: job.bookId) else {
                throw QueueError.notFound(serverId: job.serverId, bookId: job.bookId)
            }
            created = row
            return .commit
        }
        return try created.unwrapOrThrow(QueueError.notFound(
            serverId: job.serverId, bookId: job.bookId))
    }

    public static func get(
        db: GRDB.Database,
        serverId: String,
        bookId: String
    ) throws -> DownloadRow? {
        try Row.fetchOne(
            db,
            sql: "SELECT \(DownloadRow.columns) FROM downloads WHERE server_id = ? AND book_id = ?",
            arguments: [serverId, bookId]
        ).map(DownloadRow.init)
    }

    /// The queue, in the order the user built it.
    public static func list(
        db: GRDB.Database,
        serverId: String?
    ) throws -> [DownloadRow] {
        if let serverId {
            return try Row.fetchAll(
                db,
                sql: """
                SELECT \(DownloadRow.columns) FROM downloads
                WHERE server_id = ? ORDER BY position, server_id, book_id
                """,
                arguments: [serverId]
            ).map(DownloadRow.init)
        }
        return try Row.fetchAll(
            db,
            sql: "SELECT \(DownloadRow.columns) FROM downloads ORDER BY position, server_id, book_id"
        ).map(DownloadRow.init)
    }

    /// The current state, or `nil` when there is no such download.
    public static func stateOf(
        db: GRDB.Database,
        serverId: String,
        bookId: String
    ) throws -> String? {
        try String.fetchOne(
            db,
            sql: "SELECT state FROM downloads WHERE server_id = ? AND book_id = ?",
            arguments: [serverId, bookId]
        )
    }

    /// Move a book's state, through the contract table and with optimistic locking.
    ///
    /// `true` means this write is the one that changed the row. `false` means it
    /// changed nothing: the row was no longer in any of the `from` states, because
    /// somebody else — in practice the user, pausing it — got there first. The caller
    /// must then stop, not retry with a different expectation. Whether the book exists
    /// at all is a separate question with a separate function (`get`), and conflating
    /// the two is a bug that looks like a race being handled.
    public static func setState(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        from: [String],
        to: String,
        actor: QueueActor,
        now: String,
        lastError: String?
    ) throws -> Bool {
        for previous in from
        where !DownloadQueue.transitionAllowed(from: previous, to: to, actor: actor) {
            throw QueueError.illegalTransition(
                from: previous, to: to, actor: actor.rawValue
            )
        }
        // The interpolation is GRDB's, not string formatting: every value here is
        // bound as a parameter, and the sequence becomes the parenthesized
        // placeholder list the IN clause needs.
        try db.execute(literal: """
            UPDATE downloads SET state = \(to), updated_at = \(now), last_error = \(lastError)
            WHERE server_id = \(serverId) AND book_id = \(bookId) AND state IN \(from)
            """)
        return db.changesCount > 0
    }

    public static func setAllowCellular(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        allow: Bool,
        now: String
    ) throws {
        try db.execute(
            sql: "UPDATE downloads SET allow_cellular = ?, updated_at = ? WHERE server_id = ? AND book_id = ?",
            arguments: [allow ? Int64(1) : Int64(0), now, serverId, bookId]
        )
    }

    /// Park every book of one server until `until`. A rejected credential is a
    /// server-wide fact, and discovering the 401 once per book is three hundred
    /// requests that all mean the same thing.
    public static func parkServer(
        db: GRDB.Database,
        serverId: String,
        until: String,
        reason: String,
        now: String
    ) throws -> Int {
        try db.execute(
            sql: """
            UPDATE downloads SET next_retry_at = ?, last_error = ?, updated_at = ?
            WHERE server_id = ? AND state IN (?, ?)
            """,
            arguments: [
                until, reason, now, serverId,
                BookState.waiting.rawValue, BookState.downloading.rawValue,
            ]
        )
        return db.changesCount
    }

    public static func clearPark(
        db: GRDB.Database,
        serverId: String,
        now: String
    ) throws -> Int {
        try db.execute(
            sql: "UPDATE downloads SET next_retry_at = NULL, updated_at = ? WHERE server_id = ?",
            arguments: [now, serverId]
        )
        return db.changesCount
    }

    // MARK: - page rows

    public static func pages(
        db: GRDB.Database,
        serverId: String,
        bookId: String
    ) throws -> [DownloadPageRow] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT \(DownloadPageRow.columns) FROM download_pages
            WHERE server_id = ? AND book_id = ? ORDER BY page_number
            """,
            arguments: [serverId, bookId]
        ).map(DownloadPageRow.init)
    }

    public static func page(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        number: Int
    ) throws -> DownloadPageRow? {
        try Row.fetchOne(
            db,
            sql: """
            SELECT \(DownloadPageRow.columns) FROM download_pages
            WHERE server_id = ? AND book_id = ? AND page_number = ?
            """,
            arguments: [serverId, bookId, Int64(number)]
        ).map(DownloadPageRow.init)
    }

    /// The pages a book has that the reader may paint without a network. Used both by
    /// the reader's own tier check and by the prefetch planner, which must not queue
    /// what is already on the device.
    public static func completePages(
        db: GRDB.Database,
        serverId: String,
        bookId: String
    ) throws -> [Int] {
        try Int.fetchAll(
            db,
            sql: """
            SELECT page_number FROM download_pages
            WHERE server_id = ? AND book_id = ? AND state = ? ORDER BY page_number
            """,
            arguments: [serverId, bookId, PageState.complete.rawValue]
        )
    }

    /// A landed page. `path` is the final name, not the staging one: the caller has
    /// already renamed.
    public static func markPageComplete(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        number: Int,
        path: String,
        sizeBytes: Int64,
        mediaType: String,
        now: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO download_pages (server_id, book_id, page_number, file_path, state,
                                        size_bytes, media_type, attempts, last_error, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL, ?)
            ON CONFLICT(server_id, book_id, page_number) DO UPDATE SET
              file_path = excluded.file_path,
              state = excluded.state,
              size_bytes = excluded.size_bytes,
              media_type = excluded.media_type,
              last_error = NULL,
              updated_at = excluded.updated_at
            """,
            arguments: [
                serverId, bookId, Int64(number), path, PageState.complete.rawValue,
                sizeBytes, mediaType, now,
            ]
        )
    }

    /// A page attempt that was about this page. Burns one attempt, and at the limit
    /// the page becomes `failed` so the queue can move on past it.
    public static func recordPageAttempt(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        number: Int,
        error: String,
        now: String
    ) throws -> Bool {
        try db.execute(
            sql: """
            UPDATE download_pages SET attempts = attempts + 1, last_error = ?, updated_at = ?
            WHERE server_id = ? AND book_id = ? AND page_number = ?
            """,
            arguments: [error, now, serverId, bookId, Int64(number)]
        )
        let exhausted = try Bool.fetchOne(
            db,
            sql: "SELECT attempts >= ? FROM download_pages WHERE server_id = ? AND book_id = ? AND page_number = ?",
            arguments: [
                Int64(DownloadQueue.maxPageAttempts), serverId, bookId, Int64(number),
            ]
        ) ?? false
        if exhausted {
            try db.execute(
                sql: """
                UPDATE download_pages SET state = ?, updated_at = ?
                WHERE server_id = ? AND book_id = ? AND page_number = ?
                """,
                arguments: [PageState.failed.rawValue, now, serverId, bookId, Int64(number)]
            )
        }
        return exhausted
    }

    /// Clear the failed pages of a book, and only those. `complete` rows are untouched:
    /// the value of single-page retry is that three bad pages in a four-hundred page
    /// book costs three requests, and the acceptance harness asserts exactly that.
    public static func retryFailedPages(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        now: String
    ) throws -> Int {
        try db.execute(
            sql: """
            UPDATE download_pages SET state = ?, attempts = 0, last_error = NULL, updated_at = ?
            WHERE server_id = ? AND book_id = ? AND state = ?
            """,
            arguments: [
                PageState.pending.rawValue, now, serverId, bookId, PageState.failed.rawValue,
            ]
        )
        return db.changesCount
    }

    /// The `heal` direction: the filesystem disproved a row.
    public static func healPage(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        number: Int,
        now: String
    ) throws {
        let previous = try page(db: db, serverId: serverId, bookId: bookId, number: number)
        let from = previous?.state ?? PageState.pending.rawValue
        if !DownloadQueue.transitionAllowed(
            from: from, to: PageState.pending.rawValue, actor: .heal),
            from != PageState.pending.rawValue
        {
            throw QueueError.illegalTransition(
                from: from,
                to: PageState.pending.rawValue,
                actor: QueueActor.heal.rawValue
            )
        }
        if previous != nil {
            try db.execute(
                sql: """
                UPDATE download_pages SET state = ?, file_path = NULL, size_bytes = 0,
                       attempts = 0, last_error = NULL, media_type = '', updated_at = ?
                WHERE server_id = ? AND book_id = ? AND page_number = ?
                """,
                arguments: [PageState.pending.rawValue, now, serverId, bookId, Int64(number)]
            )
        } else {
            try db.execute(
                sql: "INSERT INTO download_pages (server_id, book_id, page_number, state, updated_at) VALUES (?, ?, ?, ?, ?)",
                arguments: [
                    serverId, bookId, Int64(number), PageState.pending.rawValue, now,
                ]
            )
        }
    }

    /// The other `heal` direction, and the one that looks backwards at first: a usable
    /// file with no row is ADOPTED rather than deleted. "Row commit lost, file landed"
    /// is a real event on a device under write contention, and the alternative is
    /// throwing away bytes the user paid for on a metered link.
    public static func adoptPage(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        number: Int,
        path: String,
        sizeBytes: Int64,
        mediaType: String,
        now: String
    ) throws {
        try markPageComplete(
            db: db, serverId: serverId, bookId: bookId, number: number,
            path: path, sizeBytes: sizeBytes, mediaType: mediaType, now: now
        )
    }

    public static func deletePage(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        number: Int
    ) throws {
        try db.execute(
            sql: "DELETE FROM download_pages WHERE server_id = ? AND book_id = ? AND page_number = ?",
            arguments: [serverId, bookId, Int64(number)]
        )
    }

    // MARK: - accounting

    /// Recompute both book counters from the page rows. Returns `(pages_done,
    /// bytes_done)` so the caller can settle state from the same pair it just wrote.
    public static func recomputeCounters(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        now: String
    ) throws -> (pagesDone: Int64, bytesDone: Int64) {
        let counted = try Row.fetchOne(
            db,
            sql: """
            SELECT COUNT(*) AS done, COALESCE(SUM(size_bytes), 0) AS bytes
            FROM download_pages WHERE server_id = ? AND book_id = ? AND state = ?
            """,
            arguments: [serverId, bookId, PageState.complete.rawValue]
        )
        let done = counted?["done"] as Int64? ?? 0
        let bytes = counted?["bytes"] as Int64? ?? 0
        try db.execute(
            sql: "UPDATE downloads SET pages_done = ?, bytes_done = ?, updated_at = ? WHERE server_id = ? AND book_id = ?",
            arguments: [done, bytes, now, serverId, bookId]
        )
        return (done, bytes)
    }

    /// Derive a book's state from its rows, and write it if it moved.
    ///
    /// `paused` survives untouched here whatever the rows say: the pump may settle a
    /// book it holds, and it may never launder a pause into progress. `completed` is
    /// just as sticky against a pass — and not against the sweep, which has looked at
    /// the disk. See `healReopens` in `downloads/states.json`.
    public static func settleBook(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        now: String,
        mode: SettleMode
    ) throws -> String {
        guard let row = try get(db: db, serverId: serverId, bookId: bookId) else {
            throw QueueError.notFound(serverId: serverId, bookId: bookId)
        }
        let counted = try Row.fetchOne(
            db,
            sql: """
            SELECT COALESCE(SUM(state = ?), 0) AS complete, COALESCE(SUM(state = ?), 0) AS failed
            FROM download_pages WHERE server_id = ? AND book_id = ?
            """,
            arguments: [
                PageState.complete.rawValue, PageState.failed.rawValue, serverId, bookId,
            ]
        )
        let complete = counted?["complete"] as Int64? ?? 0
        let failed = counted?["failed"] as Int64? ?? 0
        let derived = DownloadQueue.settleState(
            row.state,
            pagesTotal: Int(max(row.pagesTotal, 0)),
            complete: Int(max(complete, 0)),
            failed: Int(max(failed, 0)),
            mode: mode
        )
        _ = try recomputeCounters(db: db, serverId: serverId, bookId: bookId, now: now)
        if derived == row.state {
            return derived
        }
        _ = try setState(
            db: db,
            serverId: serverId,
            bookId: bookId,
            from: [row.state],
            to: derived,
            // The transition is always recorded as `settle`: `mode` decides what may be
            // derived, and the table says who may write. See `healReopens`.
            actor: .settle,
            now: now,
            lastError: row.lastError
        )
        return try get(db: db, serverId: serverId, bookId: bookId)?.state ?? derived
    }

    /// Force a state for the user's own actions (pause, resume, retry), refusing what
    /// the contract table refuses.
    public static func userSet(
        db: GRDB.Database,
        serverId: String,
        bookId: String,
        to: String,
        now: String,
        lastError: String?
    ) throws -> DownloadRow {
        guard let row = try get(db: db, serverId: serverId, bookId: bookId) else {
            throw QueueError.notFound(serverId: serverId, bookId: bookId)
        }
        _ = try setState(
            db: db, serverId: serverId, bookId: bookId,
            from: [row.state], to: to, actor: .user, now: now, lastError: lastError
        )
        guard let fresh = try get(db: db, serverId: serverId, bookId: bookId) else {
            throw QueueError.notFound(serverId: serverId, bookId: bookId)
        }
        return fresh
    }

    /// Delete a book's rows. Returns the page paths the caller must then remove; the
    /// order matters — rows first would leave the files unownable if the process died
    /// between the two, and the sweep preserves what it cannot attribute.
    public static func deleteRows(
        db: GRDB.Database,
        serverId: String,
        bookId: String
    ) throws -> [String] {
        let paths = try String.fetchAll(
            db,
            sql: "SELECT file_path FROM download_pages WHERE server_id = ? AND book_id = ? AND file_path IS NOT NULL",
            arguments: [serverId, bookId]
        )
        try db.execute(
            sql: "DELETE FROM download_pages WHERE server_id = ? AND book_id = ?",
            arguments: [serverId, bookId]
        )
        try db.execute(
            sql: "DELETE FROM downloads WHERE server_id = ? AND book_id = ?",
            arguments: [serverId, bookId]
        )
        return paths
    }

    /// The queue as the planner needs it: every claimable book with its page rows and
    /// the best size estimate available for each page.
    ///
    /// The estimate matters because the byte budget is the only bound that keeps a
    /// pass from holding a runtime worker through 96 MB of 4K pages, and a pending
    /// page has no measured size yet. So it falls back through the mirror's declared
    /// size to the book's own average, and a book with neither gets zero — which the
    /// planner reads as "unbounded", the same conservative-but-not-frozen answer every
    /// unknown device fact gets elsewhere in the core.
    public static func planBooks(
        db: GRDB.Database,
        serverId: String?
    ) throws -> [BookPlan] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT d.server_id AS server_id, d.book_id AS book_id, d.state AS state,
                   d.position AS position, d.allow_cellular AS allow_cellular,
                   COALESCE(d.pages_total, 0) AS pages_total, d.next_retry_at AS next_retry_at,
                   p.page_number AS page_number, p.state AS page_state, p.attempts AS attempts,
                   COALESCE(NULLIF(p.size_bytes, 0), bp.size_bytes,
                            CASE WHEN d.pages_total > 0
                                 THEN d.bytes_total / d.pages_total ELSE 0 END, 0) AS declared
            FROM downloads d
            LEFT JOIN download_pages p
                   ON p.server_id = d.server_id AND p.book_id = d.book_id
            LEFT JOIN book_pages bp
                   ON bp.server_id = d.server_id AND bp.book_id = d.book_id
                  AND bp.number = p.page_number
            WHERE (? IS NULL OR d.server_id = ?) AND d.state IN (?, ?)
            ORDER BY d.position, d.server_id, d.book_id, p.page_number
            """,
            arguments: [serverId, serverId, BookState.waiting.rawValue, BookState.downloading.rawValue]
        )
        var books: [BookPlan] = []
        for row in rows {
            let serverId: String = row["server_id"] ?? ""
            let bookId: String = row["book_id"] ?? ""
            let rawNumber: Int64? = row["page_number"]
            let page: PagePlan?
            if let number = rawNumber {
                let rawAttempts: Int64? = row["attempts"]
                let rawDeclared: Int64? = row["declared"]
                page = PagePlan(
                    number: Int(number),
                    state: row["page_state"] ?? "",
                    attempts: Int(rawAttempts ?? 0),
                    declaredBytes: rawDeclared ?? 0
                )
            } else {
                page = nil
            }
            if var last = books.last, last.serverId == serverId && last.bookId == bookId {
                if let page {
                    last.pages.append(page)
                    books[books.count - 1] = last
                }
                continue
            }
            let rawAllow: Int64? = row["allow_cellular"]
            var plan = BookPlan(
                serverId: serverId,
                bookId: bookId,
                position: Int(row["position"] ?? 0),
                state: row["state"] ?? "",
                allowCellular: (rawAllow ?? 0) != 0,
                pagesTotal: Int(row["pages_total"] ?? 0),
                nextRetryAt: row["next_retry_at"],
                pages: []
            )
            if let page {
                plan.pages.append(page)
            }
            books.append(plan)
        }
        return books
    }

    // MARK: - totals

    /// Bytes the user's downloads hold, across every server.
    public static func bytesDoneAll(db: GRDB.Database) throws -> Int64 {
        try Int64.fetchOne(
            db,
            sql: "SELECT COALESCE(SUM(size_bytes), 0) FROM download_pages WHERE state = ?",
            arguments: [PageState.complete.rawValue]
        ) ?? 0
    }

    public static func bytesDoneAll(store: KomgaStore) throws -> Int64 {
        try store.read { try bytesDoneAll(db: $0) }
    }

    public static func bytesDoneFor(db: GRDB.Database, serverId: String) throws -> Int64 {
        try Int64.fetchOne(
            db,
            sql: """
            SELECT COALESCE(SUM(p.size_bytes), 0) FROM download_pages p
            JOIN downloads d ON d.server_id = p.server_id AND d.book_id = p.book_id
            WHERE p.state = ? AND p.server_id = ?
            """,
            arguments: [PageState.complete.rawValue, serverId]
        ) ?? 0
    }

    public static func pageCountAll(db: GRDB.Database) throws -> Int64 {
        try Int64.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM download_pages WHERE state = ?",
            arguments: [PageState.complete.rawValue]
        ) ?? 0
    }

    public static func pageCountAll(store: KomgaStore) throws -> Int64 {
        try store.read { try pageCountAll(db: $0) }
    }

    /// Per-book storage rows, newest download first. Ordered in SQL rather than in
    /// Dart so both platforms' screens agree without either restating the rule.
    public static func storageRows(db: GRDB.Database) throws -> [DownloadRow] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT \(DownloadRow.columns) FROM downloads
            ORDER BY bytes_done DESC, created_at, server_id, book_id
            """
        ).map(DownloadRow.init)
    }
}

private extension Optional {
    /// A transaction block has to hand back its result through a captured
    /// variable, because GRDB's `inTransaction` completes with `.commit` rather
    /// than returning the block's value. This keeps the unwrap at the edge.
    func unwrapOrThrow(_ error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}
