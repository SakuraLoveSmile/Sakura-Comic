import XCTest
import GRDB
@testable import KomgaAPI
@testable import KomgaStore

/// Delete propagation (mirror of Rust `store/prune.rs` tests): a remote
/// deletion hard-deletes the mirror row, cascades to its children and leaves
/// a tombstone behind.
final class PruneStoreTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/library")
            .standardizedFileURL
    }

    private func load<T: Decodable>(_ name: String) throws -> T {
        let data = try Data(contentsOf: fixtureURL.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Series + books + one collection holding the series.
    private func seeded(_ store: KomgaStore) throws {
        let seriesPage: SeriesPageDTO = try load("series-page.json")
        _ = try store.upsertSeriesBatch(serverID: "srv", series: seriesPage.content)
        let books: [String: BookPageDTO] = try load("books-by-series.json")
        for page in books.values {
            _ = try store.upsertBooksBatch(serverID: "srv", books: page.content)
        }
        let collections: CollectionPageDTO = try load("collections-page.json")
        _ = try store.upsertCollectionsBatch(serverID: "srv", collections: collections.content)
    }

    private func count(_ store: KomgaStore, _ sql: String) throws -> Int {
        try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: sql, arguments: ["srv"]) ?? 0
        }
    }

    func testSeriesDeleteCascadesToBooksAndChildren() throws {
        let store = try KomgaStore()
        try seeded(store)
        // A cover record + a pending mutation for one book of series-1.
        try store.upsertThumbnail(ThumbnailRecord(
            serverID: "srv", remoteID: "book-1-1", variant: ThumbnailRecord.variantBook,
            localPath: "/tmp/b.png", sizeBytes: 10
        ))
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO pending_mutations (id, server_id, entity_id, mutation_type, payload, created_at)
                VALUES ('m1', 'srv', 'book-1-1', 'READ_PROGRESS', '{}', 'now')
                """
            )
        }
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM books WHERE server_id = ?"), 7)

        let covers = try store.deleteEntity(
            serverID: "srv", entityType: SyncEntity.series, remoteID: "series-1",
            cause: DeletionCause.reconcile
        )

        // series-1 owned 3 books; the other series keep theirs.
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM books WHERE server_id = ?"), 4)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM series WHERE server_id = ?"), 2)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM series_metadata WHERE server_id = ?"), 2)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM read_progress WHERE server_id = ?"), 1)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM collection_series WHERE server_id = ?"), 2)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM pending_mutations WHERE server_id = ?"), 0)
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM thumbnails WHERE server_id = ?"), 0)
        XCTAssertEqual(covers, ["/tmp/b.png"])
        // Tombstones: the series plus its 3 cascaded books.
        XCTAssertEqual(try store.countTombstones(serverID: "srv"), 4)
        let bookTombstones = try store.listTombstones(serverID: "srv", entityType: SyncEntity.books)
        XCTAssertEqual(bookTombstones.count, 3)
        XCTAssertEqual(bookTombstones.first?.cause, DeletionCause.cascade)
    }

    func testBookDeleteClearsMembershipAndSearch() throws {
        let store = try KomgaStore()
        try seeded(store)
        let before = try count(store, "SELECT COUNT(*) FROM book_fts WHERE server_id = ?")
        _ = try store.deleteBook(serverID: "srv", bookID: "book-1-1")

        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM books WHERE server_id = ?"), 6)
        XCTAssertEqual(
            try count(store, "SELECT COUNT(*) FROM book_fts WHERE server_id = ?"),
            before - 1,
            "the deleted book must leave the search index"
        )
        XCTAssertEqual(
            try count(store, "SELECT COUNT(*) FROM series_fts WHERE server_id = ?"), 3,
            "the parent series index is untouched"
        )
    }

    func testPruneOnlyRemovesIDsTheServerNoLongerReports() throws {
        let store = try KomgaStore()
        try seeded(store)
        let deleted = try store.prune(
            serverID: "srv",
            entityType: SyncEntity.series,
            remoteIDs: ["series-1", "series-2"],
            cause: DeletionCause.reconcile
        )
        XCTAssertEqual(deleted.ids, ["series-3"])
        XCTAssertTrue(deleted.coverPaths.isEmpty) // no cover records seeded here
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM series WHERE server_id = ?"), 2)
        XCTAssertEqual(
            try store.listTombstones(serverID: "srv", entityType: SyncEntity.series).first?.cause,
            DeletionCause.reconcile
        )
        // A re-added series clears its own tombstone; the cascaded books keep
        // theirs until the server reports them again.
        try store.clearTombstone(serverID: "srv", entityType: SyncEntity.series, remoteID: "series-3")
        XCTAssertEqual(try store.countTombstones(serverID: "srv"), 2)
    }

    func testBookPruneIsScopedToSweptSeries() throws {
        let store = try KomgaStore()
        try seeded(store)
        // series-1 was swept and reports 2 of its 3 books; series-2 was not swept.
        let deleted = try store.pruneBooksForSweptSeries(
            serverID: "srv",
            swept: ["series-1": ["book-1-1", "book-1-2"]],
            cause: DeletionCause.reconcile
        )
        XCTAssertEqual(deleted.ids, ["book-1-3"])
        XCTAssertEqual(try count(store, "SELECT COUNT(*) FROM books WHERE server_id = ?"), 6)
        // series-2's books survived: its sweep never ran.
        XCTAssertEqual(
            try count(store, "SELECT COUNT(*) FROM books WHERE server_id = ? AND series_id = 'series-2'"),
            2
        )
    }

    func testLocalIDsAreScopedToMirroredEntityTypes() throws {
        let store = try KomgaStore()
        try seeded(store)
        XCTAssertEqual(try store.localIDs(serverID: "srv", entityType: SyncEntity.series).count, 3)
        // Entity types without a mirror table have nothing to diff.
        XCTAssertEqual(try store.localIDs(serverID: "srv", entityType: SyncEntity.readProgress), [])
        XCTAssertEqual(try store.localIDs(serverID: "srv", entityType: "nonsense"), [])
        // Book ids come back per series, in sweep order.
        XCTAssertEqual(
            try store.localBookIDs(serverID: "srv", seriesID: "series-1"),
            ["book-1-1", "book-1-2", "book-1-3"]
        )
    }

    func testReAddedEntityClearsItsTombstone() throws {
        let store = try KomgaStore()
        try store.recordTombstone(
            serverID: "srv", entityType: SyncEntity.series, remoteID: "series-9",
            cause: DeletionCause.event
        )
        XCTAssertEqual(try store.countTombstones(serverID: "srv"), 1)
        XCTAssertEqual(
            try store.listTombstones(serverID: "srv", entityType: SyncEntity.series).first?.cause,
            DeletionCause.event
        )
        // Re-recording refreshes the stamp rather than duplicating the row.
        try store.recordTombstone(
            serverID: "srv", entityType: SyncEntity.series, remoteID: "series-9",
            cause: DeletionCause.cascade
        )
        let rows = try store.listTombstones(serverID: "srv", entityType: SyncEntity.series)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.cause, DeletionCause.cascade)
        try store.clearTombstone(serverID: "srv", entityType: SyncEntity.series, remoteID: "series-9")
        XCTAssertEqual(try store.countTombstones(serverID: "srv"), 0)
    }

    func testDeletingAServerClearsItsTombstones() throws {
        let store = try KomgaStore()
        try store.upsertServer(ServerProfile(
            id: "srv", displayName: "Home", baseURL: "https://komga.example.com", authType: .apiKey
        ))
        try store.recordTombstone(
            serverID: "srv", entityType: SyncEntity.series, remoteID: "series-1",
            cause: DeletionCause.reconcile
        )
        XCTAssertTrue(try store.deleteServer(id: "srv"))
        XCTAssertEqual(try store.countTombstones(serverID: "srv"), 0)
    }
}
