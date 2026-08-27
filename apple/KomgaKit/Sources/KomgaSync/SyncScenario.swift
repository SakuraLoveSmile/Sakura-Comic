import Foundation
import KomgaAPI
import KomgaStore

/// Sync scenario replay — the Stage 5 acceptance battery (mirror of Rust
/// `sync::scenario`).
///
/// A scenario file (`specs/contracts/fixtures/sync/*.json`) scripts a Komga
/// server's history: named snapshots plus the actions the client takes
/// against them (`bootstrap` / `bootstrap_fresh` / `reconcile`), optionally
/// with an injected transport failure. After every step the local SQLite
/// mirror is compared with the snapshot the server currently serves, so a
/// green scenario *is* the claim "SQLite 与 Komga 一致".
///
/// The same JSON drives the Rust tests and `stage5_smoke`, so both platforms
/// are held to one contract.

/// One point-in-time view of what the server serves. Lists of items are
/// **pages**, so a snapshot controls how many round-trips a sweep needs.
public struct Snapshot: Decodable, Sendable {
    public let id: String
    public var libraries: [LibraryDTO] = []
    public var series: [[SeriesDTO]] = []
    /// series id → book pages
    public var books: [String: [[BookDTO]]] = [:]
    public var collections: [[CollectionDTO]] = []
    public var readlists: [[ReadListDTO]] = []
    public var onDeck: [[BookDTO]] = []

    enum CodingKeys: String, CodingKey {
        case id, libraries, series, books, collections, readlists, onDeck
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        libraries = container.decoded([LibraryDTO].self, as: .libraries, fallback: [])
        series = container.decoded([[SeriesDTO]].self, as: .series, fallback: [])
        books = container.decoded([String: [[BookDTO]]].self, as: .books, fallback: [:])
        collections = container.decoded([[CollectionDTO]].self, as: .collections, fallback: [])
        readlists = container.decoded([[ReadListDTO]].self, as: .readlists, fallback: [])
        onDeck = container.decoded([[BookDTO]].self, as: .onDeck, fallback: [])
    }
}

/// Injected transport failure.
public struct Fault: Decodable, Sendable {
    /// Only `network` is modelled: the request fails as if the server were
    /// unreachable.
    public var kind: String = "network"
    /// Entity whose requests fail; `nil` fails every request (offline).
    public var entity: String?
    /// Fail after this many successful page requests of that entity.
    public var afterPages: Int = 0

    enum CodingKeys: String, CodingKey {
        case kind, entity, afterPages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = container.decoded(String.self, as: .kind, fallback: "network")
        entity = container.decoded(String?.self, as: .entity, fallback: nil)
        afterPages = container.decoded(Int.self, as: .afterPages, fallback: 0)
    }
}

/// Extra per-step expectations beyond snapshot equality.
public struct Expect: Decodable, Sendable {
    /// entity type → ids that must be tombstoned locally.
    public var tombstoned: [String: [String]] = [:]
    /// Steps the run must report as continued from a cursor.
    public var resumedSteps: [String] = []
    /// Steps the run must report as already finished.
    public var skippedSteps: [String] = []
    /// entity type → exact page-request counts, to prove a resumed sweep did
    /// not redo committed work.
    public var requests: [String: Int] = [:]
    /// entity types that must be left in `error` with their cursor intact.
    public var failedEntities: [String] = []
    /// entity type → the exact resume cursor the step must leave behind.
    public var cursors: [String: String] = [:]
    /// The mirror must equal this snapshot (defaults to the step's snapshot).
    public var mirror: String?
    /// Reconcile must report "nothing changed".
    public var clean: Bool?
    /// Reconcile must report these tallies (Added / Changed / Removed).
    public var tallies: [String: Int] = [:]
    /// The server-level rollup row must be flagged `error`.
    public var rollupError: Bool?

    enum CodingKeys: String, CodingKey {
        case tombstoned, resumedSteps, skippedSteps, requests, failedEntities
        case mirror, clean, tallies, rollupError, cursors
    }

