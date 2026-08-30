import XCTest
@testable import KomgaReader

final class DiskImageCacheTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskImageCacheTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testStoreLoadRemoveAndAccounting() throws {
        let cache = try DiskImageCache(rootURL: directory)
        let url = try cache.storeThumbnail(Data("cover-bytes".utf8), for: "srv-1/series-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try cache.load(url), Data("cover-bytes".utf8))
        XCTAssertEqual(try cache.bytesUsed(), Int64("cover-bytes".utf8.count))

        try cache.remove(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try cache.bytesUsed(), 0)
    }

    func testPathsUseSanitizedKeys() throws {
        let cache = try DiskImageCache(rootURL: directory)
        XCTAssertEqual(
            cache.thumbnailURL(for: "srv-1/series-1").lastPathComponent,
            "srv-1_series-1"
        )
        XCTAssertEqual(
            cache.pageURL(for: "srv-1/series-1").lastPathComponent,
            "srv-1_series-1"
        )
    }

    func testSafeKeySanitizes() {
        XCTAssertEqual(DiskImageCache.safeKey("srv-1/series-1"), "srv-1_series-1")
        XCTAssertEqual(DiskImageCache.safeKey("abc.def-ghi_jkl"), "abc.def-ghi_jkl")
        XCTAssertEqual(DiskImageCache.coverKey(serverID: "server A", seriesID: "series 1"), "server_A-series_1")
    }
    // MARK: - Stage 8 tiers (mirror of `cache/mod.rs`'s layout)

    /// The three-tier split is what makes eviction honest, so the directories are
    /// a contract, not an implementation detail.
    func testAllThreeTiersExistOnDisk() throws {
        let cache = try DiskImageCache(rootURL: directory)
        XCTAssertEqual(DiskImageCache.tiers, ["thumbnails", "pages", "prefetch"])
        for tier in DiskImageCache.tiers {
            var isDirectory: ObjCBool = false
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: cache.directoryURL(forTier: tier).path, isDirectory: &isDirectory
                ) && isDirectory.boolValue,
                "\(tier)/ must exist after init, so a later path build never needs mkdir"
            )
        }
        XCTAssertEqual(cache.prefetchURL(for: "srv-1/book-p2").lastPathComponent, "srv-1_book-p2")
    }

    func testBytesUsedCoversEveryTier() throws {
        let cache = try DiskImageCache(rootURL: directory)
        try cache.storePage(Data(repeating: 7, count: 100), at: cache.pageURL(for: "p1"))
        try cache.storePage(Data(repeating: 7, count: 50), at: cache.prefetchURL(for: "p2"))
        try cache.storeThumbnail(Data(repeating: 7, count: 25), for: "cover")
        XCTAssertEqual(try cache.bytesUsed(), 175)
    }

    func testFilesInTierListsSortedNamesAndToleratesAMissingDirectory() throws {
        let cache = try DiskImageCache(rootURL: directory)
        try cache.storePage(Data("a".utf8), at: cache.url(inTier: "prefetch", named: "b.png"))
        try cache.storePage(Data("a".utf8), at: cache.url(inTier: "prefetch", named: "a.png"))
        XCTAssertEqual(try cache.files(inTier: "prefetch"), ["a.png", "b.png"])
        XCTAssertEqual(try cache.files(inTier: "gone"), [])
    }

    /// A download interrupted mid-write leaves a `.part` nobody reads. The sweep
    /// has to take it out across all three tiers.
    func testRemoveStalePartsClearsEveryTier() throws {
        let cache = try DiskImageCache(rootURL: directory)
        try cache.storePage(Data("a".utf8), at: cache.url(inTier: "pages", named: "half.png.part"))
        try cache.storePage(Data("a".utf8), at: cache.url(inTier: "prefetch", named: "half.png.part"))
        try cache.storePage(Data("a".utf8), at: cache.url(inTier: "thumbnails", named: "x.part"))
        try cache.storePage(Data("a".utf8), at: cache.url(inTier: "pages", named: "whole.png"))
        XCTAssertEqual(try cache.removeStaleParts(), 3)
        XCTAssertEqual(try cache.files(inTier: "pages"), ["whole.png"])
        XCTAssertEqual(try cache.files(inTier: "prefetch"), [])
        XCTAssertEqual(try cache.removeStaleParts(), 0, "removing twice is not an error")
    }

    /// Promotion is a rename: copying a 24 MB page to promote it would cost the
    /// reader a frame, so the inode identity is what this test pins.
    func testRelocateMovesTheFileBetweenTiersKeepingItsName() throws {
        let cache = try DiskImageCache(rootURL: directory)
        let source = cache.url(inTier: "prefetch", named: "srv-book-p3.png")
        try cache.storePage(Data("page-bytes".utf8), at: source)
        let before = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
        )

        let target = try cache.relocate(source, toTier: DiskImageCache.pagesTier)
        XCTAssertEqual(target.lastPathComponent, "srv-book-p3.png")
        XCTAssertEqual(try cache.load(target), Data("page-bytes".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "it moved, not copied")
        let after = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: target.path)[.systemFileNumber] as? NSNumber
        )
        XCTAssertEqual(after, before, "a rename keeps the same inode; a copy would not")
    }
}
