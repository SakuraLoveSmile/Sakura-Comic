import Foundation
import KomgaDiagnostics
import KomgaStore
import KomgaDownloads

// MARK: - Page cache (mirror of `reader/cache.rs`)
//
// Bytes on disk under `cache/pages/` and `cache/prefetch/`, with `cache_entries`
// as the ledger and a byte-budget memory tier in front. LRU is budget-driven and
// never evicts an offline download.
//
// Four invariants worth naming:
//
// * A hit means the row exists AND the file exists AND the file is complete and
//   decodable-looking. Completion is structural: bytes are written to a `.part`
//   file and renamed, so a crash mid-download leaves no candidate for a hit.
//   Integrity is additionally *proved* on every read (`ImageIntegrity`), because
//   a cache entry that goes bad once stays bad forever otherwise.
// * The recorded path is the only thing a caller may open. Callers never rebuild
//   a filename from a key, because the extension follows the response content
//   type and can legitimately change between two fetches of one page.
// * Bytes the reader actually looked at outrank bytes it did not. That is what
//   the two directories are for: prefetch entries are promoted to pages on
//   display, and eviction takes the prefetch tier first regardless of age.
// * The size limit is only real if something runs it. `enforceBudget` is called
//   from the store path on every landing, on the cheap ledger total, so a 500-page
//   book cannot grow the pool past the ceiling between two opens.
//
// ```text
// display a page          prefetch a page
//      |                       |
//      v                       v
//  memory tier  --hit-->  promote from RAM
//      | miss                    |
//      v                         v
//  ledger + file (validate)    store under prefetch/ + hold bytes in RAM
//      | hit                        |
//      v                            v
//  promote prefetch -> pages, return path
// ```

/// Refuse to cache anything smaller than this: an empty page would look like a
/// hit forever (mirror of Rust `MIN_PAGE_BYTES`).
public let minPageBytes = 1

/// Default ceiling for the whole cache pool (covers + pages + prefetch).
public let defaultCacheBudgetBytes: Int64 = 512 * 1024 * 1024

/// Bytes the memory tier starts with before a device profile is known.
public let defaultMemoryBudgetBytes = Int(WindowConstants.memoryDefaultBytes)

/// Which tier a page's bytes live in.
public enum Tier: String, Sendable, Equatable, CaseIterable {
    /// The reader displayed this page at least once.
    case page
    /// Fetched ahead of the reader and not yet looked at.
    case prefetch

    /// The `cache_entries.kind` this tier is recorded under.
    public var kind: String { rawValue }

    /// The directory this tier's files live in.
    public var dir: String {
        switch self {
        case .page: return DiskImageCache.pagesTier
        case .prefetch: return DiskImageCache.prefetchTier
        }
    }

    /// A `download` row names a page-tier path: a user-owned file is never less
    /// worth keeping than a displayed one, and eviction excludes it by kind
    /// anyway.
    public static func fromKind(_ kind: String) -> Tier {
        kind == CacheKind.prefetch ? .prefetch : .page
    }
}

public struct PageLocation: Sendable, Equatable {
    public var url: URL
    public var size: Int64
    public var tier: Tier

    public init(url: URL, size: Int64, tier: Tier = .page) {
        self.url = url
        self.size = size
        self.tier = tier
    }
}

/// Why a store attempt did not land. The distinction matters: a corrupt payload
/// is a server-side signal the reader should retry and report, while an I/O
/// failure is the device running out of room and must not be retried per page.
public enum PageCacheError: Error, Sendable, Equatable, CustomStringConvertible {
    /// A zero-byte body would haunt the ledger as a permanent hit.
    case refusingToCacheEmptyPage
    /// Bytes failed the integrity verdict and were refused, not written.
    case corrupt(reason: String)
    /// The file vanished between the write and the accounting.
    case missingAfterWrite(String)
    case disk(String)
    case store(String)

    /// A corrupt payload is worth counting: the reader retries it, an I/O
    /// failure is not, because retrying a full disk per page is a loop.
    public var isCorrupt: Bool {
        if case .corrupt = self { return true }
        return false
    }

