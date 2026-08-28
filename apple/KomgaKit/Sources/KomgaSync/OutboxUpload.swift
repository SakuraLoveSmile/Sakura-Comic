import Foundation
import KomgaAPI
import KomgaStore

// MARK: - Mutation Upload Sync (Stage 6) — the Outbox consumer
//
// ```text
// UI → SQLite → pending_mutations → this module → Komga
// ```
//
// Mirror of Rust `sync::upload` plus the pure decision half of `store::outbox`.
// Every rule it applies is pinned by `specs/contracts/fixtures/outbox/`:
// coalescing happens on the enqueue side, and here we do the Targeted Re-fetch,
// the R1-R6 conflict decision, the retry/backoff/failed state machine and the
// cleanup after the server confirmed. A queued action is only ever dropped after
// a 204, a 404/410, or a decision that the server already has it.

/// What the user actually said, decoded from the queued payload.
public enum Intent: Sendable, Equatable {
    /// Passive page progress.
    case progress(page: Int64?, completed: Bool)
    /// Explicit statements: never overridden by a remote passive value.
    case markRead
    case markUnread
}

/// The server side of one book's progress, as of the mandatory re-fetch.
public struct RemoteProgress: Sendable, Equatable {
    public var page: Int64?
    public var completed: Bool
    public var lastModified: String?
    /// `media.mediaType` of the same BookDto: which write endpoint is legal
    /// depends on it (contract R8).
    public var mediaType: String?

    public init(page: Int64?, completed: Bool, lastModified: String?, mediaType: String? = nil) {
        self.page = page
        self.completed = completed
        self.lastModified = lastModified
        self.mediaType = mediaType
    }
}

/// Reflowable formats: Komga answers 400 "epub book is not Divina compatible"
/// for a page-based write and expects the Progression API instead. Measured on
/// the live server.
public func outboxIsReflowable(_ mediaType: String?) -> Bool {
    mediaType == "application/epub+zip" || mediaType == "application/pdf"
}

/// Outcome of the Targeted Re-fetch that must precede every upload.
public enum Refetch: Sendable, Equatable {
    case found(RemoteProgress)
    case notFound
    /// 401 / 403 — never penalise the row, and stop the run.
    case unauthorized
    /// Transport failure — we cannot see the server, so we must not write blind.
    case unreachable
}

/// The wire call an intent turns into (spec: PATCH body `ReadProgressUpdateDto`,
/// mark-unread is a DELETE with no body).
public struct WireRequest: Sendable, Equatable {
    public enum Method: String, Sendable {
        case patch = "PATCH"
        case delete = "DELETE"
    }

    public var method: Method
    public var path: String
    public var body: String?

    public init(method: Method, path: String, body: String?) {
        self.method = method
        self.path = path
        self.body = body
    }
}

/// A conflict decision (contract rules R1-R6) plus whether it costs an attempt.
public enum Decision: Sendable, Equatable {
    case upload(WireRequest)
    /// The server already has it — clean up without spending a request.
    case dropSuccess
    /// Rule R4: a strictly later remote action wins (never `max(page)`).
    case dropRemoteWins
    /// Rule R1: the server confirmed the entity is gone.
    case dropGone
    /// Rule R7: nothing the server can accept (no page / page 0, not completed).
    case dropNoOp
    /// Rule R8: a passive page progress on a reflowable book. Parked with a
    /// reason instead of retried into a guaranteed 400.
    case unsupportedFormat(reason: String)
    /// Do nothing, keep the row. Penalised rows advance the backoff.
    /// Rule R6: keep the row. `defer` is a Swift keyword, so the case is
    /// spelled `deferred`; the fixture still calls it `defer`.
    case deferred(penalised: Bool)

    /// The fixture's decision spelling, so one shared JSON pins both platforms
    /// (`fixtures/outbox/conflict.json#decisions`).
    public var fixtureName: String {
        switch self {
        case .upload: return "upload"
        case .dropSuccess: return "drop_success"
        case .dropRemoteWins: return "drop_remote_wins"
        case .dropGone: return "drop_gone"
        case .dropNoOp: return "drop_no_op"
        case .unsupportedFormat: return "unsupported_format"
        case .deferred: return "defer"
        }
    }
}

