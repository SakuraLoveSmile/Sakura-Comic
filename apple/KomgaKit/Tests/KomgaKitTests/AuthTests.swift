import XCTest
@testable import KomgaAPI

final class AuthTests: XCTestCase {
    func testAPIKeyHeader() {
        let method = AuthMethod.apiKey("secret")
        XCTAssertEqual(method.headerFields["X-API-Key"], "secret")
    }

    func testBasicHeader() {
        let method = AuthMethod.basic(username: "alice", password: "s3cret")
        XCTAssertEqual(method.headerFields["Authorization"], "Basic YWxpY2U6czNjcmV0")
    }

    func testApplyToRequest() {
        var request = URLRequest(url: URL(string: "https://komga.example.com/api/v1/series")!)
        AuthMethod.apiKey("k").apply(to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "k")
    }

    func testRedactedDescription() {
        let method = AuthMethod.basic(username: "u", password: "p")
        XCTAssertEqual(method.redactedDescription, "basic(***)")
        XCTAssertFalse(method.redactedDescription.contains("p"))
    }
}