    public var reason: String {
        switch self {
        case .refusingToCacheEmptyPage: return "refusing to cache an empty page"
        case let .corrupt(reason): return "refused corrupt bytes: \(reason)"
        case let .missingAfterWrite(path): return "page vanished after write: \(path)"
        case let .disk(detail): return "cache write failed: \(detail)"
        case let .store(detail): return "cache ledger failed: \(detail)"
        }
    }

    public var description: String { reason }
}

/// What one cleanup sweep found and fixed. Every field is a bug that used to be
/// permanent: a row pointing at a file that is gone, a file no row describes, a
/// half-written `.part`, an entry whose bytes are not a whole image.
public struct ReconcileReport: Sendable, Equatable {
    public var ghostRows: Int
    public var orphanFiles: Int
    public var staleParts: Int
    public var corrupt: Int
    public var kindRepaired: Int
    /// Files the sweep recognised as the user's own and left alone **without** an
    /// LRU row. Non-zero means the offline-download protection is doing real work.
    public var protectedKept: Int
    public var evicted: Int
    public var freedBytes: Int64

    public init(
        ghostRows: Int = 0,
        orphanFiles: Int = 0,
        staleParts: Int = 0,
        corrupt: Int = 0,
        kindRepaired: Int = 0,
        protectedKept: Int = 0,
        evicted: Int = 0,
        freedBytes: Int64 = 0
    ) {
        self.ghostRows = ghostRows
        self.orphanFiles = orphanFiles
        self.staleParts = staleParts
        self.corrupt = corrupt
        self.kindRepaired = kindRepaired
        self.protectedKept = protectedKept
        self.evicted = evicted
        self.freedBytes = freedBytes
    }
}

/// The string-keyed face of `ByteBudgetCache`.
///
/// `ByteBudgetCache` is keyed by canonical page number because that is what the
/// reader's window speaks; the disk ledger is keyed by the canonical cache key
/// (`{server}-{book}-p{n}`) because that is what survives two books on one
/// device. Rather than fork a second LRU — and with it a second set of eviction
/// rules to keep honest — this interns the key into the tier's own id space and
/// delegates every byte/count decision to `ByteBudgetCache`, whose rules
/// `MemoryCacheTests` already pins and whose Rust twin (`reader/memory.rs`)
/// resolves the same way.
public final class PageMemoryTier: @unchecked Sendable {
    private let lock = NSLock()
    private let cache: ByteBudgetCache<Data>
    private var ids: [String: UInt32] = [:]
    private var names: [UInt32: String] = [:]
    private var nextID: UInt32 = 1

    public init(budgetBytes: Int = defaultMemoryBudgetBytes) {
        cache = ByteBudgetCache<Data>(budgetBytes: budgetBytes)
    }

    public var budgetBytes: Int {
        get { cache.budgetBytes }
        set { cache.budgetBytes = newValue }
    }

    public var usedBytes: Int { cache.usedBytes }
    public var stats: MemoryCacheStats { cache.stats }

    public func contains(_ key: String) -> Bool {
        lock.withLock { ids[key].map { cache.contains($0) } ?? false }
    }

    /// Read and stamp as most recently used.
    public func value(for key: String) -> Data? {
        lock.withLock {
            guard let id = ids[key] else { return nil }
            return cache.value(for: id)
        }
    }

    /// Look without disturbing recency.
    public func peek(_ key: String) -> Data? {
        lock.withLock { ids[key].flatMap { cache.peek($0) } }
    }

    @discardableResult
    public func insert(_ bytes: Data, for key: String) -> Bool {
        let id: UInt32 = lock.withLock {
            if let existing = ids[key] { return existing }
            let fresh = nextID
            nextID += 1
            ids[key] = fresh
            names[fresh] = key
            return fresh
        }
        // The byte decision — including "this item alone is the whole budget" —
        // belongs to ByteBudgetCache, so it stays the same decision on both
        // platforms.
        if cache.insert(bytes, for: id) { return true }
        lock.withLock {
            if names[id] == key, !cache.contains(id) {
                ids[key] = nil
                names[id] = nil
            }
        }
        return false
    }

    @discardableResult
    public func remove(_ key: String) -> Data? {
        let id = lock.withLock { () -> UInt32? in
            guard let id = ids.removeValue(forKey: key) else { return nil }
            names[id] = nil
            return id
        }
        guard let id else { return nil }
        return cache.remove(id)
    }

