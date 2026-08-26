import XCTest
@testable import KomgaStore

/// Cover-cache bookkeeping (thumbnails) + sync_state rows.
final class ThumbnailStoreTests: XCTestCase {
    private func makeRecords(serverID: String = "srv-1") -> [ThumbnailRecord] {
        [
            ThumbnailRecord(
                serverID: serverID,
                remoteID: "s1",
                localPath: "/cache/srv-1-s1",
                sizeBytes: 1024
            ),
            ThumbnailRecord(
                serverID: serverID,
                remoteID: "s2",
                localPath: "/cache/srv-1-s2",
                sizeBytes: 2048
            ),
        ]
    }

    func testUpsertGetAndList() throws {
        let store = try KomgaStore()
        for record in makeRecords() {
            try store.upsertThumbnail(record)
        }

        let row = try store.thumbnail(serverID: "srv-1", remoteID: "s1")
        XCTAssertEqual(row?.localPath, "/cache/srv-1-s1")
        XCTAssertEqual(row?.sizeBytes, 1024)
        XCTAssertNotNil(row?.lastAccess)

        XCTAssertEqual(try store.listThumbnails(serverID: "srv-1").map(\.remoteID), ["s1", "s2"])
        XCTAssertEqual(try store.coverPath(serverID: "srv-1", remoteID: "s2"), "/cache/srv-1-s2")
    }

    func testUpsertIsIdempotent() throws {
        let store = try KomgaStore()
        try store.upsertThumbnail(makeRecords()[0])
        try store.upsertThumbnail(ThumbnailRecord(
            serverID: "srv-1",
            remoteID: "s1",
            localPath: "/cache/new-path",
            sizeBytes: 4096
        ))
        XCTAssertEqual(try store.listThumbnails(serverID: "srv-1").count, 1)
        let row = try store.thumbnail(serverID: "srv-1", remoteID: "s1")
        XCTAssertEqual(row?.localPath, "/cache/new-path")
        XCTAssertEqual(row?.sizeBytes, 4096)
    }

    func testMultiServerIsolation() throws {
        let store = try KomgaStore()
        try store.upsertThumbnail(makeRecords()[0])
        try store.upsertThumbnail(ThumbnailRecord(
            serverID: "srv-2",
            remoteID: "s1",
            localPath: "/cache/srv-2-s1",
            sizeBytes: 1
        ))
        XCTAssertEqual(try store.coverPath(serverID: "srv-1", remoteID: "s1"), "/cache/srv-1-s1")
        XCTAssertEqual(try store.coverPath(serverID: "srv-2", remoteID: "s1"), "/cache/srv-2-s1")
    }

    func testDeleteServerClearsCoverRecords() throws {
        let store = try KomgaStore()
        try store.upsertThumbnail(makeRecords()[0])
        try store.upsertServer(ServerProfile(
            id: "srv-1",
            displayName: "Home",
            baseURL: "https://komga.example.com",
            authType: .apiKey
        ))
        XCTAssertTrue(try store.deleteServer(id: "srv-1"))
        XCTAssertTrue(try store.listThumbnails(serverID: "srv-1").isEmpty)
    }

    func testSyncStateLifecycle() throws {
        let store = try KomgaStore()
        XCTAssertNil(try store.syncState(serverID: "srv-1"))

        let state = try store.recordSuccessfulSync(serverID: "srv-1")
        XCTAssertEqual(state.syncStatus, "idle")
        XCTAssertNotNil(state.lastSuccessfulSync)
        XCTAssertNil(state.lastError)

        // Re-recording refreshes the timestamp and keeps a single row.
        let second = try store.recordSuccessfulSync(serverID: "srv-1")
        XCTAssertEqual(second.serverID, "srv-1")
        XCTAssertEqual(try store.syncState(serverID: "srv-1")?.syncStatus, "idle")
    }
}