    /// A step that only asserts snapshot equality.
    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tombstoned = container.decoded([String: [String]].self, as: .tombstoned, fallback: [:])
        resumedSteps = container.decoded([String].self, as: .resumedSteps, fallback: [])
        skippedSteps = container.decoded([String].self, as: .skippedSteps, fallback: [])
        requests = container.decoded([String: Int].self, as: .requests, fallback: [:])
        failedEntities = container.decoded([String].self, as: .failedEntities, fallback: [])
        mirror = container.decoded(String?.self, as: .mirror, fallback: nil)
        clean = container.decoded(Bool?.self, as: .clean, fallback: nil)
        tallies = container.decoded([String: Int].self, as: .tallies, fallback: [:])
        rollupError = container.decoded(Bool?.self, as: .rollupError, fallback: nil)
        cursors = container.decoded([String: String].self, as: .cursors, fallback: [:])
    }
}

public struct ScenarioStep: Decodable, Sendable {
    public let label: String
    /// `bootstrap` | `bootstrap_fresh` | `reconcile`
    public let action: String
    public var snapshot: String?
    public var trigger: String?
    public var fault: Fault?
    public var expect = Expect()
    /// Whether the step is expected to succeed when a fault is injected.
    public var expectSuccess = true

    enum CodingKeys: String, CodingKey {
        case label, action, snapshot, trigger, fault, expect, expectSuccess
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        action = try container.decode(String.self, forKey: .action)
        snapshot = container.decoded(String?.self, as: .snapshot, fallback: nil)
        trigger = container.decoded(String?.self, as: .trigger, fallback: nil)
        fault = container.decoded(Fault?.self, as: .fault, fallback: nil)
        expect = container.decoded(Expect.self, as: .expect, fallback: Expect())
        expectSuccess = container.decoded(Bool.self, as: .expectSuccess, fallback: true)
    }
}

public struct Scenario: Decodable, Sendable {
    public let name: String
    public var description: String = ""
    /// `disabled` means no SSE events are delivered at all — the whole point
    /// of the Stage 5 completion criterion.
    public var sse: String?
    public let serverID: String
    public let snapshots: [Snapshot]
    public let steps: [ScenarioStep]

    enum CodingKeys: String, CodingKey {
        case name, description, sse, snapshots, steps
        case serverID = "serverId"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = container.decoded(String.self, as: .description, fallback: "")
        sse = container.decoded(String?.self, as: .sse, fallback: nil)
        serverID = try container.decode(String.self, forKey: .serverID)
        snapshots = try container.decode([Snapshot].self, forKey: .snapshots)
        steps = try container.decode([ScenarioStep].self, forKey: .steps)
    }
}

/// `#[serde(default)]` in Swift: a missing or null key falls back to the
/// scripted default instead of failing the decode.
private extension KeyedDecodingContainer {
    func decoded<T: Decodable>(_ type: T.Type, as key: Key, fallback: T) -> T {
        (try? decodeIfPresent(type, forKey: key)) ?? fallback
    }
}