/// Decode what the user said. An unknown mutation type is not ours to
/// interpret, so its row stays queued (mirror of Rust `intent_of`).
public func intentOf(mutationType: String, payload: String) -> Intent? {
    switch mutationType {
    case "MARK_READ": return .markRead
    case "MARK_UNREAD": return .markUnread
    case "READ_PROGRESS":
        guard let data = payload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(ProgressPayload.self, from: data)
        else { return nil }
        return .progress(page: decoded.page, completed: decoded.completed ?? false)
    default:
        return nil
    }
}

private struct ProgressPayload: Decodable {
    var page: Int64?
    var completed: Bool?
}

public func requestFor(bookID: String, intent: Intent) -> WireRequest {
    let path = "/api/v1/books/\(bookID)/read-progress"
    switch intent {
    case .markUnread:
        return WireRequest(method: .delete, path: path, body: nil)
    case .markRead:
        // `page` is omitted: an explicit mark must not rewrite the server's page.
        return WireRequest(method: .patch, path: path, body: "{\"completed\":true}")
    case .progress(let page, let completed):
        var pairs: [String] = []
        // A page is only sent when it means something (the endpoint rejects 0).
        if let page, page > 0 {
            pairs.append("\"page\":\(page)")
        }
        pairs.append("\"completed\":\(completed ? "true" : "false")")
        return WireRequest(method: .patch, path: path, body: "{" + pairs.joined(separator: ",") + "}")
    }
}

/// Does the server already hold exactly this statement? "no page recorded" and
/// "page 0" are the same statement (mirror of Rust `remote_matches`).
func remoteMatches(_ remote: RemoteProgress, _ intent: Intent) -> Bool {
    switch intent {
    case .progress(let page, let completed):
        guard remote.completed == completed else { return false }
        switch (remote.page, page) {
        case let (remote?, local?): return remote == local
        case (nil, nil), (nil, 0?), (0?, nil): return true
        default: return false
        }
    case .markRead:
        return remote.completed
    case .markUnread:
        return !remote.completed && (remote.page ?? 0) == 0
    }
}

/// Rules R1-R6 of `specs/contracts/offline-mutation/README.md`, matched in
/// order. Pure function so both platforms can be pinned by the same fixture.
public func decide(
    bookID: String,
    intent: Intent,
    localUpdatedAt: String,
    refetch: Refetch
) -> Decision {
    switch refetch {
    case .notFound:
        // R1: the server confirmed the entity is gone.
        return .dropGone
    case .unauthorized:
        // R6: a credential problem is global — defer, penalise nothing.
        return .deferred(penalised: false)
    case .unreachable:
        // R6: we cannot see the server, so we must not write blind.
        return .deferred(penalised: true)
    case .found(let remote):
        // R2: an explicit mark is uploaded unconditionally — including over a
        // server value that is strictly newer. R3's shortcut deliberately does
        // not apply: the point of a mark is that the server holds it now.
        // Marks are also the only thing the endpoint takes for a reflowable
        // book, so they are decided before R7/R8.
        if intent == .markRead || intent == .markUnread {
            return .upload(requestFor(bookID: bookID, intent: intent))
        }
        let page: Int64?
        if case .progress(let requested, _) = intent { page = requested } else { page = nil }
        // R7, both measured live: page 0 answers 400 "must be greater than 0",
        // and {"completed":false} answers 400 with no violations at all.
        if (page ?? 0) < 1 {
            return .dropNoOp
        }
        // R8: for epub (and non-Divina pdf) a page number cannot go through this
        // endpoint at all, whatever its value.
        if outboxIsReflowable(remote.mediaType) {
            return .unsupportedFormat(
                reason: "\(remote.mediaType ?? "该格式") 的翻页进度需走 Progression API"
            )
        }
        // R3
        if remoteMatches(remote, intent) {
            return .dropSuccess
        }
        // R4 — strictly newer remote stamp, decided by time, never by page.
        if let stamp = remote.lastModified, outboxNewer(stamp, than: localUpdatedAt) {
            return .dropRemoteWins
        }
        // R5
        return .upload(requestFor(bookID: bookID, intent: intent))
    }
}

