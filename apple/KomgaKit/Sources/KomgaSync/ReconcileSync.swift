import Foundation
import KomgaAPI
import KomgaStore

/// Reconciliation Sync — converge the local mirror on the server's truth
/// without needing any SSE events.
///
/// Komga has no changelog and no "deleted ids" endpoint, so the only reliable
/// reconciliation is an **id sweep**: for each entity type page through the
/// remote list, upsert what came back (Added / Changed) and then prune the
/// local ids the server no longer reports (Deleted → cascade + tombstone).
/// That is why this works with SSE completely broken: events are a hint to
/// reconcile sooner, never a source of truth.
///
/// Safety rule: pruning only happens after a sweep reached its last page. A
/// partial sweep is never evidence that an entity is gone, so a failed
/// reconciliation can only ever delay a deletion — it can never delete local
/// data the server still has. When a sweep resumes from a cursor, the ids of
/// the pages it already committed are seeded from the local rows (they came
/// from the server minutes ago), which keeps the same bias.

/// Why a reconciliation ran (mirror of Rust `ReconcileTrigger`). Every one of
/// them is a full sweep: correctness never depends on which trigger fired.
public enum ReconcileTrigger: String, Sendable, CaseIterable {
    /// Cold start of the app.
    case appLaunch = "app_launch"
    /// App came back to the foreground.
    case didBecomeActive = "did_become_active"
    /// Connectivity came back.
    case networkRecovered = "network_recovered"
    /// The SSE stream reconnected — events may have been missed while down.
    case sseReconnected = "sse_reconnected"
    /// The user pulled to refresh.
    case manualRefresh = "manual_refresh"

    /// Launch / foreground triggers can fire often; the explicit ones mean
    /// "the user (or the reconnecting stream) wants current data now".
    var isBackground: Bool {
        self == .appLaunch || self == .didBecomeActive
    }
}

/// Minimum gap between background-triggered reconciliations, in seconds.
public let minReconcileIntervalSeconds: TimeInterval = 60

/// What one reconciliation pass did.
public struct ReconcileSummary: Sendable, Equatable {
    public var serverID: String
    public var trigger: String
    public var seriesUpserted: Int
    public var seriesAdded: Int
    public var seriesChanged: Int
    public var seriesRemoved: Int
    public var booksUpserted: Int
    public var booksAdded: Int
    public var booksChanged: Int
    public var booksRemoved: Int
    public var collectionsUpserted: Int
    public var collectionsAdded: Int
    public var collectionsChanged: Int
    public var collectionsRemoved: Int
    public var readlistsUpserted: Int
    public var readlistsAdded: Int
    public var readlistsChanged: Int
    public var readlistsRemoved: Int
    public var librariesUpserted: Int
    public var librariesRemoved: Int
    public var readProgress: Int
    public var pagesSwept: Int
    /// Cover file paths orphaned by pruning (the caller deletes them).
    public var orphanedCovers: [String]
    /// True when the mirror already matched the server and nothing changed.
    public var clean: Bool

    public init(
        serverID: String,
        trigger: String = "",
        seriesUpserted: Int = 0,
        seriesAdded: Int = 0,
        seriesChanged: Int = 0,
        seriesRemoved: Int = 0,
        booksUpserted: Int = 0,
        booksAdded: Int = 0,
        booksChanged: Int = 0,
        booksRemoved: Int = 0,
        collectionsUpserted: Int = 0,
        collectionsAdded: Int = 0,
        collectionsChanged: Int = 0,
        collectionsRemoved: Int = 0,
        readlistsUpserted: Int = 0,
        readlistsAdded: Int = 0,
        readlistsChanged: Int = 0,
        readlistsRemoved: Int = 0,
        librariesUpserted: Int = 0,
        librariesRemoved: Int = 0,
        readProgress: Int = 0,
        pagesSwept: Int = 0,
        orphanedCovers: [String] = [],
        clean: Bool = false
    ) {
        self.serverID = serverID
        self.trigger = trigger
        self.seriesUpserted = seriesUpserted
        self.seriesAdded = seriesAdded
        self.seriesChanged = seriesChanged
        self.seriesRemoved = seriesRemoved
        self.booksUpserted = booksUpserted
        self.booksAdded = booksAdded
        self.booksChanged = booksChanged
        self.booksRemoved = booksRemoved
        self.collectionsUpserted = collectionsUpserted
        self.collectionsAdded = collectionsAdded
        self.collectionsChanged = collectionsChanged
        self.collectionsRemoved = collectionsRemoved
        self.readlistsUpserted = readlistsUpserted
        self.readlistsAdded = readlistsAdded
        self.readlistsChanged = readlistsChanged
        self.readlistsRemoved = readlistsRemoved
        self.librariesUpserted = librariesUpserted
        self.librariesRemoved = librariesRemoved
        self.readProgress = readProgress
        self.pagesSwept = pagesSwept
        self.orphanedCovers = orphanedCovers
        self.clean = clean
    }

