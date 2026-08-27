import XCTest
@testable import KomgaAPI
@testable import KomgaStore
@testable import KomgaSync

/// Scale sweep — the Swift mirror of `stage5_smoke --scale SERIES BOOKS_PER`.
/// "长期运行可靠" needs a measured number rather than an assumption: bootstrap a
/// large library, reconcile it twice and prove the mirror is already converged,
/// so the cost of a steady-state sweep (the one every foreground trigger pays)
/// is on record.
///
/// Timings are printed, never asserted: CI machines vary too much for a
/// threshold that isn't flaky. What does fail loudly is the behaviour those
/// timings measured — a sweep that rewrites rows it did not have to, or a prune
/// that mistakes "nothing was written" for "nothing exists".
final class ScaleSyncTests: XCTestCase {
    /// Same shape as the Rust smoke: 100 series per page at PAGE_SIZE 100, so
    /// the sweep really is paged.
    private let seriesCount = 1000
    private let booksPerSeries = 20

    func testSteadyStateSweepOfALargeLibraryWritesNothing() async throws {
        let totalBooks = seriesCount * booksPerSeries
        let store = try KomgaStore()
        let server = ScriptedServer(
            snapshot: Self.syntheticSnapshot(series: seriesCount, booksPer: booksPerSeries)
        )

        let bootstrapStart = ContinuousClock.now
        let bootstrap = try await FullSync.run(
            fetcher: server, store: store, serverID: "scale", start: .fresh
        )
        let bootstrapped = bootstrapStart.duration(to: .now)
        XCTAssertEqual(
            bootstrap.series, seriesCount, "bootstrap must mirror every series: \(bootstrap.series)"
        )
        XCTAssertEqual(
            bootstrap.books, totalBooks, "bootstrap must mirror every book: \(bootstrap.books)"
        )

        let firstStart = ContinuousClock.now
        let first = try await ReconcileSync.run(
            fetcher: server, store: store, serverID: "scale", trigger: .manualRefresh
        )
        let firstElapsed = firstStart.duration(to: .now)

        XCTAssertTrue(first.clean, "a converged mirror must report clean: \(first)")
        XCTAssertEqual(first.totalMutations(), 0)
        // Still a full sweep: 10 series pages + one page per series + the three
        // single-page steps (collections / readlists / on-deck).
        XCTAssertEqual(first.pagesSwept, 10 + seriesCount + 3)
        // The dirty-batch filter: classification is a read sweep, not thousands
        // of upserts that each rewrite their FTS row as well.
        XCTAssertEqual(
            first.seriesUpserted, 0, "an unchanged series must not be written again (with its FTS row)"
        )
        XCTAssertEqual(
            first.booksUpserted, 0, "an unchanged book must not be written again (with its FTS row)"
        )

        let secondStart = ContinuousClock.now
        let second = try await ReconcileSync.run(
            fetcher: server, store: store, serverID: "scale", trigger: .didBecomeActive
        )
        let secondElapsed = secondStart.duration(to: .now)
        XCTAssertTrue(second.clean, "the steady state must stay clean: \(second)")
        XCTAssertEqual(second.totalMutations(), 0)
        XCTAssertEqual(second.seriesUpserted, 0)
        XCTAssertEqual(second.booksUpserted, 0)

        // Nothing was written, so nothing may have been lost either: the whole
        // library is still mirrored, index included, and nothing was pruned.
        XCTAssertEqual(try store.mirrorRowCount(serverID: "scale", table: "series"), seriesCount)
        XCTAssertEqual(try store.mirrorRowCount(serverID: "scale", table: "books"), totalBooks)
        XCTAssertEqual(try store.mirrorRowCount(serverID: "scale", table: "book_fts"), totalBooks)
        XCTAssertEqual(try store.orphanBookCount(serverID: "scale"), 0)
        XCTAssertEqual(try store.countTombstones(serverID: "scale"), 0)
        for entity in [SyncEntity.series, SyncEntity.books] {
            XCTAssertNil(
                try store.resumeCursor(serverID: "scale", entityType: entity),
                "a finished sweep leaves no resume cursor behind"
            )
            XCTAssertEqual(
                try store.entityState(serverID: "scale", entityType: entity)?.syncStatus,
                SyncStatus.idle
            )
        }

        print(
            """
            [scale] \(seriesCount) series / \(totalBooks) books (scripted server, no network):
              bootstrap \(Self.ms(bootstrapped))ms (series=\(bootstrap.series) books=\(bootstrap.books) pages=\(bootstrap.seriesPages + bootstrap.bookPages))
              reconcile \(Self.ms(firstElapsed))ms (manual_refresh, upserted=\(first.seriesUpserted)+\(first.booksUpserted), pages=\(first.pagesSwept))
              reconcile \(Self.ms(secondElapsed))ms (did_become_active, upserted=\(second.seriesUpserted)+\(second.booksUpserted), pages=\(second.pagesSwept))
              wall time \(Self.ms(bootstrapped + firstElapsed + secondElapsed))ms total
            """
        )
    }