    public func removeAll() {
        lock.withLock {
            ids.removeAll(keepingCapacity: true)
            names.removeAll(keepingCapacity: true)
        }
        cache.removeAll()
    }
}

/// Disk bytes + the SQLite ledger that accounts for them.
public final class PageCache: @unchecked Sendable {
    public let disk: DiskImageCache
    private let store: KomgaStore
    private let memory: PageMemoryTier
    private let budgetLock = NSLock()
    private var _budgetBytes: Int64

    public init(store: KomgaStore, disk: DiskImageCache, memory: PageMemoryTier = PageMemoryTier()) {
        self.store = store
        self.disk = disk
        self.memory = memory
        self._budgetBytes = defaultCacheBudgetBytes
    }

    /// Opens a cache rooted at `rootURL` (which gains `thumbnails/`, `pages/` and
    /// `prefetch/`).
    public convenience init(store: KomgaStore, rootURL: URL) throws {
        try self.init(store: store, disk: try DiskImageCache(rootURL: rootURL))
    }

    /// The shape a per-call facade uses: one memory tier shared by every handle,
    /// because a per-cache tier would die between two page turns and warm nothing.
    public static func shared(store: KomgaStore, rootURL: URL) throws -> PageCache {
        try PageCache(store: store, disk: DiskImageCache(rootURL: rootURL), memory: processMemoryTier())
    }

    /// Pool ceiling applied by `enforceBudget`. Zero disables automatic trimming,
    /// which is what the ledger-level tests use.
    public var budgetBytes: Int64 {
        get { budgetLock.withLock { _budgetBytes } }
        set { budgetLock.withLock { _budgetBytes = max(newValue, 0) } }
    }

    public var memoryTier: PageMemoryTier { memory }

    public var memoryStats: MemoryCacheStats { memory.stats }

    public func setMemoryBudget(_ bytes: Int) {
        memory.budgetBytes = bytes
    }

    // ---------------------------------------------------------------- lookup

    /// Resolve a page for display, stamping it as recently used.
    ///
    /// This is the healing path: a row whose file has disappeared is deleted here
    /// rather than reported, and so is one whose bytes are not a complete image.
    /// Both answers are nil, which sends the caller to the network again instead
    /// of serving a broken picture forever. A prefetch hit is promoted on the way
    /// out, because the reader is looking at it now.
    public func lookup(key: String, now: String) throws -> PageLocation? {
        guard let entry = try store.cacheEntry(key: key) else {
            // No row. The bytes can still be resident: eviction removes file and
            // ledger together, and without this branch the RAM copy of an evicted
            // page would be dead weight while the reader re-downloaded the very
            // bytes it already holds.
            guard let resident = memory.value(for: key) else { return nil }
            return try reland(key: key, bytes: resident, contentType: contentTypeForResident(key: key), now: now)
        }
        let url = URL(fileURLWithPath: entry.path)
        let tier = Tier.fromKind(entry.kind)

        if !disk.exists(url) {
            // The file is gone. If the bytes are still resident — prefetched
            // seconds ago, then swept by an eviction this call cannot see — land
            // them again instead of paying for a network round trip.
            if let resident = memory.value(for: key) {
                return try reland(
                    key: key, bytes: resident, contentType: contentType(forPath: entry.path), now: now
                )
            }
            _ = try store.removeCacheEntry(key: key)
            return nil
        }

        if case .corrupt = ImageIntegrity.quickCheckFile(at: url, declaredSize: entry.size) {
            // A half file must not be a hit, and its debris must not stay: the
            // next fetch then lands cleanly instead of looping on the same body.
            memory.remove(key)
            try disk.remove(url)
            _ = try store.removeCacheEntry(key: key)
            return nil
        }

        if tier == .prefetch {
            return try promote(key: key, currentPath: entry.path, now: now)
        }

        try store.touchCacheEntry(key: key, now: now)
        // Trust the recorded size, but never report a phantom: re-measure.
        let size = disk.size(of: url) ?? entry.size
        return PageLocation(url: url, size: size, tier: tier)
    }

    /// Re-land resident bytes into the displayed tier after their file was lost,
    /// and stop holding RAM for them once they are on disk.
    private func reland(key: String, bytes: Data, contentType: String, now: String) throws -> PageLocation {
        let landed = try storeTier(
            key: key, bytes: bytes, contentType: contentType, now: now, kind: .page, declaredSize: nil
        )
        // The bytes are on disk in the displayed tier now; holding them in RAM too
        // would double the cost of a warm page.
        memory.remove(key)
        return landed
    }