/// A Komga server scripted by a snapshot, with request accounting and faults.
///
/// An actor keeps the counters thread safe; `requests` only counts requests
/// that were actually served (a failed one is retried by the next run).
public actor ScriptedServer: LibraryFetching {
    private var snapshot: Snapshot
    private var fault: Fault?
    /// entity → successful requests since the snapshot was installed.
    private var served: [String: Int] = [:]
    /// entity → successful requests since the last `resetCalls`.
    private var calls: [String: Int] = [:]

    public init(snapshot: Snapshot) {
        self.snapshot = snapshot
    }

    public func setSnapshot(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        served.removeAll()
    }

    /// Per-step request accounting (the scenario asserts one step at a time).
    public func resetCalls() {
        calls.removeAll()
    }

    public func setFault(_ fault: Fault?) {
        self.fault = fault
    }

    public func requestCounts() -> [String: Int] {
        calls
    }

    /// Count the request and fail it when the scripted fault applies.
    private func gate(_ entity: String) throws {
        let servedCount = served[entity] ?? 0
        if let fault, fault.kind == "network",
           fault.entity.map({ $0 == entity }) ?? true,
           servedCount >= fault.afterPages {
            throw KomgaAPIError.network
        }
        served[entity] = servedCount + 1
        calls[entity] = (calls[entity] ?? 0) + 1
    }

    /// Snapshot page helper: pages beyond the scripted list are empty+last.
    private static func slice<T>(_ pages: [[T]], _ number: Int)
        -> (content: [T], last: Bool, totalElements: Int, totalPages: Int) {
        let totalPages = pages.count
        let totalElements = pages.reduce(0) { $0 + $1.count }
        let content = number < totalPages ? pages[number] : []
        return (content, number + 1 >= totalPages, totalElements, totalPages)
    }

    public func fetchLibraries() async throws -> [LibraryDTO] {
        try gate("libraries")
        return snapshot.libraries
    }

    public func fetchSeriesPage(_ request: PageRequest) async throws -> SeriesPageDTO {
        try gate("series")
        let page = Self.slice(snapshot.series, request.page)
        return SeriesPageDTO(
            content: page.content, totalElements: page.totalElements, totalPages: page.totalPages,
            number: request.page, size: request.size, first: request.page == 0, last: page.last
        )
    }

    public func fetchBooksPage(seriesID: String, request: PageRequest) async throws -> BookPageDTO {
        try gate("books")
        let page = Self.slice(snapshot.books[seriesID] ?? [], request.page)
        return BookPageDTO(
            content: page.content, totalElements: page.totalElements, totalPages: page.totalPages,
            number: request.page, size: request.size, first: request.page == 0, last: page.last
        )
    }

    public func fetchOnDeckPage(request: PageRequest) async throws -> BookPageDTO {
        try gate("read_progress")
        let page = Self.slice(snapshot.onDeck, request.page)
        return BookPageDTO(
            content: page.content, totalElements: page.totalElements, totalPages: page.totalPages,
            number: request.page, size: request.size, first: request.page == 0, last: page.last
        )
    }

    public func fetchCollectionsPage(request: PageRequest) async throws -> CollectionPageDTO {
        try gate("collections")
        let page = Self.slice(snapshot.collections, request.page)
        return CollectionPageDTO(
            content: page.content, totalElements: page.totalElements, totalPages: page.totalPages,
            number: request.page, size: request.size, first: request.page == 0, last: page.last
        )
    }

    public func fetchReadlistsPage(request: PageRequest) async throws -> ReadListPageDTO {
        try gate("readlists")
        let page = Self.slice(snapshot.readlists, request.page)
        return ReadListPageDTO(
            content: page.content, totalElements: page.totalElements, totalPages: page.totalPages,
            number: request.page, size: request.size, first: request.page == 0, last: page.last
        )
    }
}

/// Entity types a scenario step can talk about.
let scenarioEntities: [String] = [
    "libraries", "series", "books", "collections", "readlists", "read_progress",
]

/// What a step did, as the scenario runner observed it.
struct StepOutcome: Sendable {
    var resumed: [String] = []
    var skipped: [String] = []
    var clean = false
    var tallies: [String: Int] = [:]
}

/// One executed step, reported by the smoke output and asserted by tests.
public struct StepReport: Sendable, Equatable {
    public let label: String
    public let ok: Bool
    public let detail: [String]

    public init(label: String, ok: Bool, detail: [String]) {
        self.label = label
        self.ok = ok
        self.detail = detail
    }
}

public enum SyncScenario {
    /// Parse a scenario JSON (shared with the Rust tests verbatim).
    public static func parse(_ data: Data) throws -> Scenario {
        try JSONDecoder().decode(Scenario.self, from: data)
    }

    public static func load(from url: URL) throws -> Scenario {
        try parse(Data(contentsOf: url))
    }

