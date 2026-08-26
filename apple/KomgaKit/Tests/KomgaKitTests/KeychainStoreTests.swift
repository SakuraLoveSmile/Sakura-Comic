import XCTest
@testable import KomgaStore

final class KeychainStoreTests: XCTestCase {
    private let store = KeychainStore()
    private let ref = "keychain:test-\(UUID().uuidString)"

    override func tearDown() {
        try? store.delete(ref: ref)
        super.tearDown()
    }

    func testSaveReadRoundtrip() throws {
        try store.save(secret: "s3cret", for: ref)
        XCTAssertEqual(try store.read(ref: ref), "s3cret")
    }

    func testReadMissingReturnsNil() throws {
        XCTAssertNil(try store.read(ref: "keychain:does-not-exist"))
    }

    func testSaveOverwrites() throws {
        try store.save(secret: "first", for: ref)
        try store.save(secret: "second", for: ref)
        XCTAssertEqual(try store.read(ref: ref), "second")
    }

    func testDeleteIsIdempotent() throws {
        try store.save(secret: "x", for: ref)
        try store.delete(ref: ref)
        XCTAssertNil(try store.read(ref: ref))
        // Second delete must not throw.
        try store.delete(ref: ref)
    }

    func testCredentialRefConvention() {
        XCTAssertEqual(KeychainStore.credentialRef(serverID: "srv-1"), "keychain:srv-1")
    }
}