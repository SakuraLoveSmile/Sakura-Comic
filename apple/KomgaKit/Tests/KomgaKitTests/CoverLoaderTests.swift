import XCTest
@testable import KomgaReader

actor CountingCoverFetcher: CoverFetching {
    private(set) var count = 0
    let bytes: Data

    init(bytes: Data) {
        self.bytes = bytes
    }

    func fetchCoverData(_ url: URL) async throws -> Data {
        count += 1
        return bytes
    }
}

final class CoverLoaderTests: XCTestCase {
    var directory: URL!
    private let coverURL = URL(
        string: "https://komga.example.com/api/v1/series/series-1/thumbnail"
    )!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverLoaderTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testMissFetchesThenHitsCache() async throws {
        let cache = try DiskImageCache(rootURL: directory)
        let fetcher = CountingCoverFetcher(bytes: Data("cover-bytes".utf8))
        let loader = CoverLoader(cache: cache, fetcher: fetcher)

        let first = try await loader.thumbnailData(
            serverID: "srv-1",
            seriesID: "series-1",
            coverURL: coverURL
        )
        XCTAssertEqual(first, Data("cover-bytes".utf8))
        let firstCount = await fetcher.count
        XCTAssertEqual(firstCount, 1)

        let second = try await loader.thumbnailData(
            serverID: "srv-1",
            seriesID: "series-1",
            coverURL: coverURL
        )
        XCTAssertEqual(second, Data("cover-bytes".utf8))
        let secondCount = await fetcher.count
        XCTAssertEqual(secondCount, 1, "second call must come from disk cache")
    }

    func testCachedFileLivesUnderThumbnails() async throws {
        let cache = try DiskImageCache(rootURL: directory)
        let fetcher = CountingCoverFetcher(bytes: Data("cover-bytes".utf8))
        let loader = CoverLoader(cache: cache, fetcher: fetcher)

        _ = try await loader.thumbnailData(serverID: "srv-1", seriesID: "series-1", coverURL: coverURL)

        let expected = cache.thumbnailURL(for: "srv-1-series-1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertEqual(try cache.load(expected), Data("cover-bytes".utf8))
    }
}
