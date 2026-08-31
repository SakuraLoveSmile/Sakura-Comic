import XCTest
import SQLite3
import KomgaAPI
import KomgaStore
import KomgaSync

/// Stage 4 mirror tests: shared fixtures decode, Schema v4 migrations,
/// FullSync onboarding, and the local query battery (search / filters /
/// sorts / pagination / continue reading / outbox) — all SQLite.
final class MediaLibraryStoreTests: XCTestCase {
    // MARK: - Shared fixtures

    private var libraryFixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/library")
            .standardizedFileURL
    }

    private func loadFixture<T: Decodable>(_ name: String) throws -> T {
        let data = try Data(contentsOf: libraryFixturesURL.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    func testSharedFixturesDecode() throws {
        let seriesPage: SeriesPageDTO = try loadFixture("series-page.json")
        XCTAssertEqual(seriesPage.content.count, 3)
        XCTAssertEqual(seriesPage.content[0].booksCount, 3)
        XCTAssertEqual(seriesPage.content[0].metadata?.genres?.count, 2)

        let booksBySeries: [String: BookPageDTO] = try loadFixture("books-by-series.json")
        XCTAssertEqual(booksBySeries["series-1"]?.content.count, 3)
        XCTAssertEqual(booksBySeries["series-2"]?.content.count, 2)
        let first = try XCTUnwrap(booksBySeries["series-1"]?.content.first)
        XCTAssertEqual(first.id, "book-1-1")
        XCTAssertEqual(first.metadata?.numberSort, 1.0)
        XCTAssertEqual(first.readProgress?.completed, true)

        let collections: CollectionPageDTO = try loadFixture("collections-page.json")
        XCTAssertEqual(collections.content.count, 2)
        XCTAssertEqual(collections.content[0].seriesIds, ["series-1", "series-3"])

        let readlists: ReadListPageDTO = try loadFixture("readlists-page.json")
        XCTAssertEqual(readlists.content[0].bookIds, ["book-1-1", "book-1-2", "book-2-1"])

        let onDeck: BookPageDTO = try loadFixture("ondeck-page.json")
        XCTAssertEqual(onDeck.content.first?.id, "book-1-2")
        XCTAssertEqual(onDeck.content.first?.readProgress?.page, 12)
    }

    // MARK: - Schema v4 migration

    func testSchemaV4MigratesV3Database() throws {
        // A v3-shaped database: old FTS shape + tables without the v4 columns.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("komga-v3-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temp) }

        let v3 = try GRDB2.makeV3Database(at: temp)
        XCTAssertEqual(v3, true)

        let store = try KomgaStore(path: temp.path)
        // v4 columns exist after migration.
        let seriesCount = try store.countSeries(serverID: "srv-1")
        XCTAssertEqual(seriesCount, 0)
        // The server-scoped FTS shape was rebuilt (server_id column).
        _ = try store.querySeries(serverID: "srv-1", limit: 10, offset: 0)
        // Reading the schema version through a pragma.
        XCTAssertEqual(try store.schemaVersion(), Schema.currentVersion)
        // Pinned to Rust `SCHEMA_VERSION` on purpose; the line above only
        // proves the store reported whatever this file says it is.
        XCTAssertEqual(try store.schemaVersion(), 9)
        // v5 landed on the pre-existing libraries table.
        let libraryColumns = try store.columnNames(table: "libraries")
        XCTAssertTrue(libraryColumns.contains("root"), "\(libraryColumns)")
        XCTAssertTrue(libraryColumns.contains("unavailable"), "\(libraryColumns)")
        // v6 rebuilt sync_state around a per-entity key and added tombstones.
        let syncColumns = try store.columnNames(table: "sync_state")
        XCTAssertTrue(syncColumns.contains("entity_type"), "\(syncColumns)")
        XCTAssertTrue(syncColumns.contains("sync_cursor"), "\(syncColumns)")
        let tombstoneColumns = try store.columnNames(table: "deleted_entities")
        XCTAssertTrue(tombstoneColumns.contains("cause"), "\(tombstoneColumns)")
        // v7 added the Outbox scheduling columns to the pre-existing table.
        let outboxColumns = try store.columnNames(table: "pending_mutations")
        XCTAssertTrue(outboxColumns.contains("state"), "\(outboxColumns)")
        XCTAssertTrue(outboxColumns.contains("next_retry_at"), "\(outboxColumns)")
        // ...and the index that makes a due scan cheap (same shape as a fresh DB).
        let outboxIndexes = try store.indexNames(table: "pending_mutations")
        XCTAssertTrue(outboxIndexes.contains("pending_mutations_due"), "\(outboxIndexes)")
    }

    // MARK: - FullSync + local query battery

    func testFullSyncSeedsFullMediaLibrary() async throws {
        let store = try KomgaStore()
        let fetcher = FixtureLibraryFetching()
        let summary = try await FullSync.run(fetcher: fetcher, store: store, serverID: "srv-1")
        XCTAssertEqual(summary.series, 3)
        XCTAssertEqual(summary.books, 7)
        XCTAssertEqual(summary.collections, 2)
        XCTAssertEqual(summary.readlists, 2)
        XCTAssertEqual(summary.readProgress, 4) // 3 inline + 1 on-deck

        // Libraries mirror so the Library 列表 / 详情 screens have real data.
        _ = try store.upsertLibraries(serverID: "srv-1", libraries: try loadFixture("libraries.json"))
        let libs = try store.libraryCounts(serverID: "srv-1")
        XCTAssertEqual(libs.count, 2)
        let manga = libs.first(where: { $0.remoteID == "lib-1" })
        XCTAssertEqual(manga?.seriesCount, 2)
        XCTAssertEqual(manga?.root, "/manga")
        XCTAssertEqual(manga?.unavailable, false)
        XCTAssertGreaterThan(manga?.bookCount ?? 0, 0)
        // Counts stay library-scoped: the two rows add up to the mirrored books.
        XCTAssertEqual(libs.reduce(0) { $0 + $1.bookCount }, summary.books)

        let libraryRow = try store.libraryDetail(serverID: "srv-1", libraryID: "lib-1")
        XCTAssertEqual(libraryRow?.name, manga?.name)
        XCTAssertEqual(libraryRow?.seriesCount, manga?.seriesCount)
        XCTAssertEqual(libraryRow?.bookCount, manga?.bookCount)
        XCTAssertNil(try store.libraryDetail(serverID: "srv-1", libraryID: "missing"))

        // Series wall: name order + totals.
        let wall = try store.querySeries(serverID: "srv-1", limit: 50, offset: 0)
        XCTAssertEqual(wall.total, 3)
        XCTAssertEqual(wall.items.first?.name, "Berserk")

        // Search (FTS5).
        let search = try store.querySeries(serverID: "srv-1", search: "berserk", limit: 50, offset: 0)
        XCTAssertEqual(search.total, 1)
        XCTAssertEqual(search.items.first?.remoteID, "series-2")

        // Filters.
        let byTag = try store.querySeries(serverID: "srv-1", tag: "Seinen", limit: 50, offset: 0)
        XCTAssertEqual(byTag.total, 1)
        XCTAssertEqual(byTag.items.first?.remoteID, "series-2")
        let byGenre = try store.querySeries(serverID: "srv-1", genre: "Action", limit: 50, offset: 0)
        XCTAssertEqual(byGenre.total, 2)
        let byLibrary = try store.querySeries(serverID: "srv-1", libraryID: "lib-2", limit: 50, offset: 0)
        XCTAssertEqual(byLibrary.total, 1)
        XCTAssertEqual(byLibrary.items.first?.remoteID, "series-3")
        let byStatus = try store.querySeries(serverID: "srv-1", status: "ENDED", limit: 50, offset: 0)
        XCTAssertEqual(byStatus.total, 1)

        // Sort + pagination.
        let newest = try store.querySeries(serverID: "srv-1", sort: .dateAdded, ascending: false, limit: 50, offset: 0)
        XCTAssertEqual(newest.items.first?.name, "Solo Leveling")
        let page2 = try store.querySeries(serverID: "srv-1", limit: 2, offset: 2)
        XCTAssertEqual(page2.items.count, 1)
        XCTAssertEqual(page2.items.first?.name, "Solo Leveling")

        // Series detail: metadata + tags + genres + authors + memberships.
        let detail = try XCTUnwrap(store.seriesDetail(serverID: "srv-1", seriesID: "series-2"))
        XCTAssertEqual(detail.status, "ONGOING")
        XCTAssertEqual(detail.genres, ["Action", "Dark Fantasy"])
        XCTAssertEqual(detail.tags, ["Manga", "Seinen"])
        XCTAssertEqual(detail.authors.first?.name, "Kentaro Miura")
        XCTAssertEqual(detail.collections.first?.name, "Dark Fantasy Shelf")

        // Books: read-status partition.
        let books = try store.queryBooks(serverID: "srv-1", seriesID: "series-1", limit: 100, offset: 0)
        XCTAssertEqual(books.total, 3)
        let read = try store.queryBooks(serverID: "srv-1", seriesID: "series-1", readStatus: .read, limit: 100, offset: 0)
        let inProgress = try store.queryBooks(serverID: "srv-1", seriesID: "series-1", readStatus: .inProgress, limit: 100, offset: 0)
        let unread = try store.queryBooks(serverID: "srv-1", seriesID: "series-1", readStatus: .unread, limit: 100, offset: 0)
        XCTAssertEqual(read.total, 1)
        XCTAssertEqual(inProgress.total, 1)
        XCTAssertEqual(unread.total, 1)
        XCTAssertEqual(read.total + inProgress.total + unread.total, books.total)

        // Book detail.
        let bookDetail = try XCTUnwrap(store.bookDetail(serverID: "srv-1", bookID: "book-1-2"))
        XCTAssertEqual(bookDetail.progressPage, 12)
        XCTAssertEqual(bookDetail.pagesCount, 20)
        XCTAssertEqual(bookDetail.tags, ["Manga", "Pirate"])

        // Continue reading + local mutations write the outbox.
        let shelf = try store.continueReading(serverID: "srv-1", limit: 10)
        XCTAssertEqual(shelf.count, 1)
        XCTAssertEqual(shelf.first?.bookID, "book-1-2")
        XCTAssertEqual(shelf.first?.progressPercent, 60)

        try store.setReadProgress(serverID: "srv-1", bookID: "book-1-3", page: 3, completed: false)
        let grown = try store.continueReading(serverID: "srv-1", limit: 20)
        XCTAssertTrue(grown.contains { $0.bookID == "book-1-3" })
        try store.markRead(serverID: "srv-1", bookID: "book-1-3")
        let shrunk = try store.continueReading(serverID: "srv-1", limit: 20)
        XCTAssertFalse(shrunk.contains { $0.bookID == "book-1-3" })
        // One row, not two: the read-progress family collapses to the user's last
        // statement (fixtures/outbox/coalescing.json).
        XCTAssertEqual(try store.pendingMutationCount(serverID: "srv-1"), 1)

        // Collections + readlists details.
        let collections = try store.listCollections(serverID: "srv-1", limit: 50, offset: 0)
        XCTAssertEqual(collections.total, 2)
        let colDetail = try XCTUnwrap(store.collectionDetail(serverID: "srv-1", collectionID: "col-1", limit: 50, offset: 0))
        XCTAssertEqual(colDetail.members.items.map(\.name).sorted(), ["One Piece", "Solo Leveling"])

        let readlists = try store.listReadlists(serverID: "srv-1", limit: 50, offset: 0)
        XCTAssertEqual(readlists.total, 2)
        let rlDetail = try XCTUnwrap(store.readlistDetail(serverID: "srv-1", readlistID: "rl-1", limit: 50, offset: 0))
        XCTAssertEqual(rlDetail.books.items.map(\.remoteID), ["book-1-1", "book-1-2", "book-2-1"])

        // Filter options + full-sync stamp.
        let options = try store.filterOptions(serverID: "srv-1")
        XCTAssertTrue(options.tags.contains("Seinen"))
        XCTAssertTrue(options.genres.contains("Dark Fantasy"))
        XCTAssertEqual(options.statuses.sorted(), ["COMPLETED", "ENDED", "ONGOING"])
        let state = try XCTUnwrap(store.syncState(serverID: "srv-1"))
        XCTAssertNotNil(state.lastFullSync)
    }

    func testFullSyncRecordsEveryStepAsCompleted() async throws {
        let store = try KomgaStore()
        let summary = try await FullSync.run(
            fetcher: FixtureLibraryFetching(), store: store, serverID: "srv-1"
        )
        XCTAssertEqual(summary.libraries, 2)
        XCTAssertTrue(summary.skippedSteps.isEmpty)
        XCTAssertTrue(summary.resumedSteps.isEmpty)
        // Every bootstrap step recorded its own completion, cursor cleared.
        for entity in SyncEntity.bootstrapOrder {
            let state = try XCTUnwrap(
                store.entityState(serverID: "srv-1", entityType: entity), "\(entity) step row"
            )
            XCTAssertEqual(state.syncStatus, SyncStatus.idle, entity)
            XCTAssertNil(state.syncCursor, "\(entity) left a cursor")
            XCTAssertNotNil(state.lastSyncAt, entity)
        }
    }

    func testFullSyncFromScratchIsIdempotent() async throws {
        let store = try KomgaStore()
        let fetcher = FixtureLibraryFetching()
        let first = try await FullSync.run(
            fetcher: fetcher, store: store, serverID: "srv-1", start: .fresh
        )
        let second = try await FullSync.run(
            fetcher: fetcher, store: store, serverID: "srv-1", start: .fresh
        )
        XCTAssertEqual(first.series, second.series)
        XCTAssertEqual(first.books, second.books)
        XCTAssertEqual(first.collections, second.collections)
        XCTAssertEqual(try store.countSeries(serverID: "srv-1"), 3)
        XCTAssertEqual(try store.mirrorRowCount(serverID: "srv-1", table: "books"), 7)
    }

    func testCompletedBootstrapIsNotRemirrored() async throws {
        let store = try KomgaStore()
        let fetcher = FixtureLibraryFetching()
        _ = try await FullSync.run(fetcher: fetcher, store: store, serverID: "srv-1")
        let second = try await FullSync.run(fetcher: fetcher, store: store, serverID: "srv-1")
        // Keeping the mirror current is Reconcile's job; Bootstrap skips
        // steps it already finished.
        XCTAssertEqual(second.skippedSteps, SyncEntity.bootstrapOrder)
        XCTAssertEqual(second.series, 0)
        XCTAssertEqual(try store.mirrorRowCount(serverID: "srv-1", table: "books"), 7)
    }
}

// MARK: - Fixture-backed fetching for the package tests

private struct FixtureLibraryFetching: LibraryFetching {
    private var base: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/library")
            .standardizedFileURL
    }

    private func load<T: Decodable>(_ name: String) throws -> T {
        let data = try Data(contentsOf: base.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    func fetchLibraries() async throws -> [LibraryDTO] {
        try load("libraries.json")
    }

    func fetchSeriesPage(_ request: PageRequest) async throws -> SeriesPageDTO {
        var page: SeriesPageDTO = try load("series-page.json")
        if request.page > 0 {
            page = SeriesPageDTO(content: [], totalElements: 0, totalPages: 0, number: 1, size: 100, first: false, last: true)
        }
        return page
    }

    func fetchBooksPage(seriesID: String, request: PageRequest) async throws -> BookPageDTO {
        guard request.page == 0 else {
            return BookPageDTO(content: [], totalElements: 0, totalPages: 0, number: 1, size: 100, first: false, last: true)
        }
        let bySeries: [String: BookPageDTO] = try load("books-by-series.json")
        return bySeries[seriesID] ?? BookPageDTO(content: [], totalElements: 0, totalPages: 0, number: 0, size: 100, first: true, last: true)
    }

    func fetchOnDeckPage(request _: PageRequest) async throws -> BookPageDTO {
        try load("ondeck-page.json")
    }

    func fetchCollectionsPage(request _: PageRequest) async throws -> CollectionPageDTO {
        try load("collections-page.json")
    }

    func fetchReadlistsPage(request _: PageRequest) async throws -> ReadListPageDTO {
        try load("readlists-page.json")
    }
}

// MARK: - Minimal v3 database factory + version probe

private enum GRDB2 {
    /// Creates a v3-shaped database (old FTS shape, no v4 columns).
    static func makeV3Database(at url: URL) throws -> Bool {
        let connection = try GRDBConnection(path: url.path)
        defer { connection.close() }
        let v3 = """
        CREATE TABLE servers (id TEXT PRIMARY KEY, display_name TEXT NOT NULL, base_url TEXT NOT NULL, auth_type TEXT NOT NULL, credential_ref TEXT, capabilities TEXT NOT NULL DEFAULT '[]', last_successful_connection TEXT);
        CREATE TABLE libraries (server_id TEXT NOT NULL, remote_id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY (server_id, remote_id));
        CREATE TABLE series (server_id TEXT NOT NULL, remote_id TEXT NOT NULL, library_id TEXT NOT NULL, name TEXT NOT NULL, sort_name TEXT, status TEXT, created_at TEXT, last_modified TEXT, PRIMARY KEY (server_id, remote_id));
        CREATE TABLE books (server_id TEXT NOT NULL, remote_id TEXT NOT NULL, series_id TEXT NOT NULL, title TEXT NOT NULL, number TEXT, file_size INTEGER, media_type TEXT, created_at TEXT, last_modified TEXT, PRIMARY KEY (server_id, remote_id));
        CREATE TABLE collections (server_id TEXT NOT NULL, remote_id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY (server_id, remote_id));
        CREATE TABLE readlists (server_id TEXT NOT NULL, remote_id TEXT NOT NULL, name TEXT NOT NULL, PRIMARY KEY (server_id, remote_id));
        CREATE TABLE read_progress (server_id TEXT NOT NULL, book_id TEXT NOT NULL, page INTEGER, completed INTEGER NOT NULL DEFAULT 0, local_updated_at TEXT, server_updated_at TEXT, mutation_pending INTEGER NOT NULL DEFAULT 0, PRIMARY KEY (server_id, book_id));
        CREATE TABLE series_metadata (server_id TEXT NOT NULL, series_id TEXT NOT NULL, summary TEXT, publisher TEXT, authors TEXT NOT NULL DEFAULT '[]', tags TEXT NOT NULL DEFAULT '[]', PRIMARY KEY (server_id, series_id));
        CREATE TABLE book_metadata (server_id TEXT NOT NULL, book_id TEXT NOT NULL, summary TEXT, authors TEXT NOT NULL DEFAULT '[]', tags TEXT NOT NULL DEFAULT '[]', PRIMARY KEY (server_id, book_id));
        CREATE TABLE sync_state (server_id TEXT PRIMARY KEY, last_full_sync TEXT, last_successful_sync TEXT, last_error TEXT, sync_status TEXT NOT NULL DEFAULT 'idle');
        CREATE TABLE pending_mutations (id TEXT PRIMARY KEY, server_id TEXT NOT NULL, entity_id TEXT NOT NULL, mutation_type TEXT NOT NULL, payload TEXT NOT NULL, created_at TEXT NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0, last_error TEXT);
        CREATE TABLE downloads (server_id TEXT NOT NULL, book_id TEXT NOT NULL, manifest_path TEXT, pages_total INTEGER, pages_done INTEGER, state TEXT NOT NULL, PRIMARY KEY (server_id, book_id));
        CREATE TABLE download_pages (server_id TEXT NOT NULL, book_id TEXT NOT NULL, page_number INTEGER NOT NULL, file_path TEXT, state TEXT NOT NULL, PRIMARY KEY (server_id, book_id, page_number));
        CREATE TABLE thumbnails (server_id TEXT NOT NULL, remote_id TEXT NOT NULL, variant TEXT NOT NULL DEFAULT 'series', local_path TEXT NOT NULL, size_bytes INTEGER NOT NULL, last_access TEXT NOT NULL, PRIMARY KEY (server_id, remote_id, variant));
        CREATE TABLE cache_entries (key TEXT PRIMARY KEY, kind TEXT NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, last_access TEXT NOT NULL);
        CREATE TABLE app_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE VIRTUAL TABLE series_fts USING fts5(name, sort_name, authors, publisher, tags, summary);
        CREATE VIRTUAL TABLE book_fts USING fts5(title, authors, publisher, tags, summary);
        PRAGMA user_version = 3;
        """
        for statement in v3.components(separatedBy: ";") {
            let trimmed = statement.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            try connection.exec(trimmed)
        }
        return true
    }
}

/// Tiny raw SQLite wrapper so the migration test can build its v3 DB
/// without depending on GRDB's public API in tests.
private final class GRDBConnection {
    private var handle: OpaquePointer?
    private let path: String

    init(path: String) throws {
        self.path = path
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let handle else {
            throw NSError(domain: "sqlite", code: 1)
        }
    }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "sqlite error"
            sqlite3_free(err)
            throw NSError(domain: "sqlite", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    func close() {
        sqlite3_close(handle)
        handle = nil
    }
}
