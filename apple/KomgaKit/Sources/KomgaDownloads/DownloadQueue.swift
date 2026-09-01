import Foundation

// MARK: - The download queue's rules (mirror of Rust `downloads/queue.rs`)
//
// Pure: no GRDB, no filesystem, no async. This is the module the two platforms
// are *supposed* to disagree about nothing in, so everything here is restated
// from `specs/contracts/fixtures/downloads/` and `DownloadsContractTests`
// re-reads those same files and compares row for row.
//
// The tables below are written as data rather than as `match` arms for one
// reason: a rule restated twice is a rule that drifts. The test asserts this
// table against the fixture, so a rename in the fixture turns the Apple side red
// without anyone having to diff two implementations by eye.

/// Who is asking to change a download's state. Three of these four may not do
/// the same things, which is the whole content of the state machine.
public enum QueueActor: String, Sendable, CaseIterable {
    /// The bounded download pass. The only actor that may move a book into
    /// `downloading`, and it may never move one out of `paused`.
    case pump
    /// The recalculation a pass runs on its way out: state derived from page
    /// rows, never incremented.
    case settle
    /// A gesture on the Downloads screen.
    case user
    /// The sweep, and only where the filesystem disproved a row.
    case heal
}

public enum BookState: String, Sendable, CaseIterable {
    case waiting, downloading, paused, completed, failed
}

/// Note there is no in-flight *page* state. The evidence that a write was
/// interrupted is its `.part` file, which the sweep reaps.
public enum PageState: String, Sendable, CaseIterable {
    case pending, complete, failed
}

/// One row of the transition table. `nil` means the wildcard the fixture writes
/// as an absent key: `from: nil` is "no previous state" (enqueue), `to: nil` is
/// delete, `from: "any"` is every state.
public struct TransitionRow: Sendable, Equatable {
    public var from: String?
    public var to: String?
    public var on: String

    public init(from: String?, to: String?, on: String) {
        self.from = from
        self.to = to
        self.on = on
    }
}

public enum DownloadQueue {
    // MARK: transitions

    /// Legal moves, restated from `states.json#transitions`. Book-level rows
    /// first, then the page-level ones, then delete.
    public static let transitions: [TransitionRow] = [
        TransitionRow(from: nil, to: BookState.waiting.rawValue, on: "user"),
        TransitionRow(from: "waiting", to: "waiting", on: "user"),
        TransitionRow(from: "waiting", to: "downloading", on: "pump"),
        TransitionRow(from: "downloading", to: "waiting", on: "settle"),
        TransitionRow(from: "downloading", to: "completed", on: "settle"),
        TransitionRow(from: "downloading", to: "failed", on: "settle"),
        TransitionRow(from: "waiting", to: "paused", on: "user"),
        TransitionRow(from: "waiting", to: "completed", on: "settle"),
        TransitionRow(from: "waiting", to: "failed", on: "settle"),
        TransitionRow(from: "downloading", to: "paused", on: "user"),
        TransitionRow(from: "paused", to: "waiting", on: "user"),
        TransitionRow(from: "failed", to: "waiting", on: "user"),
        TransitionRow(from: "failed", to: "waiting", on: "settle"),
        TransitionRow(from: "failed", to: "completed", on: "settle"),
        TransitionRow(from: "completed", to: "waiting", on: "user"),
        TransitionRow(from: "any", to: nil, on: "user"),
        TransitionRow(from: "complete", to: "pending", on: "heal"),
        TransitionRow(from: "pending", to: "complete", on: "pump"),
        TransitionRow(from: "pending", to: "failed", on: "pump"),
        TransitionRow(from: "failed", to: "pending", on: "user"),
        TransitionRow(from: "completed", to: "waiting", on: "settle"),
    ]

    /// Refusals, restated from `states.json#illegal`. The first is the bug this
    /// file exists to prevent: a pump that can resume a user's pause survives
    /// code review and costs the user data they chose to stop spending.
    public static let illegal: [TransitionRow] = [
        TransitionRow(from: "paused", to: "downloading", on: "pump"),
        TransitionRow(from: "downloading", to: "waiting", on: "user"),
        TransitionRow(from: "completed", to: "downloading", on: "pump"),
        TransitionRow(from: "paused", to: "waiting", on: "settle"),
        TransitionRow(from: "complete", to: "pending", on: "pump"),
        TransitionRow(from: "complete", to: "failed", on: "pump"),
        TransitionRow(from: "pending", to: "downloading", on: "pump"),
    ]

