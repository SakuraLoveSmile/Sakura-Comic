import XCTest
@testable import KomgaStore
import KomgaAPI

final class ActiveServerAndLibrariesTests: XCTestCase {
    func testServerProfileDateRoundtripIsMillisecondExact() throws {
        let store = try KomgaStore()
        // RFC 3339 serialization keeps millisecond precision; truncate like
        // the app layer does so equality holds exactly.
        let now = Date()
        let lastConnected = Date(
            timeIntervalSince1970: (now.timeIntervalSince1970 * 1000).rounded() / 1000
        )
        let profile = ServerProfile(
            displayName: "Home",
            baseURL: "http://a.local:25600",
            authType: .apiKey,
            lastSuccessfulConnection: lastConnected
        )
        try store.upsertServer(profile)
        XCTAssertEqual(try store.server(id: profile.id)?.lastSuccessfulConnection, lastConnected)
    }

    func testActiveServerRoundtrip() throws {
        let store = try KomgaStore()
        XCTAssertNil(try store.activeServerID())
        XCTAssertNil(try store.activeServerProfile())

        let profile = ServerProfile(displayName: "Home", baseURL: "http://a.local:25600", authType: .apiKey)
        try store.upsertServer(profile)
        try store.setActiveServer(id: profile.id)

        XCTAssertEqual(try store.activeServerID(), profile.id)
        XCTAssertEqual(try store.activeServerProfile(), profile)

        // Switching replaces the previous value.
        let other = ServerProfile(displayName: "Work", baseURL: "http://b.local:25600", authType: .apiKey)
        try store.upsertServer(other)
        try store.setActiveServer(id: other.id)
        XCTAssertEqual(try store.activeServerProfile(), other)
    }

    func testDeletingActiveServerClearsActiveState() throws {
        let store = try KomgaStore()
        let profile = ServerProfile(displayName: "Home", baseURL: "http://a.local:25600", authType: .apiKey)
        try store.upsertServer(profile)
        try store.setActiveServer(id: profile.id)

        XCTAssertTrue(try store.deleteServer(id: profile.id))
        XCTAssertNil(try store.activeServerID())
    }

    func testLibrariesAreScopedPerServer() throws {
        let store = try KomgaStore()
        let base = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/connection/libraries.json")
        let libraries = try JSONDecoder().decode([LibraryDTO].self, from: Data(contentsOf: base))

        XCTAssertEqual(try store.upsertLibraries(serverID: "server-1", libraries: libraries), 2)
        try store.upsertLibraries(serverID: "server-2", libraries: Array(libraries.prefix(1)))

        let s1 = try store.fetchLibraries(serverID: "server-1")
        XCTAssertEqual(s1.count, 2)
        // Same remote id on another server must not collide.
        XCTAssertEqual(s1.first { $0.name == "Manga" }?.remoteID, libraries[0].id)
        XCTAssertEqual(s1.first { $0.name == "Comics" }?.serverID, "server-1")
        XCTAssertEqual(try store.fetchLibraries(serverID: "server-2").count, 1)
    }

    func testLibraryUpsertIsIdempotent() throws {
        let store = try KomgaStore()
        let libs = [
            LibraryDTO(id: "l1", name: "Old", root: "/mnt"),
            LibraryDTO(id: "l1", name: "New", root: "/mnt"),
        ]
        try store.upsertLibraries(serverID: "s", libraries: libs)
        let rows = try store.fetchLibraries(serverID: "s")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].name, "New")
    }

    func testUpsertServerWithLibrariesIsAtomic() throws {
        let store = try KomgaStore()
        let profile = ServerProfile(id: "srv-atomic", displayName: "Atomic Srv", baseURL: "http://example.com", authType: .apiKey)
        let libs = [LibraryDTO(id: "lib-1", name: "Lib1", root: "/path")]

        let count = try store.upsertServerWithLibraries(profile: profile, libraries: libs)
        XCTAssertEqual(count, 1)

        let saved = try store.server(id: "srv-atomic")
        XCTAssertEqual(saved?.displayName, "Atomic Srv")
        let savedLibs = try store.fetchLibraries(serverID: "srv-atomic")
        XCTAssertEqual(savedLibs.count, 1)
        XCTAssertEqual(savedLibs[0].name, "Lib1")
    }

    func testDeleteServerPreservesDownloadsAndPages() throws {
        let store = try KomgaStore()
        let profile = ServerProfile(id: "srv-dl", displayName: "Download Srv", baseURL: "http://example.com", authType: .apiKey)
        try store.upsertServer(profile)

        // Seed download and download_pages rows for this server
        try store.dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO downloads (server_id, book_id, manifest_path, pages_total, pages_done, state) VALUES (?, ?, ?, ?, ?, ?)",
                arguments: ["srv-dl", "book-1", "/tmp/m.json", 10, 10, "completed"]
            )
            try db.execute(
                sql: "INSERT INTO download_pages (server_id, book_id, page_number, file_path, state) VALUES (?, ?, ?, ?, ?)",
                arguments: ["srv-dl", "book-1", 1, "/tmp/0001.png", "complete"]
            )
        }

        // Delete server
        XCTAssertTrue(try store.deleteServer(id: "srv-dl"))
        XCTAssertNil(try store.server(id: "srv-dl"))

        // Downloads and download_pages MUST survive server deletion
        let dlCount = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM downloads WHERE server_id = 'srv-dl'") ?? 0
        }
        let pageCount = try store.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM download_pages WHERE server_id = 'srv-dl'") ?? 0
        }
        XCTAssertEqual(dlCount, 1, "Downloads must not be deleted when server is deleted")
        XCTAssertEqual(pageCount, 1, "Download pages must not be deleted when server is deleted")
    }

    func testPendingCredentialCleanupsJournal() throws {
        let store = try KomgaStore()
        XCTAssertEqual(try store.pendingCredentialCleanups(), [])

        let refs = ["keychain:s1-uuid1", "keychain:s2-uuid2"]
        try store.setPendingCredentialCleanups(refs)
        XCTAssertEqual(try store.pendingCredentialCleanups(), refs)

        try store.setPendingCredentialCleanups(["keychain:s2-uuid2"])
        XCTAssertEqual(try store.pendingCredentialCleanups(), ["keychain:s2-uuid2"])
    }
}