    /// Cheap existence check for the prefetch planner: one ledger read per book,
    /// no stat, no validation. See `KomgaStore.cachedKeys` for why that is safe.
    public func isCached(key: String) throws -> Bool {
        guard let entry = try store.cacheEntry(key: key) else { return false }
        return disk.exists(URL(fileURLWithPath: entry.path))
    }

    /// Which of a manifest's pages the ledger believes are on disk — both tiers
    /// count as warm, because the question is "is there any reason to ask the
    /// server again".
    public func cachedPages(manifest: PageManifest) throws -> Set<UInt32> {
        let prefix = DiskImageCache.safeKey("\(manifest.serverID)-\(manifest.bookID)-p")
        let warm = try store.cachedKeys(prefix: prefix)
        var numbers: Set<UInt32> = []
        for page in manifest.pages where warm.contains(manifest.cacheKey(page.number)) {
            numbers.insert(page.number)
        }
        return numbers
    }

    /// Is this page's bytes currently resident? The eviction path deletes a row
    /// and its file together, so without a question like this there is no way to
    /// tell "not cached" from "cached in RAM, waiting to be relanded".
    public func isResident(key: String) -> Bool {
        memory.contains(key)
    }

    /// Which pages are in the memory tier right now — the number that says
    /// whether prefetch is actually arriving early enough to matter.
    public func residentPages(manifest: PageManifest) -> Set<UInt32> {
        var numbers: Set<UInt32> = []
        for page in manifest.pages where memory.contains(manifest.cacheKey(page.number)) {
            numbers.insert(page.number)
        }
        return numbers
    }

    // ----------------------------------------------------------------- write

    /// Commit fetched bytes the reader asked for.
    ///
    /// `kind` defaults to the displayed tier, so a display path reads exactly as
    /// it did before Stage 8; a prefetch pass names `.prefetch` and its bytes
    /// become the first victims of the next trim instead of the reader's hot set.
    /// `declaredSize` is the page's size as the server's own manifest reported it,
    /// which is the only witness able to prove a response arrived short — nothing
    /// on disk can tell a complete small image from a truncated large one.
    @discardableResult
    public func store(
        key: String,
        bytes: Data,
        contentType: String,
        now: String,
        kind: Tier = .page,
        declaredSize: Int64? = nil
    ) throws -> PageLocation {
        try storeTier(
            key: key, bytes: bytes, contentType: contentType, now: now,
            kind: kind, declaredSize: declaredSize
        )
    }

    /// Commit prefetched bytes into `prefetch/` and hold them in the memory tier
    /// as well, so the first display of this page costs neither a download nor a
    /// file read. A page too large for the tier is still cached on disk — the
    /// memory tier is an optimisation, never a requirement.
    @discardableResult
    public func storePrefetch(
        key: String,
        bytes: Data,
        contentType: String,
        now: String,
        declaredSize: Int64? = nil
    ) throws -> PageLocation {
        try storeTier(
            key: key, bytes: bytes, contentType: contentType, now: now,
            kind: .prefetch, declaredSize: declaredSize
        )
    }

