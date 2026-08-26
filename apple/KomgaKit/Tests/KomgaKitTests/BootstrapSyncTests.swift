import XCTest
@testable import KomgaAPI
@testable import KomgaStore
@testable import KomgaSync

actor FakeSeriesPageFetcher: SeriesPageFetching {
    let page: SeriesPageDTO

    init(page: SeriesPageDTO) {
        self.page = page
    }

    func fetchSeriesPage(_ request: PageRequest) async throws -> SeriesPageDTO {
        page
    }
}

final class BootstrapSyncTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/initial-sync/series-page.json")
    }

    func testRunMirrorsFirstPageIntoSqlite() async throws {
        let data = try Data(contentsOf: fixtureURL)
        let page = try JSONDecoder().decode(SeriesPageDTO.self, from: data)
        let fetcher = FakeSeriesPageFetcher(page: page)
        let store = try KomgaStore()

        let summary = try await BootstrapSync.run(fetcher: fetcher, store: store, serverID: "srv-1")
        XCTAssertEqual(summary.syncedSeries, 3)
        XCTAssertEqual(summary.totalElements, 3)
        XCTAssertFalse(summary.hasMorePages)
        XCTAssertEqual(try store.countSeries(serverID: "srv-1"), 3)
        XCTAssertEqual(try store.countSeries(serverID: "srv-2"), 0)
    }
}
