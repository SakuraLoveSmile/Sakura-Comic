import XCTest
import GRDB
@testable import KomgaStore

/// Offline read-progress priority (mirror of Rust `store/read_progress` tests
/// and `specs/contracts/fixtures/read-progress/offline-priority.json`): a sync
/// sweep mirrors the server, but never at the cost of reading state the user
/// produced offline while its upload is still queued.
final class ReadProgressSyncTests: XCTestCase {
    private let serverID = "srv"

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/read-progress")
            .standardizedFileURL
    }

    private struct Fixture: Decodable {
        struct Remote: Decodable {
            let bookId: String
            let page: Int
            let completed: Bool
            let serverUpdatedAt: String
        }

        struct Expected: Decodable {
            let page: Int
            let completed: Bool
            let uploadRequired: Bool
        }

        struct LocalPending: Decodable {
            let page: Int
            let localUpdatedAt: String
        }

        let remote: Remote
        let localPending: LocalPending
        let expected: Expected
    }

    private func row(_ store: KomgaStore, _ bookID: String) throws -> (page: Int64?, completed: Bool, pending: Bool)? {
        try store.dbQueue.read { db in
            guard let raw = try Row.fetchOne(
                db,
                sql: """
                SELECT page, completed, mutation_pending FROM read_progress
                 WHERE server_id = ? AND book_id = ?
                """,
                arguments: [serverID, bookID]
            ) else { return nil }
            let page: Int64? = raw["page"]
            let completed: Int = raw["completed"]
            let pending: Int = raw["mutation_pending"]
            return (page, completed != 0, pending != 0)
        }
    }

    private func queuedMutation(_ store: KomgaStore, _ bookID: String) throws -> String? {
        try store.dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT mutation_type FROM pending_mutations
                 WHERE server_id = ? AND entity_id = ?
                   AND mutation_type IN ('MARK_READ', 'MARK_UNREAD', 'READ_PROGRESS')
                 ORDER BY created_at DESC LIMIT 1
                """,
                arguments: [serverID, bookID]
            )
        }
    }

    private func pinLocalStamp(_ store: KomgaStore, _ bookID: String, _ stamp: String) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE read_progress SET local_updated_at = ? WHERE server_id = ? AND book_id = ?
                """,
                arguments: [stamp, serverID, bookID]
            )
            try db.execute(
                sql: "UPDATE pending_mutations SET created_at = ? WHERE server_id = ? AND entity_id = ?",
                arguments: [stamp, serverID, bookID]
            )
        }
    }

    /// The shared contract fixture drives this test: fixture in, assertions out.
    func testOfflinePriorityFixtureIsEnforced() throws {
        let data = try Data(contentsOf: fixtureURL.appendingPathComponent("offline-priority.json"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let store = try KomgaStore()

        try store.setReadProgress(
            serverID: serverID, bookID: fixture.remote.bookId,
            page: Int64(fixture.localPending.page), completed: false
        )
        try pinLocalStamp(store, fixture.remote.bookId, fixture.localPending.localUpdatedAt)

        try store.upsertSyncedReadProgress(
            serverID: serverID,
            bookID: fixture.remote.bookId,
            page: Int64(fixture.remote.page),
            completed: fixture.remote.completed,
            serverUpdatedAt: fixture.remote.serverUpdatedAt
        )

        let stored = try XCTUnwrap(try row(store, fixture.remote.bookId))
        XCTAssertEqual(Int(stored.page ?? -1), fixture.expected.page, "the offline page must survive")
        XCTAssertEqual(stored.completed, fixture.expected.completed)
        XCTAssertEqual(stored.pending, true, "the mutation must stay queued for upload")
        XCTAssertEqual(
            try queuedMutation(store, fixture.remote.bookId) != nil,
            fixture.expected.uploadRequired
        )
    }

    /// An explicit mark is user intent: no remote passive value outranks it
    /// while the mutation is still queued — not even a newer one.
    func testExplicitMarksOutrankRemoteProgress() throws {
        let store = try KomgaStore()
        try store.markRead(serverID: serverID, bookID: "b1")
        try store.upsertSyncedReadProgress(
            serverID: serverID, bookID: "b1", page: 40, completed: false,
            serverUpdatedAt: "2027-01-01T00:00:00Z"
        )
        let read = try XCTUnwrap(try row(store, "b1"))
        XCTAssertNil(read.page, "mark-read keeps its own shape")
        XCTAssertEqual(read.completed, true)
        XCTAssertEqual(read.pending, true)

        // Mark-unread must not be outvoted by a bigger page number either.
        try store.markUnread(serverID: serverID, bookID: "b2")
        try store.upsertSyncedReadProgress(
            serverID: serverID, bookID: "b2", page: 40, completed: true,
            serverUpdatedAt: "2027-01-01T00:00:00Z"
        )
        let unread = try XCTUnwrap(try row(store, "b2"))
        XCTAssertEqual(unread.page, 0)
        XCTAssertEqual(unread.completed, false)
    }

    /// With only a passive local progress queued, a genuinely newer server value
    /// is adopted — but the queued mutation survives, because dropping it here
    /// would discard an action the server never saw.
    func testNewerServerProgressWinsAndKeepsTheQueue() throws {
        let store = try KomgaStore()
        try store.setReadProgress(serverID: serverID, bookID: "b1", page: 5, completed: false)
        try pinLocalStamp(store, "b1", "2025-01-01T00:00:00Z")
        try store.upsertSyncedReadProgress(
            serverID: serverID, bookID: "b1", page: 9, completed: false,
            serverUpdatedAt: "2025-06-01T00:00:00Z"
        )
        let stored = try XCTUnwrap(try row(store, "b1"))
        XCTAssertEqual(stored.page, 9, "the newer server value is mirrored")
        XCTAssertEqual(stored.pending, true, "the queued local mutation is not silently dropped")
        XCTAssertNotNil(try queuedMutation(store, "b1"))
    }

    /// No local intent outstanding: the sweep mirrors the server as usual.
    func testRemoteProgressWithoutLocalIntentIsMirrored() throws {
        let store = try KomgaStore()
        try store.upsertSyncedReadProgress(
            serverID: serverID, bookID: "b1", page: 12, completed: false,
            serverUpdatedAt: "2025-06-01T00:00:00Z"
        )
        let stored = try XCTUnwrap(try row(store, "b1"))
        XCTAssertEqual(stored.page, 12)
        XCTAssertEqual(stored.pending, false)
    }

    /// The point of the guard on the sync path: a book DTO or on-deck payload
    /// still carrying the pre-upload value must not roll the user back.
    func testSweepCannotLoseOfflineProgress() throws {
        let store = try KomgaStore()
        try store.upsertSyncedReadProgress(
            serverID: serverID, bookID: "b1", page: 3, completed: false,
            serverUpdatedAt: "2025-01-01T00:00:00Z"
        )
        try store.setReadProgress(serverID: serverID, bookID: "b1", page: 21, completed: false)
        try pinLocalStamp(store, "b1", "2025-06-01T00:00:00Z")
        // The server still reports page 3: its upload never landed.
        try store.upsertSyncedReadProgress(
            serverID: serverID, bookID: "b1", page: 3, completed: false,
            serverUpdatedAt: "2025-01-01T00:00:00Z"
        )
        let stored = try XCTUnwrap(try row(store, "b1"))
        XCTAssertEqual(stored.page, 21, "offline progress survived the sweep")
    }
}
