import XCTest
@testable import KomgaAPI

final class ServerURLTests: XCTestCase {
    func testStripsTrailingSlash() throws {
        XCTAssertEqual(
            try ServerURL.normalized("https://komga.example.com/"),
            "https://komga.example.com"
        )
    }

    func testKeepsSubPath() throws {
        XCTAssertEqual(
            try ServerURL.normalized("https://example.com/komga/"),
            "https://example.com/komga"
        )
    }

    func testKeepsPort() throws {
        XCTAssertEqual(
            try ServerURL.normalized("http://192.168.1.10:25600/"),
            "http://192.168.1.10:25600"
        )
    }

    func testTrimsWhitespace() throws {
        XCTAssertEqual(
            try ServerURL.normalized("  https://komga.example.com  "),
            "https://komga.example.com"
        )
    }

    func testRejectsUnsupportedScheme() {
        XCTAssertThrowsError(try ServerURL.normalized("ftp://example.com")) { error in
            XCTAssertEqual(error as? ServerURLError, .unsupportedScheme("ftp"))
        }
    }

    func testRejectsQuery() {
        XCTAssertThrowsError(try ServerURL.normalized("https://komga.example.com/?a=1"))
    }

    func testRejectsEmpty() {
        XCTAssertThrowsError(try ServerURL.normalized("   "))
    }
}
