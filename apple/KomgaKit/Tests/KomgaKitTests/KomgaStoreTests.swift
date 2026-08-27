import XCTest
import GRDB
@testable import KomgaStore

final class KomgaStoreTests: XCTestCase {
    func testServerCRUD() throws {
        let store = try KomgaStore()
        var profile = ServerProfile(
            displayName: "Home",
            baseURL: "https://komga.example.com",
            authType: .apiKey,
            credentialRef: "keychain://home",
            capabilities: ["sse"]
        )
        try store.upsertServer(profile)

        var fetched = try XCTUnwrap(store.server(id: profile.id))
        XCTAssertEqual(fetched, profile)

        profile.displayName = "Home 2"
        try store.upsertServer(profile)
        fetched = try XCTUnwrap(store.server(id: profile.id))
        XCTAssertEqual(fetched.displayName, "Home 2")
        XCTAssertEqual(try store.fetchServers().count, 1)

        XCTAssertTrue(try store.deleteServer(id: profile.id))
        XCTAssertNil(try store.server(id: profile.id))
        XCTAssertFalse(try store.deleteServer(id: profile.id))
    }

    /// The mirror can always be re-derived from the server, so it must not
    /// fsync per statement — the reasoning behind WAL + `synchronous = NORMAL`.
    func testFileBackedStoreRunsOnWalWithCheapSync() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("komga-pragma-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: temp)
            try? FileManager.default.removeItem(atPath: temp.path + "-wal")
            try? FileManager.default.removeItem(atPath: temp.path + "-shm")
        }

        let store = try KomgaStore(path: temp.path)
        _ = try store.upsertServer(ServerProfile(
            displayName: "Home", baseURL: "https://komga.example.com", authType: .apiKey
        ))
        let settings = try readSettings(store)
        XCTAssertEqual(settings.journalMode, "wal", "\(settings)")
        XCTAssertEqual(settings.synchronous, 1, "NORMAL: \(settings)")
        XCTAssertEqual(settings.tempStore, 2, "MEMORY: \(settings)")
        XCTAssertEqual(settings.cacheSize, -8000, "8 MB of pages: \(settings)")
        // A committed transaction survives reopening the file.
        XCTAssertEqual(try KomgaStore(path: temp.path).fetchServers().count, 1)
    }

    /// An in-memory database cannot journal, so it keeps the rest of the
    /// settings without asking SQLite for WAL.
    func testInMemoryStoreSkipsTheJournalButKeepsTheRest() throws {
        let settings = try readSettings(try KomgaStore())
        XCTAssertEqual(settings.journalMode, "memory", "\(settings)")
        XCTAssertEqual(settings.synchronous, 1, "\(settings)")
        XCTAssertEqual(settings.tempStore, 2, "\(settings)")
        XCTAssertEqual(settings.cacheSize, -8000, "\(settings)")
    }

    private func readSettings(_ store: KomgaStore) throws -> (
        journalMode: String?, synchronous: Int?, tempStore: Int?, cacheSize: Int?
    ) {
        try store.dbQueue.read { db in
            (
                try String.fetchOne(db, sql: "PRAGMA journal_mode"),
                try Int.fetchOne(db, sql: "PRAGMA synchronous"),
                try Int.fetchOne(db, sql: "PRAGMA temp_store"),
                try Int.fetchOne(db, sql: "PRAGMA cache_size")
            )
        }
    }
}
