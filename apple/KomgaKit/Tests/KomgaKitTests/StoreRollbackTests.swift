import XCTest
import GRDB
@testable import KomgaAPI
@testable import KomgaStore

/// Mirror of the Rust `store::books` rollback test: a page write that fails
/// halfway must leave nothing behind. The sync engine writes one page per
/// transaction, and a half-written page would make the delete sweep believe
/// the server still has rows it never finished mirroring.
final class StoreRollbackTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/library")
            .standardizedFileURL
    }

    func testFailedPageWriteRollsBackTheWholePage() throws {
        let data = try Data(contentsOf: fixtureURL.appendingPathComponent("books-by-series.json"))
        let bySeries: [String: BookPageDTO] = try JSONDecoder().decode([String: BookPageDTO].self, from: data)
        let books = try XCTUnwrap(bySeries["series-1"]?.content)
        XCTAssertFalse(books.isEmpty)

        let store = try KomgaStore()
        // Fault injection: the tag table disappears, and tags are written after
        // the book row inside the same page transaction.
        try store.dbQueue.write { db in try db.execute(sql: "DROP TABLE book_tags") }
        XCTAssertThrowsError(try store.upsertBooksBatch(serverID: "srv", books: books))

        for table in ["books", "book_metadata", "book_authors", "read_progress"] {
            let count = try store.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE server_id = 'srv'") ?? 0
            }
            XCTAssertEqual(count, 0, "\(table) must not keep a partial page")
        }
        let fts = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM book_fts WHERE server_id = 'srv'") ?? 0
        }
        XCTAssertEqual(fts, 0, "the search index commits with the page")

        // No cursor was written either, so the next run re-reads this page.
        XCTAssertNil(try store.resumeCursor(serverID: "srv", entityType: SyncEntity.books))
    }
}
