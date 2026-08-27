import Foundation
import KomgaAPI
import KomgaStore

/// Fetching abstraction so the mirror can be tested without network.
/// KomgaTransport conforms via the extension below.
public protocol LibraryFetching: SeriesPageFetching {
    /// `GET /api/v1/libraries` — the plain array that starts every run.
    func fetchLibraries() async throws -> [LibraryDTO]
    func fetchBooksPage(seriesID: String, request: PageRequest) async throws -> BookPageDTO
    func fetchOnDeckPage(request: PageRequest) async throws -> BookPageDTO
    func fetchCollectionsPage(request: PageRequest) async throws -> CollectionPageDTO
    func fetchReadlistsPage(request: PageRequest) async throws -> ReadListPageDTO
}

extension KomgaTransport: LibraryFetching {}

/// Page size used by the local mirror (remote pagination slices).
public let fullSyncPageSize = 100

/// Whether to continue from the stored cursors or start the mirror over.
public enum StartAt: Sendable, Equatable {
    /// Continue from the first step that has unfinished work.
    case resume
    /// Forget every cursor and re-mirror from the top (manual rebuild).
    case fresh
}

/// Tally of one mirror run (rows written per step, not local row counts).
public struct FullSyncSummary: Sendable, Equatable {
    public var serverID: String
    public var libraries: Int
    public var series: Int
    public var books: Int
    public var collections: Int
    public var readlists: Int
    public var readProgress: Int
    public var seriesPages: Int
    public var bookPages: Int
    /// Steps that had already completed, so this run skipped them.
    public var skippedSteps: [String]
    /// Steps this run continued from a stored cursor (interrupt recovery).
    public var resumedSteps: [String]

    public init(
        serverID: String,
        libraries: Int = 0,
        series: Int = 0,
        books: Int = 0,
        collections: Int = 0,
        readlists: Int = 0,
        readProgress: Int = 0,
        seriesPages: Int = 0,
        bookPages: Int = 0,
        skippedSteps: [String] = [],
        resumedSteps: [String] = []
    ) {
        self.serverID = serverID
        self.libraries = libraries
        self.series = series
        self.books = books
        self.collections = collections
        self.readlists = readlists
        self.readProgress = readProgress
        self.seriesPages = seriesPages
        self.bookPages = bookPages
        self.skippedSteps = skippedSteps
        self.resumedSteps = resumedSteps
    }
}

/// Bootstrap Sync — mirrors the whole media library into SQLite and can pick
/// up where an interrupted run stopped.
///
/// Step order comes from `specs/contracts/initial-sync/README.md`:
/// **Libraries → Series → Books → Collections → Readlists → Read Progress**.
/// Each step pages its endpoint, commits its pages, and records its resume
/// cursor as it goes, so an interrupted run continues from the next page
/// instead of re-downloading the library. A failed step keeps its cursor and
/// is flagged `error` in `sync_state`; the next run picks it up automatically.
///
/// Once a step has completed it is not repeated: keeping the mirror current is
/// Reconcile's job (`ReconcileSync`). `StartAt.fresh` forces a re-mirror.
///
/// The UI reads SQLite while this runs (local-first): a partially mirrored
/// library is browsable, just smaller than the final one.
public enum FullSync {
    /// Mirror one server's library, continuing from wherever a previous run
    /// stopped.
    public static func run(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String,
        start: StartAt = .resume
    ) async throws -> FullSyncSummary {
        var summary = FullSyncSummary(serverID: serverID)
        if start == .fresh {
            try store.clearSyncProgress(serverID: serverID)
        }

        if try stepPlan(store: store, serverID: serverID, entity: SyncEntity.libraries, summary: &summary) {
            summary.libraries = try await syncLibraries(fetcher: fetcher, store: store, serverID: serverID)
        }
        if try stepPlan(store: store, serverID: serverID, entity: SyncEntity.series, summary: &summary) {
            let (written, pages) = try await syncSeries(fetcher: fetcher, store: store, serverID: serverID)
            summary.series += written
            summary.seriesPages += pages
        }
        if try stepPlan(store: store, serverID: serverID, entity: SyncEntity.books, summary: &summary) {
            let step = try await syncBooks(fetcher: fetcher, store: store, serverID: serverID)
            summary.books += step.written
            summary.bookPages += step.pages
            summary.readProgress += step.progress
        }
        if try stepPlan(store: store, serverID: serverID, entity: SyncEntity.collections, summary: &summary) {
            summary.collections = try await syncCollections(fetcher: fetcher, store: store, serverID: serverID)
        }
        if try stepPlan(store: store, serverID: serverID, entity: SyncEntity.readlists, summary: &summary) {
            summary.readlists = try await syncReadlists(fetcher: fetcher, store: store, serverID: serverID)
        }
        if try stepPlan(store: store, serverID: serverID, entity: SyncEntity.readProgress, summary: &summary) {
            summary.readProgress += try await syncReadProgress(fetcher: fetcher, store: store, serverID: serverID)
        }

        try store.recordFullSync(serverID: serverID)
        return summary
    }

