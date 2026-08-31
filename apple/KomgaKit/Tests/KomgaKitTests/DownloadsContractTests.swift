import Foundation
import XCTest
@testable import KomgaDownloads

// MARK: - Stage 9's queue rules, re-derived on the Apple side from the same files
//
// `downloads/queue.rs` exists as a pure module precisely so this file can exist:
// the fixtures are the specification, and the Rust suite and this one each run
// the same cases against their own implementation. Anything that only holds for
// one platform fails here rather than showing up as a download that resumes
// itself on an iPhone.

private let fixtureRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("../../../../specs/contracts/fixtures/downloads")
    .standardizedFileURL

private func downloadFixture<T: Decodable>(_ name: String) throws -> T {
    let data = try Data(contentsOf: fixtureRoot.appendingPathComponent(name))
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - fixtures, as decoded shapes

private struct StatesFixture: Decodable {
    struct Row: Decodable, Equatable {
        let from: String?
        let to: String?
        let on: String
    }

    let transitions: [Row]
    let illegal: [Row]
}

private struct ErrorsFixture: Decodable {
    struct Bounds: Decodable {
        let maxPageAttempts: Int
        let consecutiveBadPages: Int
        let defaultMaxPages: Int
        let defaultMaxBytes: Int64
        let maxElapsedMs: Int64
        let nextInMs: [String: Int64]
    }

    struct Outcome: Decodable {
        let scope: String
        let burnsAttempt: Bool
    }

    let signals: [String: String]
    let classify: [Entry]
    let `default`: String
    let outcomes: [String: Outcome]
    let bounds: Bounds

    struct Entry: Decodable {
        let signal: String
        let outcome: String
    }
}

private struct PumpFixture: Decodable {
    struct PagePlan: Decodable {
        let number: Int
        let state: String
        let attempts: Int
        let declaredBytes: Int64
    }

    struct BookPlan: Decodable {
        let bookId: String
        let position: Int
        let state: String
        let allowCellular: Bool
        let nextRetryAt: String?
        let pagesTotal: Int
        let pages: [PagePlan]
    }

    struct Reader: Decodable {
        let bookId: String
        let page: Int
    }

    struct Input: Decodable {
        let now: String
        let link: String
        let freeBytes: Int64
        let maxPages: Int
        let maxBytes: Int64
        let reader: Reader?
        let books: [BookPlan]
    }

    struct Job: Decodable {
        let bookId: String
        let page: Int
    }

    struct Expect: Decodable {
        let jobs: [Job]
        let stopReason: String
        let nextInMs: Int64?
    }

    struct Case: Decodable {
        let name: String
        let input: Input
        let expect: Expect
    }

    let cases: [Case]
}

final class DownloadsContractTests: XCTestCase {
    // MARK: transitions

    func test_the_restated_table_is_the_fixture_table_row_for_row() throws {
        let fixture: StatesFixture = try downloadFixture("states.json")
        let asRows = { (rows: [TransitionRow]) in
            Set(rows.map { "\($0.from ?? "<none>")|\($0.to ?? "<delete>")|\($0.on)" })
        }
        XCTAssertEqual(
            asRows(DownloadQueue.transitions),
            asRows(fixture.transitions.map { TransitionRow(from: $0.from, to: $0.to, on: $0.on) }),
            "the Apple transition table has drifted from states.json#transitions"
        )
        XCTAssertEqual(
            asRows(DownloadQueue.illegal),
            asRows(fixture.illegal.map { TransitionRow(from: $0.from, to: $0.to, on: $0.on) }),
            "the Apple refusal table has drifted from states.json#illegal"
        )
        XCTAssertFalse(fixture.transitions.isEmpty && fixture.illegal.isEmpty)
    }

    func test_enqueue_is_the_one_transition_with_no_previous_state() throws {
        XCTAssertTrue(DownloadQueue.enqueueAllowed())
        // Delete is the mirror case: any state, no next state, user only.
        XCTAssertTrue(
            DownloadQueue.transitionAllowed(from: "paused", to: nil, actor: .user)
        )
        XCTAssertFalse(
            DownloadQueue.transitionAllowed(from: "paused", to: nil, actor: .pump),
            "a pass may not delete what the user asked to keep"
        )
    }

    func test_a_pause_is_only_ever_left_by_the_user() {
        // The bug the fixture names first: a pump that resumes a pause survives
        // review and spends the user's data.
        XCTAssertFalse(
            DownloadQueue.transitionAllowed(from: "paused", to: "downloading", actor: .pump)
        )
        XCTAssertTrue(
            DownloadQueue.transitionAllowed(from: "paused", to: "waiting", actor: .user)
        )
        XCTAssertFalse(
            DownloadQueue.transitionAllowed(from: "paused", to: "waiting", actor: .settle),
            "settle must not launder a pause into progress"
        )
    }

    func test_an_unlisted_pair_is_refused_rather_than_allowed() {
        // Neither table names it, so it must be impossible: that is what makes a
        // state added on one platform an error on the other instead of a pass.
        XCTAssertFalse(
            DownloadQueue.transitionAllowed(from: "waiting", to: "bogus", actor: .user)
        )
        XCTAssertFalse(
            DownloadQueue.transitionAllowed(from: nil, to: "downloading", actor: .pump)
        )
    }

    func test_the_page_level_rules_match_the_book_level_ones_in_spirit() {
        XCTAssertTrue(
            DownloadQueue.transitionAllowed(from: "pending", to: "complete", actor: .pump)
        )
        XCTAssertFalse(
            DownloadQueue.transitionAllowed(from: "complete", to: "pending", actor: .pump),
            "the pump never un-completes a page; only the sweep has read the disk"
        )
        XCTAssertTrue(
            DownloadQueue.transitionAllowed(from: "complete", to: "pending", actor: .heal)
        )
        XCTAssertFalse(
            DownloadQueue.transitionAllowed(from: "pending", to: "downloading", actor: .pump),
            "there is no persisted in-flight page state"
        )
    }

    // MARK: failures

    func test_every_signal_classifies_the_way_the_fixture_says() throws {
        let fixture: ErrorsFixture = try downloadFixture("errors.json")
        for entry in fixture.classify {
            let signal = try XCTUnwrap(
                PageSignal(rawValue: entry.signal),
                "the fixture names a signal this build has no case for: \(entry.signal)"
            )
            XCTAssertEqual(
                DownloadQueue.classify(signal).rawValue,
                entry.outcome,
                "\(entry.signal) classified differently"
            )
        }
        // The fixture's list and this build's vocabulary must be the same size,
        // or a signal added on one side is silently falling to the default.
        XCTAssertEqual(
            Set(fixture.classify.map(\.signal)),
            Set(PageSignal.allCases.map(\.rawValue))
        )
    }

    func test_the_default_is_the_one_entry_not_in_the_table() throws {
        let fixture: ErrorsFixture = try downloadFixture("errors.json")
        XCTAssertEqual(DownloadQueue.defaultOutcome.rawValue, fixture.`default`)
        let mapped = Set(fixture.classify.compactMap { entry in
            PageSignal(rawValue: entry.signal) == nil ? entry.signal : nil
        })
        XCTAssertEqual(mapped.count, 0, "an unnameable signal is in the table, not the default")
    }

    func test_scope_and_attempt_cost_come_from_the_fixture_not_from_a_local_match() throws {
        let fixture: ErrorsFixture = try downloadFixture("errors.json")
        for outcome in PageOutcome.allCases {
            let entry = try XCTUnwrap(
                fixture.outcomes[outcome.rawValue],
                "this build reports an outcome the fixture does not define: \(outcome.rawValue)"
            )
            XCTAssertEqual(
                DownloadQueue.scope(of: outcome).rawValue,
                entry.scope,
                "\(outcome.rawValue) scope"
            )
            XCTAssertEqual(
                DownloadQueue.burnsAttempt(outcome),
                entry.burnsAttempt,
                "\(outcome.rawValue) attempt cost"
            )
        }
        XCTAssertEqual(Set(fixture.outcomes.keys), Set(PageOutcome.allCases.map(\.rawValue)))
        // The one fact the whole failure policy hangs on: an outage costs
        // nothing, so the user is not charged for a tunnel.
        XCTAssertFalse(DownloadQueue.burnsAttempt(.linkDown))
        XCTAssertTrue(DownloadQueue.burnsAttempt(.badPage))
    }

    // MARK: bounds

    func test_the_bounds_are_the_fixtures_numbers() throws {
        let fixture: ErrorsFixture = try downloadFixture("errors.json")
        XCTAssertEqual(DownloadQueue.maxPageAttempts, fixture.bounds.maxPageAttempts)
        XCTAssertEqual(DownloadQueue.consecutiveBadPages, fixture.bounds.consecutiveBadPages)
        XCTAssertEqual(DownloadQueue.defaultMaxPages, fixture.bounds.defaultMaxPages)
        XCTAssertEqual(DownloadQueue.defaultMaxBytes, fixture.bounds.defaultMaxBytes)
        XCTAssertEqual(DownloadQueue.maxElapsedMs, fixture.bounds.maxElapsedMs)
    }

    func test_the_wait_before_the_next_pass_is_the_fixtures_wait() throws {
        let fixture: ErrorsFixture = try downloadFixture("errors.json")
        for (reason, expected) in fixture.bounds.nextInMs {
            let stop = try XCTUnwrap(
                StopReason(rawValue: reason),
                "the fixture names a stop reason this build lacks: \(reason)"
            )
            XCTAssertEqual(
                DownloadQueue.nextInMs(for: stop, waitMs: 0),
                expected,
                "\(reason) waits differently"
            )
        }
        // A real appointment outranks a generic wait: parking was decided with
        // more information than "this attempt failed".
        XCTAssertGreaterThanOrEqual(
            DownloadQueue.nextInMs(for: .linkDown, waitMs: 90_000),
            90_000
        )
    }

    // MARK: planning

    func test_the_planner_agrees_with_every_pump_case() throws {
        let fixture: PumpFixture = try downloadFixture("pump.json")
        XCTAssertEqual(fixture.cases.count, 15, "the fixture grew and this suite did not notice")
        for testCase in fixture.cases {
            let input = PassInput(
                now: try XCTUnwrap(
                    QueueTime.parse(testCase.input.now),
                    "case \(testCase.name): unreadable now"
                ),
                books: testCase.input.books.map { book in
                    BookPlan(
                        serverId: "A",
                        bookId: book.bookId,
                        position: book.position,
                        state: book.state,
                        allowCellular: book.allowCellular,
                        pagesTotal: book.pagesTotal,
                        nextRetryAt: book.nextRetryAt,
                        pages: book.pages.map {
                            PagePlan(
                                number: $0.number,
                                state: $0.state,
                                attempts: $0.attempts,
                                declaredBytes: $0.declaredBytes
                            )
                        }
                    )
                },
                link: LinkClass.parse(testCase.input.link),
                freeBytes: testCase.input.freeBytes,
                maxPages: testCase.input.maxPages,
                maxBytes: testCase.input.maxBytes,
                reader: testCase.input.reader.map { ReaderPlace(bookId: $0.bookId, page: $0.page) }
            )

            let planned = DownloadQueue.planPass(input)
            let got = planned.jobs.map { "\($0.bookId):\($0.number)" }
            let want = testCase.expect.jobs.map { "\($0.bookId):\($0.page)" }
            XCTAssertEqual(got, want, "\(testCase.name): different jobs")
            XCTAssertEqual(
                planned.stop.rawValue,
                testCase.expect.stopReason,
                "\(testCase.name): stopped for a different reason"
            )
            if let wait = testCase.expect.nextInMs {
                XCTAssertEqual(
                    planned.nextInMs,
                    wait,
                    "\(testCase.name): told the caller to wait a different length"
                )
            }
        }
    }

    func test_the_planner_is_deterministic_for_one_input() throws {
        let fixture: PumpFixture = try downloadFixture("pump.json")
        let testCase = try XCTUnwrap(fixture.cases.first)
        let input = PassInput(
            now: QueueTime.parse(testCase.input.now)!,
            books: [
                BookPlan(
                    serverId: "A",
                    bookId: "b1",
                    position: 1,
                    state: "waiting",
                    allowCellular: false,
                    pagesTotal: 6,
                    nextRetryAt: nil,
                    pages: (1...3).map {
                        PagePlan(number: $0, state: "pending", attempts: 0, declaredBytes: 100)
                    }
                ),
            ],
            link: .unmetered,
            freeBytes: 1_000_000,
            maxPages: 4,
            maxBytes: 1_000_000,
            reader: nil
        )
        let first = DownloadQueue.planPass(input)
        let second = DownloadQueue.planPass(input)
        XCTAssertEqual(first, second, "planning the same input twice gave two answers")
        XCTAssertTrue(first.claims, "a waiting book must announce itself as downloading")
    }

    func test_an_unnamed_link_is_treated_as_unknown_not_as_free_wifi() {
        // The conservative direction: a misread here spends mobile data the user
        // never agreed to.
        XCTAssertEqual(LinkClass.parse("bluetooth"), .unknown)
        XCTAssertEqual(LinkClass.parse("unmetered"), .unmetered)
        XCTAssertNil(LinkClass(rawValue: "cellular"), "cellular is a platform word, not ours")
    }
}
