import Foundation
import GRDB

// MARK: - `cache_entries` ledger (schema v8, mirror of `store/cache.rs`)
//
// The generic LRU bookkeeping for page/prefetch bytes. `thumbnails` keeps its own
// accounting because covers are keyed per entity; everything byte-sized the
// reader generates goes here.
//
// Hit rule, same as covers: a row AND a readable file. Either missing is a miss,
// and a row whose file is gone is deleted on sight so the ledger cannot drift
// from the disk. That pruning needs to see the filesystem, which is why these
// helpers take a `fileExists` closure rather than pretending a path is enough.
//
// Two rules decide who dies when the pool is full:
//
// * **kind outranks age**. Unseen prefetch bytes are worth less than a page the
//   reader displayed an hour ago, so the eviction walk orders by kind first and
//   only then by `last_access`.
// * **protection is not a convention**. `protectedPaths` asks `downloads` and
//   `download_pages` directly, because a `kind = 'download'` row only protects a
//   file if somebody remembered to write it — and the offline-download feature
//   that will write page files later has not been written yet.
//
// The same split as Rust: `cacheTotalBytesFast` is a SUM with no stat and runs on
// every store; `cacheTotalBytes` walks the filesystem, prunes ghosts and runs on
// open.

/// Ledger kinds. Eviction must never touch an offline download.
public enum CacheKind {
    public static let page = "page"
    public static let prefetch = "prefetch"
    /// A user-owned offline download: never an eviction victim.
    public static let download = "download"
}

/// One accounted cached file.
public struct CacheEntryRecord: Sendable, Equatable {
    public var key: String
    public var kind: String
    public var path: String
    public var size: Int64
    public var lastAccess: String

    public init(key: String, kind: String, path: String, size: Int64, lastAccess: String) {
        self.key = key
        self.kind = kind
        self.path = path
        self.size = size
        self.lastAccess = lastAccess
    }
}

/// Whether a recorded file is actually still on disk. Injectable so tests can
/// model "the OS cleaned my cache" without racing a real deletion.
public typealias FileExistsProbe = @Sendable (String) -> Bool

/// The default probe: ask the filesystem.
public let fileExistsOnDisk: FileExistsProbe = { FileManager.default.fileExists(atPath: $0) }

public extension KomgaStore {
    /// Insert or replace one accounted entry. Re-recording a key replaces rather
    /// than duplicates, so the totals stay honest after a re-download.
    func recordCacheEntry(
        key: String,
        kind: String,
        path: String,
        size: Int64,
        now: String
    ) throws {
        try dbQueue.write { db in
            try Self.record(db, key: key, kind: kind, path: path, size: size, now: now)
        }
    }

    func cacheEntry(key: String) throws -> CacheEntryRecord? {
        try dbQueue.read { db in try Self.cacheEntry(key: key, db: db) }
    }

    /// Stamp an entry as recently used without rewriting the row.
    func touchCacheEntry(key: String, now: String) throws {
        try dbQueue.write { db in try Self.touchCacheEntry(key: key, now: now, db: db) }
    }

    /// Drop a row and hand back its path so the caller can delete the file.
    @discardableResult
    func removeCacheEntry(key: String) throws -> String? {
        try dbQueue.write { db in try Self.removeCacheEntry(key: key, db: db) }
    }

    /// Sweep every entry whose key starts with `prefix`, returning their paths.
    ///
    /// Page keys are `{server}-{book}-p{number}`, so a book or server prune is a
    /// prefix match. Wildcards in the prefix are escaped: an id containing `%`
    /// must not evict somebody else's cache.
    func deleteCacheEntries(keyPrefix: String) throws -> [String] {
        try dbQueue.write { db in try Self.deleteCacheEntries(keyPrefix: keyPrefix, db: db) }
    }