// MARK: - Uploader

/// The three answers an event-driven re-fetch can get. "Could not read it" is
/// deliberately not the same as "it is gone" — the second one deletes local
/// rows, the first one must not.
public enum BookOutcome: Sendable, Equatable {
    case found(BookDTO)
    /// The server confirmed this book no longer exists.
    case gone
    /// Transport / credential / decode failure: write nothing, hint survives.
    case unavailable
}

/// Everything the Outbox uploader needs from the server. A protocol so the
/// conflict rules run against a scripted fake (same pattern as `LibraryFetching`).
public protocol ProgressWriting: Sendable {
    /// Rule R6: never write blind — if this fails, the row is deferred.
    func refetch(bookID: String) async -> Refetch
    /// `PATCH` / `DELETE` the queued write. Only 200/204 counts as success.
    func apply(request: WireRequest) async -> Attempt
    /// The full DTO, for an SSE-triggered targeted re-fetch.
    func book(bookID: String) async -> BookOutcome
}

/// Why an upload run stopped early.
public enum RunStatus: String, Sendable {
    /// Every eligible row was processed.
    case complete
    /// A 401/403 ended the run; the rest of the queue is untouched.
    case blockedAuthentication = "blocked_authentication"
}

/// What one upload pass did.
public struct UploadSummary: Sendable, Equatable {
    public var serverID: String
    public var considered = 0
    public var uploaded = 0
    /// Converged without a request (rule R3).
    public var alreadyApplied = 0
    /// Rule R4: a strictly later remote action won.
    public var remoteWins = 0
    /// Rule R1: the server confirmed the entity is gone.
    public var gone = 0
    /// Rule R7: the intent said nothing uploadable; cleared without a request.
    public var noOp = 0
    /// Rule R8: the server cannot take this write for this format.
    public var unsupportedFormat = 0
    public var retried = 0
    public var rejected = 0
    /// Rows still waiting for their backoff to elapse when the run started.
    public var waiting = 0
    public var blockedAuthentication = 0
    public var status: RunStatus = .complete

    public init(serverID: String) {
        self.serverID = serverID
    }
}

public enum OutboxUpload {
    /// One pass over everything due right now. `now` is injected so the backoff
    /// schedule is testable (and so a restart cannot reschedule anything).
    @discardableResult
    public static func run(
        store: KomgaStore,
        serverID: String,
        writer: any ProgressWriting,
        now: String = outboxSecondText(Date())
    ) async throws -> UploadSummary {
        let due = try store.dueOutboxEntries(serverID: serverID, now: now)
        var summary = UploadSummary(serverID: serverID)
        summary.considered = due.count
        summary.waiting = Int(try store.outboxCounts(serverID: serverID, now: now).waiting)

        rows: for entry in due {
            guard let intent = intentOf(mutationType: entry.mutationType, payload: entry.payload) else {
                // An unknown mutation type is not ours to interpret: leave it queued.
                summary.considered -= 1
                continue
            }
            let localActionAt = try store.localActionTime(serverID: serverID, entry: entry)
            let refetch = await writer.refetch(bookID: entry.entityID)
            switch decide(bookID: entry.entityID, intent: intent, localUpdatedAt: localActionAt, refetch: refetch) {
            case .dropGone:
                try store.forget(serverID: serverID, bookID: entry.entityID)
                summary.gone += 1
            case .dropNoOp:
                // R7: opening a book and putting it down is neither a success
                // nor a failure — the queue just goes quiet.
                try store.forget(serverID: serverID, bookID: entry.entityID)
                summary.noOp += 1
            case .unsupportedFormat(let reason):
                // R8: park the row with the reason instead of spending the retry
                // ladder on a 400 the server will keep giving.
                try store.recordOutcome(
                    entry: entry, attempt: .rejected, now: now, error: reason
                )
                summary.unsupportedFormat += 1
            case .dropSuccess:
                try store.forget(serverID: serverID, bookID: entry.entityID)
                summary.alreadyApplied += 1
            case .dropRemoteWins:
                // Our intent loses on purpose. Clearing the queue lets the next
                // mirror sweep take the server value, so both sides converge.
                try store.forget(serverID: serverID, bookID: entry.entityID)
                summary.remoteWins += 1
            case .deferred(let penalised):
                if penalised {
                    try store.recordOutcome(
                        entry: entry, attempt: .retryable, now: now, error: "refetch failed"
                    )
                    summary.retried += 1
                }
                if case .unauthorized = refetch {
                    summary.status = .blockedAuthentication
                    break rows
                }
            case .upload(let request):
                let attempt = await writer.apply(request: request)
                switch attempt {
                case .succeeded:
                    try store.forget(serverID: serverID, bookID: entry.entityID)
                    summary.uploaded += 1
                case .blockedAuthentication:
                    summary.blockedAuthentication += 1
                    summary.status = .blockedAuthentication
                    try store.recordOutcome(entry: entry, attempt: attempt, now: now, error: "401")
                    break rows
                default:
                    try store.recordOutcome(entry: entry, attempt: attempt, now: now, error: attempt.label)
                    switch attempt {
                    case .retryable: summary.retried += 1
                    case .rejected: summary.rejected += 1
                    default: break
                    }
                }
            }
        }
        return summary
    }
}