    private static func covers(_ row: TransitionRow, from: String?, to: String?, on: String) -> Bool {
        guard row.on == on else { return false }
        let fromMatches: Bool
        switch row.from {
        case nil: fromMatches = from == nil
        case "any": fromMatches = from != nil
        case let previous?: fromMatches = previous == from
        }
        return fromMatches && row.to == to
    }

    /// Wildcard-aware lookup. The `illegal` list wins over `transitions`, and a
    /// pair absent from both is refused — refusing the unknown is what makes a
    /// future state added on one platform an error rather than a free pass.
    public static func transitionAllowed(from: String?, to: String?, actor: QueueActor) -> Bool {
        if illegal.contains(where: { covers($0, from: from, to: to, on: actor.rawValue) }) {
            return false
        }
        return transitions.contains(where: { covers($0, from: from, to: to, on: actor.rawValue) })
    }

    /// Enqueue is the one transition with no previous state. Checked rather than
    /// assumed: if the table stops listing it, the first enqueue on a phone is
    /// where that would surface.
    public static func enqueueAllowed() -> Bool {
        transitions.contains { $0.from == nil
            && $0.to == BookState.waiting.rawValue
            && $0.on == QueueActor.user.rawValue }
    }

    // MARK: failures

    /// What one page attempt proved, named after the transport fact rather than
    /// after either platform's error enum: a `URLError` and `ApiError::Network`
    /// are the same event seen from two sides.
    public static func classify(_ signal: PageSignal) -> PageOutcome {
        classification[signal] ?? .badPage
    }

    /// The table from `errors.json#classify`, spelled out so a missing entry is
    /// visible as a missing entry rather than as a silent default.
    static let classification: [PageSignal: PageOutcome] = [
        .ok: .complete,
        .link: .linkDown,
        .credential: .blocked,
        .notFound: .gone,
        .rateLimited: .throttled,
        .server: .badPage,
        .shortRead: .badPage,
        .corrupt: .badPage,
        .tooSmall: .badPage,
        .writeFailed: .ioFailed,
    ]

    /// Anything the table does not name is `badPage`: it is about *this*
    /// response, the page stays retryable, and treating the unknown as fatal
    /// would turn one odd server into a dead queue.
    public static let defaultOutcome: PageOutcome = .badPage

    /// How far the news travels, from `errors.json#outcomes`.
    public static func scope(of outcome: PageOutcome) -> FailureScope {
        switch outcome {
        case .complete: return .page
        case .badPage: return .page
        case .linkDown: return .pass
        case .blocked: return .serverQueue
        case .gone: return .book
        case .throttled: return .pass
        case .ioFailed: return .book
        }
    }

    /// Whether this failure spends one of the page's attempts. A link that is
    /// down spends nothing: the user is not being charged for an outage.
    public static func burnsAttempt(_ outcome: PageOutcome) -> Bool {
        switch outcome {
        case .badPage: return true
        default: return false
        }
    }

    // MARK: bounds

    /// Per page, and per user retry.
    public static let maxPageAttempts: Int = 3
    /// A run of bad pages degrades into a pass-scoped stop without burning
    /// anything more, so a dying server costs three attempts across the book
    /// instead of three per page.
    public static let consecutiveBadPages: Int = 3
    public static let defaultMaxPages: Int = 4
    public static let defaultMaxBytes: Int64 = 33_554_432
    /// The bound that keeps the pump from starving `reader_page`, which shares
    /// the process.
    public static let maxElapsedMs: Int64 = 1_000

    /// How long to wait before the next pass. A real clock wait when one is
    /// named, otherwise "as soon as the caller asks".
    public static let nextInMs: [StopReason: Int64] = [
        .linkDown: 2_000,
        .throttled: 5_000,
        .blocked: 60_000,
        .lowSpace: 60_000,
        .linkBlocked: 0,
        .budget: 0,
        .badRun: 5_000,
    ]

    /// `waitMs` is a real deadline the queue already knows about (a parked
    /// book's `nextRetryAt`); it wins over the stop reason's own wait, because
    /// parking was decided with more information than "this failed".
    public static func nextInMs(for stop: StopReason, waitMs: Int64) -> Int64 {
        let byReason = nextInMs[stop] ?? 0
        return max(byReason, waitMs)
    }
}