    /// Bootstrap Sync: the resumable run (alias of `run(start: .resume)`).
    public static func bootstrapSync(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> FullSyncSummary {
        try await run(fetcher: fetcher, store: store, serverID: serverID, start: .resume)
    }

    /// Per-step sync state by entity type (UI "sync progress" surface).
    public static func progress(store: KomgaStore, serverID: String) throws -> [String: EntitySyncState] {
        try store.listEntityStates(serverID: serverID).reduce(into: [:]) { acc, row in
            acc[row.entityType] = row
        }
    }

    // MARK: - Cursors

    /// `"page=3"` → `3`; an unparseable cursor restarts that step at page 0.
    static func parsePage(_ cursor: String) -> Int {
        guard cursor.hasPrefix("page="), let page = Int(cursor.dropFirst("page=".count)) else {
            return 0
        }
        return page
    }

    static func pageCursor(_ page: Int) -> String {
        "page=\(page)"
    }

    /// Books are swept series by series (in `remote_id` order), so their cursor
    /// names the series plus the page within it: `"series=s2|page=1"`.
    static func bookCursor(seriesID: String, page: Int) -> String {
        "series=\(seriesID)|page=\(page)"
    }

    static func parseBookCursor(_ cursor: String) -> (seriesID: String, page: Int)? {
        var series: String?
        var page: Int?
        for pair in cursor.split(separator: "|", omittingEmptySubsequences: true) {
            if pair.hasPrefix("series=") {
                series = String(pair.dropFirst("series=".count))
            } else if pair.hasPrefix("page="), let value = Int(pair.dropFirst("page=".count)) {
                page = value
            }
        }
        guard let series, let page else { return nil }
        return (series, page)
    }

    // MARK: - Step plumbing

    /// Run one step, recording its status transitions (`syncing` → `idle`/`error`).
    static func runStep<T>(
        store: KomgaStore,
        serverID: String,
        entity: String,
        work: () async throws -> T
    ) async throws -> T {
        try store.beginEntity(serverID: serverID, entityType: entity)
        do {
            let value = try await work()
            try store.completeEntity(serverID: serverID, entityType: entity)
            return value
        } catch {
            // Error recovery: keep the cursor so the next run resumes, and
            // surface the failure on both the step row and the rollup row.
            let message = String(describing: error)
            try? store.failEntity(serverID: serverID, entityType: entity, error: message)
            try? store.recordFailedSync(serverID: serverID, error: message)
            throw error
        }
    }

    /// Decide whether to run a step, and note resume/skip decisions on the summary.
    private static func stepPlan(
        store: KomgaStore,
        serverID: String,
        entity: String,
        summary: inout FullSyncSummary
    ) throws -> Bool {
        if try store.stepIsComplete(serverID: serverID, entityType: entity) {
            summary.skippedSteps.append(entity)
            return false
        }
        if try store.resumeCursor(serverID: serverID, entityType: entity) != nil {
            summary.resumedSteps.append(entity)
        }
        return true
    }

    // MARK: - Steps

    /// 1. Libraries: `GET /api/v1/libraries` returns a plain array, so this
    ///    step is one request — it still runs first and is still checkpointed,
    ///    so a later interrupted step never re-triggers it.
    private static func syncLibraries(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> Int {
        try await runStep(store: store, serverID: serverID, entity: SyncEntity.libraries) {
            let libraries = try await fetcher.fetchLibraries()
            return try store.upsertLibraries(serverID: serverID, libraries: libraries)
        }
    }

    /// 2. Series: page sweep until `last`.
    static func syncSeries(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> (written: Int, pages: Int) {
        try await runStep(store: store, serverID: serverID, entity: SyncEntity.series) {
            var page = try store.resumeCursor(serverID: serverID, entityType: SyncEntity.series)
                .map(parsePage) ?? 0
            var written = 0
            var pages = 0
            while true {
                let response = try await fetcher.fetchSeriesPage(PageRequest(page: page, size: fullSyncPageSize))
                let last = response.last
                written += try store.upsertSeriesBatch(serverID: serverID, series: response.content)
                pages += 1
                if !last {
                    try store.checkpointEntity(
                        serverID: serverID,
                        entityType: SyncEntity.series,
                        cursor: pageCursor(page + 1)
                    )
                }
                if last { break }
                page += 1
            }
            return (written, pages)
        }
    }

    /// 3. Books: sweep every local series — including ones that now look empty,
    ///    because those are where a remote book deletion shows up.
    static func syncBooks(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> (written: Int, pages: Int, progress: Int) {
        let seriesIDs = try store.localIDs(serverID: serverID, entityType: SyncEntity.series)
        let resume = try store.resumeCursor(serverID: serverID, entityType: SyncEntity.books)
            .flatMap(parseBookCursor)
        return try await runStep(store: store, serverID: serverID, entity: SyncEntity.books) {
            var index = 0
            if let resume {
                // Skip the series a previous run finished. The cursor names the
                // series that was still in progress, so that one is re-entered
                // at `resume.page` below — stepping past it would silently drop
                // the rest of its pages.
                while index < seriesIDs.count && seriesIDs[index] < resume.seriesID {
                    index += 1
                }
            }
            var written = 0
            var pages = 0
            var progress = 0
            while index < seriesIDs.count {
                let seriesID = seriesIDs[index]
                var page: Int
                if let resume, resume.seriesID == seriesID {
                    page = resume.page
                } else {
                    page = 0
                }
                while true {
                    let response = try await fetcher.fetchBooksPage(
                        seriesID: seriesID,
                        request: PageRequest(page: page, size: fullSyncPageSize)
                    )
                    progress += response.content.filter { $0.readProgress != nil }.count
                    let last = response.last
                    written += try store.upsertBooksBatch(serverID: serverID, books: response.content)
                    pages += 1
                    if !last {
                        try store.checkpointEntity(
                            serverID: serverID,
                            entityType: SyncEntity.books,
                            cursor: bookCursor(seriesID: seriesID, page: page + 1)
                        )
                    }
                    if last { break }
                    page += 1
                }
                index += 1
                // Checkpoint the series boundary too: a run interrupted at the
                // next series' first page would otherwise restart from the top.
                if let next = seriesIDs.dropFirst(index).first {
                    try store.checkpointEntity(
                        serverID: serverID,
                        entityType: SyncEntity.books,
                        cursor: bookCursor(seriesID: next, page: 0)
                    )
                }
            }
            return (written, pages, progress)
        }
    }

    /// 4. Collections (membership rides along in each CollectionDto).
    static func syncCollections(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> Int {
        try await runStep(store: store, serverID: serverID, entity: SyncEntity.collections) {
            var page = try store.resumeCursor(serverID: serverID, entityType: SyncEntity.collections)
                .map(parsePage) ?? 0
            var written = 0
            while true {
                let response = try await fetcher.fetchCollectionsPage(
                    request: PageRequest(page: page, size: fullSyncPageSize)
                )
                let last = response.last
                written += try store.upsertCollectionsBatch(
                    serverID: serverID, collections: response.content
                )
                if !last {
                    try store.checkpointEntity(
                        serverID: serverID,
                        entityType: SyncEntity.collections,
                        cursor: pageCursor(page + 1)
                    )
                }
                if last { break }
                page += 1
            }
            return written
        }
    }

    /// 5. Readlists (ordered membership rides along in each ReadListDto).
    static func syncReadlists(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> Int {
        try await runStep(store: store, serverID: serverID, entity: SyncEntity.readlists) {
            var page = try store.resumeCursor(serverID: serverID, entityType: SyncEntity.readlists)
                .map(parsePage) ?? 0
            var written = 0
            while true {
                let response = try await fetcher.fetchReadlistsPage(
                    request: PageRequest(page: page, size: fullSyncPageSize)
                )
                let last = response.last
                written += try store.upsertReadlistsBatch(
                    serverID: serverID, readlists: response.content
                )
                if !last {
                    try store.checkpointEntity(
                        serverID: serverID,
                        entityType: SyncEntity.readlists,
                        cursor: pageCursor(page + 1)
                    )
                }
                if last { break }
                page += 1
            }
            return written
        }
    }

    /// 6. Read progress: the on-deck shelf is the remote continue-reading hint.
    static func syncReadProgress(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> Int {
        try await runStep(store: store, serverID: serverID, entity: SyncEntity.readProgress) {
            var page = try store.resumeCursor(serverID: serverID, entityType: SyncEntity.readProgress)
                .map(parsePage) ?? 0
            var applied = 0
            while true {
                let response = try await fetcher.fetchOnDeckPage(
                    request: PageRequest(page: page, size: fullSyncPageSize)
                )
                let last = response.last
                for book in response.content {
                    guard let progress = book.readProgress else { continue }
                    try store.upsertSyncedReadProgress(
                        serverID: serverID,
                        bookID: book.id,
                        page: progress.page.map(Int64.init),
                        completed: progress.completed ?? false,
                        serverUpdatedAt: progress.lastModified
                    )
                    applied += 1
                }
                if !last {
                    try store.checkpointEntity(
                        serverID: serverID,
                        entityType: SyncEntity.readProgress,
                        cursor: pageCursor(page + 1)
                    )
                }
                if last { break }
                page += 1
            }
            return applied
        }
    }
}
