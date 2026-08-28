import XCTest
@testable import KomgaSync
@testable import KomgaAPI

/// The shared event-name table: `specs/contracts/fixtures/sse/events.json` is
/// the same file the Rust side asserts (`tests/sse_events_contract.rs`).
final class SSEEventContractTests: XCTestCase {

    private struct Fixture: Decodable {
        let cases: [Case]
        struct Case: Decodable {
            let event: String
            let data: String
            let expect: Expect
        }
        struct Expect: Decodable {
            var books: [String]?
            var deletedBooks: [String]?
            var needsSweep: Bool?
            var ignore: Bool?
        }
    }

    private func fixtureURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/sse/events.json")
            .standardizedFileURL
    }

    func testEventTableMatchesTheSharedFixture() throws {
        let data = try Data(contentsOf: fixtureURL())
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 20, "the event fixture lost cases")

        for testCase in fixture.cases {
            let hints = EventClassifying.classify(
                SseEvent(kind: testCase.event, data: testCase.data, id: nil, retryMS: nil)
            )
            let expect = testCase.expect
            let wantBooks = expect.books ?? []
            let wantDeleted = expect.deletedBooks ?? []
            let wantSweep = expect.needsSweep ?? false
            XCTAssertEqual(
                hints.books.sorted(), wantBooks.sorted(),
                "\(testCase.event) books"
            )
            XCTAssertEqual(
                hints.deletedBooks.sorted(), wantDeleted.sorted(),
                "\(testCase.event) deletedBooks"
            )
            XCTAssertEqual(
                hints.needsSweep, wantSweep,
                "\(testCase.event) needsSweep"
            )
            if expect.ignore == true {
                XCTAssertFalse(
                    hints.needsSweep && hints.books.isEmpty && hints.deletedBooks.isEmpty,
                    "\(testCase.event) must produce no work at all"
                )
            }
        }
    }

    /// The two cases a name-keyword matcher gets wrong, called out separately so
    /// a regression names itself.
    func testKeywordHeuristicsAreNotGoodEnough() throws {
        // No "book" in the name, but it is a book's progress that changed.
        let progress = EventClassifying.classify(
            SseEvent(
                kind: "ReadProgressChanged",
                data: "{\"bookId\":\"b1\",\"userId\":\"u1\"}",
                id: nil, retryMS: nil
            )
        )
        XCTAssertEqual(progress.books, ["b1"], "a remote read must not force a full sweep")
        XCTAssertFalse(progress.needsSweep)

        // "Deleted" in the name, but the entity is not deleted.
        let thumbnail = EventClassifying.classify(
            SseEvent(
                kind: "ThumbnailBookDeleted",
                data: "{\"bookId\":\"b1\",\"seriesId\":\"s1\",\"selected\":false}",
                id: nil, retryMS: nil
            )
        )
        XCTAssertEqual(thumbnail.books, ["b1"])
        XCTAssertFalse(
            thumbnail.deletedBooks.contains("b1"),
            "losing a poster must never delete the mirrored book"
        )
    }
}