// MARK: - vocabularies

/// What one page attempt proved.
public enum PageSignal: String, Sendable, CaseIterable, Codable {
    case ok
    case link
    case credential
    case notFound
    case server
    case rateLimited
    case shortRead
    case corrupt
    case tooSmall
    case writeFailed
}

/// What that signal means for the queue.
public enum PageOutcome: String, Sendable, CaseIterable, Codable {
    case complete
    case badPage
    case linkDown
    case blocked
    case gone
    case throttled
    case ioFailed
}

/// How far an outcome's news travels.
public enum FailureScope: String, Sendable, CaseIterable, Codable {
    /// One row; the book continues.
    case page
    /// This book ends, and stays explainable.
    case book
    /// The pass ends with no write at all.
    case pass
    /// The pass ends *and* every book for that server parks, because the next
    /// book would fail identically and the user pays per request.
    case serverQueue
}

/// What the device reports about the network. Unknown is its own answer, and it
/// is the conservative one.
public enum LinkClass: String, Sendable, CaseIterable, Codable {
    case unmetered
    case metered
    case unknown

    /// Anything the platform does not name is `unknown`, never `unmetered`: a
    /// misread here spends mobile data the user did not agree to.
    public static func parse(_ value: String) -> LinkClass {
        LinkClass(rawValue: value) ?? .unknown
    }
}

/// Why a pass stopped.
public enum StopReason: String, Sendable, CaseIterable, Codable {
    case none
    case drained
    case budget
    case bytes
    case elapsed
    case linkDown
    case blocked
    case gone
    case throttled
    case ioFailed
    case linkBlocked
    case lowSpace
    case parked
    case idle
    case badPage
    case badRun
    case paused
}

// MARK: - planning one pass

public struct PagePlan: Sendable, Equatable {
    public var number: Int
    public var state: String
    public var attempts: Int
    public var declaredBytes: Int64

    public init(number: Int, state: String, attempts: Int, declaredBytes: Int64) {
        self.number = number
        self.state = state
        self.attempts = attempts
        self.declaredBytes = declaredBytes
    }
}

/// One book as the planner sees it, pages included. A queue entry without its
/// page rows is not enough to decide anything about it, and passing the two in
/// separately is how a book gets planned against another book's pages.
public struct BookPlan: Sendable, Equatable {
    public var serverId: String
    public var bookId: String
    public var position: Int
    public var state: String
    public var allowCellular: Bool
    public var pagesTotal: Int
    public var nextRetryAt: String?
    public var pages: [PagePlan]

    public init(
        serverId: String,
        bookId: String,
        position: Int,
        state: String,
        allowCellular: Bool,
        pagesTotal: Int,
        nextRetryAt: String?,
        pages: [PagePlan]
    ) {
        self.serverId = serverId
        self.bookId = bookId
        self.position = position
        self.state = state
        self.allowCellular = allowCellular
        self.pagesTotal = pagesTotal
        self.nextRetryAt = nextRetryAt
        self.pages = pages
    }
}

/// Where the reader sits, so a pass races toward the page being looked at
/// rather than toward the end of the job.
public struct ReaderPlace: Sendable, Equatable {
    public var bookId: String
    public var page: Int

    public init(bookId: String, page: Int) {
        self.bookId = bookId
        self.page = page
    }
}

public struct PassInput: Sendable {
    public var now: Date
    public var books: [BookPlan]
    public var link: LinkClass
    public var freeBytes: Int64
    public var maxPages: Int
    public var maxBytes: Int64
    public var reader: ReaderPlace?

    public init(
        now: Date,
        books: [BookPlan],
        link: LinkClass,
        freeBytes: Int64,
        maxPages: Int,
        maxBytes: Int64,
        reader: ReaderPlace?
    ) {
        self.now = now
        self.books = books
        self.link = link
        self.freeBytes = freeBytes
        self.maxPages = maxPages
        self.maxBytes = maxBytes
        self.reader = reader
    }
}

public struct DownloadJob: Sendable, Equatable {
    public var serverId: String
    public var bookId: String
    public var number: Int
    public var declaredBytes: Int64
}

