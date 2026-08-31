import XCTest
import GRDB
@testable import KomgaAPI
@testable import KomgaDiagnostics
@testable import KomgaStore

// MARK: - Stage 10 release hardening, Apple side
//
// Mirrors of Rust `diagnostics::log`, `diagnostics::snapshot`, `ffi::error` and
// `store::auth_state`. Two of the four areas are *contract* tests against the
// same JSON the Rust and Dart suites load — the code list and the snapshot's
// field names — which is the only way "the platforms agree" means anything
// beyond "both compiled".

private let fixtureRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../../specs/contracts/fixtures")
    .standardizedFileURL

private func loadFixture<T: Decodable>(_ relativePath: String) throws -> T {
    let data = try Data(contentsOf: fixtureRoot.appendingPathComponent(relativePath))
    return try JSONDecoder().decode(T.self, from: data)
}

/// A JSON tree, so paths can be walked without committing to a shape.
private enum JSONNode: Decodable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONNode])
    case object([String: JSONNode])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONNode].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONNode].self))
        }
    }
}

/// `parent.child` for object keys and `parent[].child` for an array's elements —
/// the spelling `diagnostics/snapshot.json` uses, and the same walk
/// `flatten_paths` does in Rust.
private func flatten(_ node: JSONNode, _ prefix: String, into out: inout Set<String>) {
    switch node {
    case let .object(members):
        for (key, child) in members {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            flatten(child, path, into: &out)
        }
    case let .array(items):
        for item in items {
            flatten(item, "\(prefix)[]", into: &out)
        }
    default:
        if !prefix.isEmpty { out.insert(prefix) }
    }
}

// MARK: - The error codes

final class CoreErrorContractTests: XCTestCase {
    private struct CodesFixture: Decodable {
        struct Entry: Decodable {
            let code: String
            let retryable: Bool
            let needsUser: Bool
        }

        let codes: [Entry]
    }

    func test_the_enum_is_exactly_the_shared_fixture_list_in_order() throws {
        let fixture: CodesFixture = try loadFixture("errors/codes.json")
        XCTAssertEqual(
            CoreErrorCode.contractOrder.map(\.rawValue),
            fixture.codes.map(\.code),
            "one side renamed or reordered a code on its own"
        )
        XCTAssertEqual(
            Set(CoreErrorCode.allCases.map(\.rawValue)),
            Set(fixture.codes.map(\.code)),
            "CaseIterable and the contract order disagree, so a code is unreachable"
        )
    }

    func test_the_two_policy_bits_come_from_the_fixture_not_from_a_local_guess() throws {
        let fixture: CodesFixture = try loadFixture("errors/codes.json")
        for entry in fixture.codes {
            let code = try XCTUnwrap(CoreErrorCode(rawValue: entry.code))
            XCTAssertEqual(code.isRetryable, entry.retryable, "\(entry.code) retryable")
            XCTAssertEqual(code.needsUser, entry.needsUser, "\(entry.code) needsUser")
        }
    }

    func test_only_a_rejected_credential_asks_the_user_for_something() {
        for code in CoreErrorCode.contractOrder where code != .authExpired {
            XCTAssertFalse(code.needsUser, "\(code.rawValue) claims to need the user")
        }
        XCTAssertTrue(CoreErrorCode.authExpired.needsUser)
    }

    func test_the_policy_bits_are_derived_so_a_construction_site_cannot_argue_with_them() {
        let error = CoreError(code: .networkUnavailable, message: "no route")
        XCTAssertTrue(error.retryable)
        XCTAssertFalse(error.needsUser)
    }

    func test_a_code_this_build_has_never_seen_decodes_to_unknown_and_keeps_its_text() throws {
        let data = Data(
            """
            {"code":"quantumFailure","message":"from the future","retryable":true,"needsUser":true}
            """.utf8
        )
        let decoded = try JSONDecoder().decode(CoreError.self, from: data)
        XCTAssertEqual(decoded.code, .unknown)
        XCTAssertEqual(decoded.message, "from the future")
        // A payload cannot talk its way into a retry or a password prompt.
        XCTAssertFalse(decoded.retryable)
        XCTAssertFalse(decoded.needsUser)
    }

    func test_the_wire_shape_is_the_four_camelCase_fields() throws {
        let data = try JSONEncoder().encode(CoreError(code: .authExpired, message: "401"))
        let tree = try JSONDecoder().decode(JSONNode.self, from: data)
        guard case let .object(members) = tree else { return XCTFail("expected an object") }
        XCTAssertEqual(Set(members.keys), ["code", "message", "retryable", "needsUser"])
    }

    // MARK: Transport mapping (mirror of Rust `CoreError::from(ApiError)`)