    /// Replay a scenario: run each step and check it against its expectations.
    public static func run(store: KomgaStore, scenario: Scenario) async -> [StepReport] {
        let snapshots = Dictionary(
            uniqueKeysWithValues: scenario.snapshots.map { ($0.id, $0) }
        )
        guard let first = scenario.snapshots.first else {
            return [StepReport(label: "setup", ok: false, detail: ["scenario needs at least one snapshot"])]
        }
        let server = ScriptedServer(snapshot: first)
        let serverID = scenario.serverID
        var reports: [StepReport] = []

        for step in scenario.steps {
            var problems: [String] = []
            if let id = step.snapshot {
                if let snap = snapshots[id] {
                    await server.setSnapshot(snap)
                } else {
                    problems.append("unknown snapshot \(id)")
                }
            }
            await server.setFault(step.fault)
            await server.resetCalls()

            var outcome = StepOutcome()
            let failure: String?
            do {
                switch step.action {
                case "bootstrap":
                    let summary = try await FullSync.run(
                        fetcher: server, store: store, serverID: serverID, start: .resume
                    )
                    outcome.absorb(summary)
                case "bootstrap_fresh":
                    let summary = try await FullSync.run(
                        fetcher: server, store: store, serverID: serverID, start: .fresh
                    )
                    outcome.absorb(summary)
                case "reconcile":
                    let summary = try await ReconcileSync.run(
                        fetcher: server, store: store, serverID: serverID,
                        trigger: trigger(of: step.trigger)
                    )
                    outcome.absorb(summary)
                default:
                    problems.append("unknown action \(step.action)")
                }
                failure = nil
            } catch {
                failure = String(describing: error)
            }

            switch (failure, step.expectSuccess) {
            case (nil, true):
                break
            case (.some, false):
                // Injected failure: the error is expected, but the mirror must
                // still be usable and the step must be resumable.
                break
            case let (.some(message), true):
                problems.append("step failed: \(message)")
            case (nil, false):
                problems.append("expected the step to fail, it succeeded")
            }

            // `expect.mirror` is always asserted — including after a failed
            // step, where it proves the outage lost nothing. Without it, a
            // successful step must match the snapshot the server served.
            let mirrorID = step.expect.mirror
                ?? (step.expectSuccess ? step.snapshot : nil)
            if let id = mirrorID {
                if let snap = snapshots[id] {
                    problems.append(contentsOf: diffMirror(store: store, serverID: serverID, snapshot: snap))
                } else {
                    problems.append("unknown mirror snapshot \(id)")
                }
            }

            problems.append(contentsOf: checkSyncState(
                store: store, serverID: serverID, expect: step.expect,
                outcome: outcome, requests: await server.requestCounts()
            ))
            reports.append(StepReport(label: step.label, ok: problems.isEmpty, detail: problems))
        }
        return reports
    }

