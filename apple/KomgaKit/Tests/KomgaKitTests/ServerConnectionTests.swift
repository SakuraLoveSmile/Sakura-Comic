import XCTest
@testable import KomgaAPI

final class ServerInfoDTOTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureURL(name))
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/connection/\(name)")
    }

    func testDecodesSharedActuatorInfoFixture() throws {
        let info = try JSONDecoder().decode(ServerInfoDTO.self, from: fixture("actuator-info.json"))
        XCTAssertEqual(info.build?.version, "1.26.3")
        XCTAssertEqual(info.build?.artifact, "komga")
        XCTAssertEqual(info.build?.name, "komga")
        XCTAssertEqual(info.git?.commit?.id, "e93fa2a")
    }

    func testDecodesSharedLibrariesFixture() throws {
        let libraries = try JSONDecoder().decode([LibraryDTO].self, from: fixture("libraries.json"))
        XCTAssertEqual(libraries.count, 2)
        XCTAssertEqual(libraries[0].name, "Manga")
        XCTAssertEqual(libraries[0].root, "/mnt/media/manga")
        XCTAssertEqual(libraries[0].unavailable, false)
    }

    func testToleratesEmptyAndPartialBodies() throws {
        let empty = try JSONDecoder().decode(ServerInfoDTO.self, from: Data("{}".utf8))
        XCTAssertNil(empty.build)

        let partial = try JSONDecoder().decode(
            ServerInfoDTO.self,
            from: Data(#"{"build":{"version":"1.26.3"},"extra":42}"#.utf8)
        )
        XCTAssertEqual(partial.build?.version, "1.26.3")
    }

    func testLibrariesURLIsStable() throws {
        XCTAssertEqual(
            try KomgaTransport.librariesURL(baseURL: "https://komga.example.com").absoluteString,
            "https://komga.example.com/api/v1/libraries"
        )
        XCTAssertEqual(
            try KomgaTransport.librariesURL(baseURL: "https://example.com/komga/").absoluteString,
            "https://example.com/komga/api/v1/libraries"
        )
    }

    func testServerInfoURLIsStable() throws {
        XCTAssertEqual(
            try KomgaTransport.serverInfoURL(baseURL: "https://komga.example.com").absoluteString,
            "https://komga.example.com/actuator/info"
        )
        XCTAssertEqual(
            try KomgaTransport.serverInfoURL(baseURL: "https://example.com/komga/").absoluteString,
            "https://example.com/komga/actuator/info"
        )
    }
}

final class KomgaContractTests: XCTestCase {
    func testContractVersionMatchesPolicy() {
        XCTAssertEqual(KomgaAPI.contractVersion, "0.2.0")
        XCTAssertEqual(KomgaContract.snapshotVersion, "1.26.3")
    }

    func testAcceptsSnapshotLine() throws {
        XCTAssertEqual(try KomgaContract.check(serverVersion: "1.26.3"), .accepted)
        XCTAssertEqual(try KomgaContract.check(serverVersion: "1.26.0"), .accepted)
        // Patch-level differences inside the snapshot line are compatible.
        XCTAssertEqual(try KomgaContract.check(serverVersion: "1.26.99"), .accepted)
    }

    func testAcceptsNewerMinorSameMajor() throws {
        XCTAssertEqual(
            try KomgaContract.check(serverVersion: "1.27.0"),
            .newerMinor("1.27.0")
        )
    }

    func testRejectsBelowMinimum() {
        XCTAssertThrowsError(try KomgaContract.check(serverVersion: "1.25.9")) { error in
            guard case KomgaAPIError.apiCompatibility = error as! KomgaAPIError else {
                return XCTFail("expected apiCompatibility, got \(error)")
            }
        }
    }

    func testRejectsNewerMajor() {
        XCTAssertThrowsError(try KomgaContract.check(serverVersion: "2.0.0"))
    }