    private var changedCount: Int {
        seriesAdded + seriesChanged + seriesRemoved
            + booksAdded + booksChanged + booksRemoved
            + collectionsAdded + collectionsChanged + collectionsRemoved
            + readlistsAdded + readlistsChanged + readlistsRemoved
            + librariesRemoved
    }

    /// Rows this pass moved; the smoke output and UI both use it.
    public func totalMutations() -> Int { changedCount }

    fileprivate func merged(with step: ReconcileStepTally) -> ReconcileSummary {
        var copy = self
        copy.seriesUpserted += step.seriesUpserted
        copy.seriesAdded += step.seriesAdded
        copy.seriesChanged += step.seriesChanged
        copy.seriesRemoved += step.seriesRemoved
        copy.booksUpserted += step.booksUpserted
        copy.booksAdded += step.booksAdded
        copy.booksChanged += step.booksChanged
        copy.booksRemoved += step.booksRemoved
        copy.collectionsUpserted += step.collectionsUpserted
        copy.collectionsAdded += step.collectionsAdded
        copy.collectionsChanged += step.collectionsChanged
        copy.collectionsRemoved += step.collectionsRemoved
        copy.readlistsUpserted += step.readlistsUpserted
        copy.readlistsAdded += step.readlistsAdded
        copy.readlistsChanged += step.readlistsChanged
        copy.readlistsRemoved += step.readlistsRemoved
        copy.librariesUpserted += step.librariesUpserted
        copy.librariesRemoved += step.librariesRemoved
        copy.readProgress += step.readProgress
        copy.pagesSwept += step.pagesSwept
        copy.orphanedCovers += step.orphanedCovers
        return copy
    }
}

/// One step's tallies, merged into the run summary by the caller (the async
/// step bodies cannot mutate the summary across a suspension point).
struct ReconcileStepTally: Sendable {
    var seriesUpserted = 0
    var seriesAdded = 0
    var seriesChanged = 0
    var seriesRemoved = 0
    var booksUpserted = 0
    var booksAdded = 0
    var booksChanged = 0
    var booksRemoved = 0
    var collectionsUpserted = 0
    var collectionsAdded = 0
    var collectionsChanged = 0
    var collectionsRemoved = 0
    var readlistsUpserted = 0
    var readlistsAdded = 0
    var readlistsChanged = 0
    var readlistsRemoved = 0
    var librariesUpserted = 0
    var librariesRemoved = 0
    var readProgress = 0
    var pagesSwept = 0
    var orphanedCovers: [String] = []
}

public enum ReconcileSync {
    /// Reconcile one server against its current remote state.
    public static func run(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String,
        trigger: ReconcileTrigger
    ) async throws -> ReconcileSummary {
        var summary = ReconcileSummary(serverID: serverID, trigger: trigger.rawValue)

        summary = summary.merged(with: try await reconcileLibraries(fetcher: fetcher, store: store, serverID: serverID))
        summary = summary.merged(with: try await reconcileSeries(fetcher: fetcher, store: store, serverID: serverID))
        summary = summary.merged(with: try await reconcileBooks(fetcher: fetcher, store: store, serverID: serverID))
        summary = summary.merged(with: try await reconcileCollections(fetcher: fetcher, store: store, serverID: serverID))
        summary = summary.merged(with: try await reconcileReadlists(fetcher: fetcher, store: store, serverID: serverID))
        summary = summary.merged(with: try await reconcileReadProgress(fetcher: fetcher, store: store, serverID: serverID))

        summary.clean = summary.totalMutations() == 0
        try store.recordSuccessfulSync(serverID: serverID)
        return summary
    }

