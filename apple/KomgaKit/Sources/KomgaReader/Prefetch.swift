import Foundation

// MARK: - Adjacent-page prefetch (mirror of `reader/prefetch.rs`)
//
// Contract: `specs/contracts/fixtures/reader/prefetch.json`, shared with the Rust
// core. The window is expressed in SPREADS because that is the unit the reader can
// actually be sitting on: prefetching "one page ahead" in double-page mode leaves
// half the next screen cold.

/// How far to look ahead/behind and how many requests to keep queued.
///
/// Tunables live here as data, seeded from the contract's `defaults`, so the
/// performance phase can retune them without touching call sites.
public struct PrefetchWindow: Sendable, Equatable {
    public var forward: Int
    public var back: Int
    public var cap: Int

    public init(forward: Int, back: Int, cap: Int) {
        self.forward = forward
        self.back = back
        self.cap = cap
    }

    /// `forward: 2, back: 1, cap: 12` — equal to the fixture's `defaults`, which
    /// the contract test asserts against.
    public static let standard = PrefetchWindow(forward: 2, back: 1, cap: 12)
}

public struct PrefetchPlan: Sendable, Equatable {
    /// Pages to fetch, most useful first.
    public var queue: [UInt32]
    /// Cached pages that occupied a window slot, ascending and de-duplicated.
    public var dropped: [UInt32]

    public init(queue: [UInt32] = [], dropped: [UInt32] = []) {
        self.queue = queue
        self.dropped = dropped
    }
}

/// What a moved center does to the previous plan.
public struct Superseded: Sendable, Equatable {
    public var cancelled: [UInt32]
    /// Already downloading: left alone rather than torn down mid-byte, because a
    /// partial file is worse than a wasted one.
    public var keptInFlight: [UInt32]

    public init(cancelled: [UInt32] = [], keptInFlight: [UInt32] = []) {
        self.cancelled = cancelled
        self.keptInFlight = keptInFlight
    }
}

public enum Prefetch {
    /// Spread indices inside the window, in the documented order: center, then
    /// forward, then backward.
    static func windowed(
        spreadCount: Int,
        center: Int,
        forward: Int,
        back: Int
    ) -> [Int] {
        var indices = [center]
        if forward > 0 {
            for step in 1...forward {
                let next = center + step
                if next < spreadCount { indices.append(next) }
            }
        }
        if back > 0 {
            for step in 1...back {
                let previous = center - step
                if previous >= 0 { indices.append(previous) }
            }
        }
        return indices
    }

    /// Build the fetch plan for one spread. A cached page still occupies its slot,
    /// so a warm neighbor does not drag a distant page into the window.
    public static func plan(
        spreads: [[UInt32]],
        center: Int,
        window: PrefetchWindow,
        cached: Set<UInt32>
    ) -> PrefetchPlan {
        guard !spreads.isEmpty else { return PrefetchPlan() }
        // Clamping the center first is what keeps an out-of-range center from
        // producing an empty queue for a non-empty book.
        let clamped = min(center, spreads.count - 1)
        var queue: [UInt32] = []
        var dropped: [UInt32] = []
        for index in windowed(
            spreadCount: spreads.count, center: clamped,
            forward: window.forward, back: window.back
        ) where spreads.indices.contains(index) {
            for page in spreads[index] {
                if cached.contains(page) { dropped.append(page) } else { queue.append(page) }
            }
        }
        // Truncate from the tail: the least useful entries are the ones behind us.
        if queue.count > window.cap { queue = Array(queue.prefix(window.cap)) }
        dropped.sort()
        var seen: Set<UInt32> = []
        dropped = dropped.filter { seen.insert($0).inserted }
        return PrefetchPlan(queue: queue, dropped: dropped)
    }

    /// Which statements a moved center cancels, and which it lets finish.
    public static func supersede(
        previous: [UInt32],
        next: [UInt32],
        inFlight: Set<UInt32>
    ) -> Superseded {
        let keep = Set(next)
        var result = Superseded()
        for page in previous {
            if keep.contains(page) { continue }
            if inFlight.contains(page) { result.keptInFlight.append(page) } else { result.cancelled.append(page) }
        }
        return result
    }
}