    func test_every_transport_failure_lands_on_a_nameable_code() {
        let cases: [(KomgaAPIError, CoreErrorCode)] = [
            (.authentication, .authExpired),
            (.network, .networkUnavailable),
            (.server(statusCode: 401), .authExpired),
            (.server(statusCode: 403), .authExpired),
            (.server(statusCode: 404), .notFound),
            (.server(statusCode: 410), .notFound),
            (.server(statusCode: 409), .conflict),
            (.server(statusCode: 429), .rateLimited),
            (.server(statusCode: 500), .serverError),
            (.server(statusCode: 418), .serverError),
            (.apiCompatibility("1.40"), .contractUnsupported),
            (.urlInvalid("no scheme"), .invalidInput),
            (.decode("missing field"), .decodeFailed),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(error.coreError.code, expected, "\(error)")
            XCTAssertFalse(error.coreError.message.isEmpty, "\(error) lost its text")
        }
    }
}

// MARK: - The log ring

final class CoreLogTests: XCTestCase {
    private var log: CoreLog!

    override func setUp() {
        log = CoreLog()
        log.forwardsToSystemLog = false
    }

    private func messages() -> [String] {
        log.recent(limit: .max).map(\.message)
    }

    func test_the_ring_keeps_the_newest_lines_and_counts_the_evicted_ones() {
        log.setCapacity(3)
        for index in 0..<5 {
            log.record(level: .info, target: "gate", message: "line \(index)")
        }
        XCTAssertEqual(messages(), ["line 4", "line 3", "line 2"])
        let stats = log.stats()
        XCTAssertEqual(stats.retained, 3)
        XCTAssertEqual(stats.dropped, 2)
        XCTAssertEqual(stats.capacity, 3)
    }

    func test_a_shrink_evicts_from_the_front() {
        log.setCapacity(4)
        for index in 0..<4 {
            log.record(level: .info, target: "gate", message: "l\(index)")
        }
        log.setCapacity(0)
        XCTAssertEqual(messages(), ["l3"])
    }

    func test_counters_survive_after_the_line_itself_has_been_evicted() {
        log.setCapacity(2)
        log.error("gate", "boom")
        log.warning("gate", "hmm")
        log.info("gate", "noise")
        let stats = log.stats()
        // Three separate assertions: a Swift tuple of three is not Equatable,
        // and collapsing them into one line that cannot compile is how a check
        // quietly stops existing.
        XCTAssertEqual(stats.errors, 1)
        XCTAssertEqual(stats.warnings, 1)
        XCTAssertEqual(stats.info, 1)
        // The counter survives; the pointer does not. "Did anything go wrong
        // here" is answerable from `errors`, and only "what did it say" needs
        // the window to still be holding the line.
        XCTAssertEqual(stats.lastError, "")
    }

    func test_without_an_error_line_there_is_no_stale_last_error() {
        log.info("gate", "all quiet")
        // Empty rather than absent: the key is always there, so a reader
        // never has to guess which of the two it is looking at.
        XCTAssertEqual(log.stats().lastError, "")
    }

    func test_the_level_threshold_narrows_the_window_and_an_unknown_name_does_not_empty_it() {
        // Reading a filter needs the lines to have been captured first: the
        // ring keeps its own ceiling at info, the same default Rust installs,
        // so a debug line has to be let in before a filter is asked about it.
        log.setMaxLevel(.debug)
        log.record(level: .error, target: "gate", message: "e")
        log.record(level: .warning, target: "gate", message: "w")
        log.record(level: .info, target: "gate", message: "i")
        log.record(level: .debug, target: "gate", message: "d")
        // Newest first, like the Rust ring.
        XCTAssertEqual(log.recent(limit: 99, minLevel: "warn").map(\.level), ["warn", "error"])
        XCTAssertEqual(log.recent(limit: 99, minLevel: "debug").count, 4)
        // A typo in a filter box shows everything rather than pretending the
        // client logged nothing.
        XCTAssertEqual(log.recent(limit: 99, minLevel: "verbose").count, 4)
    }

    func test_a_line_below_the_installed_level_is_never_captured() {
        log.setMaxLevel(.info)
        log.record(level: .debug, target: "gate", message: "hidden")
        XCTAssertEqual(log.stats().retained, 0)
        XCTAssertEqual(log.stats().debug, 0)
        log.record(level: .error, target: "gate", message: "seen")
        XCTAssertEqual(log.stats().retained, 1)
    }

    func test_the_shared_ring_is_the_one_the_snapshot_reads() {
        // The Rust side installs a process-global backend; the Apple side has a
        // process-global instance. Either way a module must not be able to log
        // somewhere the diagnostics screen cannot look.
        CoreLog.shared.forwardsToSystemLog = false
        CoreLog.shared.reset()
        CoreLog.shared.info("KomgaStore", "wired through the shared ring")
        XCTAssertEqual(CoreLog.shared.stats().retained, 1)
        CoreLog.shared.reset()
        XCTAssertEqual(CoreLog.shared.stats().retained, 0)
    }
}

