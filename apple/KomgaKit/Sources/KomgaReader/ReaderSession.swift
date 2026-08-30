import Foundation
import KomgaStore

// MARK: - Reading session (mirror of `reader/session.rs`)
//
// ```text
// UI gesture -> ReaderSession.turnTo(page)
//                -> reader_position   (display state, never uploaded)
//                -> read_progress     (the value that syncs)
//                -> pending_mutations (coalesced outbox row, same transaction)
//                -> Upload.now | Upload.idle
// ```
//
// When a request happens is decided by `ProgressThrottle`, which is pure and
// contract-tested; what the request contains is decided by Stage 6's outbox. This
// type only glues them to SQLite and to the layout. It never sends anything
// itself: on `Upload.now` the caller runs `OutboxUpload.run`, so retry/backoff/
// conflict handling stays in the one place Stage 6 put it.

/// How long a page-turn burst may sit locally before the outbox is drained.
/// 5 s is a starting point, not a law: it is one number to retune in the
/// performance phase, and the contract in `reader/throttle.json` pins the
/// behaviour that depends on it.
public let uploadIntervalMs: Int64 = 5000

/// Whether the caller should drain the outbox right now.
public enum Upload: Sendable, Equatable {
    case now
    case idle

    static func flag(_ now: Bool) -> Upload { now ? .now : .idle }
}

/// One instant in both clocks the pipeline needs: RFC 3339 for the rows,
/// milliseconds for the throttle. Taken as an argument so a test (and the
/// acceptance script) can advance time deterministically.
public struct ReaderClock: Sendable, Equatable {
    public var rfc3339: String
    public var ms: Int64

    public init(rfc3339: String, ms: Int64) {
        self.rfc3339 = rfc3339
        self.ms = ms
    }

    /// Wall clock. Nothing in the throttle ever calls this.
    public static func now() -> ReaderClock {
        let date = Date()
        return ReaderClock(rfc3339: KomgaStore.rfc3339Text(date), ms: Int64(date.timeIntervalSince1970 * 1000))
    }

    /// A clock whose two readings describe the same instant, for tests.
    public static func at(ms: Int64) -> ReaderClock {
        ReaderClock(rfc3339: "\(ms)", ms: ms)
    }
}

public final class ReaderSession: @unchecked Sendable {
    private let serverID: String
    private let bookID: String
    private let store: KomgaStore
    public let pageCount: UInt32
    /// Stage 6 rule R8: only an image-paged manifest may report page numbers.
    private let writesProgress: Bool
    public private(set) var mode: ReadMode
    public private(set) var direction: Direction
    private let firstPageSingle: Bool
    public private(set) var layout: Layout
    public private(set) var current: UInt32
    public private(set) var spread: Int
    private var throttle: ProgressThrottle

    /// Restore-or-start. A saved position supplies both the page and the layout it
    /// was displayed with, but only when the user wants positions restored; with
    /// `restorePosition` off, every book starts at page 1.
    public init(
        store: KomgaStore,
        serverID: String,
        bookID: String,
        pageCount: UInt32,
        writesProgress: Bool,
        settings: ReaderSettingsDocument,
        clock: ReaderClock
    ) throws {
        let saved = settings.restorePosition
            ? try store.readerPosition(serverID: serverID, bookID: bookID)
            : nil

        let mode = saved.map { ReadMode.parse($0.mode) } ?? settings.mode
        let direction = saved.map { Direction.parse($0.direction) } ?? settings.direction
        let layout = Paging.layout(
            pageCount: pageCount,
            mode: mode,
            direction: direction,
            firstPageSingle: settings.firstPageSingle,
            unpairable: []
        )

        // A manifest can shrink between two reads; never restore past its end.
        let wanted = saved.flatMap { $0.page > 0 ? UInt32(exactly: $0.page) : nil } ?? 1
        let start: UInt32 = pageCount == 0 ? 1 : min(max(wanted, 1), pageCount)
        let spreadIndex = layout.spreadIndex(forPage: start) ?? 0
        let current = layout.entryPage(spreadIndex) ?? start

        let restored = try Self.restoredPending(store: store, serverID: serverID, bookID: bookID)
        // `lastUploadAt` stays unknown on purpose: a row a crash left behind is
        // owed immediately rather than after another full interval.
        self.throttle = ProgressThrottle(
            config: ThrottleConfig(
                bookID: bookID, pageCount: pageCount, intervalMs: uploadIntervalMs
            ),
            current: current,
            lastUploadAt: nil,
            restored: restored
        )

        self.store = store
        self.serverID = serverID
        self.bookID = bookID
        self.pageCount = pageCount
        self.writesProgress = writesProgress
        self.mode = mode
        self.direction = direction
        self.firstPageSingle = settings.firstPageSingle
        self.layout = layout
        self.current = current
        self.spread = spreadIndex

        // A restore can legally move the page: the stored page may be the second
        // half of a pair, or past the end of a manifest that shrank. Stamp the
        // corrected page so the row always describes what is on screen.
        if let saved, saved.page != Int64(current) {
            try persist(store: store, clock: clock)
        }
    }

    /// Pages on screen, left-to-right / top-to-bottom.
    public func visible() -> [UInt32] {
        layout.visual(spread) ?? []
    }

