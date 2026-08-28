import Foundation
import GRDB

// MARK: - Mutation Outbox consumer side (Stage 6, mirror of `store/outbox.rs`)
//
// This is the *read/decide* half of `specs/contracts/offline-mutation/README.md`.
// The enqueue half lives in `KomgaStore+MediaLibrary` (local-first writes) and
// calls `coalesceOutbox` so a device only ever uploads the user's last statement
// per book.
//
// The queue holds no in-flight state: a Komga `read-progress` write is
// idempotent, so "at-least-once + replay after a kill" is the whole recovery
// story. `next_retry_at` is an absolute stamp precisely so that restarting the
// app cannot buy a given-up row a fresh head start.

/// Read-progress mutation family — the kinds that collapse into one another
/// (mirror of Rust `FAMILY`; pinned by `fixtures/outbox/coalescing.json#family`).
public enum OutboxFamily {
    public static let all: [String] = ["READ_PROGRESS", "MARK_READ", "MARK_UNREAD"]
    public static let pending = "pending"
    public static let failed = "failed"
}

/// Backoff policy, mirrored from `fixtures/outbox/backoff.json#policy`.
public enum OutboxPolicy {
    public static let baseSeconds: Int64 = 2
    public static let maxSeconds: Int64 = 300
    public static let maxAttempts: Int64 = 8
}

/// One queued client write waiting for the server.
public struct OutboxEntry: Sendable, Equatable {
    public var id: String
    public var serverID: String
    public var entityID: String
    public var mutationType: String
    public var payload: String
    public var createdAt: String
    public var retryCount: Int64
    public var lastError: String?
    public var state: String
    public var nextRetryAt: String?

    public init(
        id: String,
        serverID: String,
        entityID: String,
        mutationType: String,
        payload: String,
        createdAt: String,
        retryCount: Int64,
        lastError: String?,
        state: String,
        nextRetryAt: String?
    ) {
        self.id = id
        self.serverID = serverID
        self.entityID = entityID
        self.mutationType = mutationType
        self.payload = payload
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.lastError = lastError
        self.state = state
        self.nextRetryAt = nextRetryAt
    }
}

/// How a single upload attempt ended (contract: 结果分类).
public enum Attempt: Sendable, Equatable {
    /// 204 — the server has it; the row is deleted.
    case succeeded
    /// 404 / 410 — the server confirmed the entity is gone; drop the row.
    case gone
    /// 400 — the payload was rejected; give up without burning retries.
    case rejected
    /// 408 / 429 / 5xx / transport — try again after the backoff.
    case retryable
    /// 401 / 403 — a credential problem is global: stop the run, penalise nothing.
    case blockedAuthentication

    /// Same spelling Rust's `format!("{other:?}")` writes into `last_error`.
    public var label: String {
        switch self {
        case .succeeded: return "Succeeded"
        case .gone: return "Gone"
        case .rejected: return "Rejected"
        case .retryable: return "Retryable"
        case .blockedAuthentication: return "BlockedAuthentication"
        }
    }

    /// Status-code classification (mirror of Rust `Attempt::from_status`).
    public static func from(statusCode: Int) -> Attempt {
        switch statusCode {
        case 401, 403: return .blockedAuthentication
        case 404, 410: return .gone
        case 400: return .rejected
        default: return .retryable
        }
    }
}

/// Counts the uploader leaves behind for the UI (Outbox badge / settings row).
public struct OutboxCounts: Sendable, Equatable {
    public var pending: Int64 = 0
    /// Due, but still inside its backoff window.
    public var waiting: Int64 = 0
    public var failed: Int64 = 0

    public init(pending: Int64 = 0, waiting: Int64 = 0, failed: Int64 = 0) {
        self.pending = pending
        self.waiting = waiting
        self.failed = failed
    }

    public var total: Int64 { pending + waiting + failed }
}

/// Exponential backoff in seconds after `retry_count` failures (>= 1).
public func outboxBackoffSeconds(_ retryCount: Int64) -> Int64 {
    let exponent = min(max(retryCount - 1, 0), 16)
    return min(OutboxPolicy.baseSeconds << exponent, OutboxPolicy.maxSeconds)
}

/// RFC 3339 with or without fractional seconds; both spellings occur in the
/// database (the store stamps milliseconds, the schedule writes whole seconds).
public func outboxTimestamp(_ text: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: text) { return date }
    return ISO8601DateFormatter().date(from: text)
}

/// Second-precision UTC stamp (`next_retry_at` is compared as text, so it must
/// never carry a fraction that would sort against a plain stamp incorrectly).
public func outboxSecondText(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
}

