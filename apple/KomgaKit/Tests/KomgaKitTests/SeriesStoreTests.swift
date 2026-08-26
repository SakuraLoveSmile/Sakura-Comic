import XCTest
@testable import KomgaStore

final class SeriesStoreTests: XCTestCase {
    func testBatchUpsertAndPage() throws {
        let store = try KomgaStore()
        try store.upsertSeriesBatch([
            SeriesRecord(serverID: "srv-1", remoteID: "s1", libraryID: "lib-1", name: "One Piece", status: "ONGOING"),
            SeriesRecord(serverID: "srv-1", remoteID: "s2", libraryID: "lib-1", name: "Berserk"),
        ])
        XCTAssertEqual(try store.countSeries(serverID: "srv-1"), 2)

        let rows = try store.fetchSeries(serverID: "srv-1", limit: 10, offset: 0)
        XCTAssertEqual(rows.map(\.name), ["Berserk", "One Piece"])
        let onePiece = rows.first { $0.name == "One Piece" }
        XCTAssertEqual(onePiece?.status, "ONGOING")
    }

    func testUpsertIsIdempotent() throws {
        let store = try KomgaStore()
        try store.upsertSeriesBatch([
            SeriesRecord(serverID: "srv-1", remoteID: "s1", libraryID: "lib-1", name: "One Piece")
        ])
        try store.upsertSeriesBatch([
            SeriesRecord(serverID: "srv-1", remoteID: "s1", libraryID: "lib-1", name: "One Piece (Revised)")
        ])
        XCTAssertEqual(try store.countSeries(serverID: "srv-1"), 1)
        XCTAssertEqual(
            try store.fetchSeries(serverID: "srv-1", limit: 10, offset: 0).first?.name,
            "One Piece (Revised)"
        )
    }

    func testMultiServerIsolation() throws {
        let store = try KomgaStore()
        try store.upsertSeriesBatch([
            SeriesRecord(serverID: "srv-1", remoteID: "s1", libraryID: "lib-1", name: "One Piece")
        ])
        try store.upsertSeriesBatch([
            SeriesRecord(serverID: "srv-2", remoteID: "s1", libraryID: "lib-1", name: "One Piece")
        ])
        XCTAssertEqual(try store.countSeries(serverID: "srv-1"), 1)
        XCTAssertEqual(try store.countSeries(serverID: "srv-2"), 1)
    }
}
