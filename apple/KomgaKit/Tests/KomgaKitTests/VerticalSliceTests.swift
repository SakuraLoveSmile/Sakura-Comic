import XCTest
@testable import KomgaAPI
@testable import KomgaReader
@testable import KomgaStore
@testable import KomgaSync

actor FakePageFetcher: SeriesPageFetching {
    let page: SeriesPageDTO

    init(page: SeriesPageDTO) {
        self.page = page
    }

    func fetchSeriesPage(_ request: PageRequest) async throws -> SeriesPageDTO {
        page
    }
}

actor StubCoverFetcher: CoverFetching {
    func fetchCoverData(_ url: URL) async throws -> Data {
        Data("cover-bytes".utf8)
    }
}

/// Mirrors the acceptance chain without network:
/// bootstrap (shared fixture) -> SQLite -> read-back -> cover fetch -> disk cache.
final class VerticalSliceTests: XCTestCase {
    var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VerticalSliceTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func testBootstrapStoreAndCoverChain() async throws {
        let data = try Data(contentsOf: fixtureURL)
        let page = try JSONDecoder().decode(SeriesPageDTO.self, from: data)

        let store = try KomgaStore()
        let summary = try await BootstrapSync.run(
            fetcher: FakePageFetcher(page: page),
            store: store,
            serverID: "srv-1"
        )
        XCTAssertEqual(summary.syncedSeries, 3)
        XCTAssertEqual(summary.totalElements, 3)

        let rows = try store.fetchSeries(serverID: "srv-1", limit: 10, offset: 0)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.name), ["Berserk", "One Piece", "Solo Leveling"])

        let cache = try DiskImageCache(rootURL: directory)
        let loader = CoverLoader(cache: cache, fetcher: StubCoverFetcher())
        let coverURL = try KomgaTransport.seriesThumbnailURL(
            baseURL: "https://komga.example.com",
            seriesID: rows[0].remoteID
        )
        let coverData = try await loader.thumbnailData(
            serverID: "srv-1",
            seriesID: rows[0].remoteID,
            coverURL: coverURL
        )
        XCTAssertEqual(coverData, Data("cover-bytes".utf8))

        let cached = cache.thumbnailURL(for: "srv-1-\(rows[0].remoteID)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cached.path))
        XCTAssertEqual(try cache.load(cached), Data("cover-bytes".utf8))
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/initial-sync/series-page.json")
    }
}
