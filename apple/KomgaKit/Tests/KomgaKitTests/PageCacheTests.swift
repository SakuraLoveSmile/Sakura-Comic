import XCTest
@testable import KomgaDiagnostics
import GRDB
@testable import KomgaReader
@testable import KomgaStore

// MARK: - Mirror of `reader/cache.rs`'s unit tests
//
// Same cases, same names, same expectations as the Rust module: three tiers, the
// promotion that makes prefetch honest, the memory tier that has to be reachable
// after eviction, the budget that actually runs, and the cleanups that may never
// take a user's download.
//
// `CacheHarness` starts with `budgetBytes = 0`, which disables automatic trimming
// — the same opt-out Rust's `Harness::new()` uses — so a test only sees eviction
// when it asks for it.

final class PageCacheTests: XCTestCase {
    private func harness(
        budgetBytes: Int64 = 0,
        memoryBytes: Int? = nil
    ) throws -> CacheHarness {
        try CacheHarness(budgetBytes: budgetBytes, memoryBytes: memoryBytes)
    }

    func testStoreThenLookupRoundTripsWithAccounting() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let store = harness.store
        let cache = harness.cache
        let pages = harness.manifest(pages: 1)
        let key = pages.cacheKey(1)
        let bytes = harness.page(1)

        XCTAssertNil(try cache.lookup(key: key, now: "t2"))
        let location = try cache.store(key: key, bytes: bytes, contentType: "image/png", now: "t1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.url.path))
        XCTAssertTrue(location.url.path.hasSuffix(".png"))
        XCTAssertEqual(location.size, Int64(bytes.count))
        XCTAssertEqual(location.tier, .page)
        XCTAssertEqual(try cache.bytesUsed(), Int64(bytes.count))

        let hit = try XCTUnwrap(cache.lookup(key: key, now: "t2"))
        XCTAssertEqual(hit.url, location.url)
        XCTAssertEqual(
            try store.cacheEntry(key: key)?.lastAccess, "t2",
            "a hit must stamp the entry or LRU will evict what is on screen"
        )
        XCTAssertEqual(try Data(contentsOf: hit.url), bytes)
    }

