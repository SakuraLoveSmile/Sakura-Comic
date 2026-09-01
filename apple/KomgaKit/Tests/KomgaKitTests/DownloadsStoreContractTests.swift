import Foundation
import XCTest
import GRDB
import KomgaStore
@testable import KomgaDownloads

// MARK: - Stage 9's download store, re-derived on the Apple side
//
// `downloads/store.rs` is the module the whole stage leans on, so these are its
// own tests restated, row for row, against the Swift implementation. The
// fixtures are the specification; the timestamps come from the same fixed clock
// the Rust harness uses, so a run is replayable and a `next_retry_at`
// comparison cannot pass by accident because the wall clock happened to move.

private let fixtureRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../../specs/contracts/fixtures/downloads")
    .standardizedFileURL

/// A fixed clock: every timestamp in a test is derived from it, so a run is
/// replayable. (Mirror of Rust `harness::stamp` — 2026-08-30T05:00:00Z + n s.)
private func stamp(_ seconds: Int) -> String {
    var components = DateComponents()
    (components.year, components.month, components.day) = (2026, 8, 30)
    (components.hour, components.minute, components.second) = (5, 0, 0)
    components.timeZone = TimeZone(identifier: "UTC")
    let base = Calendar(identifier: .gregorian).date(from: components)!
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: base.addingTimeInterval(TimeInterval(seconds)))
}

/// An in-memory store with the v9 schema. The store is pure GRDB — no tree, no
/// transport — so the mirror needs nothing on disk. (Mirror of Rust `Tree`.)
private func withStore(_ body: (GRDB.Database) throws -> Void) throws {
    let dbQueue = try DatabaseQueue()
    try dbQueue.inDatabase { db in
        try Schema.migrate(db)
        try body(db)
    }
}

/// Enqueue a book the way the facade does: mirror the manifest into `book_pages`
/// (the declared sizes the byte budget works from come from there and nowhere
/// else), then lay out the page rows. (Mirror of Rust `harness::enqueue_book`.)
private func enqueueBook(_ db: GRDB.Database, _ server: String, _ book: String, _ pages: Int) throws {
    let numbers = Array(1...pages)
    for number in numbers {
        try db.execute(
            sql: """
            INSERT OR REPLACE INTO book_pages
              (server_id, book_id, number, file_name, media_type, width, height, size_bytes, fetched_at)
            VALUES (?, ?, ?, ?, ?, 0, 0, ?, ?)
            """,
            arguments: [
                server, book, Int64(number), String(format: "%04d.png", number),
                "image/png", Int64(1_000 + number), stamp(0),
            ]
        )
    }
    let bytesTotal = numbers.reduce(Int64(0)) { $0 + Int64(1_000 + $1) }
    _ = try DownloadStore.enqueue(
        db: db,
        job: NewDownload(
            serverId: server,
            bookId: book,
            pagesTotal: pages,
            bytesTotal: bytesTotal,
            manifestPath: "/downloads/\(server)/\(book)/manifest.json",
            remoteLastModified: "2024-05-11T18:07:33Z",
            bookTitle: "Book \(book)",
            seriesTitle: "Series One"
        ),
        numbers: numbers,
        now: stamp(0)
    )
}

/// Land one page the way the engine would have, final path included. The path is
/// built by the real file-name rule, so a drift in either half shows.
private func mark(_ db: GRDB.Database, _ book: String, _ number: Int) throws {
    let path = "/downloads/s1/\(book)/"
        + DownloadTree.pageFileName(number: number, fileExtension: "png")
    try DownloadStore.markPageComplete(
        db: db,
        serverId: "s1",
        bookId: book,
        number: number,
        path: path,
        sizeBytes: Int64(1_000 + number),
        mediaType: "image/png",
        now: stamp(0)
    )
}

final class DownloadsStoreContractTests: XCTestCase {
    // MARK: accounting

