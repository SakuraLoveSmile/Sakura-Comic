import XCTest
import GRDB
@testable import KomgaStore
@testable import KomgaSync

/// Stage 6 acceptance gate: both platforms replay the SAME JSON from
/// `specs/contracts/fixtures/outbox/`, so the Outbox state machine, the
/// retry/backoff schedule and the R1-R6 conflict rules are one shared contract
/// rather than two suites that could drift. Mirror of the Rust
/// `store::outbox::contract_tests`.
final class OutboxContractTests: XCTestCase {
    private let serverID = "A"

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/outbox")
            .standardizedFileURL
    }

    private func load<T: Decodable>(_ name: String) throws -> T {
        let data = try Data(contentsOf: fixtureURL.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Fixture shapes

    /// A JSON tree, so a wire body can be compared structurally against the
    /// fixture's own object form (key order is not part of the contract).
    private enum JSONValue: Decodable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Double.self) { self = .number(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
            if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value"
            )
        }

        static func parse(_ text: String?) -> JSONValue? {
            guard let text, let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    private struct ConflictFixture: Decodable {
        var decisions: [String]
        var cases: [ConflictCase]
    }

    private struct ConflictCase: Decodable {
        var name: String
        var intent: IntentJSON
        var localUpdatedAt: String
        var refetch: RefetchJSON
        var expected: ExpectedConflict

        enum CodingKeys: String, CodingKey {
            case name, intent, refetch, expected
            case localUpdatedAt = "local_updated_at"
        }
    }

    private struct IntentJSON: Decodable {
        var type: String
        var page: Int64?
        var completed: Bool?
    }

    private struct RefetchJSON: Decodable {
        var status: Int
        var page: Int64?
        var completed: Bool?
        var progressLastModified: String?
        var mediaType: String?

        enum CodingKeys: String, CodingKey {
            case status, page, completed, mediaType
            case progressLastModified = "progressLastModified"
        }
    }

    private struct ExpectedConflict: Decodable {
        var decision: String
        var packets: [PacketJSON]
        var effect: EffectJSON?

        enum CodingKeys: String, CodingKey {
            case decision, packets, effect
        }
    }

    private struct PacketJSON: Decodable {
        var method: String
        var path: String
        var body: JSONValue?
    }

    private struct EffectJSON: Decodable {
        var retryCount: String?
        var state: String?
        var runStatus: String?
        var nextRetryAt: String?
        var row: String?

        enum CodingKeys: String, CodingKey {
            case retryCount = "retry_count"
            case state
            case runStatus = "run_status"
            case nextRetryAt = "next_retry_at"
            case row
        }
    }

    private struct BackoffFixture: Decodable {
        var policy: Policy
        var schedule: [ScheduleRow]
        var outcomeClasses: [OutcomeClass]
        var cases: [BackoffCase]

        enum CodingKeys: String, CodingKey {
            case policy, schedule, cases
            case outcomeClasses = "outcome_classes"
        }
    }

    private struct Policy: Decodable {
        var baseSeconds: Int64
        var maxSeconds: Int64
        var maxAttempts: Int64

        enum CodingKeys: String, CodingKey {
            case baseSeconds = "base_seconds"
            case maxSeconds = "max_seconds"
            case maxAttempts = "max_attempts"
        }
    }

    private struct ScheduleRow: Decodable {
        var retryCount: Int64
        var delaySeconds: Int64

        enum CodingKeys: String, CodingKey {
            case retryCount = "retry_count"
            case delaySeconds = "delay_seconds"
        }
    }

    private struct OutcomeClass: Decodable {
        var name: String
        var result: ResultJSON
        var effect: EffectJSON

        enum CodingKeys: String, CodingKey {
            case name, result, effect
        }
    }

    private struct ResultJSON: Decodable {
        var kind: String
        var status: Int?
    }

    private struct BackoffCase: Decodable {
        var name: String
        var start: RowState?
        var dueChecks: [DueCheck]?
        var failures: [String]?
        var expected: ExpectedRow?
        var manualRetry: ManualRetry?
        var policyProbe: PolicyProbe?

        enum CodingKeys: String, CodingKey {
            case name, start, expected, failures
            case dueChecks = "due_checks"
            case manualRetry = "manual_retry"
            case policyProbe = "policy_probe"
        }
    }

    private struct PolicyProbe: Decodable {
        var retryCount: Int64

        enum CodingKeys: String, CodingKey {
            case retryCount = "retry_count"
        }
    }

    private struct ManualRetry: Decodable {
        var op: String
        var entity: String
        var now: String
    }

    private struct RowState: Decodable {
        var state: String
        var retryCount: Int64
        var nextRetryAt: String?

        enum CodingKeys: String, CodingKey {
            case state
            case retryCount = "retry_count"
            case nextRetryAt = "next_retry_at"
        }
    }

    private struct DueCheck: Decodable {
        var now: String
        var due: Bool
    }

    private struct ExpectedRow: Decodable {
        var state: String?
        var retryCount: Int64?
        var nextRetryAt: String?
        var lastError: String?
        var delaySeconds: Int64?
        var row: String?

        enum CodingKeys: String, CodingKey {
            case state, row
            case retryCount = "retry_count"
            case nextRetryAt = "next_retry_at"
            case lastError = "last_error"
            case delaySeconds = "delay_seconds"
        }
    }

    private struct CoalescingFixture: Decodable {
        var family: [String]
        var cases: [CoalescingCase]
    }

    private struct CoalescingCase: Decodable {
        var name: String
        var steps: [Step]
        var expected: ExpectedQueue
    }

    private struct Step: Decodable {
        var op: String
        var entity: String
        var type: String?
        var page: Int64?
        var completed: Bool?
        var retryCount: Int64?
        var state: String?
        var error: String?

        enum CodingKeys: String, CodingKey {
            case op, entity, type, page, completed, state, error
            case retryCount = "retry_count"
        }
    }

    private struct ExpectedQueue: Decodable {
        var queue: [QueuedJSON]
    }

    private struct QueuedJSON: Decodable {
        var type: String
        var entity: String
        var page: Int64?
        var completed: Bool?
        var state: String?
        var retryCount: Int64?

        enum CodingKeys: String, CodingKey {
            case type, entity, page, completed, state
            case retryCount = "retry_count"
        }
    }

    // MARK: - Helpers

    /// The fixture's `refetch` object as the uploader would have seen it.
    private func refetch(of value: RefetchJSON) -> Refetch {
        switch value.status {
        case 200:
            return .found(
                RemoteProgress(
                    page: value.page,
                    completed: value.completed ?? false,
                    lastModified: value.progressLastModified,
                    mediaType: value.mediaType
                )
            )
        case 404, 410: return .notFound
        case 401, 403: return .unauthorized
        default: return .unreachable
        }
    }

    private func intent(of value: IntentJSON) throws -> Intent {
        switch value.type {
        case "MARK_READ": return .markRead
        case "MARK_UNREAD": return .markUnread
        case "READ_PROGRESS":
            return .progress(page: value.page, completed: value.completed ?? false)
        case let other:
            throw FixtureError(message: "fixture intent \(other) is not one of the three known kinds")
        }
    }

    /// Seed one outbox row exactly as the fixture describes it.
    private func seed(
        _ store: KomgaStore,
        id: String = "m-1",
        entity: String = "book-1",
        mutationType: String = "READ_PROGRESS",
        payload: String = "{}",
        createdAt: String = "2026-08-28T10:00:00Z",
        retryCount: Int64,
        state: String,
        nextRetryAt: String? = nil,
        lastError: String? = nil
    ) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO pending_mutations (id, server_id, entity_id, mutation_type, payload,
                                               created_at, retry_count, state, next_retry_at, last_error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [id, serverID, entity, mutationType, payload, createdAt, retryCount, state, nextRetryAt, lastError]
            )
        }
    }

    private func markFailed(
        _ store: KomgaStore,
        entity: String,
        retryCount: Int64,
        state: String,
        error: String?
    ) throws {
        try store.dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_mutations SET retry_count = ?, state = ?, last_error = ?
                 WHERE entity_id = ?
                """,
                arguments: [retryCount, state, error, entity]
            )
        }
    }

    // MARK: - conflict.json

    /// R1-R6, including the two cases that prove this is not `max(page)`.
    func testConflictRulesMatchTheSharedFixture() throws {
        let fixture: ConflictFixture = try load("conflict.json")
        XCTAssertGreaterThanOrEqual(
            fixture.cases.count, 10,
            "the conflict fixture lost cases: \(fixture.cases.count)"
        )
        for case_ in fixture.cases {
            let intent = try intent(of: case_.intent)
            let decision = decide(
                bookID: "book-1",
                intent: intent,
                localUpdatedAt: case_.localUpdatedAt,
                refetch: refetch(of: case_.refetch)
            )
            let label = "case \(case_.name)"
            XCTAssertEqual(fixture.decisions.contains(decision.fixtureName), true, "\(label): unknown decision")
            XCTAssertEqual(decision.fixtureName, case_.expected.decision, label)

            switch decision {
            case .upload(let request):
                let packet = try XCTUnwrap(
                    case_.expected.packets.first, "\(label): an upload must send exactly one packet"
                )
                XCTAssertEqual(case_.expected.packets.count, 1, label)
                XCTAssertEqual(request.method.rawValue, packet.method, label)
                XCTAssertEqual(request.path, packet.path, label)
                // The fixture spells "no body" as `null`; we spell it as nil.
                let expectedBody = packet.body == .null ? nil : packet.body
                XCTAssertEqual(JSONValue.parse(request.body), expectedBody, label)
            case .deferred(let penalised):
                let wantsPenalty = case_.expected.effect?.retryCount == "+1"
                XCTAssertEqual(penalised, wantsPenalty, "\(label) (penalised=\(wantsPenalty))")
            default:
                XCTAssertEqual(case_.expected.packets.isEmpty, true, "\(label): decided without sending nothing")
            }
        }
    }

    /// No fixture case may be decided by comparing page numbers — the machine
    /// check for 「不能统一采用 max(page)」.
    func testTheLosingSideIsNeverChosenBecauseItsPageIsBigger() {
        // Same two stamps, page order reversed: the decision must not flip.
        for (localPage, remotePage) in [(3, 90), (90, 3)] {
            let decision = decide(
                bookID: "b",
                intent: .progress(page: Int64(localPage), completed: false),
                localUpdatedAt: "2026-08-28T11:00:00Z",
                refetch: .found(
                    RemoteProgress(page: Int64(remotePage), completed: false, lastModified: "2026-08-28T10:00:00Z")
                )
            )
            XCTAssertEqual(
                decision.fixtureName, "upload",
                "page \(localPage) vs remote \(remotePage) must be decided by time, not size"
            )
        }
        // And the mirror image: a later remote action wins whatever the pages are.
        for (localPage, remotePage) in [(90, 3), (3, 90)] {
            XCTAssertEqual(
                decide(
                    bookID: "b",
                    intent: .progress(page: Int64(localPage), completed: false),
                    localUpdatedAt: "2026-08-28T10:00:00Z",
                    refetch: .found(RemoteProgress(page: Int64(remotePage), completed: false, lastModified: "2026-08-28T11:00:00Z"))
                ).fixtureName,
                "drop_remote_wins",
                "page order must not decide R4"
            )
        }
    }

    /// An explicit mark outranks a strictly newer remote passive value — and
    /// `MARK_UNREAD` is the case where `max(page)` would have swallowed it.
    func testExplicitMarksAreUploadedUnconditionally() {
        let newerRemote = Refetch.found(
            RemoteProgress(page: 50, completed: true, lastModified: "2026-08-28T11:00:00Z")
        )
        XCTAssertEqual(
            decide(bookID: "b1", intent: .markRead, localUpdatedAt: "2026-08-28T10:00:00Z", refetch: newerRemote),
            .upload(WireRequest(method: .patch, path: "/api/v1/books/b1/read-progress", body: "{\"completed\":true}"))
        )
        XCTAssertEqual(
            decide(bookID: "b1", intent: .markUnread, localUpdatedAt: "2026-08-28T10:00:00Z", refetch: newerRemote),
            .upload(WireRequest(method: .delete, path: "/api/v1/books/b1/read-progress", body: nil))
        )
    }

    /// `fixtures/outbox/conflict.json#after_success`: a confirmed write clears
    /// the queue row and the local flags, and never guesses a server stamp.
    func testAfterSuccessClearsTheLocalRowWithoutAGuessedStamp() throws {
        let store = try KomgaStore()
        try store.setReadProgress(serverID: serverID, bookID: "book-1", page: 7, completed: false)
        try store.upsertSyncedReadProgress(
            serverID: serverID, bookID: "book-1", page: 3, completed: false,
            serverUpdatedAt: "2026-08-28T09:00:00Z"
        )
        try store.forget(serverID: serverID, bookID: "book-1")

        XCTAssertTrue(try store.allOutboxEntries(serverID: serverID).isEmpty, "outbox_row = deleted")
        let row = try readProgressRow(store, "book-1")
        XCTAssertEqual(row.pending, false, "read_progress.mutation_pending = 0")
        XCTAssertNil(row.serverUpdatedAt, "read_progress.server_updated_at = null")
    }

    private func readProgressRow(_ store: KomgaStore, _ bookID: String) throws -> (page: Int64?, completed: Bool, pending: Bool, serverUpdatedAt: String?, localUpdatedAt: String?) {
        try store.dbQueue.read { db in
            let raw = try XCTUnwrap(
                Row.fetchOne(
                    db,
                    sql: "SELECT page, completed, mutation_pending, server_updated_at, local_updated_at FROM read_progress WHERE server_id = ? AND book_id = ?",
                    arguments: [serverID, bookID]
                )
            )
            let page: Int64? = raw["page"]
            let completed: Int = raw["completed"]
            let pending: Int = raw["mutation_pending"]
            let serverUpdatedAt: String? = raw["server_updated_at"]
            let localUpdatedAt: String? = raw["local_updated_at"]
            return (page, completed != 0, pending != 0, serverUpdatedAt, localUpdatedAt)
        }
    }

    // MARK: - backoff.json

    /// Both platforms read the policy from the fixture rather than hardcoding a
    /// private opinion about it.
    func testBackoffPolicyMatchesTheFixture() throws {
        let fixture: BackoffFixture = try load("backoff.json")
        XCTAssertEqual(fixture.policy.baseSeconds, OutboxPolicy.baseSeconds)
        XCTAssertEqual(fixture.policy.maxSeconds, OutboxPolicy.maxSeconds)
        XCTAssertEqual(fixture.policy.maxAttempts, OutboxPolicy.maxAttempts)
        for row in fixture.schedule {
            XCTAssertEqual(
                outboxBackoffSeconds(row.retryCount), row.delaySeconds,
                "retry_count \(row.retryCount)"
            )
        }
        // The cap holds far past the schedule table.
        XCTAssertEqual(outboxBackoffSeconds(30), OutboxPolicy.maxSeconds)
        XCTAssertFalse(fixture.cases.isEmpty, "the backoff fixture lost its cases")
    }

    /// Every documented result class, replayed against a real row.
    func testOutcomeClassesMatchTheFixture() throws {
        let fixture: BackoffFixture = try load("backoff.json")
        for outcome in fixture.outcomeClasses {
            let attempt: Attempt
            switch outcome.result.kind {
            case "network": attempt = .retryable
            case "server":
                attempt = Attempt.from(statusCode: try XCTUnwrap(outcome.result.status, outcome.name))
            case "gone": attempt = .gone
            case "authentication": attempt = .blockedAuthentication
            default: throw FixtureError(message: "unknown outcome class \(outcome.result.kind)")
            }
            let store = try KomgaStore()
            try seed(store, retryCount: 2, state: OutboxFamily.pending, nextRetryAt: "2026-08-28T10:00:08Z")
            let before = try XCTUnwrap(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"))
            try store.recordOutcome(entry: before, attempt: attempt, now: "2026-08-28T10:00:00Z", error: outcome.result.status.map(String.init) ?? outcome.result.kind)

            switch outcome.effect.row {
            case "deleted":
                XCTAssertNil(
                    try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"),
                    "\(outcome.name): the row must be gone"
                )
                continue
            default: break
            }
            let after = try XCTUnwrap(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"))
            if outcome.effect.retryCount == "+1" {
                XCTAssertEqual(after.retryCount, before.retryCount + 1, outcome.name)
            } else {
                XCTAssertEqual(after.retryCount, before.retryCount, "\(outcome.name): not a retry")
            }
            if outcome.effect.state != "unchanged" {
                XCTAssertEqual(after.state, outcome.effect.state, outcome.name)
            } else {
                XCTAssertEqual(after.state, before.state, outcome.name)
            }
            switch outcome.effect.nextRetryAt {
            case "null":
                XCTAssertNil(after.nextRetryAt, outcome.name)
            case "now + backoff(retry_count)":
                XCTAssertEqual(
                    after.nextRetryAt,
                    outboxNextRetryAt(now: "2026-08-28T10:00:00Z", retryCount: after.retryCount),
                    outcome.name
                )
            default:
                XCTAssertEqual(after.nextRetryAt, before.nextRetryAt, "\(outcome.name): schedule untouched")
            }
            if outcome.effect.runStatus == "blocked_authentication" {
                XCTAssertEqual(attempt, .blockedAuthentication, outcome.name)
            }
        }
    }

    /// The fixture's own cases, replayed in order.
    func testBackoffCasesMatchTheFixture() throws {
        let fixture: BackoffFixture = try load("backoff.json")
        for testCase in fixture.cases {
            if let probe = testCase.policyProbe {
                XCTAssertEqual(
                    outboxBackoffSeconds(probe.retryCount),
                    try XCTUnwrap(testCase.expected?.delaySeconds),
                    testCase.name
                )
                continue
            }
            let store = try KomgaStore()
            let start = try XCTUnwrap(testCase.start, testCase.name)
            try seed(
                store,
                retryCount: start.retryCount,
                state: start.state,
                nextRetryAt: start.nextRetryAt
            )
            for failure in testCase.failures ?? [] {
                let entry = try XCTUnwrap(
                    try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"),
                    testCase.name
                )
                let attempt: Attempt
                switch failure {
                case "network": attempt = .retryable
                case "server-503": attempt = Attempt.from(statusCode: 503)
                default: throw FixtureError(message: "unknown failure \(failure)")
                }
                try store.recordOutcome(entry: entry, attempt: attempt, now: entry.createdAt, error: failure)
            }
            for check in testCase.dueChecks ?? [] {
                XCTAssertEqual(
                    try store.dueOutboxEntries(serverID: serverID, now: check.now).isEmpty == false,
                    check.due,
                    "\(testCase.name): due check at \(check.now)"
                )
            }
            if let retry = testCase.manualRetry {
                XCTAssertEqual(retry.op, "retry_failed", testCase.name)
                XCTAssertEqual(
                    try store.retryFailed(serverID: serverID, bookID: retry.entity), 1,
                    testCase.name
                )
            }
            let expected = try XCTUnwrap(testCase.expected, testCase.name)
            let stored = try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1")
            if expected.row == "deleted" {
                XCTAssertNil(stored, testCase.name)
                continue
            }
            let actual = try XCTUnwrap(stored, testCase.name)
            if let state = expected.state { XCTAssertEqual(actual.state, state, testCase.name) }
            if let retryCount = expected.retryCount { XCTAssertEqual(actual.retryCount, retryCount, testCase.name) }
            XCTAssertEqual(actual.nextRetryAt, expected.nextRetryAt, testCase.name)
            if expected.lastError == nil, testCase.manualRetry != nil {
                XCTAssertNil(actual.lastError, "\(testCase.name): last_error must be cleared")
            }
        }
    }

    /// A restart must not buy the queue a fresh head start: the deadline is an
    /// absolute stamp in the database, not a timer in memory.
    func testAbsoluteDeadlineSurvivesARestart() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("komga-outbox-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: temp) }

        do {
            let store = try KomgaStore(path: temp.path)
            try seed(store, retryCount: 3, state: OutboxFamily.pending, nextRetryAt: "2026-08-28T10:01:04Z")
        }
        let store = try KomgaStore(path: temp.path) // what an app relaunch gets
        let stored = try store.allOutboxEntries(serverID: serverID)
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored[0].retryCount, 3)
        XCTAssertEqual(stored[0].nextRetryAt, "2026-08-28T10:01:04Z")
        for (now, due) in [
            ("2026-08-28T10:00:31Z", false),
            ("2026-08-28T10:01:03Z", false),
            ("2026-08-28T10:01:04Z", true),
        ] {
            XCTAssertEqual(
                try store.dueOutboxEntries(serverID: serverID, now: now).isEmpty == false,
                due,
                "due check at \(now)"
            )
        }
    }

    /// Eight retryable failures and the row stops asking for the network; a new
    /// user action revives it with the counter reset.
    func testRetryableFailuresWalkIntoFailed() throws {
        let store = try KomgaStore()
        try seed(store, retryCount: 0, state: OutboxFamily.pending)
        var now = "2026-08-28T10:00:00Z"
        for attempt in 1...7 {
            let entry = try XCTUnwrap(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"))
            try store.recordOutcome(entry: entry, attempt: .retryable, now: now, error: "503")
            let stored = try XCTUnwrap(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"))
            XCTAssertEqual(stored.retryCount, Int64(attempt))
            XCTAssertEqual(stored.state, OutboxFamily.pending)
            XCTAssertEqual(
                stored.nextRetryAt, outboxNextRetryAt(now: now, retryCount: Int64(attempt)),
                "attempt \(attempt) must be scheduled by the shared schedule"
            )
            // Time travel: only after the deadline is the row due again.
            XCTAssertEqual(try store.dueOutboxEntries(serverID: serverID, now: now).count, 0)
            now = try XCTUnwrap(stored.nextRetryAt)
            XCTAssertEqual(try store.dueOutboxEntries(serverID: serverID, now: now).count, 1)
        }
        let entry = try XCTUnwrap(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"))
        try store.recordOutcome(entry: entry, attempt: .retryable, now: now, error: "503")
        let failed = try XCTUnwrap(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"))
        XCTAssertEqual(failed.state, OutboxFamily.failed)
        XCTAssertEqual(failed.retryCount, OutboxPolicy.maxAttempts)
        XCTAssertNil(failed.nextRetryAt)
        XCTAssertNil(
            try store.dueOutboxEntries(serverID: serverID, now: "2030-01-01T00:00:00Z").first,
            "a failed row must never come back on its own"
        )
        XCTAssertEqual(try store.outboxCounts(serverID: serverID, now: now).failed, 1)

        // A new user action revives it (coalescing replaces the row).
        try store.setReadProgress(serverID: serverID, bookID: "book-1", page: 12, completed: false)
        let revived = try XCTUnwrap(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"))
        XCTAssertEqual(revived.state, OutboxFamily.pending)
        XCTAssertEqual(revived.retryCount, 0)
    }

    // MARK: - coalescing.json

    /// The queue is written through the production entry points, so this also
    /// proves `enqueueMutation` really does coalesce.
    func testCoalescingMatchesTheSharedFixture() throws {
        let fixture: CoalescingFixture = try load("coalescing.json")
        XCTAssertEqual(
            fixture.family, OutboxFamily.all,
            "the fixture family list must match the code"
        )
        for testCase in fixture.cases {
            let store = try KomgaStore()
            for step in testCase.steps {
                switch step.op {
                case "enqueue":
                    switch try XCTUnwrap(step.type, "\(testCase.name): enqueue step without a type") {
                    case "MARK_READ": try store.markRead(serverID: serverID, bookID: step.entity)
                    case "MARK_UNREAD": try store.markUnread(serverID: serverID, bookID: step.entity)
                    case "READ_PROGRESS":
                        try store.setReadProgress(
                            serverID: serverID, bookID: step.entity,
                            page: step.page ?? 0, completed: step.completed ?? false
                        )
                    case let other: throw FixtureError(message: "fixture enqueue type \(other) is unknown")
                    }
                case "fail_outbox":
                    try markFailed(
                        store, entity: step.entity,
                        retryCount: step.retryCount ?? OutboxPolicy.maxAttempts,
                        state: step.state ?? OutboxFamily.pending,
                        error: step.error
                    )
                default: throw FixtureError(message: "unknown fixture op \(step.op)")
                }
            }
            let queued = try store.allOutboxEntries(serverID: serverID)
            XCTAssertEqual(
                queued.count, testCase.expected.queue.count,
                "\(testCase.name) left the wrong number of rows: \(queued.map { "\($0.entityID):\($0.mutationType)" })"
            )
            // `created_at` only carries milliseconds, so two rows enqueued in the
            // same millisecond tie-break on their random id. The contract is
            // per-entity, so pair by entity instead of by position.
            for want in testCase.expected.queue {
                let got = try XCTUnwrap(
                    queued.first { $0.entityID == want.entity },
                    "\(testCase.name): no row queued for \(want.entity)"
                )
                XCTAssertEqual(got.mutationType, want.type, testCase.name)
                if let page = want.page {
                    XCTAssertTrue(
                        got.payload.contains("\"page\":\(page)"),
                        "\(testCase.name): payload lost the newest page: \(got.payload)"
                    )
                }
                if let completed = want.completed {
                    XCTAssertTrue(
                        got.payload.contains("\"completed\":\(completed ? "true" : "false")"),
                        "\(testCase.name): payload lost the newest completed flag: \(got.payload)"
                    )
                }
                if let state = want.state { XCTAssertEqual(got.state, state, testCase.name) }
                if let retryCount = want.retryCount { XCTAssertEqual(got.retryCount, retryCount, testCase.name) }
            }
        }
    }

    /// Coalescing is scoped to one server: two servers mirroring the same book
    /// id never collapse into each other.
    func testCoalescingNeverCrossesServers() throws {
        let store = try KomgaStore()
        try store.setReadProgress(serverID: "A", bookID: "book-1", page: 2, completed: false)
        try store.setReadProgress(serverID: "B", bookID: "book-1", page: 5, completed: false)
        XCTAssertEqual(try store.allOutboxEntries(serverID: "A").count, 1)
        XCTAssertEqual(try store.allOutboxEntries(serverID: "B").count, 1)
    }

    // MARK: - The uploader itself (sync/upload.rs mirror)

    func testUploaderProcessesEachDecisionAndStopsOnBlockedCredentials() async throws {
        let store = try KomgaStore()
        // Three books, three different verdicts from the same re-fetch script.
        // Seeded one second apart: `created_at` only has millisecond precision,
        // and this test needs the queue order to be the one the user produced.
        for (index, bookID) in ["book-1", "book-2", "book-3"].enumerated() {
            try seedQueued(
                store, bookID: bookID, page: 30,
                actionAt: "2026-08-28T10:0\(5 + index):00Z"
            )
        }

        let writer = ScriptedWriter(
            refetches: [
                "book-1": .found(RemoteProgress(page: 5, completed: false, lastModified: "2026-08-28T09:00:00Z")),
                // R4: strictly later remote action.
                "book-2": .found(RemoteProgress(page: 3, completed: false, lastModified: "2026-08-28T11:00:00Z")),
                "book-3": .unauthorized,
            ],
            attempts: [.succeeded]
        )
        let summary = try await OutboxUpload.run(store: store, serverID: serverID, writer: writer, now: "2026-08-28T12:00:00Z")

        XCTAssertEqual(summary.considered, 3)
        XCTAssertEqual(summary.uploaded, 1)
        XCTAssertEqual(summary.remoteWins, 1)
        XCTAssertEqual(summary.status, .blockedAuthentication)
        let sent = await writer.requests
        XCTAssertEqual(sent.count, 1, "only the winning row may spend a request")
        XCTAssertEqual(sent.first?.method, .patch)
        XCTAssertEqual(sent.first?.path, "/api/v1/books/book-1/read-progress")
        XCTAssertEqual(sent.first?.body, "{\"page\":30,\"completed\":false}")

        XCTAssertNil(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"))
        XCTAssertNil(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-2"))
        // The deferred row is untouched: no penalty for somebody else's 401.
        let deferred = try XCTUnwrap(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-3"))
        XCTAssertEqual(deferred.retryCount, 0)
        XCTAssertEqual(deferred.state, OutboxFamily.pending)
        XCTAssertNil(deferred.nextRetryAt)
    }

    /// Rule R6 with a transport failure: the row is penalised and rescheduled,
    /// never written blind.
    func testUnreachableRefetchDefersWithAPenaltyAndSendsNothing() async throws {
        let store = try KomgaStore()
        try seedQueued(store, bookID: "book-1", page: 30, actionAt: "2026-08-28T10:05:00Z")
        let writer = ScriptedWriter(refetches: ["book-1": .unreachable], attempts: [])
        let summary = try await OutboxUpload.run(store: store, serverID: serverID, writer: writer, now: "2026-08-28T12:00:00Z")

        XCTAssertEqual(summary.retried, 1)
        XCTAssertEqual(summary.status, .complete)
        let nothingSent = await writer.requests
        XCTAssertTrue(nothingSent.isEmpty)
        let entry = try XCTUnwrap(try store.queuedOutboxEntry(serverID: serverID, bookID: "book-1"))
        XCTAssertEqual(entry.retryCount, 1)
        XCTAssertEqual(entry.nextRetryAt, "2026-08-28T12:00:02Z", "now + backoff(1)")
        XCTAssertEqual(entry.lastError, "refetch failed")
    }

    /// A scripted server whose replies are set per book, so the uploader's
    /// ordering and early-stop behaviour are observable.
    private actor ScriptedWriter: ProgressWriting {
        private let refetches: [String: Refetch]
        private let books: [String: BookOutcome]
        private var remainingAttempts: [Attempt]
        private(set) var requests: [WireRequest] = []

        init(
            refetches: [String: Refetch],
            attempts: [Attempt],
            books: [String: BookOutcome] = [:]
        ) {
            self.refetches = refetches
            self.remainingAttempts = attempts
            self.books = books
        }

        func refetch(bookID: String) async -> Refetch {
            refetches[bookID] ?? .unreachable
        }

        func apply(request: WireRequest) async -> Attempt {
            requests.append(request)
            guard !remainingAttempts.isEmpty else { return .retryable }
            return remainingAttempts.removeFirst()
        }

        func book(bookID: String) async -> BookOutcome {
            books[bookID] ?? .unavailable
        }
    }

    /// One local action + its queued row, at an explicit action time. Millisecond
    /// stamps otherwise tie inside one second, and these tests need a known order.
    private func seedQueued(_ store: KomgaStore, bookID: String, page: Int64, actionAt: String) throws {
        try store.setReadProgress(serverID: serverID, bookID: bookID, page: page, completed: false)
        try store.dbQueue.write { db in
            try db.execute(
                sql: "UPDATE read_progress SET local_updated_at = ? WHERE server_id = ? AND book_id = ?",
                arguments: [actionAt, serverID, bookID]
            )
            try db.execute(
                sql: "UPDATE pending_mutations SET created_at = ? WHERE server_id = ? AND entity_id = ?",
                arguments: [actionAt, serverID, bookID]
            )
        }
    }
}

/// A fixture that does not fit the shape this test reads is a contract break,
/// not a reason to skip.
private struct FixtureError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}