    func storeTier(
        key: String,
        bytes: Data,
        contentType: String,
        now: String,
        kind: Tier,
        declaredSize: Int64?
    ) throws -> PageLocation {
        if bytes.count < minPageBytes { throw PageCacheError.refusingToCacheEmptyPage }
        // The deep check runs here, once, while the bytes are already in hand.
        // Later reads only need the head-and-tail proof. On Apple the deep check
        // also opens the container with ImageIO, so the verdict is computed once
        // and reused for the naming rule below rather than derived twice.
        let verdict = ImageIntegrity.inspect(
            bytes, declaredContentType: contentType, declaredSize: declaredSize
        )
        if case let .corrupt(corruption) = verdict {
            throw PageCacheError.corrupt(reason: corruption.reason)
        }
        let ext = `extension`(for: verdict, contentType: contentType)

        // The extension follows the bytes, so an earlier attempt under a different
        // one must not leave an orphan behind.
        if let previous = try store.cacheEntry(key: key) {
            let previousURL = URL(fileURLWithPath: previous.path)
            if previousURL.pathExtension != ext {
                try disk.remove(previousURL)
                memory.remove(key)
            }
        }

        let name = DiskImageCache.safeKey(key) + "." + ext
        let url = disk.url(inTier: kind.dir, named: name)
        do {
            try disk.storePage(bytes, at: url)
        } catch {
            throw PageCacheError.disk(String(describing: error))
        }
        guard let size = disk.size(of: url) else {
            throw PageCacheError.missingAfterWrite(url.path)
        }
        do {
            try store.recordCacheEntry(
                key: key, kind: kind.kind, path: url.path, size: size, now: now
            )
        } catch {
            throw PageCacheError.store(String(describing: error))
        }
        // The size limit runs here, or it does not run at all.
        try enforceBudget(exceptKey: key)
        if kind == .prefetch {
            // Prefetch bytes are held in RAM as well as on disk. The first display
            // of a prefetched page then costs no file read, and if the pool is
            // tight enough that its file is trimmed before the reader arrives, the
            // resident copy relands it instead of a second download.
            memory.insert(bytes, for: key)
        }
        return PageLocation(url: url, size: size, tier: kind)
    }

    /// Prefer the container the bytes actually are; fall back to the declared
    /// content type when this module cannot walk it.
    func extensionFor(bytes: Data, contentType: String) -> String {
        `extension`(
            for: ImageIntegrity.inspect(bytes, declaredContentType: contentType),
            contentType: contentType
        )
    }

    /// The same rule read off a verdict already in hand. `extension` is a keyword,
    /// so the backticks are the honest spelling rather than a rename that would
    /// lose the connection to Rust's `extension_for`.
    func `extension`(for verdict: Verdict, contentType: String) -> String {
        switch verdict {
        case let .valid(info), let .reclassified(info, _):
            return info.format.fileExtension ?? "img"
        default:
            return String(
                pageExtension(forContentType: contentType).drop(while: { $0 == "." })
            )
        }
    }

    // ------------------------------------------------------------- promote

    /// Move a prefetched page into the displayed tier: a rename, then the ledger
    /// follows. After this the entry is no longer the first victim of eviction,
    /// which is the whole point of having two tiers.
    @discardableResult
    public func promote(key: String, currentPath: String, now: String) throws -> PageLocation {
        let source = URL(fileURLWithPath: currentPath)
        let target: URL
        do {
            target = try disk.relocate(source, toTier: DiskImageCache.pagesTier)
        } catch {
            throw PageCacheError.disk(String(describing: error))
        }
        do {
            // The leaf is unchanged, so the ledger's new path is derived, not
            // guessed.
            try store.relocateCacheEntry(
                key: key, path: target.path, kind: CacheKind.page, now: now
            )
        } catch let error as CacheLedgerError {
            throw PageCacheError.store(String(describing: error))
        }
        // Promotion hands the bytes to disk and stops holding RAM for them.
        memory.remove(key)
        let size = disk.size(of: target) ?? 0
        return PageLocation(url: target, size: size, tier: .page)
    }

    // -------------------------------------------------------------- eviction

    /// Trim the pool to `budget`, prefetch tier first, never touching an offline
    /// download. Returns how many entries were dropped.
    @discardableResult
    public func evictToBudget(_ budget: Int64) throws -> Int {
        let removed = try store.evictCacheToBudget(budget: budget) { [disk] path in
            disk.exists(URL(fileURLWithPath: path))
        }
        for path in removed {
            try disk.remove(URL(fileURLWithPath: path))
        }
        return removed.count
    }

    /// Trim to this cache's configured pool.
    @discardableResult
    public func enforceBudget() throws -> Int {
        try enforceBudget(exceptKey: nil)
    }

    /// `enforceBudget` with one key held back. Runs after every store, on the
    /// cheap ledger total: walking the filesystem per page turn would make a
    /// 500-page book O(n^2) to read.
    @discardableResult
    public func enforceBudget(exceptKey: String?) throws -> Int {
        let budget = budgetBytes
        guard budget > 0 else { return 0 }
        let used = try store.cacheTotalBytesFast()
        guard used > budget else { return 0 }
        let removed = try store.evictCacheToBudget(budget: budget, exceptKey: exceptKey) { [disk] path in
            disk.exists(URL(fileURLWithPath: path))
        }
        for path in removed {
            try disk.remove(URL(fileURLWithPath: path))
        }
        // Deliberately no memory release here: eviction drops the row and the
        // file together, and the resident copy is what lets the next display
        // reland the page instead of re-downloading it. Dropping it here is how a
        // bounded pool ends up holding bytes no reader can reach.
        return removed.count
    }