    func test_counters_are_derived_from_rows_and_a_corrupted_one_is_recomputed() throws {
        try withStore { db in
            try enqueueBook(db, "s1", "b1", 6)
            for number in 1...3 {
                try mark(db, "b1", number)
            }
            // A page write does not touch the book's counters: the engine recomputes
            // them inside the same transaction it lands the page in, which is the only
            // order that cannot leave a book claiming a page the disk does not have.
            _ = try DownloadStore.recomputeCounters(
                db: db, serverId: "s1", bookId: "b1", now: stamp(1))
            var row = try XCTUnwrap(try DownloadStore.get(db: db, serverId: "s1", bookId: "b1"))
            XCTAssertEqual(row.pagesDone, 3)
            XCTAssertEqual(row.bytesDone, 1_001 + 1_002 + 1_003)

            // Corrupt the counter the way a half-applied commit would, and prove the
            // recompute fixes it. Without this half the test only measures arithmetic.
            try db.execute(
                sql: "UPDATE downloads SET pages_done = 999, bytes_done = 1 WHERE book_id = 'b1'")
            let derived = try DownloadStore.recomputeCounters(
                db: db, serverId: "s1", bookId: "b1", now: stamp(1))
            XCTAssertEqual(derived.pagesDone, 3)
            XCTAssertEqual(derived.bytesDone, 3_006)
            row = try XCTUnwrap(try DownloadStore.get(db: db, serverId: "s1", bookId: "b1"))
            XCTAssertEqual(row.pagesDone, 3)
            XCTAssertEqual(row.bytesDone, 3_006)
        }
    }

    // MARK: the optimistic write

    func test_a_pause_that_lands_mid_pass_wins_the_write() throws {
        try withStore { db in
            try enqueueBook(db, "s1", "b1", 4)
            _ = try DownloadStore.setState(
                db: db, serverId: "s1", bookId: "b1", from: [BookState.waiting.rawValue],
                to: BookState.downloading.rawValue, actor: .pump, now: stamp(0), lastError: nil)
            // The user's gesture arrives while a page is in flight.
            _ = try DownloadStore.userSet(
                db: db, serverId: "s1", bookId: "b1", to: BookState.paused.rawValue,
                now: stamp(1), lastError: nil)
            // The pass now tries to settle the book it believes it holds. It must not
            // move at all — and it must not report an error, because nothing went wrong.
            let moved = try DownloadStore.setState(
                db: db, serverId: "s1", bookId: "b1", from: [BookState.downloading.rawValue],
                to: BookState.completed.rawValue, actor: .settle, now: stamp(2), lastError: nil)
            XCTAssertFalse(moved, "a settle overwrote the user's pause")
            try mark(db, "b1", 1)
            _ = try DownloadStore.settleBook(
                db: db, serverId: "s1", bookId: "b1", now: stamp(3), mode: .pass)
            let row = try XCTUnwrap(try DownloadStore.get(db: db, serverId: "s1", bookId: "b1"))
            XCTAssertEqual(row.state, BookState.paused.rawValue, "settle laundered the pause")
            XCTAssertEqual(row.pagesDone, 1, "the counters still track the rows")
        }
    }

    // MARK: retries

    func test_retry_clears_failed_pages_and_leaves_complete_ones_alone() throws {
        try withStore { db in
            try enqueueBook(db, "s1", "b1", 4)
            try mark(db, "b1", 1)
            try mark(db, "b1", 2)
            for number in 3...4 {
                XCTAssertFalse(
                    try DownloadStore.recordPageAttempt(
                        db: db, serverId: "s1", bookId: "b1", number: number,
                        error: "页面没有完整到达", now: stamp(1)))
                XCTAssertFalse(
                    try DownloadStore.recordPageAttempt(
                        db: db, serverId: "s1", bookId: "b1", number: number,
                        error: "页面没有完整到达", now: stamp(2)))
                XCTAssertTrue(
                    try DownloadStore.recordPageAttempt(
                        db: db, serverId: "s1", bookId: "b1", number: number,
                        error: "still bad", now: stamp(3)),
                    "the third attempt is the limit")
            }
            let settled = try DownloadStore.settleBook(
                db: db, serverId: "s1", bookId: "b1", now: stamp(4), mode: .pass)
            XCTAssertEqual(
                settled, BookState.failed.rawValue,
                "2 of 4 done, 2 failed = no options left")

            let reset = try DownloadStore.retryFailedPages(
                db: db, serverId: "s1", bookId: "b1", now: stamp(5))
            XCTAssertEqual(reset, 2, "only the failed pages are re-queued")
            let kept = try DownloadStore.pages(db: db, serverId: "s1", bookId: "b1")
                .filter { $0.state == PageState.complete.rawValue }
            XCTAssertEqual(kept.count, 2)
            XCTAssertTrue(
                kept.allSatisfy { row in
                    let path = row.filePath ?? ""
                    return !path.isEmpty && row.sizeBytes > 0
                },
                "a retry must not clear a page the disk already has")
            // The book is fetchable again, so it is no longer failed.
            _ = try DownloadStore.userSet(
                db: db, serverId: "s1", bookId: "b1", to: BookState.waiting.rawValue,
                now: stamp(6), lastError: nil)
            XCTAssertEqual(
                try DownloadStore.stateOf(db: db, serverId: "s1", bookId: "b1"),
                BookState.waiting.rawValue)
        }
    }

