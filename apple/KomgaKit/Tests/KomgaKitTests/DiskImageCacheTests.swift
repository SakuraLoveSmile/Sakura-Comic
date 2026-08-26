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
}
