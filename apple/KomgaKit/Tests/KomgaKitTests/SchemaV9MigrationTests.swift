import XCTest
import GRDB
@testable import KomgaStore

// MARK: - Mirror of Rust `store::mod`'s two v8 → v9 migration tests
//
// v9 is the only migration in this project whose failure mode is losing a user's
// bookkeeping rather than missing a column: a `downloads` row is the only record
// of what the user asked to keep offline, and it is what names the files on disk
// for a later delete. So these two tests are not "did the columns appear" — one
// proves an existing row survives the upgrade with its values intact, and the
// other proves the guarded-ALTER route and the fresh-DDL route land on the same
// shape. A column added to the fresh DDL but not to `v9AlterStatements` otherwise
// passes everything else and then makes an upgrading user's downloads query a
// column that is not there.

private let v8Downloads = """
CREATE TABLE downloads (
    server_id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    manifest_path TEXT,
    pages_total INTEGER,
    pages_done INTEGER,
    state TEXT NOT NULL,
    PRIMARY KEY (server_id, book_id)
)
"""

private let v8DownloadPages = """
CREATE TABLE download_pages (
    server_id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    page_number INTEGER NOT NULL,
    file_path TEXT,
    state TEXT NOT NULL,
    PRIMARY KEY (server_id, book_id, page_number)
)
"""

final class SchemaV9MigrationTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(string: url.path + suffix)!)
            }
        }
        urls.removeAll()
        super.tearDown()
    }

    /// A store on a real file, remembered for teardown.
    private func storeOnDisk() throws -> (URL, KomgaStore) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("komga_v9_\(UUID().uuidString).sqlite")
        urls.append(url)
        return (url, try KomgaStore(path: url.path))
    }

    /// Rebuild the two download tables exactly as v8 wrote them, with a user's
    /// queue in them, and mark the file as a v8 database.
    private func makeItAV8Database(_ store: KomgaStore) throws {
        try store.dbQueue.write { db in
            try db.execute(sql: "DROP TABLE downloads")
            try db.execute(sql: "DROP TABLE download_pages")
            try db.execute(sql: v8Downloads)
            try db.execute(sql: v8DownloadPages)
            try db.execute(
                sql: """
                INSERT INTO downloads (server_id, book_id, manifest_path, pages_total,
                                       pages_done, state)
                VALUES ('s1','b1','/dwn/s1/b1/manifest.json',120,40,'paused')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO download_pages (server_id, book_id, page_number, file_path, state)
                VALUES ('s1','b1',7,'/dwn/s1/b1/0007.png','complete')
                """
            )
            try db.execute(sql: "PRAGMA user_version = 8")
        }
    }

    func test_a_v8_download_row_survives_the_v9_migration_untouched() throws {
        let (url, seed) = try storeOnDisk()
        try makeItAV8Database(seed)
        XCTAssertEqual(try seed.schemaVersion(), 8, "the fixture is not a v8 database")

        // Reopening is the upgrade path a user's next launch actually takes.
        let upgraded = try KomgaStore(path: url.path)
        XCTAssertEqual(try upgraded.schemaVersion(), Schema.currentVersion)

        let row = try upgraded.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM downloads WHERE server_id = 's1' AND book_id = 'b1'"
            )
        }
        let existing = try XCTUnwrap(row, "the user's queue row did not survive the upgrade")
        // GRDB indexes a Row by the column name, not by the camelCase a
        // Codable record would map it to — the aliases only exist in the
        // snapshot queries that ask for them.
        XCTAssertEqual(existing["manifest_path"] as String?, "/dwn/s1/b1/manifest.json")
        XCTAssertEqual(existing["pages_total"] as Int?, 120)
        XCTAssertEqual(existing["pages_done"] as Int?, 40)
        XCTAssertEqual(existing["state"] as String?, "paused")

        let page = try upgraded.dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM download_pages WHERE page_number = 7")
        }
        let existingPage = try XCTUnwrap(page, "the page row did not survive either")
        XCTAssertEqual(existingPage["file_path"] as String?, "/dwn/s1/b1/0007.png")
        XCTAssertEqual(existingPage["state"] as String?, "complete")

        // The new columns arrive with the defaults the queue expects, not NULL:
        // `position` orders the queue and `bytes_*` back the storage screen.
        let added = Set(try upgraded.columnNames(table: "downloads"))
        for column in ["position", "bytes_total", "bytes_done", "created_at", "allow_cellular"] {
            XCTAssertTrue(added.contains(column), "\(column) missing after the upgrade")
        }
        let defaults = try upgraded.dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT position, bytes_total, bytes_done, allow_cellular FROM downloads"
            )
        }
        let values = try XCTUnwrap(defaults)
        XCTAssertEqual(values["position"] as Int?, 0)
        XCTAssertEqual(values["bytes_total"] as Int?, 0)
        XCTAssertEqual(values["bytes_done"] as Int?, 0)
        XCTAssertEqual(values["allow_cellular"] as Int?, 0)
    }

    func test_the_migrated_shape_and_the_fresh_shape_are_the_same_shape() throws {
        let (url, seed) = try storeOnDisk()
        try makeItAV8Database(seed)
        let upgraded = try KomgaStore(path: url.path)
        let fresh = try KomgaStore()

        for table in ["downloads", "download_pages"] {
            XCTAssertEqual(
                try upgraded.columnNames(table: table),
                try fresh.columnNames(table: table),
                "a v8 database converged on a different \(table) shape than a fresh one"
            )
        }
    }
}