// MARK: - Event → action (the read half of `specs/contracts/reconnect`)

/// What one batch of hints wants looked at. An event never carries truth into
/// SQLite — it names an entity, and the content comes back from the API.
public struct EventHints: Sendable, Equatable {
    public var books: [String] = []
    public var deletedBooks: [String] = []
    /// Anything broader than a bare book touch: membership, derived counters
    /// and deletions cannot be patched locally, so a full sweep is required.
    public var needsSweep = false

    public init() {}

    public var isEmpty: Bool { books.isEmpty && deletedBooks.isEmpty && !needsSweep }

    public mutating func merge(_ other: EventHints) {
        books += other.books
        deletedBooks += other.deletedBooks
        needsSweep = needsSweep || other.needsSweep
    }
}

public enum EventClassifying {
    /// The verified Komga name -> entity table (`specs/events/komga-sse-events.md`,
    /// asserted by `specs/contracts/fixtures/sse/events.json` on both platforms).
    ///
    /// Name matching is deliberately exact, not keyword-based, because two cases
    /// break a `contains("book")` heuristic:
    /// - `ReadProgressChanged` carries a `bookId` but has no "book" in its name,
    ///   so keyword matching would send every remote read into a full sweep;
    /// - `ThumbnailBookDeleted` is about a *thumbnail record*, and treating it as
    ///   a book deletion would erase a mirrored book because its poster changed.
    ///
    /// An unknown name falls back to "sweep", so guessing wrong costs a
    /// reconciliation, never mirror correctness.
    public static func classify(_ event: SseEvent) -> EventHints {
        let ids = event.decoded(EventIDs.self)
        var hints = EventHints()
        switch event.kind {
        case "TaskQueueStatus", "SessionExpired":
            return hints // says nothing about mirrored data
        case "BookDeleted":
            guard let id = ids?.bookId else { return swept() }
            hints.deletedBooks = [id]
            return hints
        case "BookAdded", "BookChanged", "ThumbnailBookAdded", "ThumbnailBookDeleted",
             "ReadProgressChanged", "ReadProgressDeleted", "BookImported":
            guard let id = ids?.bookId else { return swept() }
            hints.books = [id]
            return hints
        default:
            // Series / collection / readlist / library changes, deletions and
            // anything unrecognised: only a full sweep can find what disappeared.
            return swept()
        }
    }

    private static func swept() -> EventHints {
        var hints = EventHints()
        hints.needsSweep = true
        return hints
    }
}

private struct EventIDs: Decodable {
    /// Only `bookId` is read: every other entity's change, add and delete is
    /// answered by a sweep anyway, so decoding more would just invite drift.
    var bookId: String?
}