public struct PlannedPass: Sendable, Equatable {
    public var jobs: [DownloadJob]
    public var stop: StopReason
    /// The book this pass holds.
    public var book: (serverId: String, bookId: String)?
    /// True when this pass must write `downloading` before serving anything.
    ///
    /// Not the same question as "has this book already started", and
    /// conflating them is a bug that shows up only on a second pass: landing a
    /// page refuses to commit while the book is not `downloading`, so a pass
    /// that believed the claim had been made lands nothing, forever, on any
    /// book with one page on disk.
    public var claims: Bool
    public var nextInMs: Int64

    public static func == (lhs: PlannedPass, rhs: PlannedPass) -> Bool {
        lhs.jobs == rhs.jobs
            && lhs.stop == rhs.stop
            && lhs.book?.bookId == rhs.book?.bookId
            && lhs.book?.serverId == rhs.book?.serverId
            && lhs.claims == rhs.claims
            && lhs.nextInMs == rhs.nextInMs
    }
}

public extension DownloadQueue {
    /// Pages this book still wants, in the order a pass should take them.
    static func candidates(_ book: BookPlan, readerPage: Int?) -> [PagePlan] {
        let wanted = book.pages
            .filter {
                $0.state == PageState.pending.rawValue && $0.attempts < maxPageAttempts
            }
            .sorted { $0.number < $1.number }
        guard let readerPage else { return wanted }
        // Forward first: a reader continues ahead, so the pages in front of
        // them are worth more than the ones behind. The tail then covers what
        // was never fetched before their position.
        return wanted.sorted { lhs, rhs in
            let lhsRank = lhs.number >= readerPage ? 0 : 1
            let rhsRank = rhs.number >= readerPage ? 0 : 1
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.number < rhs.number
        }
    }

    /// Decide one pass. Pure over ``PassInput``, so both platforms can run the
    /// same `pump.json` cases against their own implementation.
    static func planPass(_ input: PassInput) -> PlannedPass {
        let resumable = input.books
            .filter { $0.state == BookState.waiting.rawValue || $0.state == BookState.downloading.rawValue }
            .sorted {
                if $0.position != $1.position { return $0.position < $1.position }
                if $0.serverId != $1.serverId { return $0.serverId < $1.serverId }
                return $0.bookId < $1.bookId
            }

        func due(_ book: BookPlan) -> Bool? {
            guard let raw = book.nextRetryAt, let until = QueueTime.parse(raw) else { return nil }
            return until <= input.now
        }

        let parkedUntil = resumable
            .filter { due($0) == false }
            .compactMap { $0.nextRetryAt.flatMap(QueueTime.parse) }
            .min()
        let ready = resumable.filter { due($0) != false }

        guard let book = ready.first else {
            return stopped(
                parkedUntil != nil ? .parked : .idle,
                now: input.now,
                waitUntil: parkedUntil
            )
        }

        // "Already started" is the book having pages on the device, not the
        // transient `downloading` state: every settle resets a partway book to
        // `waiting`, so a test keyed on that marker would let a book advance
        // exactly one pass and then stall forever wherever the platform will
        // not report its free space. The state still counts, because a killed
        // pass leaves it set.
        let started = book.state == BookState.downloading.rawValue
            || book.pages.contains { $0.state == PageState.complete.rawValue }

        switch input.link {
        case .metered where !book.allowCellular:
            return stopped(.linkBlocked, now: input.now, waitUntil: nil)
        case .unknown where !started:
            return stopped(.linkBlocked, now: input.now, waitUntil: nil)
        default:
            break
        }

        var readerPage: Int?
        if let reader = input.reader, reader.bookId == book.bookId {
            readerPage = reader.page
        }
        var queue = candidates(book, readerPage: readerPage)
        var pass = PlannedPass(
            jobs: [],
            stop: .drained,
            book: (book.serverId, book.bookId),
            claims: book.state == BookState.waiting.rawValue,
            nextInMs: 0
        )
        if queue.isEmpty {
            // Nothing to fetch for a book the queue still holds. The caller
            // settles it, which is how a book whose every page failed reaches
            // `failed` instead of being reported as having nothing to do.
            return pass
        }

        // Headroom for a new book is measured against the first two pages it
        // would take, not the whole remaining book: a user with 200 MB free can
        // finish a 12 MB-per-page book page by page, and refusing it for the
        // total would make the storage screen's own numbers unusable.
        let headroom = started
            ? 0
            : queue.prefix(2).reduce(Int64(0)) { $0 + max($1.declaredBytes, 0) }
        // `freeBytes == 0` means the platform would not say. That never stops a
        // book already running, and always stops a new one.
        if !started && (input.freeBytes == 0 || headroom > input.freeBytes) {
            return stopped(.lowSpace, now: input.now, waitUntil: nil)
        }

        let maxPages = input.maxPages == 0 ? defaultMaxPages : input.maxPages
        let maxBytes = input.maxBytes == 0 ? defaultMaxBytes : input.maxBytes

        var bytes: Int64 = 0
        while !queue.isEmpty {
            if pass.jobs.count >= maxPages {
                pass.stop = .budget
                break
            }
            let page = queue.removeFirst()
            let size = max(page.declaredBytes, 0)
            // One page is always served even if it alone exceeds the byte
            // budget, or a book of such pages could never be finished.
            if !pass.jobs.isEmpty && bytes + size > maxBytes {
                pass.stop = .bytes
                break
            }
            bytes += size
            pass.jobs.append(
                DownloadJob(
                    serverId: book.serverId,
                    bookId: book.bookId,
                    number: page.number,
                    declaredBytes: size
                )
            )
        }
        pass.nextInMs = nextInMs(for: pass.stop, waitMs: 0)
        return pass
    }