// MARK: - The store's own account of itself

final class DatabaseHealthTests: XCTestCase {
    func test_a_fresh_store_reports_the_schema_it_ships_and_an_intact_file() throws {
        let store = try KomgaStore()
        let health = try store.databaseHealth()
        XCTAssertEqual(health.schemaVersion, Schema.currentVersion)
        XCTAssertEqual(health.integrity, "ok")
        XCTAssertGreaterThan(health.pageSize, 0)
        XCTAssertEqual(health.fileBytes, health.pageSize * health.pageCount)
        XCTAssertTrue(health.foreignKeysOn, "the store opened without FK enforcement")
    }

    func test_the_download_tables_are_in_the_report_even_with_no_writer_for_them() throws {
        let tables = try KomgaStore().userTables()
        for name in ["downloads", "download_pages", "cache_entries", "series"] {
            XCTAssertTrue(tables.contains(name), "\(name) missing from the report")
        }
    }

    func test_fts_shadow_tables_are_folded_away_but_the_index_itself_is_counted() throws {
        let tables = try KomgaStore().userTables()
        XCTAssertTrue(tables.contains("series_fts"))
        for suffix in KomgaStore.ftsShadowSuffixes {
            XCTAssertFalse(
                tables.contains { $0.hasSuffix(suffix) },
                "a shadow table survived the filter: \(suffix)"
            )
        }
    }