    /// A remote read-progress edit does **not** bump the book's own
    /// `lastModified`, so the metadata classifier reports "unchanged" — the only
    /// thing that still pulls a write is the progress comparison. Drop that
    /// comparison and `dirty` stays empty, which fails this test.
    func testProgressOnlyChangeStillGetsWritten() async throws {
        let store = try KomgaStore()
        // Book 0 is read up to page 7; book 1 is untouched. The on-deck shelf is
        // empty, so nothing but the books sweep can heal either of them.
        var snapshot = Self.snapshot(progress: [(7, false), (0, false)])
        let server = ScriptedServer(snapshot: snapshot)

        _ = try await FullSync.run(fetcher: server, store: store, serverID: "scale", start: .fresh)
        let baseline = try await ReconcileSync.run(
            fetcher: server, store: store, serverID: "scale", trigger: .manualRefresh
        )
        XCTAssertTrue(baseline.clean)
        XCTAssertEqual(baseline.readProgress, 0, "the on-deck sweep served nothing here")
        XCTAssertEqual(
            baseline.booksUpserted, 0, "the same stamp and the same progress is nothing to write"
        )

        // The reader finishes book 0; the server never moves its lastModified.
        snapshot = Self.snapshot(progress: [(42, true), (0, false)])
        await server.setSnapshot(snapshot)
        let healed = try await ReconcileSync.run(
            fetcher: server, store: store, serverID: "scale", trigger: .manualRefresh
        )
        XCTAssertEqual(healed.booksAdded, 0, "the book itself is not new")
        XCTAssertEqual(healed.booksChanged, 0, "…and its lastModified did not move")
        XCTAssertEqual(
            healed.booksUpserted, 1, "only the book whose progress moved may be written"
        )

        let stored = try store.localReadProgress(serverID: "scale")
        XCTAssertEqual(stored.count, 2)
        let healedBook = try XCTUnwrap(stored[Self.bookID(index: 0, series: 0)])
        XCTAssertEqual(healedBook.page, 42)
        XCTAssertTrue(healedBook.completed)
        XCTAssertEqual(try store.mirrorRowCount(serverID: "scale", table: "book_fts"), 2)
    }

    /// The seen/remote set must cover **every** id a sweep scanned, not just the
    /// ones it wrote — otherwise the dirty-batch filter would let prune delete
    /// live rows. Here 20 books exist, none are rewritten, and prune must still
    /// conclude that all 20 are on the server.
    func testPruneNeverDeletesRowsTheSweepSkippedWriting() async throws {
        let store = try KomgaStore()
        var snapshot = Self.syntheticSnapshot(series: 1, booksPer: 20)
        let server = ScriptedServer(snapshot: snapshot)
        _ = try await FullSync.run(fetcher: server, store: store, serverID: "scale", start: .fresh)

        // Converged: zero writes, zero removals.
        let clean = try await ReconcileSync.run(
            fetcher: server, store: store, serverID: "scale", trigger: .manualRefresh
        )
        XCTAssertEqual(clean.booksUpserted, 0)
        XCTAssertEqual(clean.booksRemoved, 0)
        XCTAssertEqual(try store.mirrorRowCount(serverID: "scale", table: "books"), 20)

        // One book disappears remotely: prune has to notice even though the
        // other nineteen were never written by this sweep.
        let pages = snapshot.books[Self.seriesID(0)] ?? []
        snapshot.books[Self.seriesID(0)] = [Array(pages.first?.dropFirst() ?? [])]
        await server.setSnapshot(snapshot)
        let pruned = try await ReconcileSync.run(
            fetcher: server, store: store, serverID: "scale", trigger: .manualRefresh
        )
        XCTAssertEqual(pruned.booksRemoved, 1, "the missing book must still be pruned")
        XCTAssertEqual(pruned.booksUpserted, 0, "the remaining nineteen need no write")
        XCTAssertEqual(try store.mirrorRowCount(serverID: "scale", table: "books"), 19)
        XCTAssertEqual(try store.countTombstones(serverID: "scale"), 1)
    }