    /// Should this trigger actually run a sweep right now?
    public static func shouldRun(
        store: KomgaStore,
        serverID: String,
        trigger: ReconcileTrigger,
        now: Date = Date()
    ) throws -> Bool {
        guard trigger.isBackground else {
            return true // explicit triggers always run
        }
        guard let last = try store.lastSyncedAt(serverID: serverID) else {
            return true // never synced: the first chance is the right chance
        }
        guard let lastDate = parseTimestamp(last) else {
            return true // unreadable stamp: re-sync rather than stay stale
        }
        return now.timeIntervalSince(lastDate) >= minReconcileIntervalSeconds
    }

    /// RFC 3339 with millisecond precision (matches the store's stamps), with a
    /// plain-Internet-date fallback for rows written by other clients.
    static func parseTimestamp(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }

    /// `known[id]` absent → Added; present with a different stamp → Changed.
    static func classify(
        _ known: [String: String?],
        id: String,
        stamp: String?
    ) -> (added: Bool, changed: Bool) {
        guard let knownStamp = known[id] else { return (true, false) }
        return (false, knownStamp != stamp)
    }

    /// Does this book need writing at all? New or edited metadata always does;
    /// otherwise only a read-progress change does — the server never bumps the
    /// book's own `lastModified` for one (mirror of Rust `needs_write`). The
    /// normalisation matches what the upsert would store.
    static func needsWrite(
        added: Bool,
        changed: Bool,
        remote: ReadProgressDTO?,
        stored: (page: Int64?, completed: Bool, serverUpdatedAt: String?)?
    ) -> Bool {
        if added || changed { return true }
        guard let remote else { return false }
        guard let stored else { return true }
        return stored.page != remote.page.map(Int64.init)
            || stored.completed != (remote.completed ?? false)
            || stored.serverUpdatedAt != remote.lastModified
    }

    /// Did the mirrored series columns move? `booksCount` and the read counters
    /// change without Komga touching `series.lastModified`, so comparing the
    /// stamp alone would miss them (mirror of Rust `series_projection`).
    static func countersMoved(
        stored: (
            lastModified: String?, booksCount: Int?, booksReadCount: Int?,
            booksUnreadCount: Int?, booksInProgressCount: Int?
        )?,
        remote: SeriesDTO
    ) -> Bool {
        guard let stored else { return true }
        return stored.lastModified != remote.lastModified
            || stored.booksCount != remote.booksCount
            || stored.booksReadCount != remote.booksReadCount
            || stored.booksUnreadCount != remote.booksUnreadCount
            || stored.booksInProgressCount != remote.booksInProgressCount
    }

    /// Members live in their own table and can be edited without a new
    /// `lastModifiedDate`, so they have to be compared too (mirror of Rust
    /// `members_moved`; membership is an unordered set).
    static func membersMoved(stored: [String]?, remoteSeriesIDs: [String]) -> Bool {
        guard let stored else { return !remoteSeriesIDs.isEmpty }
        return stored != remoteSeriesIDs.sorted()
    }

    /// The same check for a readlist, where the order of the books is itself
    /// the data (mirror of Rust `books_moved`).
    static func booksMoved(stored: [String]?, remoteBookIDs: [String]) -> Bool {
        guard let stored else { return !remoteBookIDs.isEmpty }
        return stored != remoteBookIDs
    }

    // MARK: - Steps