    func test_row_counts_move_when_the_mirror_grows() throws {
        let store = try KomgaStore()
        let before = try store.tableCounts().first { $0.table == "series" }?.rows ?? -1
        XCTAssertEqual(before, 0)
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO servers (id, display_name, base_url, auth_type, credential_ref)
                VALUES ('s1','S','http://x','apiKey','ref')
                """
            )
            try db.execute(
                sql: "INSERT INTO series (server_id, remote_id, library_id, name) VALUES ('s1','r1','l1','A')"
            )
        }
        let after = try store.tableCounts().first { $0.table == "series" }?.rows ?? -1
        XCTAssertEqual(after, before + 1)
    }

    func test_a_missing_table_reads_as_nil_rather_than_an_error() throws {
        let store = try KomgaStore()
        let found = try store.dbQueue.read { db in
            try KomgaStore.countRowsIfTable(db: db, table: "series")
        }
        XCTAssertEqual(found, 0)
        let missing = try store.dbQueue.read { db in
            try KomgaStore.countRowsIfTable(db: db, table: "not_a_table")
        }
        // No rows and no table at all are different facts, and a diagnostic that
        // conflates them would hide a schema that never migrated.
        XCTAssertNil(missing)
    }
}

// MARK: - The credential verdict

final class AuthStateTests: XCTestCase {
    func test_a_server_never_spoken_to_is_unknown_rather_than_expired() throws {
        let report = try KomgaStore().credentialState(serverID: "s1")
        XCTAssertEqual(report.state, .unknown)
        XCTAssertNil(report.at)
    }

    func test_a_rejection_says_expired_and_keeps_the_moment_it_happened() throws {
        let store = try KomgaStore()
        let state = try store.noteCredential(
            serverID: "s1",
            verdict: .rejected,
            at: "2026-08-31T12:04:00.000Z"
        )
        XCTAssertEqual(state, .expired)
        let report = try store.credentialState(serverID: "s1")
        XCTAssertEqual(report.state, .expired)
        XCTAssertEqual(report.at, "2026-08-31T12:04:00.000Z")
    }

    func test_a_later_acceptance_is_what_clears_an_expiration() throws {
        let store = try KomgaStore()
        try store.noteCredential(serverID: "s1", verdict: .rejected, at: "t1")
        XCTAssertEqual(try store.noteCredential(serverID: "s1", verdict: .accepted, at: "t2"), .valid)
        let report = try store.credentialState(serverID: "s1")
        XCTAssertEqual(report.state, .valid)
        // The timestamp moves with the verdict, or a stale "expired at t1" would
        // sit beside a valid state and make the banner unreadable.
        XCTAssertEqual(report.at, "t2")
    }

    func test_two_servers_hold_two_independent_verdicts() throws {
        let store = try KomgaStore()
        try store.noteCredential(serverID: "s1", verdict: .rejected, at: "t1")
        try store.noteCredential(serverID: "s2", verdict: .accepted, at: "t1")
        XCTAssertEqual(try store.credentialState(serverID: "s1").state, .expired)
        XCTAssertEqual(try store.credentialState(serverID: "s2").state, .valid)
        try store.clearCredentialState(serverID: "s1")
        XCTAssertEqual(try store.credentialState(serverID: "s1").state, .unknown)
        XCTAssertEqual(try store.credentialState(serverID: "s2").state, .valid)
    }

    func test_a_note_this_build_cannot_read_is_unknown_not_expired() throws {
        let store = try KomgaStore()
        // Only this code writes the key, so arriving here means another era's
        // build left it: fall back to "ask the server".
        try store.putAppStateValue(
            key: KomgaStore.credentialKey(serverID: "s1"),
            value: "not json"
        )
        XCTAssertEqual(try store.credentialState(serverID: "s1").state, .unknown)
        try store.putAppStateValue(
            key: KomgaStore.credentialKey(serverID: "s2"),
            value: "{\"state\":\"revoked\",\"at\":\"t\"}"
        )
        XCTAssertEqual(try store.credentialState(serverID: "s2").state, .unknown)
    }

    func test_clearing_a_verdict_leaves_the_active_server_pick_alone() throws {
        let store = try KomgaStore()
        try store.setActiveServer(id: "s1")
        try store.noteCredential(serverID: "s1", verdict: .rejected, at: "t1")
        try store.clearCredentialState(serverID: "s1")
        XCTAssertEqual(try store.activeServerID(), "s1")
    }
}

// MARK: - The aggregate

final class DiagnosticsSnapshotTests: XCTestCase {
    func test_the_snapshot_exposes_every_field_the_contract_names() throws {
        struct Fields: Decodable {
            let fields: [String]
        }

        let fixture: Fields = try loadFixture("diagnostics/snapshot.json")
        XCTAssertFalse(fixture.fields.isEmpty, "an empty contract proves nothing")

        let store = try KomgaStore()
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO servers (id, display_name, base_url, auth_type, credential_ref)
                VALUES ('s1','S','http://x','apiKey','ref')
                """
            )
            // The queue paths can only be checked against a queue with a row in
            // it: an empty JSON array contributes no element paths, so reading
            // the shape empty would let the gate pass by omitting the check.
            try db.execute(
                sql: """
                INSERT INTO downloads (server_id, book_id, state, pages_total, pages_done,
                                      bytes_total, bytes_done)
                VALUES ('s1','b1','queued',10,1,100,10)
                """
            )
            try db.execute(
                sql: """
                INSERT INTO cache_entries (key, kind, path, size, last_access)
                VALUES ('k1','page','/tmp/k1',10,'now')
                """
            )
            try db.execute(
                sql: """
                INSERT INTO sync_state (server_id, entity_type, last_sync_at,
                                        sync_cursor, sync_status)
                VALUES ('s1','series','now','page=3','error')
                """
            )
        }
        try store.noteCredential(serverID: "s1", verdict: .rejected, at: "t1")
        CoreLog.shared.forwardsToSystemLog = false
        CoreLog.shared.reset()
        CoreLog.shared.warning("KomgaStore", "a line the snapshot has to count")

        let snapshot = try store.diagnosticsSnapshot(serverID: "s1")
        let data = try JSONEncoder().encode(snapshot)
        var paths = Set<String>()
        flatten(try JSONDecoder().decode(JSONNode.self, from: data), "", into: &paths)

        for path in fixture.fields {
            XCTAssertTrue(
                paths.contains(path),
                "the contract names `\(path)` but this build's snapshot has no such field"
            )
        }

        // The shape that crossed is the shape the Rust side named: the queue
        // numbers came out of the seeded row, not out of the encoder.
        XCTAssertEqual(snapshot.queue.count, 1)
        XCTAssertEqual(snapshot.queue[0].state, "queued")
        XCTAssertEqual(snapshot.queue[0].bytesDone, 10)
        XCTAssertEqual(snapshot.cache.pageBytes, 10)
        XCTAssertEqual(snapshot.auth.state, "expired")
        XCTAssertEqual(snapshot.log.warnings, 1)
        XCTAssertEqual(snapshot.outboxQueuedRows, 0)
        XCTAssertEqual(snapshot.policy.contractVersion, KomgaContract.contractVersion)
        XCTAssertEqual(snapshot.policy.minServerVersion, "1.26.0")
        XCTAssertTrue(paths.contains("db.busyTimeoutMs"))
        XCTAssertFalse(
            paths.contains { $0.contains("_") },
            "a snake_case field leaked into the contract shape"
        )
    }

    func test_reading_the_snapshot_changes_nothing_it_reports() throws {
        let store = try KomgaStore()
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO cache_entries (key, kind, path, size, last_access)
                VALUES ('k1','prefetch','/tmp/k1',7,'now')
                """
            )
        }
        let first = try store.diagnosticsSnapshot(serverID: "s1")
        let second = try store.diagnosticsSnapshot(serverID: "s1")
        XCTAssertEqual(first, second, "asking the question changed the answer")
        XCTAssertEqual(second.cache.prefetchBytes, 7)
    }
}