    // MARK: - Snapshot builders

    /// Synthesise a Komga-shaped snapshot of `series` series, each with
    /// `booksPer` books — the shape `synthetic_snapshot` builds in Rust. Built
    /// through the real JSON decoders, so a renamed contract key fails here
    /// instead of silently writing NULL columns.
    static func syntheticSnapshot(series: Int, booksPer: Int) -> Snapshot {
        var snapshot = Snapshot(json: ["id": "scale"])
        snapshot.libraries = [LibraryDTO(id: "lib-1", name: "Scale", root: "/scale")]
        snapshot.collections = [[]]
        snapshot.readlists = [[]]
        snapshot.onDeck = [[]]
        snapshot.series = stride(from: 0, to: series, by: 100).map { start in
            (start..<min(start + 100, series)).map { index in
                SeriesDTO(json: [
                    "id": seriesID(index),
                    "libraryId": "lib-1",
                    "name": "Scale Series \(index)",
                    "created": "2025-01-01T00:00:00Z",
                    "lastModified": "2025-01-02T00:00:00Z",
                    "booksCount": booksPer,
                    "metadata": [
                        "title": "Scale Series \(index)",
                        "status": "ONGOING",
                        "summary": "Synthetic series used to measure the sync engine.",
                        "genres": ["Scale"],
                        "tags": ["Synthetic"],
                        "authors": [],
                    ] as [String: Any],
                ])
            }
        }
        for index in 0..<series {
            // PAGE_SIZE is 100, so 20 books per series fit in one page.
            snapshot.books[seriesID(index)] = [(0..<booksPer).map {
                book(index: $0, series: index, lastModified: "2025-01-02T00:00:00Z", progress: nil)
            }]
        }
        return snapshot
    }

    /// The three fields Komga edits **without** moving the row's own timestamp:
    /// a series' counters, a collection's members and a readlist's order. Each
    /// has to be compared against the mirror, or the sweep heals nothing and
    /// reports a clean run over stale rows.
    func testStampInvisibleEditsStillGetHealed() async throws {
        let store = try KomgaStore()
        let stamp = "2025-01-02T00:00:00Z"
        var snapshot = Snapshot(json: ["id": "edits"])
        snapshot.libraries = [LibraryDTO(id: "lib-1", name: "L", root: "/l")]
        snapshot.series = [[Self.series(index: 0, stamp: stamp, booksCount: 3)]]
        snapshot.books[Self.seriesID(0)] = [Self.books(series: 0, count: 3, stamp: stamp)]
        snapshot.collections = [[Self.collection(members: [Self.seriesID(0)])]]
        snapshot.readlists = [[Self.readlist(books: [
            Self.bookID(index: 0, series: 0), Self.bookID(index: 1, series: 0),
        ])]]
        snapshot.onDeck = [[]]
        let server = ScriptedServer(snapshot: snapshot)
        _ = try await FullSync.run(fetcher: server, store: store, serverID: "edits", start: .fresh)

        // Nothing moved: neither the timestamps nor the projections differ, so
        // this sweep writes no row of any entity type.
        let baseline = try await ReconcileSync.run(
            fetcher: server, store: store, serverID: "edits", trigger: .manualRefresh
        )
        XCTAssertTrue(baseline.clean)
        XCTAssertEqual([baseline.seriesUpserted, baseline.booksUpserted, baseline.collectionsUpserted, baseline.readlistsUpserted], [0, 0, 0, 0])

        // Same timestamps, different content: counters up, member swapped, order
        // reversed.
        snapshot.series = [[Self.series(index: 0, stamp: stamp, booksCount: 4)]]
        snapshot.books[Self.seriesID(0)] = [Self.books(series: 0, count: 4, stamp: stamp)]
        snapshot.collections = [[Self.collection(members: ["series-deleted"])]]
        snapshot.readlists = [[Self.readlist(books: [
            Self.bookID(index: 1, series: 0), Self.bookID(index: 0, series: 0),
        ])]]
        await server.setSnapshot(snapshot)

        let healed = try await ReconcileSync.run(
            fetcher: server, store: store, serverID: "edits", trigger: .manualRefresh
        )
        XCTAssertEqual(healed.seriesChanged, 0, "the series stamp did not move")
        XCTAssertEqual(healed.collectionsChanged, 0, "nor the collection's")
        XCTAssertEqual(healed.readlistsChanged, 0, "nor the readlist's")
        XCTAssertEqual(
            [healed.seriesUpserted, healed.collectionsUpserted, healed.readlistsUpserted], [1, 1, 1],
            "each stamp-invisible edit must still reach its batch"
        )
        XCTAssertEqual(try store.mirrorRowCount(serverID: "edits", table: "series"), 1)
        XCTAssertEqual(
            try store.localIDs(serverID: "edits", entityType: SyncEntity.books).count, 4,
            "the fourth book arrived with the counter bump"
        )
        XCTAssertEqual(
            try store.collectionMemberIDs(serverID: "edits", collectionID: "col-1"),
            ["series-deleted"],
            "membership is mirrored as the server reports it"
        )
        XCTAssertEqual(
            try store.readlistBookIDs(serverID: "edits", readlistID: "rl-1"),
            [Self.bookID(index: 1, series: 0), Self.bookID(index: 0, series: 0)],
            "the reorder must land in the new order"
        )
    }