    // MARK: the contract table

    func test_an_illegal_state_write_is_refused_rather_than_ignored() throws {
        try withStore { db in
            try enqueueBook(db, "s1", "b1", 2)
            _ = try DownloadStore.setState(
                db: db, serverId: "s1", bookId: "b1", from: [BookState.waiting.rawValue],
                to: BookState.downloading.rawValue, actor: .pump, now: stamp(0), lastError: nil)
            XCTAssertThrowsError(
                try DownloadStore.setState(
                    db: db, serverId: "s1", bookId: "b1",
                    from: [BookState.downloading.rawValue], to: BookState.downloading.rawValue,
                    actor: .pump, now: stamp(1), lastError: nil)
            ) { error in
                // `downloading -> downloading` is not in the table at all, so the
                // refusal is the contract's, not a special case in this module.
                guard case QueueError.illegalTransition = error else {
                    return XCTFail("refused for the wrong reason: \(error)")
                }
            }
        }
    }

    func test_re_enqueueing_while_a_pass_holds_the_book_is_refused() throws {
        try withStore { db in
            try enqueueBook(db, "s1", "b1", 3)
            _ = try DownloadStore.setState(
                db: db, serverId: "s1", bookId: "b1", from: [BookState.waiting.rawValue],
                to: BookState.downloading.rawValue, actor: .pump, now: stamp(0), lastError: nil)
            func again() throws {
                _ = try DownloadStore.enqueue(
                    db: db,
                    job: NewDownload(
                        serverId: "s1", bookId: "b1", pagesTotal: 3, bytesTotal: 3_000,
                        manifestPath: "/tmp/manifest.json", remoteLastModified: nil,
                        bookTitle: nil, seriesTitle: nil),
                    numbers: [1, 2, 3],
                    now: stamp(1))
            }
            XCTAssertThrowsError(try again()) { error in
                guard case QueueError.illegalTransition = error else {
                    return XCTFail("refused for the wrong reason: \(error)")
                }
            }
            // The rows the in-flight pass is working from are still there.
            XCTAssertEqual(try DownloadStore.pages(db: db, serverId: "s1", bookId: "b1").count, 3)
            // A completed book, by contrast, restarts: same gesture, different state.
            for number in 1...3 {
                try mark(db, "b1", number)
            }
            _ = try DownloadStore.settleBook(
                db: db, serverId: "s1", bookId: "b1", now: stamp(2), mode: .pass)
            XCTAssertEqual(
                try DownloadStore.stateOf(db: db, serverId: "s1", bookId: "b1"),
                BookState.completed.rawValue)
            _ = try DownloadStore.enqueue(
                db: db,
                job: NewDownload(
                    serverId: "s1", bookId: "b1", pagesTotal: 2, bytesTotal: 2_000,
                    manifestPath: "/tmp/manifest.json", remoteLastModified: nil,
                    bookTitle: nil, seriesTitle: nil),
                numbers: [1, 2],
                now: stamp(3))
            XCTAssertEqual(try DownloadStore.pages(db: db, serverId: "s1", bookId: "b1").count, 2)
        }
    }

    // MARK: parking

    func test_a_parked_server_leaves_paused_and_finished_books_alone() throws {
        try withStore { db in
            for book in ["b1", "b2", "b3"] {
                try enqueueBook(db, "s1", book, 2)
            }
            _ = try DownloadStore.userSet(
                db: db, serverId: "s1", bookId: "b2", to: BookState.paused.rawValue,
                now: stamp(1), lastError: nil)
            try mark(db, "b3", 1)
            try mark(db, "b3", 2)
            _ = try DownloadStore.settleBook(
                db: db, serverId: "s1", bookId: "b3", now: stamp(1), mode: .pass)
            let parked = try DownloadStore.parkServer(
                db: db, serverId: "s1", until: stamp(60), reason: "服务器拒绝了凭据", now: stamp(2))
            XCTAssertEqual(
                parked, 1,
                "a parked appointment is only worth giving to a book that would run")
            for book in ["b1", "b2", "b3"] {
                let row = try XCTUnwrap(try DownloadStore.get(db: db, serverId: "s1", bookId: book))
                XCTAssertEqual(
                    row.nextRetryAt != nil, book == "b1",
                    "\(book) carries a park appointment it should not have")
            }
        }
    }