    /// Compare the local mirror with a snapshot; every mismatch is one line.
    public static func diffMirror(
        store: KomgaStore,
        serverID: String,
        snapshot snap: Snapshot
    ) -> [String] {
        var problems: [String] = []
        func ids(_ entity: String) -> [String] {
            (try? store.localIDs(serverID: serverID, entityType: entity)) ?? []
        }
        func sortedUnique(_ values: [String]) -> [String] {
            Set(values).sorted()
        }

        let wantLibraries = snap.libraries.map(\.id).sorted()
        let gotLibraries = ids(SyncEntity.libraries).sorted()
        if wantLibraries != gotLibraries {
            problems.append("libraries: server \(wantLibraries) != local \(gotLibraries)")
        }

        let wantSeries = pagedIDs(snap.series.map { $0.map(\.id) }).sorted()
        let gotSeries = ids(SyncEntity.series).sorted()
        if wantSeries != gotSeries {
            problems.append("series: server \(wantSeries) != local \(gotSeries)")
        }

        let wantBooks = sortedUnique(allSnapshotBooks(snap).map(\.id))
        let gotBooks = ids(SyncEntity.books).sorted()
        if wantBooks != gotBooks {
            problems.append("books: server \(wantBooks) != local \(gotBooks)")
        }

        let wantCollections = pagedIDs(snap.collections.map { $0.map(\.id) }).sorted()
        let gotCollections = ids(SyncEntity.collections).sorted()
        if wantCollections != gotCollections {
            problems.append("collections: server \(wantCollections) != local \(gotCollections)")
        }

        let wantReadlists = pagedIDs(snap.readlists.map { $0.map(\.id) }).sorted()
        let gotReadlists = ids(SyncEntity.readlists).sorted()
        if wantReadlists != gotReadlists {
            problems.append("readlists: server \(wantReadlists) != local \(gotReadlists)")
        }

        // Values, not just identity: name / status / lastModified must match.
        for series in snap.series.flatMap({ $0 }) {
            guard let detail = try? store.seriesDetail(serverID: serverID, seriesID: series.id) else {
                problems.append("series \(series.id): missing locally")
                continue
            }
            if detail.name != series.name {
                problems.append("series \(series.id): name local \(detail.name) != server \(series.name)")
            }
            let wantStatus = series.metadata?.status
            if detail.status != wantStatus {
                problems.append("series \(series.id): status local \(String(describing: detail.status)) != server \(String(describing: wantStatus))")
            }
            if detail.lastModified != series.lastModified {
                problems.append("series \(series.id): lastModified local \(String(describing: detail.lastModified)) != server \(String(describing: series.lastModified))")
            }
            // Metadata edits must reach the normalized filter tables.
            if let meta = series.metadata {
                if detail.genres.sorted() != (meta.genres ?? []).sorted() {
                    problems.append("series \(series.id): genres local \(detail.genres.sorted()) != server \((meta.genres ?? []).sorted())")
                }
                if detail.summary != meta.summary {
                    problems.append("series \(series.id): summary local \(String(describing: detail.summary)) != server \(String(describing: meta.summary))")
                }
            }
        }

        for book in allSnapshotBooks(snap) {
            let title = try? store.bookDetail(serverID: serverID, bookID: book.id)?.title
            if title != book.name {
                problems.append("book \(book.id): title local \(String(describing: title)) != server \(book.name)")
            }
        }

        // Collection / readlist membership.
        for collection in snap.collections.flatMap({ $0 }) {
            let members = (try? store.collectionMemberIDs(serverID: serverID, collectionID: collection.id)) ?? []
            let serverIDs = collection.seriesIds ?? []
            if members.count != serverIDs.count || !members.allSatisfy(serverIDs.contains) {
                problems.append("collection \(collection.id): members local \(members) != server \(serverIDs)")
            }
        }
        for readlist in snap.readlists.flatMap({ $0 }) {
            let books = (try? store.readlistBookIDs(serverID: serverID, readlistID: readlist.id)) ?? []
            if books != (readlist.bookIds ?? []) {
                problems.append("readlist \(readlist.id): books local \(books) != server \(readlist.bookIds ?? [])")
            }
        }

        // Search index must not keep ghosts of pruned rows.
        let ftsSeries = (try? store.mirrorRowCount(serverID: serverID, table: "series_fts")) ?? -1
        let wantSeriesRows = snap.series.reduce(0) { $0 + $1.count }
        if ftsSeries != wantSeriesRows {
            problems.append("series_fts rows \(ftsSeries) != server series count \(wantSeriesRows)")
        }
        let ftsBooks = (try? store.mirrorRowCount(serverID: serverID, table: "book_fts")) ?? -1
        if ftsBooks != wantBooks.count {
            problems.append("book_fts rows \(ftsBooks) != server book count \(wantBooks.count)")
        }

        // Read progress: exactly the books the server reports progress for.
        let wantProgress = sortedUnique(allSnapshotBooks(snap).filter { $0.readProgress != nil }.map(\.id))
        let gotProgress = (try? store.readProgressBookIDs(serverID: serverID)) ?? []
        if gotProgress != wantProgress {
            problems.append("read_progress: server \(wantProgress) != local \(gotProgress)")
        }

        // Orphans: a book under a series the server no longer has.
        let orphans = (try? store.orphanBookCount(serverID: serverID)) ?? -1
        if orphans != 0 {
            problems.append("\(orphans) orphan books survived the cascade")
        }
        return problems
    }

    // MARK: - Snapshot helpers

    /// Every book the snapshot serves, across series and pages.
    static func allSnapshotBooks(_ snap: Snapshot) -> [BookDTO] {
        snap.books.keys.sorted().flatMap { key in snap.books[key]!.flatMap { $0 } }
            + snap.onDeck.flatMap { $0 }
    }

    /// Remote ids across every page of a snapshot list.
    static func pagedIDs(_ pages: [[String]]) -> [String] {
        pages.flatMap { $0 }
    }
}

