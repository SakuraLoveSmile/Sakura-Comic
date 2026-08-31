import Foundation
import XCTest
@testable import KomgaDownloads

// MARK: - The download tree, checked against the files that define it
//
// `layout.json#cases` is the same list the Rust tests assert, so the two
// platforms either agree on every path or one of them goes red. This is the part
// of the port where "we both wrote a downloads folder" would otherwise be true
// while the folders are unreadable to each other.

private struct LayoutFixture: Decodable {
    struct Case: Decodable {
        let name: String
        let serverId: String
        let bookId: String
        let number: Int
        let sniffed: String
        let expect: String
    }

    let zeroPadWidth: Int
    let manifestFileName: String
    let partSuffix: String
    /// Not a field the fixture states: the fallback is what the
    /// `unsniffable` case's expected name implies, so it is checked there.
    var fallbackExtension: String? { nil }
    let cases: [Case]
}

private struct ManifestFixture: Decodable {
    let document: DownloadManifest
    let rewrittenOn: [String]
}

final class DownloadsTreeContractTests: XCTestCase {
    private var layout: LayoutFixture!

    override func setUpWithError() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/downloads")
            .standardizedFileURL
        layout = try JSONDecoder().decode(
            LayoutFixture.self,
            from: Data(contentsOf: root.appendingPathComponent("layout.json"))
        )
    }

    func test_every_layout_case_lands_where_the_fixture_says() throws {
        XCTAssertEqual(layout.cases.count, 6, "the fixture grew and this suite did not notice")
        for testCase in layout.cases {
            let fileName = DownloadTree.pageFileName(
                number: testCase.number,
                fileExtension: DownloadTree.extensionFor(sniffed: testCase.sniffed)
            )
            let path = "downloads/"
                + DownloadTree.safeKey(testCase.serverId) + "/"
                + DownloadTree.safeKey(testCase.bookId) + "/"
                + fileName
            XCTAssertEqual(path, testCase.expect, testCase.name)
        }
    }

    func test_the_padding_constants_are_the_fixtures() {
        XCTAssertEqual(DownloadTree.zeroPadWidth, layout.zeroPadWidth)
        XCTAssertEqual(DownloadRoot.manifestFileName, layout.manifestFileName)
        XCTAssertEqual(DownloadRoot.partSuffix, layout.partSuffix)
        // The fallback lives in the case list, not as a field: `unsniffable`
        // expects `.img`, and that is the assertion below.
    }

    func test_page_numbers_grow_instead_of_colliding() {
        // The injective-half-of-the-mapping check: a fixed width would make
        // page 10000 and page 0 both `0000.png` at width 4.
        XCTAssertNotEqual(
            DownloadTree.pageFileName(number: 10_000, fileExtension: "png"),
            DownloadTree.pageFileName(number: 0, fileExtension: "png")
        )
        XCTAssertEqual(DownloadTree.pageFileName(number: 10_000, fileExtension: "png"), "10000.png")
        XCTAssertEqual(DownloadTree.pageFileName(number: 1, fileExtension: "png"), "0001.png")
    }

    func test_an_unsniffable_page_keeps_a_neutral_extension_rather_than_a_claim() {
        XCTAssertEqual(DownloadTree.extensionFor(sniffed: ""), DownloadRoot.fallbackExtension)
        XCTAssertEqual(DownloadTree.extensionFor(sniffed: "svg"), DownloadRoot.fallbackExtension)
        // jpeg/jpg are the same container spelled two ways.
        XCTAssertEqual(DownloadTree.extensionFor(sniffed: "JPEG"), "jpg")
    }

    func test_page_numbers_read_back_from_file_names() {
        XCTAssertEqual(DownloadTree.pageNumber(ofFile: "0042.jpg"), 42)
        XCTAssertEqual(DownloadTree.pageNumber(ofFile: "12345.png"), 12_345)
        XCTAssertNil(DownloadTree.pageNumber(ofFile: "manifest.json"))
        XCTAssertNil(DownloadTree.pageNumber(ofFile: "cover.png"))
        // Page 0 is not a thing in a 1-based manifest, so a file that parses to
        // it is not evidence of page 0 either way.
        XCTAssertEqual(DownloadTree.pageNumber(ofFile: "0000.png"), 0)
    }

    func test_the_tree_is_a_sibling_of_the_cache_never_inside_it() throws {
        let database = URL(fileURLWithPath: "/tmp/comic-tree-probe/comic.sqlite")
        let root = try DownloadRoot.forDatabase(database)
        XCTAssertEqual(root.url.path, "/tmp/comic-tree-probe/downloads")
        XCTAssertFalse(root.url.path.contains("/cache/"))
    }

    func test_a_root_parked_inside_the_cache_is_refused_at_construction() {
        // This is the structural half of "no eviction can delete a download":
        // `PageCache` builds paths only through the cache root, so anything that
        // *is* under the cache root is not a download root by definition.
        XCTAssertThrowsError(
            try DownloadRoot.at(
                URL(fileURLWithPath: "/tmp/probe/cache/downloads"),
                cacheRoot: URL(fileURLWithPath: "/tmp/probe/cache")
            )
        ) { error in
            guard case DownloadTreeError.rootInsideCacheRoot = error else {
                return XCTFail("refused for the wrong reason: \(error)")
            }
        }
        // A sibling called `caching` is not inside `cache`, and must not be
        // refused by a prefix test that forgot the separator.
        XCTAssertNoThrow(
            try DownloadRoot.at(
                URL(fileURLWithPath: "/tmp/probe/caching"),
                cacheRoot: URL(fileURLWithPath: "/tmp/probe/cache")
            )
        )
    }

    func test_the_manifest_round_trips_the_documents_own_shape() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/downloads")
            .standardizedFileURL
        let fixture = try JSONDecoder().decode(
            ManifestFixture.self,
            from: Data(contentsOf: root.appendingPathComponent("manifest.json"))
        )
        let document = fixture.document
        XCTAssertEqual(document.serverId, "s1")
        XCTAssertEqual(document.pages.count, 5)
        // Raw ids, not the sanitised directory names.
        XCTAssertEqual(document.pages.first?.fileName, "0001.png")
        XCTAssertEqual(document.pages.map(\.number), [1, 2, 3, 4, 6])
        XCTAssertEqual(document.pages.last?.mediaType, "image/jpeg")
        // Geometry is part of the document, so a reader that never touches the
        // network can still lay a page out at its real size.
        XCTAssertEqual(document.pages.first?.width, 520)
        XCTAssertEqual(document.pages.last?.width, 1200)
        // The fixture's `pages` skips 5, which is a claim about disk contents,
        // not about numbering: a gap is what "not downloaded yet" looks like.
        XCTAssertFalse(document.pageNumbers.contains(5))

        let encoded = try JSONEncoder().encode(document)
        let decoded = try DownloadManifest.read(
            at: writeTemp(encoded)
        )
        XCTAssertEqual(decoded, document, "the manifest is not round-trippable")
    }

    func test_a_missing_manifest_reads_as_nil_and_a_broken_one_as_an_error() throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("no-such-manifest-\(UUID().uuidString).json")
        XCTAssertNil(try DownloadManifest.read(at: missing))

        // A process killed mid-rename leaves exactly this: present, not JSON.
        let broken = writeTemp(Data("{\"pages\": [".utf8))
        XCTAssertThrowsError(try DownloadManifest.read(at: broken)) { error in
            guard case DownloadTreeError.unreadable = error else {
                return XCTFail("reported the wrong thing: \(error)")
            }
        }
    }

    private func writeTemp(_ data: Data) -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifest-probe-\(UUID().uuidString).json")
        try! data.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func test_written_atomically_and_readable_by_the_other_platforms_field_names() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("manifest-write-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let manifest = DownloadManifest(
            serverId: "s 1",
            bookId: "b/2",
            pagesCount: 2,
            downloadedAt: "2026-08-30T04:52:00Z",
            remoteLastModified: nil,
            pages: [
                ManifestPage(
                    number: 1, fileName: "0001.png", mediaType: "image/png",
                    sizeBytes: 10, width: 4, height: 8
                ),
            ]
        )
        try manifest.write(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        // The field names are the contract with the Rust reader; a synthesised
        // snake_case conversion would make the two sides' trees unreadable to
        // each other.
        for key in ["\"serverId\"", "\"bookId\"", "\"pagesCount\"", "\"downloadedAt\"", "\"sizeBytes\""] {
            XCTAssertTrue(text.contains(key), "manifest lost the field name \(key)")
        }
        XCTAssertTrue(text.contains("\"remoteLastModified\"") || text.contains("\"pages\""))
        XCTAssertEqual(try DownloadManifest.read(at: url), manifest)
    }
}