    // MARK: planning

    func test_plan_books_sizes_pages_from_the_mirror_then_the_book_average() throws {
        try withStore { db in
            try enqueueBook(db, "s1", "b1", 4)
            var plans = try DownloadStore.planBooks(db: db, serverId: "s1")
            XCTAssertEqual(plans.count, 1)
            XCTAssertEqual(plans[0].pages.count, 4, "every page of the book is planned")
            XCTAssertTrue(
                plans[0].pages.allSatisfy { $0.declaredBytes > 0 },
                "the mirror's declared sizes are what the byte budget works from")
            let mirrored = plans[0].pages[0].declaredBytes

            // Take the mirror away: the book's own average still bounds the pass.
            try db.execute(sql: "DELETE FROM book_pages")
            plans = try DownloadStore.planBooks(db: db, serverId: "s1")
            let average = plans[0].pages[0].declaredBytes
            XCTAssertGreaterThan(average, 0, "bytes_total / pages_total is the fallback")
            XCTAssertLessThan(
                abs(average - mirrored), mirrored,
                "the average is the same order as the real sizes: \(average) vs \(mirrored)")

            // And with neither, zero means "unbounded", which the planner reads as
            // page-count-bound rather than as a frozen queue.
            try db.execute(sql: "UPDATE downloads SET bytes_total = 0")
            plans = try DownloadStore.planBooks(db: db, serverId: "s1")
            XCTAssertEqual(plans[0].pages[0].declaredBytes, 0)
            XCTAssertEqual(try DownloadStore.planBooks(db: db, serverId: "other").count, 0)
        }
    }

    // MARK: the reader's share

    func test_complete_pages_is_the_list_the_reader_and_the_prefetcher_share() throws {
        try withStore { db in
            try enqueueBook(db, "s1", "b1", 5)
            try mark(db, "b1", 1)
            try mark(db, "b1", 3)
            XCTAssertEqual(
                try DownloadStore.completePages(db: db, serverId: "s1", bookId: "b1"), [1, 3])
            XCTAssertEqual(try DownloadStore.pageCountAll(db: db), 2)
            XCTAssertGreaterThan(try DownloadStore.bytesDoneAll(db: db), 0)
            XCTAssertEqual(try DownloadStore.bytesDoneFor(db: db, serverId: "nope"), 0)
        }
    }

    // MARK: heal

    func test_a_settled_book_does_not_un_settle_when_a_row_goes_missing() throws {
        try withStore { db in
            try enqueueBook(db, "s1", "b1", 2)
            try mark(db, "b1", 1)
            try mark(db, "b1", 2)
            XCTAssertEqual(
                try DownloadStore.settleBook(
                    db: db, serverId: "s1", bookId: "b1", now: stamp(1), mode: .pass),
                BookState.completed.rawValue)
            try DownloadStore.healPage(db: db, serverId: "s1", bookId: "b1", number: 2, now: stamp(2))
            let settled = try DownloadStore.settleBook(
                db: db, serverId: "s1", bookId: "b1", now: stamp(3), mode: .pass)
            XCTAssertEqual(
                settled, BookState.completed.rawValue,
                "a completion is the disk's, and settle does not take it back")
            // The missing page is still queued for the sweep to re-fetch.
            XCTAssertEqual(
                try DownloadStore.page(db: db, serverId: "s1", bookId: "b1", number: 2)?.state,
                PageState.pending.rawValue)
        }
    }

    // MARK: deletion

    func test_delete_rows_hands_back_the_paths_it_stopped_tracking() throws {
        try withStore { db in
            try enqueueBook(db, "s1", "b1", 3)
            try mark(db, "b1", 1)
            let paths = try DownloadStore.deleteRows(db: db, serverId: "s1", bookId: "b1")
            XCTAssertEqual(paths.count, 1)
            XCTAssertNil(try DownloadStore.get(db: db, serverId: "s1", bookId: "b1"))
            XCTAssertTrue(try DownloadStore.pages(db: db, serverId: "s1", bookId: "b1").isEmpty)
            XCTAssertEqual(try DownloadStore.bytesDoneAll(db: db), 0)
        }
    }