// MARK: - Step assertions

private extension StepOutcome {
    mutating func absorb(_ summary: FullSyncSummary) {
        resumed = summary.resumedSteps
        skipped = summary.skippedSteps
        tallies["series_written"] = summary.series
        tallies["books_written"] = summary.books
    }

    mutating func absorb(_ summary: ReconcileSummary) {
        clean = summary.clean
        tallies["series_added"] = summary.seriesAdded
        tallies["series_changed"] = summary.seriesChanged
        tallies["series_removed"] = summary.seriesRemoved
        tallies["books_added"] = summary.booksAdded
        tallies["books_changed"] = summary.booksChanged
        tallies["books_removed"] = summary.booksRemoved
        tallies["collections_removed"] = summary.collectionsRemoved
        tallies["readlists_removed"] = summary.readlistsRemoved
    }
}

/// Which trigger the scenario names (unknown = an explicit manual refresh).
func trigger(of name: String?) -> ReconcileTrigger {
    switch name {
    case "app_launch": .appLaunch
    case "did_become_active": .didBecomeActive
    case "network_recovered": .networkRecovered
    case "sse_reconnected": .sseReconnected
    default: .manualRefresh
    }
}

func checkSyncState(
    store: KomgaStore,
    serverID: String,
    expect: Expect,
    outcome: StepOutcome,
    requests calls: [String: Int]
) -> [String] {
    var problems: [String] = []

    if !expect.resumedSteps.isEmpty && outcome.resumed != expect.resumedSteps {
        problems.append("resumed_steps \(outcome.resumed) != expected \(expect.resumedSteps)")
    }
    if !expect.skippedSteps.isEmpty && outcome.skipped != expect.skippedSteps {
        problems.append("skipped_steps \(outcome.skipped) != expected \(expect.skippedSteps)")
    }
    if let want = expect.clean, outcome.clean != want {
        problems.append("clean \(outcome.clean) != expected \(want)")
    }
    for (key, want) in expect.tallies {
        let got = outcome.tallies[key] ?? Int.max
        if got != want {
            problems.append("tally \(key): got \(got), want \(want)")
        }
    }
    for (entity, ids) in expect.tombstoned {
        let got = ((try? store.listTombstones(serverID: serverID, entityType: entity)) ?? [])
            .map(\.remoteID).sorted()
        // Tombstones are stored newest-first; the scenario asserts a set.
        if got != ids.sorted() {
            problems.append("tombstones[\(entity)]: got \(got), want \(ids.sorted())")
        }
    }
    for entity in expect.failedEntities {
        guard let state = try? store.entityState(serverID: serverID, entityType: entity) else {
            problems.append("\(entity): no sync_state row")
            continue
        }
        if state.syncStatus != SyncStatus.error {
            problems.append("\(entity): status \(state.syncStatus) != error")
        }
        // The libraries step is one request: a failure there leaves
        // nothing partial, so only the paged sweeps must keep a cursor.
        if entity != "libraries" && state.syncCursor == nil {
            problems.append("\(entity): error left no resume cursor")
        }
    }
    for (entity, wantCursor) in expect.cursors {
        let got = try? store.resumeCursor(serverID: serverID, entityType: entity)
        if got != wantCursor {
            let want = wantCursor
            problems.append("sync_cursor[\(entity)]: got \(String(describing: got)), want \(want)")
        }
    }
    if let want = expect.rollupError {
        let rollup = try? store.syncState(serverID: serverID)
        let isError = rollup?.syncStatus == SyncStatus.error
        if isError != want {
            problems.append("rollup sync_status error \(isError) != expected \(want)")
        }
    }
    for (entity, want) in expect.requests {
        let got = calls[entity] ?? 0
        if got != want {
            problems.append("requests[\(entity)]: got \(got), want \(want)")
        }
    }
    // No step may be left claiming it is still running with no cursor.
    for entity in scenarioEntities {
        if let state = try? store.entityState(serverID: serverID, entityType: entity),
           state.syncStatus == SyncStatus.idle, state.syncCursor != nil {
            problems.append("\(entity): idle row still holds a cursor")
        }
    }
    return problems
}