    /// Turn to a canonical page. Clamped, idempotent, and durable before it is
    /// visible: the position row and the outbox row are written in the same
    /// transaction, so a crash cannot show a page the server will never hear
    /// about.
    public func turnTo(page: UInt32, clock: ReaderClock) throws -> Upload {
        guard pageCount > 0 else { return .idle }
        let clamped = min(max(page, 1), pageCount)
        guard clamped != current, let target = layout.spreadIndex(forPage: clamped) else {
            return .idle
        }
        current = clamped
        spread = target
        try persist(store: store, clock: clock)
        // T9: a book the image reader cannot drive (EPUB/PDF) must never enter the
        // page-progress stream, not even as a queued row.
        guard writesProgress else { return .idle }
        return Upload.flag(!throttle.apply(.page(at: clock.ms, clamped)).isEmpty)
    }

    /// Advance one spread in the current reading direction.
    public func next(clock: ReaderClock) throws -> Upload {
        try step(by: 1, clock: clock)
    }

    public func previous(clock: ReaderClock) throws -> Upload {
        try step(by: -1, clock: clock)
    }

    private func step(by delta: Int, clock: ReaderClock) throws -> Upload {
        guard layout.spreadCount > 0 else { return .idle }
        let moved = min(max(spread + delta, 0), layout.spreadCount - 1)
        let entry = layout.entryPage(moved) ?? current
        return try turnTo(page: entry, clock: clock)
    }

    /// Re-pair the book after a mode/direction change without losing the place.
    public func relayout(
        mode: ReadMode,
        direction: Direction,
        clock: ReaderClock
    ) throws {
        self.mode = mode
        self.direction = direction
        layout = Paging.layout(
            pageCount: pageCount, mode: mode, direction: direction,
            firstPageSingle: firstPageSingle, unpairable: []
        )
        spread = layout.spreadIndex(forPage: current) ?? 0
        current = layout.entryPage(spread) ?? current
        try persist(store: store, clock: clock)
    }

    /// Explicit user statement — never throttled (rule T4).
    public func markRead(clock: ReaderClock) throws -> Upload {
        if writesProgress {
            try store.markReadProgressRead(serverID: serverID, bookID: bookID, now: clock.rfc3339)
        }
        return Upload.flag(
            !throttle.apply(.of(at: clock.ms, .markRead)).isEmpty
        )
    }

    public func markUnread(clock: ReaderClock) throws -> Upload {
        if writesProgress {
            try store.markReadProgressUnread(serverID: serverID, bookID: bookID, now: clock.rfc3339)
        }
        current = 0
        spread = 0
        return Upload.flag(
            !throttle.apply(.of(at: clock.ms, .markUnread)).isEmpty
        )
    }

    /// The UI's periodic timer.
    public func tick(clock: ReaderClock) -> Upload {
        Upload.flag(!throttle.apply(.of(at: clock.ms, .tick)).isEmpty)
    }

    /// Leaving the reader: persist once more and give the outbox its chance.
    public func close(clock: ReaderClock) throws -> Upload {
        if current > 0 { try persist(store: store, clock: clock) }
        return Upload.flag(!throttle.apply(.of(at: clock.ms, .exit)).isEmpty)
    }

    /// Backgrounding is the last reliable moment to get a request out.
    public func background(clock: ReaderClock) -> Upload {
        Upload.flag(!throttle.apply(.of(at: clock.ms, .background)).isEmpty)
    }

    /// The throttle's own view, for tests and diagnostics.
    public var snapshot: ThrottleSnapshot { throttle.snapshot }

    /// Which statement, if any, this book currently owes the server.
    public func outboxState() throws -> String? {
        guard let entry = try store.queuedOutboxEntry(serverID: serverID, bookID: bookID) else {
            return nil
        }
        switch entry.mutationType {
        case "READ_PROGRESS", "MARK_READ", "MARK_UNREAD": return entry.mutationType
        default: return nil
        }
    }

    /// Position + progress + the coalesced outbox row, all before the gesture is
    /// visible. The store owns its own transaction; these three statements land in
    /// the order the pipeline documents.
    private func persist(store: KomgaStore, clock: ReaderClock) throws {
        try store.saveReaderPosition(
            serverID: serverID, bookID: bookID, page: Int64(current),
            mode: mode.rawValue, direction: direction.rawValue, now: clock.rfc3339
        )
        if writesProgress && current > 0 {
            try store.upsertLocalReadProgress(
                serverID: serverID, bookID: bookID,
                page: Int64(current), completed: current >= pageCount, now: clock.rfc3339
            )
        }
    }

    /// The row a previous session left unpaid, if any.
    public static func restoredPending(
        store: KomgaStore,
        serverID: String,
        bookID: String
    ) throws -> PendingIntent? {
        guard let entry = try store.queuedOutboxEntry(serverID: serverID, bookID: bookID) else {
            return nil
        }
        guard let intent = intentOf(mutationType: entry.mutationType, payload: entry.payload) else {
            return nil
        }
        switch intent {
        case .progress(let page, let completed):
            return .progress(page: UInt32(max(page ?? 1, 1)), completed: completed)
        case .markRead:
            return .markRead
        case .markUnread:
            return .markUnread
        }
    }
}
