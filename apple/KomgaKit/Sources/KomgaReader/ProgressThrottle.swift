import Foundation

// MARK: - Reading-progress throttle (mirror of `reader/throttle.rs`)
//
// Contract: `specs/contracts/fixtures/reader/throttle.json`, shared with the Rust
// core.
//
// This is the pure decision layer: it says WHAT leaves and WHEN, given an ordered
// event stream with explicit timestamps. The durable half lives in the store (the
// write) and in `KomgaSync`'s uploader (the wire call), and the wire bodies come
// from Stage 6's `requestFor(bookID:intent:)` so this module can never invent a
// second on-the-wire format.
//
// The one idea worth stating twice: the throttle gates the NETWORK, never
// durability. Every page change is committed locally with its outbox row, so a
// kill -9 between two page turns loses nothing. There is deliberately no clock in
// here — `at` on each event is the only time this sees.

public enum EventKind: String, Sendable, Equatable, Codable {
    /// The reader moved to another page.
    case page
    /// Explicit user statement.
    case markRead
    /// Explicit user statement.
    case markUnread
    /// Reader closed normally.
    case exit
    /// App backgrounded — the last moment we can be sure to get a request out.
    case background
    /// The UI's periodic timer.
    case tick
}

public struct ProgressEvent: Sendable, Equatable {
    public var at: Int64
    public var kind: EventKind
    public var page: UInt32?

    public init(at: Int64, kind: EventKind, page: UInt32?) {
        self.at = at
        self.kind = kind
        self.page = page
    }

    public static func page(at: Int64, _ page: UInt32) -> ProgressEvent {
        ProgressEvent(at: at, kind: .page, page: page)
    }

    public static func of(at: Int64, _ kind: EventKind) -> ProgressEvent {
        ProgressEvent(at: at, kind: kind, page: nil)
    }
}

/// The mutation queued in `pending_mutations`, after family coalescing.
public enum PendingIntent: Sendable, Equatable {
    case progress(page: UInt32, completed: Bool)
    case markRead
    case markUnread

    /// The `mutation_type` spelling the outbox row carries.
    public var mutationType: String {
        switch self {
        case .progress: return "READ_PROGRESS"
        case .markRead: return "MARK_READ"
        case .markUnread: return "MARK_UNREAD"
        }
    }

    /// Translated to Stage 6's vocabulary, which owns the wire body.
    public var intent: Intent {
        switch self {
        case .progress(let page, let completed):
            return .progress(page: Int64(page), completed: completed)
        case .markRead: return .markRead
        case .markUnread: return .markUnread
        }
    }
}

/// One request that went out, with the timestamp it fired at.
public struct WireCall: Sendable, Equatable {
    public var at: Int64
    public var method: String
    public var path: String
    public var body: String?

    public init(at: Int64, method: String, path: String, body: String?) {
        self.at = at
        self.method = method
        self.path = path
        self.body = body
    }
}

public struct ThrottleConfig: Sendable, Equatable {
    public var bookID: String
    public var pageCount: UInt32
    public var intervalMs: Int64

    public init(bookID: String, pageCount: UInt32, intervalMs: Int64) {
        self.bookID = bookID
        self.pageCount = pageCount
        self.intervalMs = intervalMs
    }
}

/// Where the pipeline stands after replaying events.
public struct ThrottleSnapshot: Sendable, Equatable {
    /// Page-position writes committed to SQLite (rule T1).
    public var localWrites: Int
    /// Rows still sitting in `pending_mutations` for this book.
    public var outbox: [String]
    /// Locally stored page; 0 means "unread from the start".
    public var page: Int64
    public var completed: Bool

    public init(localWrites: Int = 0, outbox: [String] = [], page: Int64 = 0, completed: Bool = false) {
        self.localWrites = localWrites
        self.outbox = outbox
        self.page = page
        self.completed = completed
    }
}

/// Finite state machine over the event stream. Deterministic: the clock is an
/// argument, so both platforms can replay the same fixture without a timer.
public struct ProgressThrottle: Sendable {
    private let config: ThrottleConfig
    private var current: UInt32?
    private var completed: Bool
    private var lastUploadAt: Int64?
    private var localWrites: Int
    private var pending: PendingIntent?

    /// `restored` is whatever `pending_mutations` still holds for this book when
    /// the reader opens — the row a crash left behind.
    public init(
        config: ThrottleConfig,
        current: UInt32?,
        lastUploadAt: Int64?,
        restored: PendingIntent?
    ) {
        self.config = config
        self.current = current
        self.completed = restored == .markRead
        self.lastUploadAt = lastUploadAt
        self.localWrites = 0
        self.pending = restored
    }

    public var snapshot: ThrottleSnapshot {
        ThrottleSnapshot(
            localWrites: localWrites,
            outbox: pending.map { [$0.mutationType] } ?? [],
            page: Int64(current ?? 0),
            completed: completed
        )
    }

    /// Feed one event; returns the requests that must go out because of it.
    public mutating func apply(_ event: ProgressEvent) -> [WireCall] {
        switch event.kind {
        case .page:
            recordPage(event.page)
            return []
        case .markRead:
            pending = .markRead
            completed = true
            return flush(at: event.at)
        case .markUnread:
            pending = .markUnread
            current = 0
            completed = false
            return flush(at: event.at)
        case .exit, .background:
            return pending == nil ? [] : flush(at: event.at)
        // T3: only the timer consults the interval. A page turn never uploads on
        // the spot, however long the interval has aged.
        case .tick:
            guard pending != nil, due(at: event.at) else { return [] }
            return flush(at: event.at)
        }
    }

    /// T1 + T5 + T8: clamp into [1, pageCount], ignore a page we are already on,
    /// and never write at all for a book with no pages.
    private mutating func recordPage(_ page: UInt32?) {
        guard let page, config.pageCount > 0 else { return }
        let clamped = min(max(page, 1), config.pageCount)
        if current == clamped { return }
        current = clamped
        // T6: finishing the book is derived progress, not an explicit mark.
        completed = clamped >= config.pageCount
        localWrites += 1
        pending = .progress(page: clamped, completed: completed)
    }

    private func due(at: Int64) -> Bool {
        guard let last = lastUploadAt else {
            // Never uploaded: do not make the user wait an interval.
            return true
        }
        return at.distance(from: last) >= config.intervalMs
    }

    private mutating func flush(at: Int64) -> [WireCall] {
        guard let intent = pending else { return [] }
        pending = nil
        lastUploadAt = at
        // Stage 6 owns the body: reuse its request builder verbatim.
        let request = requestFor(bookID: config.bookID, intent: intent.intent)
        return [WireCall(at: at, method: request.method.rawValue, path: request.path, body: request.body)]
    }
}

private extension Int64 {
    /// `self - other`, saturating so a clock that goes backwards (an NTP
    /// correction, or a restore from a future stamp) can never manufacture a
    /// "due" tick.
    func distance(from other: Int64) -> Int64 {
        let (value, overflow) = subtractingReportingOverflow(other)
        if overflow { return value < 0 ? .min : .max }
        return value
    }
}