/// `now + seconds` as an RFC 3339 UTC stamp, or nil when `now` is unreadable
/// (mirror of Rust `at_offset`).
public func outboxAtOffset(now: String, seconds: Int64) -> String? {
    guard let date = outboxTimestamp(now) else { return nil }
    return outboxSecondText(date.addingTimeInterval(TimeInterval(seconds)))
}

/// `now + backoff(retry_count)` (mirror of Rust `next_retry_at`).
public func outboxNextRetryAt(now: String, retryCount: Int64) -> String? {
    outboxAtOffset(now: now, seconds: outboxBackoffSeconds(retryCount))
}

/// True when `candidate` is strictly later than `current`; an unreadable stamp
/// never wins (mirror of Rust `read_progress::newer`).
public func outboxNewer(_ candidate: String, than current: String) -> Bool {
    guard let a = outboxTimestamp(candidate), let b = outboxTimestamp(current) else { return false }
    return a > b
}

public extension KomgaStore {
    /// Drop the queued entries this new one supersedes (contract: Mutation 合并).
    ///
    /// Same server, same entity, same family — the user's newest statement wins,
    /// including over a row that had already given up. Different entities are
    /// never merged. Called from `enqueueMutation` before the new row lands.
    @discardableResult
    func coalesceOutbox(_ db: GRDB.Database, serverID: String, entityID: String) throws -> Int {
        try db.execute(
            sql: """
            DELETE FROM pending_mutations
             WHERE server_id = ? AND entity_id = ? AND mutation_type IN (?, ?, ?)
            """,
            arguments: [serverID, entityID, OutboxFamily.all[0], OutboxFamily.all[1], OutboxFamily.all[2]]
        )
        return db.changesCount
    }