    private static func reconcileLibraries(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> ReconcileStepTally {
        try await FullSync.runStep(store: store, serverID: serverID, entity: SyncEntity.libraries) {
            let libraries = try await fetcher.fetchLibraries()
            let remote = Set(libraries.map(\.id))
            var tally = ReconcileStepTally()
            tally.librariesUpserted = try store.upsertLibraries(serverID: serverID, libraries: libraries)
            for id in remote {
                try store.clearTombstone(serverID: serverID, entityType: SyncEntity.libraries, remoteID: id)
            }
            tally.librariesRemoved = try store.prune(
                serverID: serverID,
                entityType: SyncEntity.libraries,
                remoteIDs: remote,
                cause: DeletionCause.reconcile
            ).count
            return tally
        }
    }

    private static func reconcileSeries(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> ReconcileStepTally {
        let seeded: Set<String>
        if try store.resumeCursor(serverID: serverID, entityType: SyncEntity.series) != nil {
            // Resuming: pages before the cursor were already committed locally.
            seeded = Set(try store.localIDs(serverID: serverID, entityType: SyncEntity.series))
        } else {
            seeded = []
        }
        return try await FullSync.runStep(store: store, serverID: serverID, entity: SyncEntity.series) {
            let known = try store.localStamps(serverID: serverID, entityType: SyncEntity.series)
            let projected = try store.localSeriesProjection(serverID: serverID)
            var remote = seeded
            var tally = ReconcileStepTally()
            var page = try store.resumeCursor(serverID: serverID, entityType: SyncEntity.series)
                .map(FullSync.parsePage) ?? 0
            while true {
                let response = try await fetcher.fetchSeriesPage(
                    PageRequest(page: page, size: fullSyncPageSize)
                )
                let last = response.last
                let ids = response.content.map(\.id)
                var dirty: [SeriesDTO] = []
                for series in response.content {
                    let (added, changed) = classify(known, id: series.id, stamp: series.lastModified)
                    tally.seriesAdded += added ? 1 : 0
                    tally.seriesChanged += changed ? 1 : 0
                    if added || changed
                        || countersMoved(stored: projected[series.id], remote: series)
                    {
                        dirty.append(series)
                    }
                }
                // A converged library costs a read sweep, not a page of upserts
                // that each rewrite their FTS row as well.
                if !dirty.isEmpty {
                    tally.seriesUpserted += try store.upsertSeriesBatch(serverID: serverID, series: dirty)
                }
                // A re-appearing id is not deleted any more.
                try store.clearTombstones(serverID: serverID, entityType: SyncEntity.series, remoteIDs: ids)
                // The delete diff still sees every id the sweep scanned, dirty or not.
                remote.formUnion(ids)
                tally.pagesSwept += 1
                if !last {
                    try store.checkpointEntity(
                        serverID: serverID,
                        entityType: SyncEntity.series,
                        cursor: FullSync.pageCursor(page + 1)
                    )
                }
                if last { break }
                page += 1
            }
            // Prune only after a complete sweep.
            let removed = try store.prune(
                serverID: serverID,
                entityType: SyncEntity.series,
                remoteIDs: remote,
                cause: DeletionCause.reconcile
            )
            tally.seriesRemoved = removed.count
            tally.orphanedCovers += removed.coverPaths
            return tally
        }
    }

    private static func reconcileBooks(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> ReconcileStepTally {
        let resume = try store.resumeCursor(serverID: serverID, entityType: SyncEntity.books)
            .flatMap(FullSync.parseBookCursor)
        return try await FullSync.runStep(store: store, serverID: serverID, entity: SyncEntity.books) {
            let seriesIDs = try store.localIDs(serverID: serverID, entityType: SyncEntity.series)
            let known = try store.localStamps(serverID: serverID, entityType: SyncEntity.books)
            let stored = try store.localReadProgress(serverID: serverID)
            // seriesID → remote book ids (the scoped prune input).
            var swept: [String: Set<String>] = [:]
            var tally = ReconcileStepTally()
            var index = 0
            var resumeSeries: String?
            if let resume {
                // Series before the cursor: their books are already mirrored.
                while index < seriesIDs.count && seriesIDs[index] < resume.seriesID {
                    swept[seriesIDs[index]] = Set(
                        try store.localBookIDs(serverID: serverID, seriesID: seriesIDs[index])
                    )
                    index += 1
                }
                resumeSeries = resume.seriesID
            }
            while index < seriesIDs.count {
                let seriesID = seriesIDs[index]
                var page = (resumeSeries == seriesID) ? resume?.page ?? 0 : 0
                var entry = swept[seriesID] ?? []
                if page > 0 {
                    // Mid-series resume: local rows for this series are the ids
                    // committed before the interruption.
                    entry.formUnion(try store.localBookIDs(serverID: serverID, seriesID: seriesID))
                }
                while true {
                    let response = try await fetcher.fetchBooksPage(
                        seriesID: seriesID,
                        request: PageRequest(page: page, size: fullSyncPageSize)
                    )
                    let last = response.last
                    let ids = response.content.map(\.id)
                    var dirty: [BookDTO] = []
                    for book in response.content {
                        let (added, changed) = classify(known, id: book.id, stamp: book.lastModified)
                        tally.booksAdded += added ? 1 : 0
                        tally.booksChanged += changed ? 1 : 0
                        if needsWrite(
                            added: added, changed: changed,
                            remote: book.readProgress, stored: stored[book.id]
                        ) {
                            dirty.append(book)
                        }
                    }
                    // A converged library costs a read sweep, not thousands of
                    // redundant upserts (each of which also rewrites its FTS row).
                    if !dirty.isEmpty {
                        tally.booksUpserted += try store.upsertBooksBatch(serverID: serverID, books: dirty)
                    }
                    try store.clearTombstones(serverID: serverID, entityType: SyncEntity.books, remoteIDs: ids)
                    entry.formUnion(ids)
                    tally.pagesSwept += 1
                    if !last {
                        try store.checkpointEntity(
                            serverID: serverID,
                            entityType: SyncEntity.books,
                            cursor: FullSync.bookCursor(seriesID: seriesID, page: page + 1)
                        )
                    }
                    if last { break }
                    page += 1
                }
                swept[seriesID] = entry
                index += 1
                // Same series-boundary checkpoint as Bootstrap: an interrupted
                // sweep resumes at the next series instead of restarting.
                if let next = seriesIDs.dropFirst(index).first {
                    try store.checkpointEntity(
                        serverID: serverID,
                        entityType: SyncEntity.books,
                        cursor: FullSync.bookCursor(seriesID: next, page: 0)
                    )
                }
            }
            let removed = try store.pruneBooksForSweptSeries(
                serverID: serverID, swept: swept, cause: DeletionCause.reconcile
            )
            tally.booksRemoved = removed.count
            tally.orphanedCovers += removed.coverPaths
            return tally
        }
    }

    private static func reconcileCollections(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> ReconcileStepTally {
        let seeded: Set<String>
        if try store.resumeCursor(serverID: serverID, entityType: SyncEntity.collections) != nil {
            seeded = Set(try store.localIDs(serverID: serverID, entityType: SyncEntity.collections))
        } else {
            seeded = []
        }
        return try await FullSync.runStep(store: store, serverID: serverID, entity: SyncEntity.collections) {
            let known = try store.localStamps(serverID: serverID, entityType: SyncEntity.collections)
            let members = try store.localCollectionMembers(serverID: serverID)
            var remote = seeded
            var tally = ReconcileStepTally()
            var page = try store.resumeCursor(serverID: serverID, entityType: SyncEntity.collections)
                .map(FullSync.parsePage) ?? 0
            while true {
                let response = try await fetcher.fetchCollectionsPage(
                    request: PageRequest(page: page, size: fullSyncPageSize)
                )
                let last = response.last
                let ids = response.content.map(\.id)
                var dirty: [CollectionDTO] = []
                for collection in response.content {
                    let (added, changed) = classify(
                        known, id: collection.id, stamp: collection.lastModifiedDate
                    )
                    tally.collectionsAdded += added ? 1 : 0
                    tally.collectionsChanged += changed ? 1 : 0
                    if added || changed
                        || membersMoved(stored: members[collection.id], remoteSeriesIDs: collection.seriesIds ?? [])
                    {
                        dirty.append(collection)
                    }
                }
                if !dirty.isEmpty {
                    tally.collectionsUpserted += try store.upsertCollectionsBatch(
                        serverID: serverID, collections: dirty
                    )
                }
                try store.clearTombstones(
                    serverID: serverID, entityType: SyncEntity.collections, remoteIDs: ids
                )
                remote.formUnion(ids)
                tally.pagesSwept += 1
                if !last {
                    try store.checkpointEntity(
                        serverID: serverID,
                        entityType: SyncEntity.collections,
                        cursor: FullSync.pageCursor(page + 1)
                    )
                }
                if last { break }
                page += 1
            }
            tally.collectionsRemoved = try store.prune(
                serverID: serverID,
                entityType: SyncEntity.collections,
                remoteIDs: remote,
                cause: DeletionCause.reconcile
            ).count
            return tally
        }
    }

    private static func reconcileReadlists(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> ReconcileStepTally {
        let seeded: Set<String>
        if try store.resumeCursor(serverID: serverID, entityType: SyncEntity.readlists) != nil {
            seeded = Set(try store.localIDs(serverID: serverID, entityType: SyncEntity.readlists))
        } else {
            seeded = []
        }
        return try await FullSync.runStep(store: store, serverID: serverID, entity: SyncEntity.readlists) {
            let known = try store.localStamps(serverID: serverID, entityType: SyncEntity.readlists)
            let storedBooks = try store.localReadlistBooks(serverID: serverID)
            var remote = seeded
            var tally = ReconcileStepTally()
            var page = try store.resumeCursor(serverID: serverID, entityType: SyncEntity.readlists)
                .map(FullSync.parsePage) ?? 0
            while true {
                let response = try await fetcher.fetchReadlistsPage(
                    request: PageRequest(page: page, size: fullSyncPageSize)
                )
                let last = response.last
                let ids = response.content.map(\.id)
                var dirty: [ReadListDTO] = []
                for readlist in response.content {
                    let (added, changed) = classify(
                        known, id: readlist.id, stamp: readlist.lastModifiedDate
                    )
                    tally.readlistsAdded += added ? 1 : 0
                    tally.readlistsChanged += changed ? 1 : 0
                    if added || changed
                        || booksMoved(
                            stored: storedBooks[readlist.id], remoteBookIDs: readlist.bookIds ?? []
                        )
                    {
                        dirty.append(readlist)
                    }
                }
                if !dirty.isEmpty {
                    tally.readlistsUpserted += try store.upsertReadlistsBatch(
                        serverID: serverID, readlists: dirty
                    )
                }
                try store.clearTombstones(
                    serverID: serverID, entityType: SyncEntity.readlists, remoteIDs: ids
                )
                remote.formUnion(ids)
                tally.pagesSwept += 1
                if !last {
                    try store.checkpointEntity(
                        serverID: serverID,
                        entityType: SyncEntity.readlists,
                        cursor: FullSync.pageCursor(page + 1)
                    )
                }
                if last { break }
                page += 1
            }
            tally.readlistsRemoved = try store.prune(
                serverID: serverID,
                entityType: SyncEntity.readlists,
                remoteIDs: remote,
                cause: DeletionCause.reconcile
            ).count
            return tally
        }
    }

    private static func reconcileReadProgress(
        fetcher: any LibraryFetching,
        store: KomgaStore,
        serverID: String
    ) async throws -> ReconcileStepTally {
        try await FullSync.runStep(store: store, serverID: serverID, entity: SyncEntity.readProgress) {
            var tally = ReconcileStepTally()
            var page = try store.resumeCursor(serverID: serverID, entityType: SyncEntity.readProgress)
                .map(FullSync.parsePage) ?? 0
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
                    tally.readProgress += 1
                }
                tally.pagesSwept += 1
                if !last {
                    try store.checkpointEntity(
                        serverID: serverID,
                        entityType: SyncEntity.readProgress,
                        cursor: FullSync.pageCursor(page + 1)
                    )
                }
                if last { break }
                page += 1
            }
            return tally
        }
    }
}
