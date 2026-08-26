import XCTest
@testable import KomgaStore

final class ServerProfileTests: XCTestCase {
    func testCodableRoundtrip() throws {
        let profile = ServerProfile(
            displayName: "Home",
            baseURL: "https://komga.example.com",
            authType: .apiKey,
            credentialRef: "keychain://home",
            capabilities: ["sse"]
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: data)
        XCTAssertEqual(profile, decoded)
    }

    func testUniqueIDs() {
        let a = ServerProfile(displayName: "A", baseURL: "http://a", authType: .basic)
        let b = ServerProfile(displayName: "B", baseURL: "http://b", authType: .basic)
        XCTAssertNotEqual(a.id, b.id)
    }
}
