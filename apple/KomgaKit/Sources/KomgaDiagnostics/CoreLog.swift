import Foundation

/// An in-process ring of the client's own log lines.
///
/// Mirror of Rust `crate::diagnostics::log`. The two platforms get to the same
/// place by different roads: Rust calls the `log` crate and had to install a
/// backend to catch lines it was already writing, while Swift writes through
/// here explicitly and forwards to `os.Logger` for Console.app. The shape of
/// what comes out — capacity, retained, dropped, per-level counters, the newest
/// error, whether the sink is live — is the same on both, because
/// `Diagnostics.snapshot()` has to answer with one vocabulary.
///
/// # Why a ring and not just `os.Logger`
///
/// Because the reader has to be able to *ask*. A support export, a diagnostics
/// screen and the acceptance gates all need "the last few hundred lines of this
/// process" as data; os.Logger hands them to a system viewer that a test cannot
/// read back.
public final class CoreLog: @unchecked Sendable {
    /// Lines kept per process, matching Rust `DEFAULT_CAPACITY`. What matters is
    /// the tail, and a few hundred short strings is nothing next to a page cache.
    public static let defaultCapacity = 512

    /// The one instance the modules write to. A second ring would mean two
    /// partial answers to "what just happened".
    public static let shared = CoreLog()

    /// A captured line. Field names match the Rust `LogRecord`.
    public struct Record: Sendable, Equatable, Codable {
        public var level: String
        public var target: String
        public var message: String
        /// RFC 3339 with milliseconds, the same format the store writes its
        /// timestamps in.
        public var at: String
    }

    /// The counters the diagnostics snapshot carries.
    public struct Stats: Sendable, Equatable, Codable {
        /// Always true here, and kept anyway: the Rust side can lose the `log`
        /// slot to another logger, and a snapshot that is comparable between
        /// platforms has to carry the same field with the same meaning.
        public var installed: Bool
        public var capacity: Int
        public var retained: Int
        public var dropped: Int
        public var errors: Int
        public var warnings: Int
        public var info: Int
        public var debug: Int
        public var trace: Int
        /// The newest error line still inside the window; empty when there
        /// is none. A plain String rather than an optional because a Swift
        /// encoder drops a nil key, and the snapshot contract requires
        /// `log.lastError` to be present either way: "nothing failed" and
        /// "this build reports no failures" must not be the same document.
        /// Rust keeps its Option and writes null, which the same path
        /// covers. The counters above do not depend on the retained window;
        /// this pointer does.
        public var lastError: String
        public var maxLevel: String
    }

    public enum Level: String, Sendable, CaseIterable {
        case error, warning, info, debug, trace

        /// The name the Rust side uses (`log::Level::Warn` renders as `warn`).
        /// Kept as a separate spelling so `Stats.errors`/`warnings` and the
        /// level filter agree across the two implementations.
        var wireName: String {
            switch self {
            case .error: return "error"
            case .warning: return "warn"
            case .info: return "info"
            case .debug: return "debug"
            case .trace: return "trace"
            }
        }

        static func fromWire(_ name: String) -> Level? {
            Level.allCases.first { $0.wireName == name }
        }

        /// Rank for "at or above this level", where error is the loudest.
        var rank: Int {
            switch self {
            case .error: return 0
            case .warning: return 1
            case .info: return 2
            case .debug: return 3
            case .trace: return 4
            }
        }
    }

    private let lock = NSLock()
    private var ring: [Record] = []
    private var capacity = CoreLog.defaultCapacity
    private var dropped = 0
    private var counts: [String: Int] = [:]
    private var maxLevel: Level = .info

    /// Forwards to `os.Logger` as well, so a device console still shows the
    /// same lines the ring holds. Off by default in unit tests, where
    /// Console.app is not the audience and the noise hides real output.
    public var forwardsToSystemLog = true

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    public init() {}

    /// Set the quietest level that is captured. Lines below it are dropped here
    /// as `log`'s level filter drops them on the Rust side, so the two rings
    /// hold the same thing for the same setting.
    public func setMaxLevel(_ level: Level) {
        lock.lock()
        maxLevel = level
        lock.unlock()
    }

    public func record(level: Level, target: String, message: String) {
        let entry = Record(
            level: level.wireName,
            target: target,
            message: message,
            at: CoreLog.timestamp.string(from: Date())
        )
        lock.lock()
        guard level.rank <= maxLevel.rank else {
            lock.unlock()
            return
        }
        counts[entry.level, default: 0] += 1
        if ring.count >= max(1, capacity) {
            ring.removeFirst()
            dropped += 1
        }
        ring.append(entry)
        lock.unlock()
        if forwardsToSystemLog {
            SystemLogBridge.write(level: level, target: target, message: message)
        }
    }

    public func error(_ target: String, _ message: String) {
        record(level: .error, target: target, message: message)
    }

    public func warning(_ target: String, _ message: String) {
        record(level: .warning, target: target, message: message)
    }

    public func info(_ target: String, _ message: String) {
        record(level: .info, target: target, message: message)
    }

    /// Newest first, at or above `minLevel` when one is given. An unrecognised
    /// level name means "no filter" rather than "hide everything": a typo in a
    /// filter box that shows an empty list reads as "the client logged nothing".
    public func recent(limit: Int, minLevel: String? = nil) -> [Record] {
        let threshold = minLevel.flatMap(Level.init(wireName:))?.rank
        lock.lock()
        let selected = ring.reversed().filter { record in
            guard let threshold else { return true }
            return (Level.fromWire(record.level)?.rank ?? Level.trace.rank) <= threshold
        }
        let page = Array(selected.prefix(max(0, limit)))
        lock.unlock()
        return page
    }

    public func stats() -> Stats {
        lock.lock()
        defer { lock.unlock() }
        let lastError = ring.reversed().first { $0.level == "error" }
            .map { $0.target + ": " + $0.message } ?? ""
        return Stats(
            installed: true,
            capacity: capacity,
            retained: ring.count,
            dropped: dropped,
            errors: counts["error", default: 0],
            warnings: counts["warn", default: 0],
            info: counts["info", default: 0],
            debug: counts["debug", default: 0],
            trace: counts["trace", default: 0],
            lastError: lastError,
            maxLevel: maxLevel.wireName
        )
    }

    /// Resize; only the tail survives a shrink.
    public func setCapacity(_ newCapacity: Int) {
        lock.lock()
        capacity = max(1, newCapacity)
        if ring.count > capacity {
            dropped += ring.count - capacity
            ring.removeFirst(ring.count - capacity)
        }
        lock.unlock()
    }

    /// Forget everything. For tests; a running app never calls it.
    public func reset() {
        lock.lock()
        ring.removeAll()
        counts.removeAll()
        dropped = 0
        lock.unlock()
    }
}

private extension CoreLog.Level {
    init?(wireName: String) {
        guard let found = CoreLog.Level.fromWire(wireName) else { return nil }
        self = found
    }
}