    /// Entries eligible for upload right now, in the order the user made them.
    func dueOutboxEntries(serverID: String, now: String) throws -> [OutboxEntry] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, server_id, entity_id, mutation_type, payload, created_at, retry_count,
                       last_error, state, next_retry_at
                  FROM pending_mutations
                 WHERE server_id = ? AND state = 'pending'
                   AND (next_retry_at IS NULL OR next_retry_at <= ?)
                 ORDER BY created_at ASC, id ASC
                """,
                arguments: [serverID, now]
            ).map(Self.outboxEntry(from:))
        }
    }

    /// Everything queued, including entries still backing off or given up.
    func allOutboxEntries(serverID: String) throws -> [OutboxEntry] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, server_id, entity_id, mutation_type, payload, created_at, retry_count,
                       last_error, state, next_retry_at
                  FROM pending_mutations WHERE server_id = ?
                 ORDER BY created_at ASC, id ASC
                """,
                arguments: [serverID]
            ).map(Self.outboxEntry(from:))
        }
    }

    /// The newest queued mutation for one book (UI badge + tests).
    func queuedOutboxEntry(serverID: String, bookID: String) throws -> OutboxEntry? {
        try dbQueue.read { db in
            try Row.fetchOne(
                db,
                sql: """
                SELECT id, server_id, entity_id, mutation_type, payload, created_at, retry_count,
                       last_error, state, next_retry_at
                  FROM pending_mutations WHERE server_id = ? AND entity_id = ?
                 ORDER BY created_at DESC LIMIT 1
                """,
                arguments: [serverID, bookID]
            ).map(Self.outboxEntry(from:))
        }
    }

    /// Record the outcome of one attempt (contract: 结果分类).
    func recordOutcome(entry: OutboxEntry, attempt: Attempt, now: String, error: String) throws {
        try dbQueue.write { db in
            switch attempt {
            case .succeeded, .gone:
                try db.execute(
                    sql: "DELETE FROM pending_mutations WHERE id = ?",
                    arguments: [entry.id]
                )
            case .blockedAuthentication:
                // Deliberate no-op: a 401 must not advance the penalty of the
                // user's action — the credential problem is global.
                break
            case .rejected:
                try db.execute(
                    sql: """
                    UPDATE pending_mutations SET state = 'failed', next_retry_at = NULL, last_error = ?
                     WHERE id = ?
                    """,
                    arguments: [error, entry.id]
                )
            case .retryable:
                let attempts = entry.retryCount + 1
                if attempts >= OutboxPolicy.maxAttempts {
                    try db.execute(
                        sql: """
                        UPDATE pending_mutations SET retry_count = ?, state = 'failed',
                           next_retry_at = NULL, last_error = ?
                         WHERE id = ?
                        """,
                        arguments: [attempts, error, entry.id]
                    )
                } else {
                    try db.execute(
                        sql: """
                        UPDATE pending_mutations SET retry_count = ?, state = 'pending',
                           next_retry_at = ?, last_error = ?
                         WHERE id = ?
                        """,
                        arguments: [attempts, outboxNextRetryAt(now: now, retryCount: attempts), error, entry.id]
                    )
                }
            }
        }
    }

    /// Take the row out of the queue and let the mirror own the local value
    /// again. Used by every "the server side is settled" outcome: confirmed
    /// upload, already applied, or rule R4 giving the round to a later remote
    /// action. `server_updated_at` goes NULL — a 204 carries no body, so a
    /// guessed stamp would make rule R4 lie on the next round.
    func forget(serverID: String, bookID: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM pending_mutations WHERE server_id = ? AND entity_id = ?",
                arguments: [serverID, bookID]
            )
            try db.execute(
                sql: """
                UPDATE read_progress SET mutation_pending = 0, server_updated_at = NULL
                 WHERE server_id = ? AND book_id = ?
                """,
                arguments: [serverID, bookID]
            )
        }
    }

    /// pending / waiting (backing off) / failed, for the UI.
    func outboxCounts(serverID: String, now: String) throws -> OutboxCounts {
        try dbQueue.read { db in
            var counts = OutboxCounts()
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT state, CASE WHEN next_retry_at IS NULL OR next_retry_at <= ? THEN 0 ELSE 1 END,
                       COUNT(*)
                  FROM pending_mutations WHERE server_id = ? GROUP BY 1, 2
                """,
                arguments: [now, serverID]
            )
            for row in rows {
                let state: String = row[0]
                let waiting: Int64 = row[1]
                let count: Int64 = row[2]
                if state == OutboxFamily.failed {
                    counts.failed += count
                } else if waiting == 1 {
                    counts.waiting += count
                } else {
                    counts.pending += count
                }
            }
            return counts
        }
    }

    /// Hand a given-up row back to the retry machine (UI "retry now"). A new
    /// user action on the same book supersedes it instead. Returns rows reset.
    @discardableResult
    func retryFailed(serverID: String, bookID: String) throws -> Int {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_mutations SET state = 'pending', retry_count = 0,
                   next_retry_at = NULL, last_error = NULL
                 WHERE server_id = ? AND entity_id = ? AND state = 'failed'
                """,
                arguments: [serverID, bookID]
            )
            return db.changesCount
        }
    }

    /// When the user actually did this. `local_updated_at` is the authoritative
    /// answer; a queue row that outlived its local row falls back to its own
    /// creation time so rule R4 still has something honest to compare against.
    func localActionTime(serverID: String, entry: OutboxEntry) throws -> String {
        try dbQueue.read { db in
            let stamp: String? = try String.fetchOne(
                db,
                sql: """
                SELECT local_updated_at FROM read_progress WHERE server_id = ? AND book_id = ?
                """,
                arguments: [serverID, entry.entityID]
            )
            return stamp ?? entry.createdAt
        }
    }

    // MARK: - Payload building (canonical spelling, shared with the Rust side)

    /// The `READ_PROGRESS` payload: `{"bookId":...,"page":...,"completed":...}`.
    static func readProgressPayload(bookID: String, page: Int64?, completed: Bool) -> String {
        var pairs = ["\"bookId\":\(outboxJSONString(bookID))"]
        if let page {
            pairs.append("\"page\":\(page)")
        }
        pairs.append("\"completed\":\(completed ? "true" : "false")")
        return "{" + pairs.joined(separator: ",") + "}"
    }

    /// The mark payload: `{"bookId":...,"completed":...}` — no page, because an
    /// explicit mark must not rewrite the server's page.
    static func markPayload(bookID: String, completed: Bool) -> String {
        "{\"bookId\":\(outboxJSONString(bookID)),\"completed\":\(completed ? "true" : "false")}"
    }

    // MARK: - Row mapping

    static func outboxEntry(from row: Row) -> OutboxEntry {
        let lastError: String? = row["last_error"]
        let nextRetryAt: String? = row["next_retry_at"]
        let retryCount: Int64? = row["retry_count"]
        let state: String? = row["state"]
        return OutboxEntry(
            id: row["id"],
            serverID: row["server_id"],
            entityID: row["entity_id"],
            mutationType: row["mutation_type"],
            payload: row["payload"],
            createdAt: row["created_at"],
            retryCount: retryCount ?? 0,
            lastError: lastError,
            state: state ?? OutboxFamily.pending,
            nextRetryAt: nextRetryAt
        )
    }

    /// A database value the uploader needs but the row shape keeps optional.
    static func outboxJSONString(_ value: String) -> String {
        let data = (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8)
        return String(data: data, encoding: .utf8) ?? "\"\""
    }
}
