import Foundation

// MARK: - Byte-budget memory tier (mirror of `reader/memory.rs`)
//
// Stage 7's reader held `images: [UInt32: Data]` and never dropped an entry. On a
// 500-page strip that is not "a cache that grows"; it is a leak with a nice name —
// the process is killed by the foot-limit watchdog or the OS jetsam, and the reader
// loses the page it was on. The whole point of Stage 8 is that memory stays flat
// over a long session, so growth here is bounded by construction: the tier holds at
// most the budget it was given, and says so when it refuses an item.
//
// Three reasons the tier exists at all, rather than leaving every read on disk:
//
// * a turn that lands on a prefetched page gets its bytes without a file read,
//   which is the difference between a smooth flip and a hitch on a 24 MB page,
// * the reader's hot set (the visible spread plus its neighbours) stays pinned no
//   matter how many other pages are open in the session,
// * and because it is budgeted, it cannot be the thing that OOMs the session.
//
// Rules the tests pin down:
//
// * `usedBytes` never exceeds `budgetBytes` after any operation, including
//   `insert` — room is made for an incoming entry *before* it lands, so the total
//   never even transiently overshoots.
// * An item larger than the whole budget is refused, not stored, and is not
//   allowed to evict everything else for it. The caller then falls back to disk,
//   which is always correct: a refusal is a lost optimization, never a lost page.
// * Re-inserting a key replaces its bytes rather than growing the tier.
// * Eviction is by least-recently-*used*, not least-recently-inserted: reading an
//   entry stamps it, so a page the reader is looking at cannot be the victim.
// * Recency is a monotonic sequence number, never wall-clock time. Two runs with
//   the same operations must pick the same victim, and a clock that can tie at
//   millisecond resolution (or step backwards when the system re-syncs) would make
//   eviction depend on when the test happened to run.
//
// This mirrors `MemoryCache` field for field so a plan sized on one platform means
// the same bytes on the other.

/// What the tier is doing right now: how much it holds and why it dropped things.
/// The performance harness reads this to prove memory stays flat over a long
/// session, which `usedBytes` alone cannot show — a tier can be small because it is
/// warm and hitting, or small because it is thrashing.
public struct MemoryCacheStats: Sendable, Equatable {
    public var entries: Int = 0
    public var bytes: Int = 0
    /// High-water mark of `bytes`, which is what "bounded" actually claims.
    public var peakBytes: Int = 0
    public var hits: Int = 0
    public var misses: Int = 0
    /// Entries dropped to stay inside the budget.
    public var evictions: Int = 0
    /// Insertions refused because the item alone exceeded the budget.
    public var refusedOversized: Int = 0

    public init() {}

    /// Hits over lookups, or nil when nothing was asked for yet: an average of an
    /// empty sample is not 0%, it is unknown.
    public var hitRate: Double? {
        let lookups = hits + misses
        return lookups > 0 ? Double(hits) / Double(lookups) : nil
    }
}

/// A byte-budget LRU over canonical page numbers.
///
/// `Value` is generic so the same discipline covers encoded page bytes and any
/// future representation the UI wants pinned; `UInt32` keys because a page number
/// is the only identity the reader has (see `PageManifest`'s canonical numbering).
///
/// Threaded by a lock rather than by an actor because it is read from the view
/// body's synchronous path (`imageData(for:)`) as well as from the async loading
/// path — an actor would force a `await` in front of a pixel that is already warm.
public final class ByteBudgetCache<Value: Sendable>: @unchecked Sendable {
    private struct Slot {
        var value: Value
        var bytes: Int
        /// Position in this cache's own timeline; see the header on why not a date.
        var seq: UInt64
    }

    private let lock = NSLock()
    private var slots: [UInt32: Slot] = [:]
    /// `(seq, key)` pairs appended in increasing `seq`, so the live oldest entry is
    /// the first pair still matching its slot. Bumping recency appends a new pair
    /// and leaves the old one behind as garbage that is skipped on the way past —
    /// which is what keeps eviction O(1) amortized instead of a rescan.
    private var order: [(seq: UInt64, key: UInt32)] = []
    private var head = 0
    private var sequence: UInt64 = 0
    private var used = 0
    private var peak = 0
    private var hits = 0
    private var misses = 0
    private var evictions = 0
    private var refusedOversized = 0
    private var budget: Int
    private let byteCount: @Sendable (Value) -> Int

    /// Cost of one value, in bytes. Injected because only the caller knows what it
    /// is holding: an encoded page counts its `Data` length, a bitmap would count
    /// its pixels.
    public init(
        budgetBytes: Int,
        byteCount: @escaping @Sendable (Value) -> Int
    ) {
        self.budget = max(budgetBytes, 0)
        self.byteCount = byteCount
    }

    /// Bytes the tier may hold. Lowering it evicts from the LRU tail immediately.
    public var budgetBytes: Int {
        get { lock.withLock { budget } }
        set { setBudgetBytes(newValue) }
    }

    public var usedBytes: Int { lock.withLock { used } }
    public var peakBytes: Int { lock.withLock { peak } }
    public var count: Int { lock.withLock { slots.count } }
    public var isEmpty: Bool { lock.withLock { slots.isEmpty } }

