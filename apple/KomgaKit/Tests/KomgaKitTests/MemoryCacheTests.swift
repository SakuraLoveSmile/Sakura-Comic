import XCTest
@testable import KomgaReader

/// The Stage 8 memory tier: `android/komga_core/src/reader/memory.rs`'s rules,
/// restated against `ByteBudgetCache`. The acceptance list's claim is that memory
/// stays flat over 500 pages, and every test here exists to keep that claim from
/// being decorative — a cache that "happens to be small" during a run proves
/// nothing, a cache that refuses to exceed the budget it was given does.
final class MemoryCacheTests: XCTestCase {
    private let kb = 1024

    private func page(_ bytes: Int) -> Data { Data(count: bytes) }

    // MARK: - Accounting

    func testInsertReadRemoveRoundTripsWithAccounting() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 10 * kb)
        XCTAssertNil(cache.value(for: 1), "an empty tier answers nothing")
        XCTAssertEqual(cache.stats.misses, 1, "a miss has to be counted or hitRate lies")

        XCTAssertTrue(cache.insert(page(4 * kb), for: 1))
        XCTAssertEqual(cache.usedBytes, 4 * kb)
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.value(for: 1)?.count, 4 * kb)
        XCTAssertEqual(cache.stats.hits, 1)
        XCTAssertEqual(cache.stats.hitRate ?? 0, 0.5, accuracy: 0.0001)

        XCTAssertEqual(cache.remove(1)?.count, 4 * kb)
        XCTAssertEqual(cache.usedBytes, 0)
        XCTAssertTrue(cache.isEmpty)
        XCTAssertNil(cache.remove(1), "removing twice is not an error")
    }

    /// Re-inserting must not double-count: the shape of the bug this catches is a
    /// reader that re-reads one page forty times and ends the session holding
    /// forty copies of it.
    func testReInsertingAKeyReplacesRatherThanGrows() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 10 * kb)
        XCTAssertTrue(cache.insert(page(4 * kb), for: 7))
        XCTAssertTrue(cache.insert(page(6 * kb), for: 7))
        XCTAssertEqual(cache.usedBytes, 6 * kb, "the same key must not double-count")
        XCTAssertEqual(cache.count, 1)
        XCTAssertEqual(cache.stats.evictions, 0, "a replacement is not an eviction")
        XCTAssertEqual(cache.peek(7)?.count, 6 * kb, "the new bytes won")
    }

    // MARK: - The bound

    /// The property the acceptance list depends on: no sequence of inserts ever
    /// leaves the tier holding more than it was given.
    ///
    /// MUTATION CHECK: `usedBytes <= budget` alone would still pass for a cache
    /// that cleared itself on every insert — it would be bounded, useless, and the
    /// `entries == 21` / `evictions >= 470` pair below is what makes that
    /// implementation fail, by naming exactly how much has to survive.
    func testTheTierNeverExceedsItsBudgetUnderSustainedLoad() {
        let budget = 64 * kb
        let cache = ByteBudgetCache<Data>(budgetBytes: budget)
        for index: UInt32 in 0..<500 {
            // 3 KiB pages: 21 fit, so this evicts on nearly every insert.
            XCTAssertTrue(cache.insert(page(3072), for: index))
            XCTAssertLessThanOrEqual(
                cache.usedBytes, cache.budgetBytes, "over budget at page \(index)"
            )
            XCTAssertEqual(
                cache.usedBytes, cache.count * 3072,
                "byte count and entry count disagree at page \(index): something was "
                    + "subtracted twice or not at all"
            )
        }
        let stats = cache.stats
        XCTAssertEqual(stats.entries, 21, "64KiB / 3KiB = 21 whole pages")
        XCTAssertGreaterThanOrEqual(stats.evictions, 470)
        XCTAssertEqual(stats.peakBytes, 63 * kb, "21 * 3KiB, and never more")
        XCTAssertLessThanOrEqual(stats.peakBytes, budget, "the high-water mark is the bound")
        XCTAssertTrue(stats.refusedOversized == 0, "3KiB fits a 64KiB tier")
    }

    /// Replacing a resident page with a bigger one is the path where the tier has
    /// to evict somebody else to make room — and the path where an accounting bug
    /// hides, because the outgoing bytes can be subtracted once by the replacement
    /// and once again by the eviction that follows it.
    ///
    /// MUTATION CHECK: with the outgoing slot left resident while the bytes are
    /// subtracted, the eviction loop below picks that same key as its victim and
    /// `usedBytes` lands on 8192 instead of 9216. Every other assertion in this
    /// file — including the budget bound above, which only ever inserts distinct
    /// keys — still passes. That is why both the total and the surviving key set
    /// are named here: `usedBytes <= budget` alone would call 8192 a success.
    func testReplacingAResidentPageWithABiggerOneAccountsOnce() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 10 * kb)
        cache.insert(page(1 * kb), for: 1)
        cache.insert(page(9 * kb), for: 2)
        XCTAssertEqual(cache.usedBytes, 10 * kb)
        XCTAssertTrue(cache.insert(page(9 * kb), for: 1))
        XCTAssertEqual(cache.usedBytes, 9 * kb, "one resident page of 9KiB, nothing else")
        XCTAssertEqual(cache.count, 1)
        XCTAssertFalse(cache.contains(2), "2 was the victim; 1 must not evict itself twice")
        XCTAssertEqual(cache.stats.evictions, 1)
        // The bound still holds for what comes next, which is what an under-count
        // would quietly break: a tier that thinks it is empty fills past its budget.
        XCTAssertTrue(cache.insert(page(1 * kb), for: 3))
        XCTAssertEqual(cache.usedBytes, 10 * kb)
        XCTAssertLessThanOrEqual(cache.usedBytes, cache.budgetBytes)
    }

    /// Every item in this tier is smaller than the budget, yet a budget of zero
    /// still cannot be overfilled — the degenerate case is where an off-by-one in
    /// the eviction predicate shows up.
    func testAZeroBudgetHoldsNothing() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 0)
        XCTAssertFalse(cache.insert(page(1), for: 1))
        XCTAssertEqual(cache.stats.refusedOversized, 1)
        XCTAssertTrue(cache.isEmpty)
        // A negative budget is a caller bug, not a crash: it clamps to zero.
        let clamped = ByteBudgetCache<Data>(budgetBytes: -4096)
        XCTAssertEqual(clamped.budgetBytes, 0)
        XCTAssertTrue(clamped.insert(page(0), for: 1), "an empty value costs nothing")
        XCTAssertEqual(clamped.usedBytes, 0)
        XCTAssertFalse(clamped.insert(page(1), for: 2))
    }

    // MARK: - Victim selection

    /// Eviction has to follow *use*, because the page the reader is looking at is
    /// the one that must not be re-read from disk.
    ///
    /// MUTATION CHECK: a least-recently-*inserted* tier passes every byte-count
    /// assertion in this file — it is just as bounded. Only the `a` survives /
    /// `b` is the victim pair below separates the two, and only because `a` was
    /// read after `b` was inserted. Asserting the totals instead would let an
    /// insertion-order queue through with a nicer-looking failure rate.
    func testEvictionIsLeastRecentlyUsedNotLeastRecentlyInserted() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 10 * kb)
        cache.insert(page(3 * kb), for: 1)
        cache.insert(page(3 * kb), for: 2)
        cache.insert(page(3 * kb), for: 3)
        // Touch page 1 so it becomes the newest; insertion order would lose it.
        XCTAssertNotNil(cache.value(for: 1))
        cache.insert(page(3 * kb), for: 4)
        XCTAssertTrue(cache.contains(1), "1 was used most recently")
        XCTAssertFalse(cache.contains(2), "2 is the oldest untouched entry, so 2 is the victim")
        XCTAssertTrue(cache.contains(3))
        XCTAssertTrue(cache.contains(4))
    }

    /// A `peek` is a question, not a use: it must not rescue a page from eviction,
    /// or every diagnostic that looks at the tier would silently change its
    /// contents.
    func testPeekDoesNotChangeRecencyOrCountAsAHit() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 10 * kb)
        cache.insert(page(3 * kb), for: 1)
        cache.insert(page(3 * kb), for: 2)
        XCTAssertNotNil(cache.peek(1))
        XCTAssertEqual(cache.stats.hits, 0, "a peek is not a use")
        cache.insert(page(3 * kb), for: 3)
        cache.insert(page(3 * kb), for: 4)
        XCTAssertFalse(cache.contains(1), "peeking left 1 as the oldest real use")
        XCTAssertTrue(cache.contains(2))
    }

    // MARK: - Refusal

    /// An oversized page is a lost optimization, never a lost page — and it must
    /// not be allowed to evict the spread that is on screen to make room for
    /// itself.
    func testAnItemLargerThanTheBudgetIsRefusedWithoutDisturbingResidents() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 4 * kb)
        XCTAssertTrue(cache.insert(page(2 * kb), for: 1))
        XCTAssertFalse(cache.insert(page(5 * kb), for: 2), "refused")
        XCTAssertEqual(cache.stats.refusedOversized, 1)
        XCTAssertTrue(cache.contains(1), "a refusal must not evict what is already resident")
        XCTAssertEqual(cache.usedBytes, 2 * kb)
        XCTAssertEqual(cache.count, 1)
        XCTAssertNil(cache.peek(2), "and the oversized key is not half-stored")

        // Exactly the whole budget is not oversized: it just evicts everything.
        XCTAssertTrue(cache.insert(page(4 * kb), for: 3))
        XCTAssertEqual(cache.usedBytes, 4 * kb)
        XCTAssertFalse(cache.contains(1), "the tier holds one full-budget page and nothing else")
    }

    // MARK: - Resizing

    func testShrinkingTheBudgetEvictsFromTheTail() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 12 * kb)
        for key: UInt32 in [1, 2, 3] { cache.insert(page(4 * kb), for: key) }
        XCTAssertEqual(cache.usedBytes, 12 * kb)
        XCTAssertEqual(cache.setBudgetBytes(8 * kb), 1, "one entry had to go")
        XCTAssertEqual(cache.usedBytes, 8 * kb)
        XCTAssertFalse(cache.contains(1), "the oldest went first")
        XCTAssertTrue(cache.contains(2) && cache.contains(3))
        cache.budgetBytes = 0
        XCTAssertTrue(cache.isEmpty, "the setter path has to trim too")
        // Growing never admits entries back: what was evicted comes from disk.
        cache.budgetBytes = 32 * kb
        XCTAssertEqual(cache.usedBytes, 0)
        XCTAssertTrue(cache.insert(page(4 * kb), for: 9))
    }

    func testRetainKeysDropsEverythingOutsideTheLiveWindow() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 20 * kb)
        for key: UInt32 in [1, 2, 3, 4] { cache.insert(page(2 * kb), for: key) }
        XCTAssertEqual(cache.retainKeys([2, 3]), 2)
        XCTAssertEqual(cache.usedBytes, 4 * kb)
        XCTAssertFalse(cache.contains(1) || cache.contains(4))
        XCTAssertTrue(cache.contains(2) && cache.contains(3))
        XCTAssertEqual(cache.retainKeys([2, 3]), 0, "retaining what is already kept is a no-op")
        // Retention is not eviction-by-budget: peak stays where it was.
        XCTAssertEqual(cache.stats.peakBytes, 8 * kb)
    }

    /// Fast flips are the case the plan shrinks and the tier has to follow: what
    /// the reader flew past may keep its bytes, but the LRU order must be intact
    /// afterwards, which is only true if nothing renumbered the survivors.
    func testRetainedEntriesKeepTheirRelativeRecency() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 12 * kb)
        for key: UInt32 in [1, 2, 3] { cache.insert(page(4 * kb), for: key) }
        XCTAssertNotNil(cache.value(for: 1))
        XCTAssertEqual(cache.retainKeys([1, 2, 3]), 0)
        // Nothing was dropped, so the next insert must still lose page 2 — the
        // oldest by use, since 1 was read and 3 was inserted after it.
        cache.insert(page(4 * kb), for: 4)
        XCTAssertFalse(cache.contains(2))
        XCTAssertTrue(cache.contains(1) && cache.contains(3) && cache.contains(4))
    }

    // MARK: - Stats

    func testResetStatsClearsCountersButNotContents() {
        let cache = ByteBudgetCache<Data>(budgetBytes: 10 * kb)
        cache.insert(page(3 * kb), for: 1)
        cache.insert(page(6 * kb), for: 2)
        XCTAssertNotNil(cache.value(for: 1))
        XCTAssertNil(cache.value(for: 99))
        cache.resetStats()
        let stats = cache.stats
        XCTAssertEqual(stats.hits, 0)
        XCTAssertEqual(stats.misses, 0)
        XCTAssertEqual(stats.evictions, 0)
        XCTAssertEqual(stats.refusedOversized, 0)
        XCTAssertEqual(stats.entries, 2, "a stats reset is not a flush")
        XCTAssertEqual(stats.peakBytes, cache.usedBytes, "peak restarts at what is held")
        XCTAssertNil(stats.hitRate, "an empty sample has no rate")
    }

    // MARK: - Generic value shape

    /// The tier is generic over `Value` with an injected cost, so a caller that
    /// counts something other than `Data.count` has to get the same bound.
    func testACustomByteCountIsHonoured() {
        // 1 byte per element of an Int array, which is not `MemoryLayout.size`.
        let cache = ByteBudgetCache<[Int]>(budgetBytes: 12) { $0.count }
        let four = Array(repeating: 0, count: 4)
        XCTAssertTrue(cache.insert(four, for: 1))
        XCTAssertTrue(cache.insert(four, for: 2))
        XCTAssertTrue(cache.insert(four, for: 3))
        XCTAssertEqual(cache.usedBytes, 12)
        XCTAssertTrue(cache.insert(four, for: 4), "room is made, not refused")
        XCTAssertFalse(cache.contains(1))
        XCTAssertEqual(cache.stats.evictions, 1)
        XCTAssertFalse(
            cache.insert(Array(repeating: 0, count: 13), for: 5), "13 does not fit 12"
        )
        XCTAssertEqual(cache.stats.refusedOversized, 1)
        XCTAssertEqual(cache.usedBytes, 12, "a refusal changed nothing")
    }

    // MARK: - Concurrency

    /// The tier is shared by the view body's synchronous read and the async load
    /// path, so it is locked rather than actor-isolated. This is the only test that
    /// exercises that lock.
    func testConcurrentInsertsStayInsideTheBudget() {
        let budget = 65536
        let cache = ByteBudgetCache<Data>(budgetBytes: budget)
        // Built up here: the `@Sendable` closure must not capture the test case.
        let pages = (0..<500).map { _ in Data(count: 3072) }
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            cache.insert(pages[index], for: UInt32(index % 50))
            _ = cache.value(for: UInt32(index % 50))
            _ = cache.peek(UInt32(index % 50))
        }
        XCTAssertLessThanOrEqual(cache.usedBytes, budget)
        XCTAssertLessThanOrEqual(cache.stats.peakBytes, budget)
        XCTAssertEqual(cache.stats.hits + cache.stats.misses, 500)
    }
}
