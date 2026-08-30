import XCTest
import GRDB
@testable import KomgaAPI
@testable import KomgaStore
@testable import KomgaSync
@testable import KomgaReader

/// Stage 7 acceptance gate, extended by Stage 8: both platforms replay the SAME
/// five JSON files from `specs/contracts/fixtures/reader/`, so spread pairing,
/// manifest normalization, the prefetch window, the progress throttle and the
/// dynamic window plan are one shared contract rather than two suites that could
/// drift.
///
/// Mirrors of the Rust `contract_tests` modules in `reader/paging.rs`,
/// `reader/manifest.rs`, `reader/prefetch.rs`, `reader/throttle.rs` and
/// `reader/window.rs`.
///
/// Deliberate choice: nothing in the fixture shapes below is `Optional` unless the
/// Rust struct treats that key as absent-able (`#[serde(default)]` / `Option`). A
/// missing key must fail the decode loudly, because a silently-defaulted
/// expectation would let a wrong implementation pass.
final class ReaderContractTests: XCTestCase {
    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../../../../specs/contracts/fixtures/reader")
            .standardizedFileURL
    }

    private func load<T: Decodable>(_ name: String) throws -> T {
        let data = try Data(contentsOf: fixtureURL.appendingPathComponent(name))
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// A JSON tree, so a wire body can be compared structurally against the
    /// fixture's own object form (key order is not part of the contract).
    private enum JSONValue: Decodable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case object([String: JSONValue])
        case array([JSONValue])
        case null

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null; return }
            if let value = try? container.decode(Bool.self) { self = .bool(value); return }
            if let value = try? container.decode(Double.self) { self = .number(value); return }
            if let value = try? container.decode(String.self) { self = .string(value); return }
            if let value = try? container.decode([String: JSONValue].self) { self = .object(value); return }
            if let value = try? container.decode([JSONValue].self) { self = .array(value); return }
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unsupported JSON value"
            )
        }

        static func parse(_ text: String?) -> JSONValue? {
            guard let text, let data = text.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
    }

    // MARK: - paging.json

    private struct PagingFixture: Decodable {
        var cases: [PagingCase]
    }

    private struct PagingCase: Decodable {
        var name: String
        var input: PagingInput
        var expect: PagingExpect
    }

    private struct PagingInput: Decodable {
        var pageCount: UInt32
        var mode: ReadMode
        var direction: Direction
        var firstPageSingle: Bool
        /// Absent-able exactly like Rust's `#[serde(default)]`.
        var unpairable: [UInt32]?
    }

    private struct PagingExpect: Decodable {
        var spreads: [[UInt32]]?
        var spreadCount: Int
        var scrollAxis: String
        var reversed: Bool
        var visualLeftToRight: [[UInt32]]?
        var advanceSwipe: String
        var retreatSwipe: String
        var tapNext: String
        var tapPrev: String
        var spreadIndexForPage: [String: Int]
    }

    func testPagingMatchesTheSharedContract() throws {
        let fixture: PagingFixture = try load("paging.json")
        XCTAssertFalse(fixture.cases.isEmpty)
        for case_ in fixture.cases {
            let skip = Set(case_.input.unpairable ?? [])
            let layout = Paging.layout(
                pageCount: case_.input.pageCount,
                mode: case_.input.mode,
                direction: case_.input.direction,
                firstPageSingle: case_.input.firstPageSingle,
                unpairable: skip
            )
            let navigation = layout.nav()
            let name = case_.name
            let expect = case_.expect

            if let spreads = expect.spreads {
                XCTAssertEqual(layout.spreads, spreads, "\(name): spreads")
            }
            if let visual = expect.visualLeftToRight {
                XCTAssertEqual(layout.allVisual(), visual, "\(name): visualLeftToRight")
            }
            XCTAssertEqual(layout.spreadCount, expect.spreadCount, "\(name): spreadCount")
            XCTAssertEqual(layout.axis.rawValue, expect.scrollAxis, "\(name): scrollAxis")
            XCTAssertEqual(layout.reversed, expect.reversed, "\(name): reversed")
            XCTAssertEqual(navigation.advance.rawValue, expect.advanceSwipe, "\(name): advanceSwipe")
            XCTAssertEqual(navigation.retreat.rawValue, expect.retreatSwipe, "\(name): retreatSwipe")
            XCTAssertEqual(navigation.tapNext.rawValue, expect.tapNext, "\(name): tapNext")
            XCTAssertEqual(navigation.tapPrev.rawValue, expect.tapPrev, "\(name): tapPrev")
            for (page, want) in expect.spreadIndexForPage {
                let page = try XCTUnwrap(UInt32(page), "\(name): page key must be numeric")
                XCTAssertEqual(
                    layout.spreadIndex(forPage: page), want,
                    "\(name): spreadIndexForPage[\(page)]"
                )
            }
        }
    }

    /// Anti-vacuity: the case table must actually discriminate.
    func testPagingCasesAreNotDuplicates() throws {
        let fixture: PagingFixture = try load("paging.json")
        var seen = Set<String>()
        for case_ in fixture.cases {
            let key = """
            \(case_.input.mode)|\(case_.input.direction)|\(case_.input.pageCount)|\
            \(case_.input.firstPageSingle)|\(case_.input.unpairable ?? []) => \
            \(case_.expect.spreads ?? [])|\(case_.expect.spreadCount)|\
            \(case_.expect.visualLeftToRight ?? [])|\(case_.expect.reversed)
            """
            XCTAssertTrue(seen.insert(key).inserted, "duplicate paging case: \(case_.name)")
        }
        XCTAssertGreaterThanOrEqual(seen.count, 12, "expected a discriminating table")
    }

    /// Property mirror of Rust `pairing_partitions_the_book_exactly_once`: every
    /// page lands in exactly one spread, in reading order, for every combination.
    func testPairingPartitionsTheBookExactlyOnce() {
        for mode in [ReadMode.single, .double, .webtoon] {
            for firstPageSingle in [false, true] {
                for skip in [[] as [UInt32], [1], [2, 5], [7]] {
                    let unpairable = Set(skip)
                    for pageCount: UInt32 in 0..<40 {
                        let spreads = Paging.pair(
                            pageCount: pageCount, mode: mode,
                            firstPageSingle: firstPageSingle, unpairable: unpairable
                        )
                        let expected = pageCount == 0 ? [] : Array(1...pageCount)
                        XCTAssertEqual(
                            spreads.flatMap { $0 }, expected,
                            "mode=\(mode) first=\(firstPageSingle) skip=\(skip) count=\(pageCount)"
                        )
                        XCTAssertTrue(
                            spreads.allSatisfy { !$0.isEmpty && $0.count <= 2 },
                            "spread size: \(spreads)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - manifest.json

    private struct ManifestFixture: Decodable {
        var cases: [ManifestCase]
        var contentTypes: [String: String]
    }

    private struct ManifestCase: Decodable {
        var name: String
        var input: ManifestInput
        var expect: ManifestExpect
    }

    private struct RawPageJSON: Decodable {
        var fileName: String?
        var mediaType: String?
        var number: Int64?
        var width: Int64?
        var height: Int64?
        var sizeBytes: Int64?

        var rawPage: RawPage {
            RawPage(
                fileName: fileName ?? "",
                mediaType: mediaType ?? "",
                number: number ?? 0,
                width: width,
                height: height,
                sizeBytes: sizeBytes
            )
        }
    }

    private struct ManifestInput: Decodable {
        var serverId: String
        var bookId: String
        var mediaType: String?
        var pages: [RawPageJSON]
    }

    private struct ManifestExpect: Decodable {
        var pageCount: UInt32
        var canonical: [UInt32]?
        var requestedNumbers: [UInt32]?
        var drift: UInt32
        var looksZeroBased: Bool
        var paged: Bool
        var reflowable: Bool?
        var progressionApi: Bool?
        var fallback: String?
        var emptyError: Bool?
        var widths: [UInt32]?
        var heights: [UInt32]?
        var sizeBytes: [Int64]?
        var unknownDimensions: [UInt32]?
        var unpairable: [UInt32]?
        var cacheKeys: [String]?
        var manifestMediaTypes: [String]?
        var responseExtensions: [String: String]?
    }

    func testManifestMatchesTheSharedContract() throws {
        let fixture: ManifestFixture = try load("manifest.json")
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 8)
        for case_ in fixture.cases {
            let manifest = PageManifest.fromRaw(
                serverID: case_.input.serverId,
                bookID: case_.input.bookId,
                bookMediaType: case_.input.mediaType,
                raw: case_.input.pages.map(\.rawPage)
            )
            let name = case_.name
            let expect = case_.expect

            XCTAssertEqual(manifest.pageCount, expect.pageCount, "\(name): pageCount")
            XCTAssertEqual(manifest.drift, expect.drift, "\(name): drift")
            XCTAssertEqual(
                manifest.looksZeroBased, expect.looksZeroBased, "\(name): looksZeroBased"
            )
            XCTAssertEqual(manifest.isPaged, expect.paged, "\(name): paged")
            if let reflowable = expect.reflowable {
                XCTAssertEqual(manifest.reflowable, reflowable, "\(name): reflowable")
            }
            if let progressionApi = expect.progressionApi {
                XCTAssertEqual(
                    manifest.progressionApi, progressionApi, "\(name): progressionApi"
                )
            }
            XCTAssertEqual(
                manifest.emptyError, expect.emptyError ?? false, "\(name): emptyError"
            )
            let fallback = try expect.fallback.map { raw -> Fallback in
                switch raw {
                case "epub": return .epub
                case "pdf": return .pdf
                default: XCTFail("\(name): unknown fallback \(raw)"); return .epub
                }
            }
            XCTAssertEqual(manifest.fallback, fallback, "\(name): fallback")
            if let canonical = expect.canonical {
                XCTAssertEqual(manifest.canonical(), canonical, "\(name): canonical")
            }
            if let requested = expect.requestedNumbers {
                XCTAssertEqual(manifest.canonical(), requested, "\(name): requestedNumbers")
            }
            if let widths = expect.widths {
                XCTAssertEqual(manifest.pages.map(\.width), widths, "\(name): widths")
            }
            if let heights = expect.heights {
                XCTAssertEqual(manifest.pages.map(\.height), heights, "\(name): heights")
            }
            if let sizes = expect.sizeBytes {
                XCTAssertEqual(manifest.pages.map(\.sizeBytes), sizes, "\(name): sizeBytes")
            }
            if let unknown = expect.unknownDimensions {
                XCTAssertEqual(
                    manifest.unknownDimensions(), unknown, "\(name): unknownDimensions"
                )
            }
            if let unpairable = expect.unpairable {
                XCTAssertEqual(
                    manifest.unknownDimensions().sorted(), unpairable.sorted(),
                    "\(name): unpairable"
                )
                XCTAssertEqual(manifest.unpairable(), Set(unpairable), "\(name): unpairable set")
            }
            if let keys = expect.cacheKeys {
                XCTAssertEqual(manifest.cacheKeys(), keys, "\(name): cacheKeys")
            }
            if let mediaTypes = expect.manifestMediaTypes {
                XCTAssertEqual(
                    manifest.pages.map(\.mediaType), mediaTypes, "\(name): manifestMediaTypes"
                )
            }
            if let extensions = expect.responseExtensions {
                for (contentType, want) in extensions {
                    XCTAssertEqual(
                        pageExtension(forContentType: contentType), want,
                        "\(name): responseExtensions[\(contentType)]"
                    )
                }
            }
        }

        // The content-type table is data in the fixture; the implementation must
        // agree with every row of it.
        for (contentType, ext) in fixture.contentTypes {
            if contentType == "other" {
                XCTAssertEqual(pageExtension(forContentType: "text/plain"), ext, "other")
                continue
            }
            XCTAssertEqual(
                pageExtension(forContentType: contentType), ext, contentType
            )
        }
    }

    func testManifestCasesAreDistinct() throws {
        let fixture: ManifestFixture = try load("manifest.json")
        var seen = Set<String>()
        for case_ in fixture.cases {
            let key = case_.input.pages
                .map { "\($0.number ?? 0):\($0.mediaType ?? ""):\($0.width ?? -1):\($0.height ?? -1):\($0.sizeBytes ?? -1)" }
                .joined(separator: ",") + "|\(case_.input.mediaType ?? "")"
            XCTAssertTrue(seen.insert(key).inserted, "duplicate manifest case: \(case_.name)")
        }
    }

    // MARK: - prefetch.json

    private struct PrefetchFixture: Decodable {
        var defaults: WindowJSON
        var cases: [PrefetchCase]
    }

    private struct WindowJSON: Decodable, Equatable {
        var forward: Int
        var back: Int
        var cap: Int
    }

    private struct PrefetchCase: Decodable {
        var name: String
        var input: PrefetchInput
        var expect: PrefetchExpect
    }

    private struct PrefetchInput: Decodable {
        var spreads: [[UInt32]]?
        var spreadCount: Int?
        var center: Int
        var forward: Int
        var back: Int
        var cached: [UInt32]
        var cap: Int
        var previousQueue: [UInt32]?
        var inFlight: [UInt32]?
        var mode: String?
        var direction: String?
    }

    private struct PrefetchExpect: Decodable {
        var queue: [UInt32]
        var dropped: [UInt32]?
        var cancelled: [UInt32]?
        var keptInFlight: [UInt32]?
    }

    func testPrefetchMatchesTheSharedContract() throws {
        let fixture: PrefetchFixture = try load("prefetch.json")
        XCTAssertEqual(
            WindowJSON(forward: PrefetchWindow.standard.forward,
                       back: PrefetchWindow.standard.back,
                       cap: PrefetchWindow.standard.cap),
            fixture.defaults,
            "code defaults must equal the contract defaults"
        )
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 10)
        for case_ in fixture.cases {
            let spreads = Self.spreads(of: case_.input)
            let plan = Prefetch.plan(
                spreads: spreads,
                center: case_.input.center,
                window: PrefetchWindow(
                    forward: case_.input.forward, back: case_.input.back, cap: case_.input.cap
                ),
                cached: Set(case_.input.cached)
            )
            let name = case_.name
            XCTAssertEqual(plan.queue, case_.expect.queue, "\(name): queue")
            XCTAssertEqual(plan.dropped, case_.expect.dropped ?? [], "\(name): dropped")

            if let previous = case_.input.previousQueue, !previous.isEmpty {
                let moved = Prefetch.supersede(
                    previous: previous,
                    next: plan.queue,
                    inFlight: Set(case_.input.inFlight ?? [])
                )
                XCTAssertEqual(moved.cancelled, case_.expect.cancelled ?? [], "\(name): cancelled")
                XCTAssertEqual(
                    moved.keptInFlight, case_.expect.keptInFlight ?? [], "\(name): keptInFlight"
                )
            }
        }
    }

    private static func spreads(of input: PrefetchInput) -> [[UInt32]] {
        if let spreads = input.spreads { return spreads }
        if let count = input.spreadCount { return (1...UInt32(count)).map { [$0] } }
        return []
    }

    func testPrefetchCasesAreDistinct() throws {
        let fixture: PrefetchFixture = try load("prefetch.json")
        var seen = Set<String>()
        for case_ in fixture.cases {
            let key = """
            \(Self.spreads(of: case_.input))|\(case_.input.center)|\(case_.input.forward)|\
            \(case_.input.back)|\(case_.input.cached)|\(case_.input.cap)|\
            \(case_.input.mode ?? "")|\(case_.input.direction ?? "")
            """
            XCTAssertTrue(seen.insert(key).inserted, "duplicate prefetch case: \(case_.name)")
        }
    }

    // MARK: - throttle.json

    private struct ThrottleFixture: Decodable {
        var cases: [ThrottleCase]
    }

    private struct ThrottleCase: Decodable {
        var name: String
        var input: ThrottleInput?
        var expect: ThrottleExpect?
        var phases: [ThrottlePhase]?
    }

    private struct ThrottlePhase: Decodable {
        var input: ThrottleInput
        var expect: ThrottleExpect
    }

    private struct InitialJSON: Decodable {
        var current: UInt32?
        var lastUploadAt: Int64?
    }

    private struct RestoredJSON: Decodable {
        var type: String
        var page: UInt32?
        var completed: Bool?
    }

    private struct EventJSON: Decodable {
        var at: Int64
        var kind: EventKind
        var page: UInt32?
    }

    private struct ThrottleInput: Decodable {
        var bookId: String
        var pageCount: UInt32
        var intervalMs: Int64
        var initial: InitialJSON
        var events: [EventJSON]
        var restore: [RestoredJSON]?
    }

    private struct WireJSON: Decodable {
        var at: Int64
        var method: String
        var path: String
        var body: JSONValue?
    }

    private struct ThrottleExpect: Decodable {
        var localWrites: Int
        var wireRequests: [WireJSON]
        var outboxAfter: [String]
        var finalPage: Int64
        var finalCompleted: Bool
    }

    /// Replay one event stream and assert every field of its expectation. Shared
    /// by single-shot cases and by each phase of a multi-phase case.
    private func runThrottle(_ input: ThrottleInput, _ expect: ThrottleExpect, _ name: String) throws {
        let restored = try (input.restore ?? []).first.map { row -> PendingIntent in
            switch row.type {
            case "READ_PROGRESS":
                guard let page = row.page else {
                    throw ContractAssertionError("\(name): READ_PROGRESS restore carries a page")
                }
                return .progress(page: page, completed: row.completed ?? false)
            case "MARK_READ": return .markRead
            case "MARK_UNREAD": return .markUnread
            default:
                throw ContractAssertionError("\(name): unknown restored kind \(row.type)")
            }
        }
        var throttle = ProgressThrottle(
            config: ThrottleConfig(
                bookID: input.bookId, pageCount: input.pageCount, intervalMs: input.intervalMs
            ),
            current: input.initial.current,
            lastUploadAt: input.initial.lastUploadAt,
            restored: restored
        )
        var calls: [WireCall] = []
        for event in input.events {
            calls.append(contentsOf: throttle.apply(
                ProgressEvent(at: event.at, kind: event.kind, page: event.page)
            ))
        }
        let shot = throttle.snapshot

        XCTAssertEqual(shot.localWrites, expect.localWrites, "\(name): localWrites")
        XCTAssertEqual(shot.page, expect.finalPage, "\(name): finalPage")
        XCTAssertEqual(shot.completed, expect.finalCompleted, "\(name): finalCompleted")
        XCTAssertEqual(shot.outbox, expect.outboxAfter, "\(name): outboxAfter")

        XCTAssertEqual(
            calls.count, expect.wireRequests.count,
            "\(name): wire count, got \(calls)"
        )
        for (got, want) in zip(calls, expect.wireRequests) {
            XCTAssertEqual(got.at, want.at, "\(name): request time")
            XCTAssertEqual(got.method, want.method, "\(name): method at \(got.at)")
            XCTAssertEqual(got.path, want.path, "\(name): path at \(got.at)")
            XCTAssertEqual(
                JSONValue.parse(got.body), want.body, "\(name): body at \(got.at)"
            )
        }
    }

    func testThrottleMatchesTheSharedContract() throws {
        let fixture: ThrottleFixture = try load("throttle.json")
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 10)
        for case_ in fixture.cases {
            if let input = case_.input, let expect = case_.expect {
                try runThrottle(input, expect, case_.name)
            }
            // A multi-phase case replays a real restart: each phase states in its
            // own `restore` what `pending_mutations` still holds, so no expectation
            // is ever fed back in as an input.
            for (index, phase) in (case_.phases ?? []).enumerated() {
                try runThrottle(phase.input, phase.expect, "\(case_.name)[phase \(index + 1)]")
            }
        }
    }

    func testThrottleCasesAreDistinct() throws {
        let fixture: ThrottleFixture = try load("throttle.json")
        var seen = Set<String>()
        for case_ in fixture.cases {
            let key: String
            if let input = case_.input, let expect = case_.expect {
                key = "\(input.events.map { "\($0.at)\($0.kind.rawValue)\($0.page ?? 0)" })|\(expect.localWrites)"
            } else {
                key = "phases:\(case_.phases?.count ?? 0)"
            }
            XCTAssertTrue(seen.insert(key).inserted, "duplicate throttle case: \(case_.name)")
        }
    }

    /// Rule T3 restated as a property, mirroring Rust `only_the_timer_respects_the_interval`.
    func testOnlyTheTimerRespectsTheInterval() {
        for interval in [Int64(0), 1, 5000, 600_000] {
            var early = ProgressThrottle(
                config: ThrottleConfig(bookID: "b1", pageCount: 10, intervalMs: interval),
                current: nil, lastUploadAt: 0, restored: nil
            )
            _ = early.apply(.page(at: 10, 2))
            XCTAssertEqual(
                early.apply(.of(at: interval / 2, .tick)).count,
                interval == 0 ? 1 : 0,
                "interval \(interval): half-elapsed tick"
            )
            var exiting = ProgressThrottle(
                config: ThrottleConfig(bookID: "b1", pageCount: 10, intervalMs: interval),
                current: nil, lastUploadAt: 0, restored: nil
            )
            _ = exiting.apply(.page(at: 10, 2))
            XCTAssertEqual(exiting.apply(.of(at: 11, .exit)).count, 1)
        }
    }

    /// The wire bodies must be Stage 6's, verbatim: this is the assertion that
    /// keeps the reader from inventing a second on-the-wire format.
    func testThrottleBodiesAreStage6OutboxBodies() {
        var throttle = ProgressThrottle(
            config: ThrottleConfig(bookID: "b1", pageCount: 40, intervalMs: 5000),
            current: nil, lastUploadAt: 0, restored: nil
        )
        _ = throttle.apply(.page(at: 100, 7))
        let progress = throttle.apply(.of(at: 6000, .tick))
        XCTAssertEqual(progress.count, 1)
        XCTAssertEqual(progress[0].method, "PATCH")
        XCTAssertEqual(progress[0].path, "/api/v1/books/b1/read-progress")
        XCTAssertEqual(progress[0].body, "{\"page\":7,\"completed\":false}")
        XCTAssertEqual(
            JSONValue.parse(progress[0].body),
            JSONValue.parse(requestFor(bookID: "b1", intent: .progress(page: 7, completed: false)).body)
        )

        _ = throttle.apply(.page(at: 7000, 8))
        let mark = throttle.apply(.of(at: 7100, .markRead))
        XCTAssertEqual(mark[0].body, "{\"completed\":true}")
        XCTAssertEqual(throttle.snapshot.page, 8, "the mark does not move the page")

        let unread = throttle.apply(.of(at: 8000, .markUnread))
        XCTAssertEqual(unread[0].method, "DELETE")
        XCTAssertNil(unread[0].body)
    }

    // MARK: - window.json

    private struct WindowFixture: Decodable {
        var constants: WindowConstantsJSON
        var cases: [WindowPlanCase]
        var slotCases: [WindowSlotCase]
    }

    /// The tunables, as the contract states them. Required fields on purpose: a
    /// constant that stops being pinned stops being shared, and that has to fail
    /// here rather than quietly fall back to whatever Swift says.
    private struct WindowConstantsJSON: Decodable, Equatable {
        var memoryFraction: Int64
        var memoryFloorBytes: Int64
        var memoryCeilingBytes: Int64
        var memoryDefaultBytes: Int64
        var defaultPageBytes: Int64
        var prefetchShare: Int
        var maxForward: Int
        var maxBack: Int
        var maxInFlight: Int
        var minDecodeSlots: Int
        var maxDecodeSlots: Int
    }

    private struct WindowPlanCase: Decodable {
        var name: String
        var input: WindowProfileJSON
        var expect: WindowPlanJSON
    }

    /// `input` is `WindowProfile` field for field, and the raw-value enums decode
    /// straight from the fixture's lowercase mode/direction/network strings.
    private struct WindowProfileJSON: Decodable, Equatable {
        var deviceMemoryBytes: Int64
        var cacheBudgetBytes: Int64
        var avgPageBytes: Int64
        var pagesPerSpread: Int
        var mode: ReadMode
        var direction: Direction
        var network: NetworkMode
        var stable: Bool

        var profile: WindowProfile {
            WindowProfile(
                deviceMemoryBytes: deviceMemoryBytes,
                cacheBudgetBytes: cacheBudgetBytes,
                avgPageBytes: avgPageBytes,
                pagesPerSpread: pagesPerSpread,
                mode: mode,
                direction: direction,
                network: network,
                stable: stable
            )
        }
    }

    private struct WindowPlanJSON: Decodable, Equatable {
        var forward: Int
        var back: Int
        var cap: Int
        var memoryBudgetBytes: Int64
        var inFlight: Int

        init(_ plan: WindowPlan) {
            forward = plan.forward
            back = plan.back
            cap = plan.cap
            memoryBudgetBytes = plan.memoryBudgetBytes
            inFlight = plan.inFlight
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            forward = try container.decode(Int.self, forKey: .forward)
            back = try container.decode(Int.self, forKey: .back)
            cap = try container.decode(Int.self, forKey: .cap)
            memoryBudgetBytes = try container.decode(Int64.self, forKey: .memoryBudgetBytes)
            inFlight = try container.decode(Int.self, forKey: .inFlight)
        }

        private enum CodingKeys: String, CodingKey {
            case forward, back, cap, memoryBudgetBytes, inFlight
        }
    }

    private struct WindowSlotCase: Decodable {
        var name: String
        var memoryBudgetBytes: Int64
        var decodedPageBytes: Int64
        var slots: Int
    }

    /// A constant that drifted would change the shape of every plan at once, so it
    /// is asserted by name: `XCTAssertEqual(fixture.constants, ours)` would fail
    /// with one diff and hide which knob moved.
    func testWindowConstantsAreTheSharedNumbers() throws {
        let fixture: WindowFixture = try load("window.json")
        let expect = fixture.constants
        XCTAssertEqual(expect.memoryFraction, WindowConstants.memoryFraction, "memoryFraction")
        XCTAssertEqual(expect.memoryFloorBytes, WindowConstants.memoryFloorBytes, "memoryFloorBytes")
        XCTAssertEqual(
            expect.memoryCeilingBytes, WindowConstants.memoryCeilingBytes, "memoryCeilingBytes"
        )
        XCTAssertEqual(
            expect.memoryDefaultBytes, WindowConstants.memoryDefaultBytes, "memoryDefaultBytes"
        )
        XCTAssertEqual(expect.defaultPageBytes, WindowConstants.defaultPageBytes, "defaultPageBytes")
        XCTAssertEqual(expect.prefetchShare, WindowConstants.prefetchShare, "prefetchShare")
        XCTAssertEqual(expect.maxForward, WindowConstants.maxForward, "maxForward")
        XCTAssertEqual(expect.maxBack, WindowConstants.maxBack, "maxBack")
        XCTAssertEqual(expect.maxInFlight, WindowConstants.maxInFlight, "maxInFlight")
        XCTAssertEqual(
            expect.minDecodeSlots, WindowConstants.minDecodeSlots, "minDecodeSlots"
        )
        XCTAssertEqual(
            expect.maxDecodeSlots, WindowConstants.maxDecodeSlots, "maxDecodeSlots"
        )
    }

    func testWindowMatchesTheSharedContract() throws {
        let fixture: WindowFixture = try load("window.json")
        XCTAssertGreaterThanOrEqual(
            fixture.cases.count, 14,
            "thin contract: a planner could pass 13 cases without learning the rules"
        )
        XCTAssertFalse(fixture.slotCases.isEmpty, "no slot cases means decodeSlots is unpinned")
        for case_ in fixture.cases {
            let got = WindowPlanJSON(planWindow(case_.input.profile))
            XCTAssertEqual(got, case_.expect, case_.name)
        }
        for case_ in fixture.slotCases {
            XCTAssertEqual(
                decodeSlots(
                    memoryBudgetBytes: case_.memoryBudgetBytes,
                    decodedPageBytes: case_.decodedPageBytes
                ),
                case_.slots,
                case_.name
            )
        }
    }

    /// Anti-vacuity, same discipline as every other reader contract: identical
    /// inputs with identical expectations would let a rule that ignores one of the
    /// eight named inputs pass unnoticed.
    func testWindowCasesIsolateOneInputAtATime() throws {
        let fixture: WindowFixture = try load("window.json")
        var seen = Set<String>()
        for case_ in fixture.cases {
            let input = case_.input
            let key = """
            \(input.deviceMemoryBytes)|\(input.cacheBudgetBytes)|\(input.avgPageBytes)|\
            \(input.pagesPerSpread)|\(input.mode.rawValue)|\(input.direction.rawValue)|\
            \(input.network.rawValue)|\(input.stable)
            """
            XCTAssertTrue(seen.insert(key).inserted, "duplicate window input: \(case_.name)")
        }
        func varies(_ pick: (WindowProfileJSON) -> String, _ label: String) {
            let values = Set(fixture.cases.map(\.input).map(pick))
            XCTAssertGreaterThan(
                values.count, 1,
                "no case varies \(label), so nothing proves the planner reads it"
            )
        }
        varies({ $0.deviceMemoryBytes.description }, "deviceMemoryBytes")
        varies({ $0.avgPageBytes.description }, "avgPageBytes")
        varies({ $0.cacheBudgetBytes.description }, "cacheBudgetBytes")
        varies({ $0.pagesPerSpread.description }, "pagesPerSpread")
        varies({ $0.mode.rawValue }, "mode")
        varies({ $0.direction.rawValue }, "direction")
        varies({ $0.network.rawValue }, "network")
        varies({ $0.stable.description }, "stable")
    }

    /// A fixture that only ever agreed with the code would also agree with a
    /// planner that returned a constant. At least one pair must share every input
    /// except one and disagree on the answer — and `direction` must have no such
    /// pair, because the window is measured in reading-order spreads.
    func testWindowCasesPinWhichInputsMayMoveThePlan() throws {
        let fixture: WindowFixture = try load("window.json")
        var proven = Set<String>()
        for a in fixture.cases {
            for b in fixture.cases where a.name != b.name && a.expect != b.expect {
                var differs: [String] = []
                if a.input.deviceMemoryBytes != b.input.deviceMemoryBytes {
                    differs.append("deviceMemoryBytes")
                }
                if a.input.avgPageBytes != b.input.avgPageBytes {
                    differs.append("avgPageBytes")
                }
                if a.input.mode != b.input.mode { differs.append("mode") }
                if a.input.network != b.input.network { differs.append("network") }
                if a.input.cacheBudgetBytes != b.input.cacheBudgetBytes {
                    differs.append("cacheBudgetBytes")
                }
                if a.input.stable != b.input.stable { differs.append("stable") }
                if a.input.pagesPerSpread != b.input.pagesPerSpread {
                    differs.append("pagesPerSpread")
                }
                if a.input.direction != b.input.direction { differs.append("direction") }
                if differs.count == 1 { proven.insert(differs[0]) }
            }
        }
        for input in ["avgPageBytes", "mode", "network", "cacheBudgetBytes", "stable"] {
            XCTAssert(
                proven.contains(input),
                "no single-\(input) pair changes the plan, so \(input) may be ignored"
            )
        }
        XCTAssertFalse(
            proven.contains("direction"),
            "direction must never change the plan; a pair that differs only by it "
                + "must produce equal expectations"
        )
    }
}

// MARK: - Decode-time failure helpers

/// Thrown out of a decode/derive step after the failure has already been
/// recorded, so one bad fixture row stops the test instead of being skipped.
private struct ContractAssertionError: Error {
    init(_ message: String) {
        XCTFail(message)
    }
}