public enum EventApplication {
    /// `SSE Event → Entity ID → API 重新拉取 → SQLite 更新`.
    ///
    /// Book hints are re-fetched one by one; anything broader is answered with a
    /// full Reconcile, because only a sweep can find a deletion. Writes go
    /// through the ordinary sync path, so a local mutation that has not been
    /// uploaded yet still outranks the server.
    ///
    /// Returns the trigger the caller must run when a sweep was requested.
    @discardableResult
    public static func apply(
        hints: EventHints,
        store: KomgaStore,
        serverID: String,
        reader: any ProgressWriting
    ) async throws -> ReconcileTrigger? {
        for bookID in hints.books {
            switch await reader.book(bookID: bookID) {
            case .found(let book):
                _ = try store.upsertBooksBatch(serverID: serverID, books: [book])
            case .gone:
                // The server says it is gone: that is the confirmation Stage 5
                // required before a mirrored entity may be dropped. The queued
                // Outbox row for it survives until the upload sees a 404 itself.
                _ = try store.deleteEntity(
                    serverID: serverID, entityType: SyncEntity.books,
                    remoteID: bookID, cause: DeletionCause.event
                )
            case .unavailable:
                // Refusing to write here is what "events are not a queue" means:
                // the hint is re-applied by the next sweep instead.
                break
            }
        }
        for bookID in hints.deletedBooks {
            _ = try store.deleteEntity(
                serverID: serverID, entityType: SyncEntity.books,
                remoteID: bookID, cause: DeletionCause.event
            )
        }
        return hints.needsSweep ? .manualRefresh : nil
    }
}

// MARK: - Production transport (mirror of Rust `impl ProgressWriter for KomgaClient`)

public extension Attempt {
    /// Error classification for a *write* attempt (contract: 结果分类). A decode
    /// failure means the write may well have landed; retrying an idempotent
    /// progress write is cheaper than losing the user action.
    static func from(error: KomgaAPIError) -> Attempt {
        switch error {
        case .authentication: return .blockedAuthentication
        case .server(let statusCode): return Attempt.from(statusCode: statusCode)
        default: return .retryable
        }
    }
}

public extension RemoteProgress {
    /// The progress row's own server state. `readProgress.lastModified` is what
    /// advances when another device reads — `book.lastModified` does not, which
    /// is exactly why using it here would make conflict rule R4 blind.
    init(of book: BookDTO) {
        // The format rides along: which write endpoint is legal depends on it
        // (contract R8), and this is the only place the DTO is read.
        let mediaType = book.media?.mediaType
        guard let progress = book.readProgress else {
            // No progress row at all: the server has never been told anything,
            // so there is no stamp to lose against.
            self.init(page: nil, completed: false, lastModified: nil, mediaType: mediaType)
            return
        }
        self.init(
            page: progress.page.map(Int64.init),
            completed: progress.completed ?? false,
            lastModified: progress.lastModified,
            mediaType: mediaType
        )
    }
}

extension KomgaTransport: ProgressWriting {
    public func refetch(bookID: String) async -> Refetch {
        do {
            return .found(RemoteProgress(of: try await fetchBook(id: bookID)))
        } catch let error as KomgaAPIError {
            switch error {
            case .authentication:
                return .unauthorized
            case .server(let statusCode):
                switch Attempt.from(statusCode: statusCode) {
                case .gone: return .notFound
                case .blockedAuthentication: return .unauthorized
                default: return .unreachable
                }
            default:
                return .unreachable
            }
        } catch {
            return .unreachable
        }
    }

    public func apply(request: WireRequest) async -> Attempt {
        do {
            let status = try await performWrite(
                method: request.method.rawValue, path: request.path, body: request.body
            )
            // 204 is the documented success; 200 is accepted as the same thing.
            return status == 200 || status == 204 ? .succeeded : Attempt.from(statusCode: status)
        } catch let error as KomgaAPIError {
            return Attempt.from(error: error)
        } catch {
            return .retryable
        }
    }

    public func book(bookID: String) async -> BookOutcome {
        do {
            return .found(try await fetchBook(id: bookID))
        } catch let error as KomgaAPIError {
            switch error {
            case .server(let statusCode):
                return Attempt.from(statusCode: statusCode) == .gone ? .gone : .unavailable
            default:
                return .unavailable
            }
        } catch {
            return .unavailable
        }
    }
}