    /// Bytes the ledger believes are on disk, with no filesystem walk. This is
    /// what the per-store budget check reads.
    public func bytesUsedFast() throws -> Int64 {
        try store.cacheTotalBytesFast()
    }

    /// Bytes actually on disk: the reconciling variant, which prunes rows whose
    /// file already vanished. Runs on open, not on the hot path.
    public func bytesUsed() throws -> Int64 {
        try store.cacheTotalBytes { [disk] path in
            disk.exists(URL(fileURLWithPath: path))
        }
    }

    public func bytes(ofTier tier: Tier) throws -> Int64 {
        try store.cacheBytes(kind: tier.kind)
    }

    // -------------------------------------------------------------- cleanup

    /// Drop a whole tier. This is the user-facing "clear the reader cache":
    /// dropping `.prefetch` frees the bytes the reader guessed at while leaving
    /// every page it actually displayed, and dropping `.page` still never touches
    /// an offline download, because the ledger refuses to hand back a protected
    /// path.
    @discardableResult
    public func clearTier(_ tier: Tier) throws -> Int {
        // Prefetched bytes are held twice on purpose — RAM and `prefetch/` — so
        // releasing the tier has to release both, or the memory pressure response
        // would free the part nobody was short of.
        let keys = try store.cacheEntries()
            .filter { $0.kind == tier.kind }
            .map(\.key)
        let paths = try store.deleteCacheEntries(kind: tier.kind)
        for path in paths {
            try disk.remove(URL(fileURLWithPath: path))
        }
        for key in keys {
            memory.remove(key)
        }
        return paths.count
    }

    /// Drop every cached page of one book (used when a book is pruned).
    @discardableResult
    public func clearBook(serverID: String, bookID: String) throws -> Int {
        let prefix = DiskImageCache.safeKey("\(serverID)-\(bookID)-p")
        // The key set has to be read before the rows are deleted: afterwards
        // there is nothing left to tell the memory tier which bytes are dead.
        let keys = try store.cachedKeys(prefix: prefix)
        let paths = try store.deleteCacheEntries(keyPrefix: prefix)
        for path in paths {
            try disk.remove(URL(fileURLWithPath: path))
        }
        for key in keys {
            memory.remove(key)
        }
        return paths.count
    }

