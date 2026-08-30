import XCTest
import GRDB
@testable import KomgaStore

// MARK: - Mirror of `store/cache.rs`'s unit tests
//
// The generic LRU ledger: what it records, what it refuses to evict, and the two
// totals that disagree on purpose. Same cases and names as the Rust module so a
// reviewer can diff the behaviour across platforms.
//
// `cacheTotalBytes` counts what is really on disk, so these tests write real temp
// files rather than trusting the ledger — exactly as `tracked()` does in Rust.

final class CacheLedgerTests: XCTestCase {
    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles.removeAll()
        super.tearDown()
    }

    private func tempPath() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("komga_cache_entry_\(UUID().uuidString)")
        tempFiles.append(url)
        return url
    }

    /// Write a real file for a row to point at, and remember it for teardown.
    @discardableResult
    private func tracked(_ url: URL, _ bytes: [UInt8] = [UInt8](repeating: 0, count: 100)) -> URL {
        try? Data(bytes).write(to: url)
        return url
    }

    func testRecordGetTouchRemove() throws {
        let store = try KomgaStore()
        let path = tempPath()
        tracked(path, Array("0123456789".utf8))
        try store.recordCacheEntry(
            key: "k1", kind: CacheKind.page, path: path.path, size: 10,
            now: "2026-01-01T00:00:00.000Z"
        )
        let entry = try XCTUnwrap(store.cacheEntry(key: "k1"))
        XCTAssertEqual(entry.size, 10)
        XCTAssertEqual(entry.kind, CacheKind.page)
        XCTAssertEqual(try store.cacheTotalBytes(), 10)

        try store.touchCacheEntry(key: "k1", now: "2026-02-01T00:00:00.000Z")
        XCTAssertEqual(
            try store.cacheEntry(key: "k1")?.lastAccess, "2026-02-01T00:00:00.000Z"
        )

        // Re-recording the same key replaces rather than duplicates.
        try store.recordCacheEntry(
            key: "k1", kind: CacheKind.page, path: path.path, size: 4,
            now: "2026-03-01T00:00:00.000Z"
        )
        XCTAssertEqual(try store.cacheTotalBytes(), 4)

        XCTAssertEqual(try store.removeCacheEntry(key: "k1"), path.path)
        XCTAssertNil(try store.cacheEntry(key: "k1"))
        XCTAssertNil(
            try store.removeCacheEntry(key: "k1"),
            "removing twice is not an error"
        )
    }

    func testARowWhoseFileIsGoneIsAMissAndGetsPruned() throws {
        let store = try KomgaStore()
        let path = tempPath() // deliberately never created
        try store.recordCacheEntry(
            key: "ghost", kind: CacheKind.page, path: path.path, size: 999,
            now: "2026-01-01T00:00:00.000Z"
        )
        XCTAssertNotNil(try store.cacheEntry(key: "ghost"))
        XCTAssertEqual(
            try store.cacheTotalBytes(), 0,
            "phantom bytes must not steer eviction"
        )
        XCTAssertNil(try store.cacheEntry(key: "ghost"), "cacheTotalBytes pruned it")
    }

    func testEvictionGoesPrefetchThenPagesOldestFirst() throws {
        let store = try KomgaStore()
        var paths: [URL] = []
        let kinds = [CacheKind.page, CacheKind.prefetch, CacheKind.page, CacheKind.download]
        for (index, kind) in kinds.enumerated() {
            let path = tracked(tempPath())
            try store.recordCacheEntry(
                key: "k\(index)", kind: kind, path: path.path, size: 100,
                now: "2026-01-0\(index)T00:00:00.000Z"
            )
            paths.append(path)
        }
        XCTAssertEqual(try store.cacheTotalBytes(), 400)
        XCTAssertEqual(try store.cacheBytes(kind: CacheKind.download), 100)

        let removed = try store.evictCacheToBudget(budget: 250)
        XCTAssertEqual(
            removed.count, 2,
            "400 -> 250 needs the prefetch row and then the oldest page"
        )
        XCTAssertEqual(
            removed.first, paths[1].path,
            "the prefetch entry goes first even though k0 is older"
        )
        XCTAssertEqual(removed.last, paths[0].path)
        // k1/k0 gone, k2 evictable but no longer needed, k3 never eligible.
        XCTAssertNotNil(try store.cacheEntry(key: "k3"))
        XCTAssertEqual(try store.cacheTotalBytes(), 200)

        // Even an impossible budget cannot evict the download.
        let rest = try store.evictCacheToBudget(budget: 0)
        XCTAssertEqual(rest.count, 1, "only the remaining page row is eligible")
        XCTAssertNotNil(try store.cacheEntry(key: "k3"))
        XCTAssertEqual(try store.cacheBytes(kind: CacheKind.download), 100)
    }

    /// The promotion rule, stated the other way: an entry stops being the first
    /// victim as soon as the reader looks at it, and a much older displayed page
    /// is then the one that goes.
    func testPromotingAPrefetchEntryPutsItBehindOlderPages() throws {
        let store = try KomgaStore()
        let oldPage = tracked(tempPath())
        let seenPage = tracked(tempPath())
        try store.recordCacheEntry(
            key: "old", kind: CacheKind.page, path: oldPage.path, size: 100,
            now: "2026-01-01T00:00:00.000Z"
        )
        try store.recordCacheEntry(
            key: "warm", kind: CacheKind.prefetch, path: seenPage.path, size: 100,
            now: "2026-02-01T00:00:00.000Z"
        )

        // While it is prefetch bytes, it is the victim despite being newer.
        XCTAssertEqual(try store.evictCacheToBudget(budget: 100), [seenPage.path])
        XCTAssertNotNil(try store.cacheEntry(key: "old"))

        // A second entry, promoted, flips the decision.
        let third = tracked(tempPath())
        try store.recordCacheEntry(
            key: "third", kind: CacheKind.prefetch, path: third.path, size: 100,
            now: "2026-03-01T00:00:00.000Z"
        )
        try store.relocateCacheEntry(
            key: "third", path: third.path, kind: CacheKind.page,
            now: "2026-03-01T00:00:00.000Z"
        )
        XCTAssertEqual(
            try store.cacheEntry(key: "third")?.kind, CacheKind.page,
            "promotion must be visible in the ledger"
        )
        XCTAssertEqual(
            try store.evictCacheToBudget(budget: 100), [oldPage.path],
            "no prefetch rows remain, so the oldest page is the victim again"
        )
        XCTAssertThrowsError(
            try store.relocateCacheEntry(key: "ghost", path: "/tmp/x", kind: CacheKind.page, now: "now")
        ) { error in
            XCTAssertEqual(error as? CacheLedgerError, .entryNotFound("ghost"))
        }
    }

    func testFastAndReconcilingTotalsAgreeAndDisagreeHonestly() throws {
        let store = try KomgaStore()
        let path = tracked(tempPath(), [UInt8](repeating: 0, count: 40))
        try store.recordCacheEntry(
            key: "real", kind: CacheKind.page, path: path.path, size: 40,
            now: "2026-01-01T00:00:00.000Z"
        )
        // A phantom row: the ledger believes 90 bytes that are not on disk.
        try store.recordCacheEntry(
            key: "phantom", kind: CacheKind.page, path: tempPath().path, size: 50,
            now: "2026-01-01T00:00:00.000Z"
        )
        XCTAssertEqual(
            try store.cacheTotalBytesFast(), 90,
            "the cheap path reports what the ledger says"
        )
        XCTAssertEqual(try store.cacheTotalBytes(), 40, "the walking path proves it")
        XCTAssertNil(try store.cacheEntry(key: "phantom"), "and prunes the lie")
    }

    /// The rule that keeps a half-full pool from thrashing: the entry that
    /// triggered the trim is the one entry the trim may not take.
    func testTheEntryJustWrittenSurvivesTheTrimItTriggered() throws {
        let store = try KomgaStore()
        let older = tracked(tempPath())
        let fresh = tracked(tempPath())
        // Same millisecond, and the fresh key sorts first: age and tie-break
        // would both pick it as the victim.
        for (key, path) in [("p2", fresh), ("p9", older)] {
            try store.recordCacheEntry(
                key: key, kind: CacheKind.page, path: path.path, size: 100,
                now: "2026-01-01T00:00:00.000Z"
            )
        }
        XCTAssertEqual(
            try store.evictCacheToBudget(budget: 100, exceptKey: "p2"), [older.path],
            "p2 was held back, so the other page went"
        )
        XCTAssertNotNil(try store.cacheEntry(key: "p2"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path))
        // Without the protection the tie-break by key takes the fresh one.
        XCTAssertEqual(
            try store.evictCacheToBudget(budget: 0, exceptKey: nil), [fresh.path]
        )
    }

    func testEvictionTiesAreDeterministic() throws {
        let store = try KomgaStore()
        let now = "2026-01-01T00:00:00.000Z"
        for key in ["b", "a", "c"] {
            let path = tracked(tempPath(), [UInt8](repeating: 0, count: 50))
            try store.recordCacheEntry(
                key: key, kind: CacheKind.page, path: path.path, size: 50, now: now
            )
        }
        XCTAssertEqual(try store.evictCacheToBudget(budget: 50).count, 2)
        let kept = try ["a", "b", "c"].filter { key in
            try store.cacheEntry(key: key) != nil
        }
        XCTAssertEqual(kept, ["c"], "same timestamp -> key order wins")
    }

    /// The shape the offline-download feature will write: files the user asked to
    /// keep, recorded only in the download tables. Cleanup must protect them
    /// without being told twice.
    func testADownloadRecordedOnlyInTheDownloadTablesIsStillProtected() throws {
        let store = try KomgaStore()
        let manifest = tracked(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("dl-manifest-\(UUID().uuidString)"),
            Array(#"{"pages":3}"#.utf8)
        )
        let page = tracked(
            FileManager.default.temporaryDirectory
                .appendingPathComponent("dl-page-\(UUID().uuidString)"),
            Array("page-bytes".utf8)
        )
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done, state)
                VALUES ('A', 'book', ?, 1, 1, 'complete')
                """,
                arguments: [manifest.path]
            )
            try db.execute(
                sql: """
                INSERT INTO download_pages (server_id, book_id, page_number, file_path, state)
                VALUES ('A', 'book', 1, ?, 'complete')
                """,
                arguments: [page.path]
            )
        }

        let protected = try store.protectedCachePaths()
        XCTAssertTrue(protected.contains(manifest.path))
        XCTAssertTrue(protected.contains(page.path))
        // Nothing in the LRU ledger, and it still knows.
        XCTAssertNil(try store.cacheEntry(key: "whatever"))
    }

    func testProtectedPathsIncludesAnLedgerDownloadRowAndSkipsEmptyPaths() throws {
        let store = try KomgaStore()
        let file = tracked(tempPath(), Array("x".utf8))
        try store.recordCacheEntry(
            key: "dl", kind: CacheKind.download, path: file.path, size: 1, now: "now"
        )
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done, state)
                VALUES ('A', 'b', '', 1, 1, 'downloading')
                """,
                arguments: []
            )
        }
        let protected = try store.protectedCachePaths()
        XCTAssertTrue(protected.contains(file.path))
        XCTAssertFalse(protected.contains(""), "an empty path would protect the world")
    }
}