    static func series(index: Int, stamp: String, booksCount: Int) -> SeriesDTO {
        SeriesDTO(json: [
            "id": seriesID(index), "libraryId": "lib-1", "name": "Series \(index)",
            "created": "2025-01-01T00:00:00Z", "lastModified": stamp, "booksCount": booksCount,
        ])
    }

    static func collection(members: [String]) -> CollectionDTO {
        CollectionDTO(json: [
            "id": "col-1", "name": "Collection", "ordered": false,
            "createdDate": "2025-01-01T00:00:00Z", "lastModifiedDate": "2025-01-02T00:00:00Z",
            "seriesIds": members,
        ])
    }

    static func readlist(books: [String]) -> ReadListDTO {
        ReadListDTO(json: [
            "id": "rl-1", "name": "Readlist", "ordered": true,
            "createdDate": "2025-01-01T00:00:00Z", "lastModifiedDate": "2025-01-02T00:00:00Z",
            "bookIds": books,
        ])
    }

    /// One series with `count` books sharing one `lastModified`.
    static func books(series: Int, count: Int, stamp: String) -> [BookDTO] {
        (0..<count).map { book(index: $0, series: series, lastModified: stamp, progress: nil) }
    }

    /// One series, one book per entry of `progress`, all sharing the same book
    /// `lastModified` so only their inline read-progress can differ.
    static func snapshot(progress: [(page: Int, completed: Bool)]) -> Snapshot {
        var snapshot = syntheticSnapshot(series: 1, booksPer: progress.count)
        snapshot.books[seriesID(0)] = [progress.enumerated().map { index, value in
            book(index: index, series: 0, lastModified: "2025-01-02T00:00:00Z", progress: value)
        }]
        return snapshot
    }

    static func seriesID(_ index: Int) -> String { "series-\(String(format: "%06d", index))" }

    static func book(
        index: Int,
        series: Int,
        lastModified: String,
        progress: (page: Int, completed: Bool)?
    ) -> BookDTO {
        var payload: [String: Any] = [
            "id": bookID(index: index, series: series),
            "seriesId": seriesID(series),
            "name": "Scale Series \(series) #\(index)",
            "number": index + 1,
            "created": "2025-01-01T00:00:00Z",
            "lastModified": lastModified,
            "media": ["mediaType": "CBZ", "pagesCount": 24],
        ]
        if let progress {
            payload["readProgress"] = [
                "page": progress.page,
                "completed": progress.completed,
                "lastModified": lastModified,
            ]
        }
        return BookDTO(json: payload)
    }

    static func bookID(index: Int, series: Int) -> String {
        "\(seriesID(series))-book-\(String(format: "%03d", index))"
    }

    private static func ms(_ duration: Duration) -> Int {
        Int(duration.components.seconds) * 1_000
            + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Building DTOs from a JSON literal

private let scaleDecoder = JSONDecoder()

private extension Decodable {
    /// Decode a DTO out of a JSON literal, so the synthetic snapshots speak the
    /// same contract keys the fixtures do.
    init(json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        self = try! scaleDecoder.decode(Self.self, from: data)
    }
}