    /// Reconcile the ledger with the filesystem, then trim. Runs on open, not on
    /// the hot path, and makes every permanent-looking inconsistency transient.
    ///
    /// Where the two disagree the filesystem wins, because it is the witness: a
    /// row whose file is gone is deleted, a file no row describes is deleted, and
    /// a row that names the wrong tier is repaired to name the one its file
    /// actually sits in.
    public func reconcile(now: String) throws -> ReconcileReport {
        var report = ReconcileReport(staleParts: try disk.removeStaleParts())
        let protectedBefore = try store.protectedCachePaths()

        var livePaths: Set<String> = []
        for entry in try store.cacheEntries() {
            let url = URL(fileURLWithPath: entry.path)
            guard disk.exists(url) else {
                // Nothing was freed: the bytes were already gone. Counting the
                // row's claimed size here would inflate what the sweep reports.
                _ = try store.removeCacheEntry(key: entry.key)
                report.ghostRows += 1
                continue
            }
            let actualSize = disk.size(of: url) ?? 0
            if actualSize != entry.size && protectedBefore.contains(entry.path) {
                // A download whose recorded size drifted is not a cache entry to
                // recycle; leave it and let the download feature reconcile it.
                livePaths.insert(entry.path)
                continue
            }
            if actualSize != entry.size {
                // The ledger's number drives eviction, so a lie here is worse than
                // a missing file: it hides real bytes.
                try disk.remove(url)
                _ = try store.removeCacheEntry(key: entry.key)
                report.corrupt += 1
                report.freedBytes += max(actualSize, 0)
                continue
            }
            if case .corrupt = ImageIntegrity.quickCheckFile(at: url, declaredSize: entry.size) {
                try disk.remove(url)
                _ = try store.removeCacheEntry(key: entry.key)
                report.corrupt += 1
                report.freedBytes += actualSize
                continue
            }
            // The tier is a fact about the path, not about the row.
            let kindOnDisk = tierOfPath(entry.path).kind
            if kindOnDisk != entry.kind && entry.kind != CacheKind.download {
                try store.relocateCacheEntry(
                    key: entry.key, path: entry.path, kind: kindOnDisk, now: now
                )
                report.kindRepaired += 1
            }
            livePaths.insert(entry.path)
        }

        // Files the user owns outright are never orphans, even with no
        // `cache_entries` row: `downloads` / `download_pages` are the schema's own
        // statement of what may not be swept, so a future offline-download feature
        // cannot erase a user's book by forgetting to also file an LRU row.
        let protected = try store.protectedCachePaths()
        for dir in [DiskImageCache.pagesTier, DiskImageCache.prefetchTier] {
            for name in try disk.files(inTier: dir) {
                let url = disk.directoryURL(forTier: dir).appendingPathComponent(name)
                if protected.contains(url.path) {
                    if !livePaths.contains(url.path) { report.protectedKept += 1 }
                    continue
                }
                if !livePaths.contains(url.path) {
                    let size = disk.size(of: url) ?? 0
                    try disk.remove(url)
                    report.orphanFiles += 1
                    report.freedBytes += size
                }
            }
        }

        report.evicted = try enforceBudget()
        // Mirror of the Rust sweep line, including the condition: a sweep
        // that found nothing says nothing, because a reader that has to
        // filter noise out of the log stops reading it. This is the only
        // moment a cache that is quietly failing every day becomes visible
        // from outside — the person reading sees a page reload.
        if report.ghostRows + report.orphanFiles + report.staleParts + report.corrupt > 0 {
            CoreLog.shared.info(
                "KomgaReader.PageCache",
                "cache sweep: \(report.ghostRows) ghost rows, \(report.orphanFiles) orphan files, "
                    + "\(report.staleParts) stale parts, \(report.corrupt) corrupt, "
                    + "\(report.evicted) evicted, \(report.freedBytes) bytes freed"
            )
        }
        return report
    }

    /// Which tier a recorded path lives in. Anything outside the prefetch tier
    /// reads as the displayed tier, which is also where a download's files go.
    private func tierOfPath(_ path: String) -> Tier {
        let prefetchRoot = disk.directoryURL(forTier: DiskImageCache.prefetchTier).path
        return path.hasPrefix(prefetchRoot + "/") ? .prefetch : .page
    }
}

/// The content type a resident entry was filed under. A resident entry has no
/// path to read an extension from, so the bytes are their own witness:
/// `storeTier` sniffs them anyway and names the file after what it finds.
func contentTypeForResident(key: String) -> String {
    "application/octet-stream"
}

/// The content type implied by a cached file's extension — the only witness left
/// once the response headers are gone.
func contentType(forPath path: String) -> String {
    switch (path as NSString).pathExtension {
    case "png": return "image/png"
    case "jpg", "jpeg": return "image/jpeg"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    default: return "application/octet-stream"
    }
}

// MARK: - Process-wide memory tier

/// Swift 6 will not allow a bare `var` global; the box is the same shape
/// `ByteBudgetCache` uses for its own state — a reference the lock guards.
private final class SharedMemoryBox: @unchecked Sendable {
    var tier: PageMemoryTier?
}

private let sharedMemoryLock = NSLock()
private let sharedMemoryBox = SharedMemoryBox()

/// The process-wide memory tier, for a facade that rebuilds its cache per call
/// and for resetting it between acceptance phases.
public func processMemoryTier() -> PageMemoryTier {
    sharedMemoryLock.withLock {
        if let existing = sharedMemoryBox.tier { return existing }
        let fresh = PageMemoryTier()
        sharedMemoryBox.tier = fresh
        return fresh
    }
}

/// Replace the process-wide tier with an empty one. What an acceptance harness
/// does between phases so one run's warm bytes cannot flatter the next.
public func resetProcessMemoryTier() {
    sharedMemoryLock.withLock {
        sharedMemoryBox.tier?.removeAll()
        sharedMemoryBox.tier = nil
    }
}