    /// Total bytes accounted. Rows whose file already vanished are excluded from
    /// the total and pruned, so the LRU decision sees the real disk state.
    func cacheTotalBytes(fileExists: @escaping FileExistsProbe = fileExistsOnDisk) throws -> Int64 {
        try dbQueue.write { db in
            try Self.pruneMissingFiles(db: db, fileExists: fileExists)
            return try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(size), 0) FROM cache_entries"
            ) ?? 0
        }
    }

    func cacheBytes(kind: String) throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(size), 0) FROM cache_entries WHERE kind = ?",
                arguments: [kind]
            ) ?? 0
        }
    }

    /// Trim the cache to `budget` bytes, prefetch tier first and never taking a
    /// protected path, with one entry held back. Returns the paths whose rows
    /// were dropped.
    func evictCacheToBudget(
        budget: Int64,
        exceptKey: String? = nil,
        fileExists: @escaping FileExistsProbe = fileExistsOnDisk
    ) throws -> [String] {
        try dbQueue.write { db in
            try Self.evictCacheToBudget(
                budget: budget, exceptKey: exceptKey, db: db, fileExists: fileExists
            )
        }
    }

    /// Sum of accounted bytes with no filesystem walk.
    ///
    /// The eviction decision runs on every store, so it may not stat every cached
    /// file — over a 500-page book that is O(n) per page turn. `cacheTotalBytes`
    /// is the reconciling variant and runs on open instead.
    func cacheTotalBytesFast() throws -> Int64 {
        try dbQueue.read { db in try Self.cacheTotalBytesFast(db: db) }
    }

    /// Every row, for the reconciliation sweep. Ascending key so a sweep is
    /// reproducible.
    func cacheEntries() throws -> [CacheEntryRecord] {
        try dbQueue.read { db in try Self.cacheEntries(db: db) }
    }

    /// Move a row to a new path and/or kind, stamping it as used.
    ///
    /// This is the prefetch -> page promotion: the file has been renamed, and the
    /// ledger must stop describing it as a candidate for eviction before it has
    /// ever been looked at.
    func relocateCacheEntry(key: String, path: String, kind: String, now: String) throws {
        try dbQueue.write { db in
            try Self.relocateCacheEntry(key: key, path: path, kind: kind, now: now, db: db)
        }
    }

    /// Drop every entry of one kind, returning their paths — except the ones the
    /// user owns.
    func deleteCacheEntries(kind: String) throws -> [String] {
        try dbQueue.write { db in try Self.deleteCacheEntries(kind: kind, db: db) }
    }

    /// The keys under `prefix` the ledger believes are cached — one query, no
    /// filesystem walk. See `Self.cachedKeys` for why that is the right trade.
    func cachedKeys(prefix: String) throws -> Set<String> {
        try dbQueue.read { db in try Self.cachedKeys(prefix: prefix, db: db) }
    }

    /// Every path the user owns outright, whether or not the LRU ledger knows it.
    func protectedCachePaths() throws -> Set<String> {
        try dbQueue.read { db in try Self.protectedPaths(db: db) }
    }

    // MARK: - Connection-scoped halves (for a caller already inside a transaction)

    static func record(
        _ db: GRDB.Database,
        key: String,
        kind: String,
        path: String,
        size: Int64,
        now: String
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO cache_entries (key, kind, path, size, last_access)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(key) DO UPDATE SET kind = excluded.kind, path = excluded.path,
                                           size = excluded.size, last_access = excluded.last_access
            """,
            arguments: [key, kind, path, size, now]
        )
    }

    static func cacheEntry(key: String, db: GRDB.Database) throws -> CacheEntryRecord? {
        try Row.fetchOne(
            db,
            sql: """
            SELECT key, kind, path, size, last_access FROM cache_entries WHERE key = ?
            """,
            arguments: [key]
        ).map(Self.cacheEntry(from:))
    }

    static func touchCacheEntry(key: String, now: String, db: GRDB.Database) throws {
        try db.execute(
            sql: "UPDATE cache_entries SET last_access = ? WHERE key = ?",
            arguments: [now, key]
        )
    }

    static func removeCacheEntry(key: String, db: GRDB.Database) throws -> String? {
        guard let path: String = try String.fetchOne(
            db,
            sql: "SELECT path FROM cache_entries WHERE key = ?",
            arguments: [key]
        ) else { return nil }
        try db.execute(sql: "DELETE FROM cache_entries WHERE key = ?", arguments: [key])
        return path
    }

    static func removeCacheEntries(keys: [String], db: GRDB.Database) throws -> [String] {
        var paths: [String] = []
        for key in keys {
            if let path = try removeCacheEntry(key: key, db: db) { paths.append(path) }
        }
        return paths
    }

    /// Sweep every entry whose key starts with `prefix`, returning their paths.
    ///
    /// Page keys are `{server}-{book}-p{number}`, so a book or server prune is a
    /// prefix match. Wildcards in the prefix are escaped: an id containing `%`
    /// must not evict somebody else's cache.
    ///
    /// Entries whose file the user owns outright (`protectedPaths`) are left in
    /// the ledger and not returned, so the caller cannot delete them: pruning a
    /// book out of the mirror must never take an offline copy with it.
    static func deleteCacheEntries(keyPrefix: String, db: GRDB.Database) throws -> [String] {
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT key, path FROM cache_entries WHERE key LIKE ? ESCAPE '\\' ORDER BY key ASC",
            arguments: [likePrefix(keyPrefix)]
        )
        let protected = try protectedPaths(db: db)
        var paths: [String] = []
        for row in rows {
            let path: String = row["path"]
            if protected.contains(path) { continue }
            let key: String = row["key"]
            _ = try removeCacheEntry(key: key, db: db)
            paths.append(path)
        }
        return paths
    }

    /// The keys under `prefix` that the ledger believes are cached — one query, no
    /// filesystem walk.
    ///
    /// Deliberately weaker than a hit test: a row whose file has since been
    /// deleted is reported here. That is the right trade for the prefetch planner,
    /// which asks this question for a whole 500-page book on every spread change
    /// and must not stat 500 files to answer it. Anything stale is healed where it
    /// matters, by `PageCache.lookup`, which validates before it hands a path to
    /// the UI.
    static func cachedKeys(prefix: String, db: GRDB.Database) throws -> Set<String> {
        Set(try String.fetchAll(
            db,
            sql: "SELECT key FROM cache_entries WHERE key LIKE ? ESCAPE '\\'",
            arguments: [likePrefix(prefix)]
        ))
    }

    /// `LIKE` prefix with the wildcards in the caller's own id escaped.
    static func likePrefix(_ prefix: String) -> String {
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped + "%"
    }

    /// Every row, for the reconciliation sweep. Ascending key so a sweep of the
    /// same contents produces the same report twice.
    static func cacheEntries(db: GRDB.Database) throws -> [CacheEntryRecord] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT key, kind, path, size, last_access FROM cache_entries ORDER BY key ASC
            """
        ).map(Self.cacheEntry(from:))
    }

    /// Move a row to a new path and/or kind, stamping it as used. A promotion of a
    /// key nobody recorded is an error, not a silent insert: the file has already
    /// been renamed by then, and a fresh row would hide the mistake.
    static func relocateCacheEntry(
        key: String, path: String, kind: String, now: String, db: GRDB.Database
    ) throws {
        try db.execute(
            sql: """
            UPDATE cache_entries SET path = ?, kind = ?, last_access = ? WHERE key = ?
            """,
            arguments: [path, kind, now, key]
        )
        // GRDB reports the affected-row count out-of-band, the way SQLite does.
        guard db.changesCount > 0 else { throw CacheLedgerError.entryNotFound(key) }
    }

    /// Drop every entry of one kind, returning their paths — except the ones the
    /// user owns. A row recorded as `kind = 'download'` is protected by
    /// definition, and so is any path the download tables name, whichever kind
    /// filed it.
    static func deleteCacheEntries(kind: String, db: GRDB.Database) throws -> [String] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT key, path FROM cache_entries WHERE kind = ? ORDER BY key ASC
            """,
            arguments: [kind]
        )
        let protected = try protectedPaths(db: db)
        var paths: [String] = []
        for row in rows {
            let path: String = row["path"]
            if protected.contains(path) { continue }
            let key: String = row["key"]
            _ = try removeCacheEntry(key: key, db: db)
            paths.append(path)
        }
        return paths
    }

    /// Sum of accounted bytes with no filesystem walk and no pruning.
    static func cacheTotalBytesFast(db: GRDB.Database) throws -> Int64 {
        try Int64.fetchOne(
            db, sql: "SELECT COALESCE(SUM(size), 0) FROM cache_entries"
        ) ?? 0
    }

    /// Every path the user owns outright, whether or not the LRU ledger knows it.
    ///
    /// The LRU's own protection is a *convention* — write a `kind = 'download'`
    /// row and you are safe — and conventions break the day the offline-download
    /// feature writes page files without one. `downloads.manifest_path` and
    /// `download_pages.file_path` are the schema's truth about what the user asked
    /// to keep, so cleanup asks them directly instead of trusting that somebody
    /// also touched `cache_entries`.
    static func protectedPaths(db: GRDB.Database) throws -> Set<String> {
        let rows = try String.fetchAll(
            db,
            sql: """
            SELECT manifest_path FROM downloads WHERE manifest_path IS NOT NULL
            UNION SELECT file_path FROM download_pages WHERE file_path IS NOT NULL
            UNION SELECT path FROM cache_entries WHERE kind = ?
            """,
            arguments: [CacheKind.download]
        )
        return Set(rows.filter { !$0.isEmpty })
    }

    /// Delete rows whose file is gone. The ledger converges on the disk instead
    /// of drifting from it.
    @discardableResult
    static func pruneMissingFiles(
        db: GRDB.Database,
        fileExists: FileExistsProbe = fileExistsOnDisk
    ) throws -> [String] {
        let stale: [(key: String, path: String)] = try Row.fetchAll(
            db,
            sql: "SELECT key, path FROM cache_entries ORDER BY key ASC"
        ).compactMap { row in
            let key: String = row["key"]
            let path: String = row["path"]
            return fileExists(path) ? nil : (key, path)
        }
        return try removeCacheEntries(keys: stale.map(\.key), db: db)
    }

    /// Evictable entries, worst-value-first.
    ///
    /// Kind outranks age: a prefetched page the reader never looked at is worth
    /// less than a page it did, even if the reader saw that page an hour ago and
    /// the prefetch landed a second ago. Age then breaks ties inside a kind, and
    /// `key` breaks ties inside a timestamp, so two runs with the same contents
    /// evict the same entries. `kind = 'download'` never enters the candidate set
    /// at all.
    static func evictableCacheOrder(db: GRDB.Database) throws -> [(key: String, path: String, size: Int64)] {
        try Row.fetchAll(
            db,
            sql: """
            SELECT key, path, size FROM cache_entries
             WHERE kind <> ?
             ORDER BY CASE kind WHEN ? THEN 0 ELSE 1 END ASC, last_access ASC, key ASC
            """,
            arguments: [CacheKind.download, CacheKind.prefetch]
        ).map { row in
            (key: row["key"], path: row["path"], size: row["size"])
        }
    }

    static func evictCacheToBudget(
        budget: Int64,
        exceptKey: String? = nil,
        db: GRDB.Database,
        fileExists: FileExistsProbe = fileExistsOnDisk
    ) throws -> [String] {
        var removed: [String] = []
        try pruneMissingFiles(db: db, fileExists: fileExists)
        var used = try Self.cacheTotalBytesFast(db: db)
        guard used > budget else { return removed }
        let protected = try protectedPaths(db: db)
        for entry in try evictableCacheOrder(db: db) {
            if used <= budget { break }
            // The entry that was just written has to survive the trim that writing
            // it triggered, and age alone does not guarantee that: `last_access`
            // has millisecond resolution, so a prefetch and a display landing in
            // the same millisecond tie, and the tie breaks by key.
            if entry.key == exceptKey { continue }
            // Kind already excludes a download row; this catches a page row that
            // filed a path the download tables claim.
            if protected.contains(entry.path) { continue }
            _ = try removeCacheEntry(key: entry.key, db: db)
            removed.append(entry.path)
            used -= entry.size
        }
        return removed
    }

    static func cacheEntry(from row: Row) -> CacheEntryRecord {
        let size: Int64? = row["size"]
        return CacheEntryRecord(
            key: row["key"],
            kind: row["kind"],
            path: row["path"],
            size: size ?? 0,
            lastAccess: row["last_access"]
        )
    }
}

/// Mirror of `rusqlite::Error::QueryReturnedNoRows` for the one ledger call that
/// has to distinguish "no such row" from "the database said no".
public enum CacheLedgerError: Error, Sendable, Equatable, CustomStringConvertible {
    case entryNotFound(String)

    public var description: String {
        switch self {
        case .entryNotFound(let key): return "cache_entries has no row for key \(key)"
        }
    }
}