    // MARK: ordering

    func test_the_queue_reads_back_in_the_order_the_user_tapped_it() throws {
        try withStore { db in
            // Deliberately reverse-alphabetical ids, so an order that fell back to the
            // rowid or the id would show up.
            for book in ["c", "a", "b"] {
                try enqueueBook(db, "s1", book, 1)
            }
            let order = try DownloadStore.list(db: db, serverId: "s1").map { $0.bookId }
            XCTAssertEqual(order, ["c", "a", "b"])
            XCTAssertEqual(try DownloadStore.list(db: db, serverId: nil).count, 3)
        }
    }

    // MARK: the fixture, as the specification

    /// `settle_book`'s derivations, each pinned to the rule in `states.json` that
    /// demands it. The fixture's `rules` are prose — the point of this test is that
    /// the prose stays anchored to behavior that actually runs.
    func test_settle_derives_exactly_what_the_states_fixture_rules_describe() throws {
        let data = try Data(contentsOf: fixtureRoot.appendingPathComponent("states.json"))
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rules = try XCTUnwrap(fixture["rules"] as? [String: Any])
        for key in ["pauseIsSticky", "healReopens", "countersAreDerived"] {
            XCTAssertNotNil(rules[key], "states.json lost the \(key) rule this test pins")
        }
        // pauseIsSticky: settle never launders a pause into progress, whatever the rows say.
        XCTAssertEqual(
            DownloadQueue.settleState("paused", pagesTotal: 4, complete: 4, failed: 0, mode: .pass),
            "paused")
        // healReopens: a completion is sticky against a pass and not against the sweep,
        // because only the sweep has looked at the disk.
        XCTAssertEqual(
            DownloadQueue.settleState("completed", pagesTotal: 4, complete: 2, failed: 0, mode: .pass),
            "completed")
        XCTAssertEqual(
            DownloadQueue.settleState("completed", pagesTotal: 4, complete: 2, failed: 0, mode: .sweep),
            "waiting")
        // countersAreDerived: the derivation reads page rows — complete first, then
        // complete + failed, then anything else is waiting, and a book with no total
        // is one whose every page is done.
        XCTAssertEqual(
            DownloadQueue.settleState("downloading", pagesTotal: 4, complete: 4, failed: 3, mode: .pass),
            "completed")
        XCTAssertEqual(
            DownloadQueue.settleState("waiting", pagesTotal: 4, complete: 2, failed: 2, mode: .pass),
            "failed")
        XCTAssertEqual(
            DownloadQueue.settleState("waiting", pagesTotal: 4, complete: 1, failed: 1, mode: .pass),
            "waiting")
        XCTAssertEqual(
            DownloadQueue.settleState("waiting", pagesTotal: 0, complete: 0, failed: 0, mode: .pass),
            "completed")
    }

    /// The store routes every state write through the contract table, so the table it
    /// consults must be the fixture's — spot-checked here on the pairs settle and the
    /// user actually exercise (the exhaustive check lives in `DownloadsContractTests`).
    func test_the_table_the_store_consults_is_the_fixture_table() throws {
        let data = try Data(contentsOf: fixtureRoot.appendingPathComponent("states.json"))
        let fixture = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let transitions = try XCTUnwrap(fixture["transitions"] as? [[String: Any]])
        func fixtureAllows(from: String, to: String, on: String) -> Bool {
            transitions.contains {
                ($0["from"] as? String) == from && ($0["to"] as? String) == to
                    && ($0["on"] as? String) == on
            }
        }
        XCTAssertTrue(
            DownloadQueue.transitionAllowed(from: "downloading", to: "completed", actor: .settle)
                == fixtureAllows(from: "downloading", to: "completed", on: "settle"))
        XCTAssertTrue(
            DownloadQueue.transitionAllowed(from: "paused", to: "waiting", actor: .user)
                == fixtureAllows(from: "paused", to: "waiting", on: "user"))
        XCTAssertFalse(
            DownloadQueue.transitionAllowed(from: "paused", to: "waiting", actor: .settle),
            "the fixture refuses this settle, and the store must refuse it too")
    }
}