    private static func stopped(
        _ stop: StopReason,
        now: Date,
        waitUntil: Date?
    ) -> PlannedPass {
        let waitMs = waitUntil.map { Int64($0.timeIntervalSince(now) * 1_000) } ?? 0
        return PlannedPass(
            jobs: [],
            stop: stop,
            book: nil,
            claims: false,
            nextInMs: nextInMs(for: stop, waitMs: waitMs)
        )
    }
}

/// Who is deriving. The state write is recorded as `settle` either way, because
/// the question is not who is asking but who has looked at the disk: only the
/// sweep has, and only it may take a completion back. (Mirror of Rust
/// `downloads/queue.rs`'s `SettleMode`.)
public enum SettleMode: Sendable, Equatable {
    /// A download pass, settling rows it wrote itself.
    case pass
    /// The reconciliation sweep, which has just read every file.
    case sweep
}

public extension DownloadQueue {
    /// The state a book settles into, derived from its page counts and from who
    /// looked. Never incremented and never taken from a stored counter: a row
    /// lost to a half-applied transaction would otherwise make the book
    /// permanently uncompletable, and the number the UI shows would stop
    /// meaning anything. (Mirror of Rust `queue::settle_state`.)
    static func settleState(
        _ state: String,
        pagesTotal: Int,
        complete: Int,
        failed: Int,
        mode: SettleMode
    ) -> String {
        if state == BookState.paused.rawValue {
            // A pause is the user's, and no derivation may overwrite it.
            return state
        }
        if state == BookState.completed.rawValue && mode != .sweep {
            // A completed book does not un-complete itself because a pass noticed
            // a row: it has not looked at the disk. The sweep has, and for it
            // completion is not sticky — without that exception a downloaded page
            // that later fails the container check would leave the book labelled
            // complete, and a completed book is not the queue's to run, so it
            // could never be repaired. See `states.json#rules.healReopens`.
            return state
        }
        if pagesTotal == 0 || complete >= pagesTotal {
            return BookState.completed.rawValue
        }
        let summed = complete.addingReportingOverflow(failed)
        let attempted = summed.overflow ? Int.max : summed.partialValue
        if attempted >= pagesTotal {
            return BookState.failed.rawValue
        }
        return BookState.waiting.rawValue
    }
}

/// RFC 3339 in, `Date` out — the format both platforms store timestamps in.
///
/// The formatter is built per call rather than cached: `DateFormatter` is not
/// thread-safe, and a shared one would need either a lock or an
/// `nonisolated(unsafe)` escape to satisfy Swift 6's concurrency checking. A pass
/// parses a handful of `nextRetryAt` values, so the cheap correct answer is to
/// make one.
public enum QueueTime {
    public static func parse(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let at = fractional.date(from: text) { return at }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// The other direction, for a row the store writes.
    public static func text(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
