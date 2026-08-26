import XCTest
@testable import KomgaAPI

final class SeriesPageTests: XCTestCase {
    /// The shared fixture lives at specs/contracts/fixtures/initial-sync/.
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/initial-sync/series-page.json")
    }

    func testDecodesSharedFixture() throws {
        let data = try Data(contentsOf: fixtureURL)
        let page = try JSONDecoder().decode(SeriesPageDTO.self, from: data)
        XCTAssertEqual(page.totalElements, 3)
        XCTAssertEqual(page.content.count, 3)
        XCTAssertTrue(page.content.contains { $0.name == "One Piece" })
    }

    func testPageRequestQueryItems() {
        let request = PageRequest(page: 2, size: 10, sort: "name")
        XCTAssertEqual(request.queryItems().map(\.name), ["page", "size", "sort"])
        XCTAssertEqual(request.queryItems().map(\.value), ["2", "10", "name"])
    }

    func testSeriesPageURLIsStable() throws {
        let url = try KomgaTransport.seriesPageURL(
            baseURL: "https://komga.example.com",
            request: PageRequest(page: 2, size: 10)
        )
        XCTAssertEqual(url.absoluteString, "https://komga.example.com/api/v1/series?page=2&size=10")

        let sub = try KomgaTransport.seriesPageURL(
            baseURL: "https://example.com/komga/",
            request: PageRequest(page: 2, size: 10)
        )
        XCTAssertEqual(sub.absoluteString, "https://example.com/komga/api/v1/series?page=2&size=10")
    }

    func testDecodeErrorMapping() throws {
        let http = HTTPURLResponse(
            url: URL(string: "https://komga.example.com/api/v1/series")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!
        XCTAssertThrowsError(try KomgaTransport.decode(SeriesPageDTO.self, data: Data(), response: http)) { error in
            XCTAssertEqual(error as? KomgaAPIError, .authentication)
        }
    }
}