    public var stats: MemoryCacheStats {
        lock.withLock {
            var snapshot = MemoryCacheStats()
            snapshot.entries = slots.count
            snapshot.bytes = used
            snapshot.peakBytes = peak
            snapshot.hits = hits
            snapshot.misses = misses
            snapshot.evictions = evictions
            snapshot.refusedOversized = refusedOversized
            return snapshot
        }
    }

    @discardableResult
    public func setBudgetBytes(_ budgetBytes: Int) -> Int {
        lock.withLock {
            budget = max(budgetBytes, 0)
            return trimToBudgetLocked()
        }
    }

    /// Reset the counters without touching contents: one phase of a stress run
    /// should not inherit the previous phase's numbers.
    public func resetStats() {
        lock.withLock {
            hits = 0
            misses = 0
            evictions = 0
            refusedOversized = 0
            peak = used
        }
    }

    public func contains(_ key: UInt32) -> Bool {
        lock.withLock { slots[key] != nil }
    }

    /// Read a value and stamp it as most recently used. A `peek` is not a use.
    public func value(for key: UInt32) -> Value? {
        lock.withLock {
            guard var slot = slots[key] else {
                misses += 1
                return nil
            }
            hits += 1
            sequence += 1
            slot.seq = sequence
            slots[key] = slot
            order.append((seq: sequence, key: key))
            compactOrderLocked()
            return slot.value
        }
    }

    /// Look without disturbing recency — used to decide whether a page worth
    /// keeping is still resident, and by any diagnostic that must not warm itself.
    public func peek(_ key: UInt32) -> Value? {
        lock.withLock { slots[key]?.value }
    }

    /// Store a value, evicting least-recently-used entries as needed.
    ///
    /// Returns false when the item cannot fit even in an empty tier; the caller
    /// then keeps reading it from disk, which is always correct.
    @discardableResult
    public func insert(_ value: Value, for key: UInt32) -> Bool {
        let size = byteCount(value)
        return lock.withLock {
            if size > budget {
                refusedOversized += 1
                return false
            }
            // Drop the outgoing entry *before* making room, exactly as Rust's
            // `insert_arc` does. Leaving the slot in place with its bytes already
            // subtracted would let the eviction loop below pick this same key as
            // its victim and subtract them a second time, driving `used` negative
            // and silently letting the tier overfill later.
            if let previous = slots.removeValue(forKey: key) {
                // Its old pair stays in `order` as garbage: a missing slot is what
                // makes that pair skippable.
                used -= previous.bytes
            }
            // Room is made for the incoming entry, not after it lands, so `used`
            // never transiently exceeds the budget.
            while used + size > budget {
                guard let victim = popOldestLocked() else { break }
                evictions += 1
                _ = removeLocked(victim)
            }
            sequence += 1
            slots[key] = Slot(value: value, bytes: size, seq: sequence)
            order.append((seq: sequence, key: key))
            used += size
            peak = max(peak, used)
            compactOrderLocked()
            return true
        }
    }

    /// Drop one entry, handing back its value. Removing twice is not an error.
    @discardableResult
    public func remove(_ key: UInt32) -> Value? {
        lock.withLock { removeLocked(key)?.value }
    }

    /// Keep only `keys`, dropping the rest, and report how many went. What a fast
    /// flip needs: the old window's bytes are dead weight the moment the center
    /// moves past them.
    @discardableResult
    public func retainKeys(_ keys: Set<UInt32>) -> Int {
        lock.withLock {
            let stale = slots.keys.filter { !keys.contains($0) }
            for key in stale { _ = removeLocked(key) }
            return stale.count
        }
    }

    public func removeAll() {
        lock.withLock {
            slots.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            head = 0
            used = 0
        }
    }

    // MARK: - Locked internals (call only with `lock` held)

    private func removeLocked(_ key: UInt32) -> Slot? {
        guard let slot = slots.removeValue(forKey: key) else { return nil }
        used -= slot.bytes
        return slot
    }

    /// The oldest pair whose slot still carries that `seq`.
    private func popOldestLocked() -> UInt32? {
        while head < order.count {
            let pair = order[head]
            head += 1
            if slots[pair.key]?.seq == pair.seq { return pair.key }
        }
        return nil
    }

    /// Free the LRU tail until the tier fits its budget; returns how many went.
    private func trimToBudgetLocked() -> Int {
        var dropped = 0
        while used > budget {
            guard let victim = popOldestLocked() else { break }
            evictions += 1
            _ = removeLocked(victim)
            dropped += 1
        }
        return dropped
    }

    /// Forget the skipped prefix once it is half the log, so a long session's
    /// recency bookkeeping cannot outgrow the entries it describes.
    private func compactOrderLocked() {
        guard head > 32, head * 2 > order.count else { return }
        order.removeFirst(head)
        head = 0
    }
}

public extension ByteBudgetCache where Value == Data {
    /// A tier of encoded page bytes, which is the reader's case and the one the
    /// window plan's `memoryBudgetBytes` is denominated in: the core never decodes,
    /// so the bytes it holds are the bytes it counted.
    ///
    /// A `where Value == Data` clause cannot be attached to a member initializer,
    /// so this spelling lives in an extension.
    convenience init(budgetBytes: Int) {
        self.init(budgetBytes: budgetBytes) { $0.count }
    }
}