    func testMissingOrGarbageIsUnknown() throws {
        XCTAssertEqual(try KomgaContract.check(serverVersion: nil), .unknownVersion)
        XCTAssertEqual(try KomgaContract.check(serverVersion: "not-a-version"), .unknownVersion)
    }

    func testParsesMessyVersions() {
        XCTAssertEqual(try KomgaContract.check(serverVersion: "v1.26.3"), .accepted)
        XCTAssertEqual(try KomgaContract.check(serverVersion: "1.26.3-SNAPSHOT"), .accepted)
        XCTAssertEqual(
            try KomgaContract.check(serverVersion: "1.28"),
            .newerMinor("1.28")
        )
    }

    func testCapabilities() throws {
        XCTAssertEqual(KomgaContract.capabilities(from: .accepted), [])
        XCTAssertEqual(
            KomgaContract.capabilities(from: .newerMinor("1.27.0")),
            ["newer-than-snapshot:1.27.0"]
        )
        XCTAssertEqual(
            KomgaContract.capabilities(from: .unknownVersion),
            ["unknown-version"]
        )
    }
}

final class ServerConnectionTests: XCTestCase {
    /// Fake probe backed by the shared connection fixtures.
    struct FakeConnection: ConnectionFetching {
        var info: ServerInfoDTO
        var libraries: [LibraryDTO]
        var failInfo: Bool = false
        var failLibraries: Bool = false

        static func fromFixtures() throws -> FakeConnection {
            let infoJSON = try Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("../../../../specs/contracts/fixtures/connection/actuator-info.json"))
            let libsJSON = try Data(contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("../../../../specs/contracts/fixtures/connection/libraries.json"))
            return FakeConnection(
                info: try JSONDecoder().decode(ServerInfoDTO.self, from: infoJSON),
                libraries: try JSONDecoder().decode([LibraryDTO].self, from: libsJSON)
            )
        }

        func fetchServerInfo() async throws -> ServerInfoDTO {
            if failInfo { throw KomgaAPIError.authentication }
            return info
        }

        func fetchLibraries() async throws -> [LibraryDTO] {
            if failLibraries { throw KomgaAPIError.server(statusCode: 500) }
            return libraries
        }
    }

    func testConnectCollectsInfoLibrariesAndCapabilities() async throws {
        let result = try await ServerConnection.connect(fetching: try FakeConnection.fromFixtures())
        XCTAssertEqual(result.serverVersion, "1.26.3")
        XCTAssertEqual(result.libraries.count, 2)
        XCTAssertTrue(result.capabilities.contains("libraries:2"))
        XCTAssertFalse(result.capabilities.contains("unknown-version"))
    }

    func testConnectMapsAuthFailure() async {
        var fetcher = try! FakeConnection.fromFixtures()
        fetcher.failInfo = true
        do {
            _ = try await ServerConnection.connect(fetching: fetcher)
            XCTFail("expected authentication error")
        } catch let error as KomgaAPIError {
            XCTAssertEqual(error, .authentication)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testConnectRejectsUnsupportedServerVersion() async {
        var fetcher = try! FakeConnection.fromFixtures()
        fetcher.info = ServerInfoDTO(build: BuildInfoDTO(version: "2.0.0"))
        do {
            _ = try await ServerConnection.connect(fetching: fetcher)
            XCTFail("expected apiCompatibility error")
        } catch let error as KomgaAPIError {
            guard case .apiCompatibility = error else {
                return XCTFail("expected apiCompatibility, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testConnectNewerMinorRecordsCapability() async throws {
        var fetcher = try! FakeConnection.fromFixtures()
        fetcher.info = ServerInfoDTO(build: BuildInfoDTO(version: "1.27.3"))
        let result = try await ServerConnection.connect(fetching: fetcher)
        XCTAssertTrue(result.capabilities.contains("newer-than-snapshot:1.27.3"))
        XCTAssertTrue(result.capabilities.contains("libraries:2"))
    }
}