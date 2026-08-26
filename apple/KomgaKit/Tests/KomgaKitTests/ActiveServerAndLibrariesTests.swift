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
}