    func testAnEmptyOrNonImagePayloadIsNeverCached() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let cache = harness.cache
        XCTAssertThrowsError(
            try cache.store(key: "srv-book-p1", bytes: Data(), contentType: "image/png", now: "t1")
        )
        let html = Data("<html><body>502 Bad Gateway</body></html>".utf8)
        var thrown: PageCacheError?
        XCTAssertThrowsError(
            try cache.store(key: "srv-book-p1", bytes: html, contentType: "image/jpeg", now: "t1")
        ) { error in
            thrown = error as? PageCacheError
        }
        let refusal = try XCTUnwrap(thrown)
        XCTAssertTrue(
            refusal.reason.contains("not an image"),
            "the refusal must say why: \(refusal)"
        )
        XCTAssertTrue(refusal.isCorrupt)
        XCTAssertEqual(try cache.bytesUsed(), 0)
        XCTAssertNil(try cache.lookup(key: "srv-book-p1", now: "t2"))
    }

    func testADeletedFileIsAMissAndTheLedgerConverges() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let store = harness.store
        let cache = harness.cache
        let manifest = harness.manifest(pages: 1)
        let key = manifest.cacheKey(1)
        let location = try cache.store(
            key: key, bytes: harness.page(1), contentType: "image/png", now: "t1"
        )
        XCTAssertTrue(location.size > 0)

        try FileManager.default.removeItem(at: location.url)
        // The cheap check is a ledger query by design: it is what the prefetch
        // planner calls once per spread for every page of the book, and it may not
        // stat 500 files to answer. Swift's `isCached` is the stricter question —
        // row AND file — so the weak-by-design claim is pinned on `cachedPages`.
        XCTAssertNotNil(try store.cacheEntry(key: key))
        XCTAssertTrue(try cache.cachedPages(manifest: manifest).contains(1))
        XCTAssertNil(try cache.lookup(key: key, now: "t2"))
        XCTAssertNil(
            try store.cacheEntry(key: key),
            "lookup prunes the row it could not honour"
        )
        XCTAssertEqual(try cache.bytesUsed(), 0)
    }

    /// The corruption-recovery rule, on the read path rather than the write path:
    /// an entry that was whole when it landed and is not whole now must be dropped
    /// and reported as a miss, never served.
    func testATruncatedFileOnDiskIsDroppedAndReportedAsAMiss() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let store = harness.store
        let cache = harness.cache
        let key = harness.manifest(pages: 1).cacheKey(1)
        let location = try cache.store(
            key: key, bytes: harness.page(1), contentType: "image/png", now: "t1"
        )
        XCTAssertNotNil(try cache.lookup(key: key, now: "t2"))

        // Cut the tail off: the file still exists, and its size now disagrees
        // with the ledger too.
        let bytes = try Data(contentsOf: location.url)
        try Data(bytes[..<(bytes.count - 8)]).write(to: location.url)
        XCTAssertNil(
            try cache.lookup(key: key, now: "t3"),
            "a half file must not be a hit"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: location.url.path),
            "and the debris must be gone"
        )
        XCTAssertNil(try store.cacheEntry(key: key))
        // The next fetch can therefore succeed cleanly rather than loop.
        let refetched = try cache.store(
            key: key, bytes: harness.page(1), contentType: "image/png", now: "t4"
        )
        XCTAssertNotNil(try cache.lookup(key: key, now: "t5"))
        XCTAssertEqual(refetched.size, Int64(bytes.count))
    }

    func testAFileReplacedByADifferentFormatLeavesOneEntry() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let cache = harness.cache
        let key = harness.manifest(pages: 1).cacheKey(1)
        let png = harness.page(1)
        let first = try cache.store(key: key, bytes: png, contentType: "image/png", now: "t1")
        // Same key, and the container really is PNG even though the header now
        // claims JPEG: the bytes name the file, not the response.
        let second = try cache.store(key: key, bytes: png, contentType: "image/jpeg", now: "t2")
        XCTAssertEqual(first.url, second.url, "the magic wins over the header")
        XCTAssertEqual(
            try harness.cache.disk.files(inTier: DiskImageCache.pagesTier).count, 1,
            "no orphan from the superseded attempt"
        )
        XCTAssertNotNil(try cache.lookup(key: key, now: "t3"))
    }

    func testPrefetchLandsInItsOwnTierAndIsHeldInRam() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let cache = harness.cache
        let manifest = harness.manifest(pages: 2)
        let bytes = harness.page(2)
        let location = try cache.storePrefetch(
            key: manifest.cacheKey(2), bytes: bytes, contentType: "image/png", now: "t1"
        )

        XCTAssertEqual(location.tier, .prefetch)
        XCTAssertTrue(
            location.url.path.hasPrefix(harness.directory.appendingPathComponent("prefetch").path)
        )
        let (pages, prefetch) = try harness.tiers()
        XCTAssertTrue(pages.isEmpty, "prefetch must not touch pages/")
        XCTAssertEqual(prefetch.count, 1)
        XCTAssertEqual(
            cache.memoryStats.bytes, bytes.count,
            "the bytes are resident so the first display skips the disk"
        )
        XCTAssertEqual(try cache.bytes(ofTier: .prefetch), Int64(bytes.count))
        XCTAssertEqual(try cache.bytes(ofTier: .page), 0)
    }

    /// The reason two tiers exist: displaying a prefetched page promotes it, and
    /// promotion is a rename rather than a re-download or a copy.
    func testDisplayingAPrefetchedPagePromotesItOnce() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let store = harness.store
        let cache = harness.cache
        let manifest = harness.manifest(pages: 3)
        let key = manifest.cacheKey(3)
        let bytes = harness.page(3)
        let prefetchPath = try cache.storePrefetch(
            key: key, bytes: bytes, contentType: "image/png", now: "t1"
        ).url

        let shown = try XCTUnwrap(cache.lookup(key: key, now: "t2"))
        XCTAssertEqual(shown.tier, .page)
        XCTAssertEqual(
            shown.url.deletingLastPathComponent().path,
            harness.directory.appendingPathComponent("pages").path
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: shown.url.path), "the promoted path is the live one")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: prefetchPath.path),
            "promotion moved the file, not copied it"
        )
        let entry = try XCTUnwrap(store.cacheEntry(key: key))
        XCTAssertEqual(entry.kind, CacheKind.page, "the ledger knows too")
        XCTAssertEqual(entry.path, shown.url.path)
        XCTAssertEqual(
            cache.memoryStats.bytes, 0,
            "promotion hands the bytes to disk and stops holding RAM for them"
        )
        let (pages, prefetch) = try harness.tiers()
        XCTAssertEqual(pages.count, 1)
        XCTAssertTrue(prefetch.isEmpty)
        // A second display is a plain page hit and changes nothing.
        let again = try XCTUnwrap(cache.lookup(key: key, now: "t3"))
        XCTAssertEqual(again.url, shown.url)
        XCTAssertEqual(again.tier, .page)
    }

    func testTheMemoryTierServesAPageWhoseFileTheSweepAte() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let cache = harness.cache
        let manifest = harness.manifest(pages: 1)
        let key = manifest.cacheKey(1)
        let bytes = harness.page(1)
        let path = try cache.storePrefetch(
            key: key, bytes: bytes, contentType: "image/png", now: "t1"
        ).url
        XCTAssertTrue(cache.memoryStats.bytes > 0)

        // Something outside the cache's control removed the file.
        try FileManager.default.removeItem(at: path)
        let revived = try XCTUnwrap(
            cache.lookup(key: key, now: "t2"),
            "the resident copy should have been re-landed"
        )
        XCTAssertEqual(revived.tier, .page)
        XCTAssertEqual(try Data(contentsOf: revived.url), bytes)
        XCTAssertEqual(cache.memoryStats.bytes, 0)
    }

    func testAPageTooLargeForTheTierIsStillCachedOnDisk() throws {
        let harness = try harness(memoryBytes: 1024)
        defer { harness.cleanup() }
        let cache = harness.cache
        let manifest = harness.manifest(pages: 1)
        let key = manifest.cacheKey(1)
        let bytes = harness.page(1)
        XCTAssertTrue(bytes.count > 1024, "fixture must exceed the tiny tier")

        let location = try cache.storePrefetch(
            key: key, bytes: bytes, contentType: "image/png", now: "t1"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: location.url.path))
        XCTAssertEqual(
            cache.memoryStats.bytes, 0,
            "refused for RAM, not for disk"
        )
        XCTAssertEqual(try cache.bytesUsed(), Int64(bytes.count))
        XCTAssertNotNil(try cache.lookup(key: key, now: "t2"))
    }

    /// Eviction drops the row and the file together. A prefetched page still
    /// resident in RAM must therefore come back from RAM rather than the network —
    /// otherwise the memory tier holds bytes no reader can ever reach.
    func testAnEvictedPageStillResidentIsRelandedInsteadOfRefetched() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let cache = harness.cache
        let manifest = harness.manifest(pages: 4)
        let first = harness.page(1)
        let second = harness.page(2)
        try cache.store(
            key: manifest.cacheKey(1), bytes: first, contentType: "image/png", now: "t1"
        )
        try cache.storePrefetch(
            key: manifest.cacheKey(2), bytes: second, contentType: "image/png", now: "t2"
        )
        XCTAssertTrue(cache.memoryStats.bytes > 0)

        // A pool small enough that showing page 2 has to evict the prefetch row.
        cache.budgetBytes = Int64(first.count + second.count)
        XCTAssertEqual(try cache.evictToBudget(Int64(first.count)), 1)
        XCTAssertFalse(
            try cache.isCached(key: manifest.cacheKey(2)),
            "the prefetch row is gone"
        )
        XCTAssertTrue(
            cache.isResident(key: manifest.cacheKey(2)),
            "but its bytes were never dropped, which is the bug this test exists for"
        )

        let revived = try XCTUnwrap(
            cache.lookup(key: manifest.cacheKey(2), now: "t3"),
            "a resident page must survive eviction of its row"
        )
        XCTAssertEqual(revived.tier, .page)
        XCTAssertEqual(try Data(contentsOf: revived.url), second)
    }

    func testCachedPagesUsesTheLedgerAndNamesEveryWarmPage() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let cache = harness.cache
        let pages = harness.manifest(pages: 4)
        for number in [UInt32(1), 3] {
            let bytes = harness.page(number)
            if number == 1 {
                try cache.store(
                    key: pages.cacheKey(number), bytes: bytes, contentType: "image/png", now: "t1"
                )
            } else {
                try cache.storePrefetch(
                    key: pages.cacheKey(number), bytes: bytes, contentType: "image/png", now: "t1"
                )
            }
        }
        XCTAssertEqual(
            try cache.cachedPages(manifest: pages), [1, 3] as Set<UInt32>,
            "both tiers count as warm for prefetch"
        )
    }

    func testEvictionRespectsTheBudgetAndSparesDownloads() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let store = harness.store
        let cache = harness.cache
        let manifest = harness.manifest(pages: 3)
        var sizes: Int64 = 0
        for (index, number) in (1...3).enumerated() {
            let bytes = harness.page(UInt32(number))
            sizes += Int64(bytes.count)
            try cache.store(
                key: manifest.cacheKey(UInt32(number)), bytes: bytes,
                contentType: "image/png", now: "t\(index)"
            )
        }
        // A user-owned offline download lives in the same pool.
        let download = harness.directory.appendingPathComponent("offline.bin")
        try Data(repeating: 0, count: 100).write(to: download)
        try store.recordCacheEntry(
            key: "dl", kind: CacheKind.download, path: download.path, size: 100, now: "t0"
        )
        XCTAssertEqual(try cache.bytesUsed(), sizes + 100)

        let dropped = try cache.evictToBudget(200)
        XCTAssertTrue(dropped >= 1, "something had to give")
        // Tightened while porting: with 300-byte headroom against ~20 KB pages,
        // every page row must go, so the honest claim is that only the download is
        // left rather than Rust's loose "used <= total - dropped".
        XCTAssertEqual(try cache.bytesUsed(), 100)
        XCTAssertEqual(try store.cacheBytes(kind: CacheKind.download), 100)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: download.path),
            "LRU must never delete an offline download"
        )
        XCTAssertFalse(
            try cache.isCached(key: manifest.cacheKey(1)),
            "with equal kinds the oldest page goes first"
        )
    }

    /// Prefetch bytes are the first victims, so trimming the pool can never trade
    /// away what the reader is looking at while unseen pages sit in the cache.
    func testTrimmingThePoolLosesPrefetchBeforeAnyDisplayedPage() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let cache = harness.cache
        let manifest = harness.manifest(pages: 3)
        let displayed = harness.page(1)
        let unseen = harness.page(2)
        let unseenSize = Int64(unseen.count)
        try cache.store(
            key: manifest.cacheKey(1), bytes: displayed, contentType: "image/png", now: "t1"
        )
        try cache.storePrefetch(
            key: manifest.cacheKey(2), bytes: unseen, contentType: "image/png", now: "t2"
        )
        let total = Int64(displayed.count) + unseenSize
        let budget = total - unseenSize / 2

        XCTAssertEqual(try cache.evictToBudget(budget), 1, "freeing the prefetch page is enough")
        XCTAssertFalse(try cache.isCached(key: manifest.cacheKey(2)))
        XCTAssertNotNil(
            try cache.lookup(key: manifest.cacheKey(1), now: "t3"),
            "the displayed page survives a trim that a newer prefetch entry does not"
        )
    }

    func testAutomaticTrimmingHappensOnStoreAndNeverEatsTheNewPage() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let cache = harness.cache
        let manifest = harness.manifest(pages: 4)
        let sizes = (1...4).map { Int64(harness.page(UInt32($0)).count) }
        // Room for two pages, give or take.
        let budget = sizes[0] + sizes[1]
        cache.budgetBytes = budget
        for number in 1...4 {
            try cache.store(
                key: manifest.cacheKey(UInt32(number)), bytes: harness.page(UInt32(number)),
                contentType: "image/png", now: "t\(number)"
            )
        }
        let used = try cache.bytesUsed()
        XCTAssertTrue(
            used <= budget + sizes[3],
            "the pool stayed within about two pages, got \(used) of \(budget)"
        )
        XCTAssertNotNil(
            try cache.lookup(key: manifest.cacheKey(4), now: "t9"),
            "the page just handed to the reader must never be the eviction victim"
        )
        XCTAssertFalse(
            try cache.isCached(key: manifest.cacheKey(1)),
            "and the oldest displayed page is what paid for it"
        )
    }

    func testReconcileFixesGhostsOrphansPartsAndWrongTiers() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let store = harness.store
        let cache = harness.cache
        let manifest = harness.manifest(pages: 4)
        for number in 1...3 {
            try cache.store(
                key: manifest.cacheKey(UInt32(number)), bytes: harness.page(UInt32(number)),
                contentType: "image/png", now: "t1"
            )
        }
        // Ghost row: the ledger names a file that is not there.
        let ghostPath = try XCTUnwrap(store.cacheEntry(key: manifest.cacheKey(3))?.path)
        try FileManager.default.removeItem(atPath: ghostPath)
        // Orphan file: bytes on disk no row describes.
        let orphan = harness.directory.appendingPathComponent("pages/orphan.png")
        try Data("junk".utf8).write(to: orphan)
        // Stale staging file from an interrupted write.
        let half = harness.directory.appendingPathComponent("pages/half.png.part")
        try Data("junk".utf8).write(to: half)
        // Wrong tier: a page row pointing into prefetch/.
        let misplaced = try cache.storePrefetch(
            key: manifest.cacheKey(4), bytes: harness.page(4), contentType: "image/png", now: "t1"
        )
        try store.relocateCacheEntry(
            key: manifest.cacheKey(4), path: misplaced.url.path, kind: CacheKind.page, now: "t1"
        )

        let report = try cache.reconcile(now: "t2")
        XCTAssertEqual(report.ghostRows, 1, "the row whose file was deleted")
        XCTAssertEqual(report.orphanFiles, 1, "orphan.png went")
        XCTAssertEqual(report.staleParts, 1, "the .part went")
        XCTAssertEqual(
            report.kindRepaired, 1,
            "the page row is now a prefetch row"
        )
        XCTAssertEqual(
            try store.cacheEntry(key: manifest.cacheKey(4))?.kind, CacheKind.prefetch
        )
        XCTAssertNotNil(try cache.lookup(key: manifest.cacheKey(4), now: "t3"))
        XCTAssertEqual(report.evicted, 0, "nothing needed evicting")
        XCTAssertEqual(
            report.freedBytes, 4,
            "only the 4-byte orphan really freed bytes; a ghost row's file was already gone"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(try cache.isCached(key: manifest.cacheKey(1)))
    }

    func testReconcileCountsAndFreesRealBytes() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let store = harness.store
        let cache = harness.cache
        let manifest = harness.manifest(pages: 2)
        let bytes = harness.page(1)
        let size = Int64(bytes.count)
        let location = try cache.store(
            key: manifest.cacheKey(1), bytes: bytes, contentType: "image/png", now: "t1"
        )
        // A corrupt file whose ledger size still matches: the trailer check has to
        // be what catches it, not the byte count.
        let path = try XCTUnwrap(store.cacheEntry(key: manifest.cacheKey(1))?.path)
        var wounded = [UInt8](bytes)
        wounded.removeSubrange((wounded.count - 4)..<wounded.count)
        let woundedSize = Int64(wounded.count)
        try Data(wounded).write(to: URL(fileURLWithPath: path))
        try store.recordCacheEntry(
            key: manifest.cacheKey(1), kind: CacheKind.page, path: path, size: woundedSize, now: "t1"
        )
        XCTAssertEqual(woundedSize, size - 4)

        let report = try cache.reconcile(now: "t2")
        XCTAssertEqual(report.corrupt, 1)
        XCTAssertEqual(report.freedBytes, woundedSize)
        XCTAssertEqual(try cache.bytesUsed(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        _ = location
    }


    /// A sweep is the one moment a cache that fails every day becomes visible
    /// from outside the reader, so the line has to reach the log ring a
    /// diagnostics snapshot reads — not only the report a caller is free to
    /// drop. Mirror of Rust's sweep warning in `application.rs`.
    func test_reconcile_writes_into_the_log_ring_when_it_found_something() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let cache = harness.cache
        CoreLog.shared.forwardsToSystemLog = false
        CoreLog.shared.reset()

        // A clean sweep says nothing. Without that half of the rule, "there is
        // a sweep line" would stop meaning anything.
        _ = try cache.reconcile(now: "t1")
        XCTAssertTrue(
            CoreLog.shared.recent(limit: 10).isEmpty,
            "an empty sweep logged"
        )

        // A sweep that healed a lying ledger row says what it healed.
        let manifest = harness.manifest(pages: 1)
        try cache.store(
            key: manifest.cacheKey(1),
            bytes: harness.page(1),
            contentType: "image/png",
            now: "t2"
        )
        let path = try XCTUnwrap(harness.store.cacheEntry(key: manifest.cacheKey(1))?.path)
        try FileManager.default.removeItem(atPath: path)

        let report = try cache.reconcile(now: "t3")
        XCTAssertEqual(report.ghostRows, 1)
        let lines = CoreLog.shared.recent(limit: 10).map(\.message)
        XCTAssertTrue(
            lines.contains { $0.contains("cache sweep:") && $0.contains("1 ghost rows") },
            "the sweep found a ghost row and the ring has no line about it: \(lines)"
        )
        XCTAssertEqual(CoreLog.shared.stats().info, 1)
        CoreLog.shared.reset()
    }

    func testClearBookRemovesFilesRowsRamAndNothingElse() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let cache = harness.cache
        let target = harness.manifest(pages: 2)
        let other = harness.manifest(bookID: "other", pages: 1)
        let paths = [
            try cache.store(
                key: target.cacheKey(1), bytes: harness.page(1), contentType: "image/png", now: "t1"
            ).url,
            try cache.storePrefetch(
                key: target.cacheKey(2), bytes: harness.page(2), contentType: "image/png", now: "t1"
            ).url,
        ]
        let kept = try cache.store(
            key: other.cacheKey(1), bytes: harness.page(1), contentType: "image/png", now: "t1"
        )

        XCTAssertEqual(
            try cache.clearBook(serverID: "srv", bookID: "other2"), 0,
            "no false matches"
        )
        XCTAssertEqual(try cache.clearBook(serverID: "srv", bookID: "book"), 2)
        for path in paths {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: path.path), "\(path.path) survived"
            )
        }
        XCTAssertTrue(try cache.isCached(key: other.cacheKey(1)))
        XCTAssertEqual(kept.size, Int64(harness.page(1).count))
        XCTAssertEqual(
            cache.memoryStats.bytes, 0,
            "clearing a book must drop its resident bytes too"
        )
    }

    /// The acceptance line "Cache 清理不会影响用户主动下载内容", proven on the worst
    /// case: a download whose file lives inside the very tier being swept. Without
    /// the cooperation of the LRU ledger — which is how the offline-download
    /// feature will actually look, because it is still a stub and nothing writes
    /// `kind = 'download'` yet. Protection that depends on that row being written
    /// is a convention; this is the version that is not.
    func testADownloadWithNoLedgerRowIsStillKeptByEveryCleanup() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let store = harness.store
        let cache = harness.cache
        // A downloaded page filed exactly where the reader would also put one, and
        // recorded only in the download tables.
        let downloaded = cache.disk.pageURL(for: "srv-book-p2.png")
        try harness.page(2).write(to: downloaded)
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done, state)
                VALUES ('srv', 'book', NULL, 1, 1, 'complete')
                """,
                arguments: []
            )
            try db.execute(
                sql: """
                INSERT INTO download_pages (server_id, book_id, page_number, file_path, state)
                VALUES ('srv', 'book', 2, ?, 'complete')
                """,
                arguments: [downloaded.path]
            )
        }
        XCTAssertNil(try store.cacheEntry(key: "anything"))

        let report = try cache.reconcile(now: "t1")
        XCTAssertEqual(
            report.orphanFiles, 0,
            "the user's downloaded page must not read as an orphan: \(report)"
        )
        XCTAssertEqual(report.protectedKept, 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: downloaded.path),
            "and it is still on disk after the sweep"
        )

        XCTAssertEqual(try cache.clearBook(serverID: "srv", bookID: "book"), 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: downloaded.path),
            "pruning the mirrored book keeps the download"
        )
        XCTAssertEqual(try cache.clearTier(.page), 0)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: downloaded.path),
            "clearing the displayed tier keeps a file the download tables claim"
        )
    }

    func testClearingATierAndSweepingNeverTouchesAnOfflineDownload() throws {
        let harness = try harness()
        defer { harness.cleanup() }
        let store = harness.store
        let cache = harness.cache
        let manifest = harness.manifest(pages: 3)
        // A download deliberately parked in pages/, where a naive sweep would eat it.
        let download = cache.disk.pageURL(for: "srv-book-p2.png")
        try harness.page(2).write(to: download)
        let downloadSize = try XCTUnwrap(cache.disk.size(of: download))
        try store.recordCacheEntry(
            key: manifest.cacheKey(2), kind: CacheKind.download, path: download.path,
            size: downloadSize, now: "t1"
        )
        try cache.store(
            key: manifest.cacheKey(1), bytes: harness.page(1), contentType: "image/png", now: "t1"
        )
        try cache.storePrefetch(
            key: manifest.cacheKey(3), bytes: harness.page(3), contentType: "image/png", now: "t1"
        )
        let displayed = try XCTUnwrap(store.cacheEntry(key: manifest.cacheKey(1))?.path)

        let report = try cache.reconcile(now: "t2")
        XCTAssertEqual(
            [report.ghostRows, report.orphanFiles, report.corrupt], [0, 0, 0],
            "a download row must not read as an orphan: \(report)"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: download.path), "the sweep left the download file alone")

        XCTAssertEqual(try cache.clearTier(.prefetch), 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: download.path),
            "clearing prefetch left the download alone"
        )
        XCTAssertTrue(try cache.isCached(key: manifest.cacheKey(1)))
        XCTAssertEqual(
            try cache.bytes(ofTier: .page),
            try XCTUnwrap(cache.disk.size(of: URL(fileURLWithPath: displayed)))
        )
        XCTAssertEqual(try cache.clearTier(.page), 1)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: download.path),
            "even clearing the displayed tier may not delete a user's download"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: displayed))
        XCTAssertEqual(cache.memoryStats.bytes, 0)
    }

    func testTheTierAndExtensionRulesAreExplicit() throws {
        XCTAssertEqual(Tier.page.kind, CacheKind.page)
        XCTAssertEqual(Tier.prefetch.kind, CacheKind.prefetch)
        XCTAssertEqual(Tier.page.dir, DiskImageCache.pagesTier)
        XCTAssertEqual(Tier.prefetch.dir, DiskImageCache.prefetchTier)
        XCTAssertEqual(Tier.fromKind(CacheKind.prefetch), .prefetch)
        XCTAssertEqual(Tier.fromKind(CacheKind.download), .page)
        XCTAssertEqual(contentType(forPath: "x/y.jpg"), "image/jpeg")
        XCTAssertEqual(contentType(forPath: "x/y.png"), "image/png")
        XCTAssertEqual(contentType(forPath: "x/y.bin"), "application/octet-stream")

        let harness = try harness()
        defer { harness.cleanup() }
        XCTAssertEqual(
            harness.cache.extensionFor(bytes: harness.page(1), contentType: "image/jpeg"),
            "png",
            "a PNG body behind a JPEG header is named for its body"
        )
        XCTAssertEqual(
            harness.cache.extensionFor(bytes: Data("<html/>".utf8), contentType: "text/html"),
            "img",
            "undecidable bytes keep the declared name"
        )
        XCTAssertEqual(ImageFormat.from(magic: DemoPNG.pageBytes(1)), .png)
    }

    func testASharedTierSurvivesNewCacheHandles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedTier-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try KomgaStore()
        resetProcessMemoryTier()
        let first = try PageCache.shared(store: store, rootURL: directory)
        first.budgetBytes = 0
        let manifest = try harness().manifest(pages: 1)
        let key = manifest.cacheKey(1)
        let bytes = DemoPNG.page(1)
        try first.storePrefetch(key: key, bytes: bytes, contentType: "image/png", now: "t1")
        // A second handle — what every facade call rebuilds — sees the same RAM.
        let second = try PageCache.shared(store: store, rootURL: directory)
        second.budgetBytes = 0
        XCTAssertEqual(
            second.memoryStats.bytes, bytes.count,
            "the tier must be process-wide or it warms nothing"
        )
        XCTAssertTrue(first.memoryTier === second.memoryTier)
        second.setMemoryBudget(0)
        XCTAssertEqual(second.memoryStats.bytes, 0)
        // Leave the shared tier empty for later tests in the same process.
        first.setMemoryBudget(defaultMemoryBudgetBytes)
        resetProcessMemoryTier()
    }
}

private func harness() throws -> CacheHarness { try CacheHarness(budgetBytes: 0) }
