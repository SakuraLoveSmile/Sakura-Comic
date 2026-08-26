import XCTest
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
}
