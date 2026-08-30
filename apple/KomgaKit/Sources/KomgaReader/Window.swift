import Foundation

// MARK: - Dynamic prefetch window (mirror of `reader/window.rs`)
//
// Contract: `specs/contracts/fixtures/reader/window.json`, the same file the Rust
// core replays (`komga_core::reader::window`), so the two platforms cannot
// disagree about how far a reader may look ahead on the same device.
//
// Why this is computed per session instead of being a constant: Stage 7 shipped
// `2/1/12` and said so. That number is right for neither a phone reading 24 MB
// pages nor a tablet reading 256 KB ones — it is merely the number nobody had to
// defend. A window that does not fit the memory tier is how a reader OOMs, and a
// window that is wider than the reader can turn is a burst of requests for bytes
// nobody will look at, which is the "大量重复请求" failure the acceptance list
// forbids. So the answer here is a decision made from what the device reports:
// its RAM, this book's page sizes, the link, the layout, and whether the center
// is still moving.
//
// The arithmetic ORDER is the contract, not just the numbers, because later steps
// read earlier results: size the tier → divide by page cost → shape by mode →
// bound in bytes → let the network decide → let motion have the last word. A step
// moved is a different plan even with the same constants, which is why the cases
// below are replayed from the fixture rather than restated.
//
// Two rules are easy to get wrong and are pinned deliberately:
//
// * `direction` is carried in and must NOT change the answer. The window is
//   measured in reading-order spreads, so LTR and RTL plan identically; the
//   direction was already spent in `reader/paging.json` deciding which page of a
//   spread is entered first. A planner that keyed on it would prefetch what the
//   reader will never reach.
// * Every input has an unknown value (0, or `unknown` for the link) and every
//   unknown resolves to the SMALLER answer. A reader on a device it cannot
//   describe should prefetch two pages, not twelve.
//
// The plan is advisory: it sizes what the reader asks for in the background. The
// visible page always goes through the same pipeline with its own request, and a
// plan that cannot be satisfied is never an error.

/// How the reader believes the connection behaves. The UI is the only party that
/// can know this; the core never probes, and an unreported link is treated as
/// constrained rather than free.
public enum NetworkMode: String, Sendable, CaseIterable, Codable {
    /// Any high-bandwidth, low-latency link (Wi-Fi, ethernet, fast 5G).
    case wifi
    /// Metered or higher-latency, and the user may be paying per byte.
    case cellular
    /// Measured slow or lossy: few requests, one at a time.
    case weak
    /// Known unreachable. Nothing may be queued.
    case offline
    /// Not reported.
    case unknown

    /// Anything unrecognised is `unknown`, never `wifi`: guessing the generous
    /// answer for a string the app did not mean to send is how a metered reader
    /// starts 26 requests.
    public static func parse(_ value: String) -> NetworkMode {
        NetworkMode(rawValue: value) ?? .unknown
    }
}

/// The tunables, as data the contract can pin. Every name and value here must
/// equal the fixture's `constants` object — the contract test asserts it field by
/// field, so retuning means changing this table and the fixture together.
public enum WindowConstants {
    /// Fraction of device RAM the reader may use for its memory tier.
    public static let memoryFraction: Int64 = 8
    /// Never size the tier below this: a page cannot be split across evictions.
    public static let memoryFloorBytes: Int64 = 16 * 1024 * 1024
    /// Never size it above this either; past a few 4K bitmaps the tier is only
    /// waiting to be trimmed by the OS.
    public static let memoryCeilingBytes: Int64 = 256 * 1024 * 1024
    /// What to use when the device did not report its memory at all.
    public static let memoryDefaultBytes: Int64 = 32 * 1024 * 1024
    /// What to assume one page costs when the manifest reported no sizes.
    public static let defaultPageBytes: Int64 = 2 * 1024 * 1024
    /// Share of the memory tier that may be spent on pages not yet on screen.
    public static let prefetchShare: Int = 4
    public static let maxForward: Int = 8
    public static let maxBack: Int = 4
    /// Requests a reader should keep in flight at once on a good connection.
    public static let maxInFlight: Int = 4
    /// Floor for the UI's decoded-image cache: the visible spread plus one each side.
    public static let minDecodeSlots: Int = 4
    /// Ceiling, because a slot costs a full bitmap and scrolling evicts anyway.
    public static let maxDecodeSlots: Int = 32
}

/// Everything the planner may consider. `0` means "unknown" for the byte fields.
///
/// The defaults mirror the Rust struct's `#[serde(default)]` per field, including
/// the two that are not zero: an absent `pagesPerSpread` is 2 and an absent
/// `network` is the enum default, Wi-Fi. Those only matter for a fixture or a
/// payload that omits a key; an app that knows nothing passes `unknown`
/// explicitly, exactly as Rust's `parse_network("")` does.
public struct WindowProfile: Sendable, Equatable {
    /// Total physical RAM reported by the device.
    public var deviceMemoryBytes: Int64
    /// The disk cache pool's ceiling, which also bounds one window.
    public var cacheBudgetBytes: Int64
    /// Average encoded page size from the manifest.
    public var avgPageBytes: Int64
    /// Pages per spread for the current layout: 1 for single/webtoon, 2 double.
    public var pagesPerSpread: Int
    public var mode: ReadMode
    /// Carried in, and proven not to change the answer.
    public var direction: Direction
    public var network: NetworkMode
    /// False while the center is still moving (a flip landed within the settle
    /// window). A settled reader is the normal case, so this defaults to true.
    public var stable: Bool

    public init(
        deviceMemoryBytes: Int64 = 0,
        cacheBudgetBytes: Int64 = 0,
        avgPageBytes: Int64 = 0,
        pagesPerSpread: Int = 2,
        mode: ReadMode = .single,
        direction: Direction = .ltr,
        network: NetworkMode = .wifi,
        stable: Bool = true
    ) {
        self.deviceMemoryBytes = deviceMemoryBytes
        self.cacheBudgetBytes = cacheBudgetBytes
        self.avgPageBytes = avgPageBytes
        self.pagesPerSpread = pagesPerSpread
        self.mode = mode
        self.direction = direction
        self.network = network
        self.stable = stable
    }
}

/// The computed window. `forward`/`back`/`cap` feed `Prefetch.plan` unchanged;
/// `memoryBudgetBytes` and `inFlight` are new because the memory tier and the
/// request concurrency have to move with the window.
public struct WindowPlan: Sendable, Equatable {
    public var forward: Int
    public var back: Int
    public var cap: Int
    public var memoryBudgetBytes: Int64
    public var inFlight: Int

    public init(
        forward: Int = 0,
        back: Int = 0,
        cap: Int = 0,
        memoryBudgetBytes: Int64 = 0,
        inFlight: Int = 0
    ) {
        self.forward = forward
        self.back = back
        self.cap = cap
        self.memoryBudgetBytes = memoryBudgetBytes
        self.inFlight = inFlight
    }

    /// The same triple Rust's `WindowPlan::window()` hands to `prefetch::plan`.
    /// Kept as a computed value rather than stored so a plan can never carry a
    /// window that disagrees with its own numbers.
    public var prefetchWindow: PrefetchWindow {
        PrefetchWindow(forward: forward, back: back, cap: cap)
    }

    /// Zero is a real answer, not an empty one: an offline reader has a window of
    /// nothing, and callers must not read `nil` into it.
    public var queuesNothing: Bool { cap == 0 || inFlight == 0 }
}

public enum WindowPlanner {
    /// Clamp that never reorders its bounds; `bounded` rather than a name that
    /// could collide with a future stdlib spelling.
    static func bounded(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    static func bounded(_ value: Int64, _ low: Int64, _ high: Int64) -> Int64 {
        min(max(value, low), high)
    }

    /// How large the memory tier may be, from what the device reported.
    public static func memoryBudget(deviceMemoryBytes: Int64) -> Int64 {
        if deviceMemoryBytes <= 0 { return WindowConstants.memoryDefaultBytes }
        return bounded(
            deviceMemoryBytes / WindowConstants.memoryFraction,
            WindowConstants.memoryFloorBytes,
            WindowConstants.memoryCeilingBytes
        )
    }

    /// One page's ENCODED size: the core never decodes, so this is the cost the
    /// Rust tier really carries. The UI's decoded cost reaches the plan through
    /// `decodeSlots` instead.
    static func pageCost(_ avgPageBytes: Int64) -> Int64 {
        avgPageBytes > 0 ? avgPageBytes : WindowConstants.defaultPageBytes
    }

    /// The plan for one session. Order matters and is the contract: size the tier,
    /// derive what fits, shape it by mode, bound it in bytes, then let the network
    /// and the reader's motion have the final say.
    ///
    /// Every division below is integer and truncating, matching Rust's `/` on
    /// non-negative values: a tier that fits 10.6 pages fits 10.
    public static func plan(_ profile: WindowProfile) -> WindowPlan {
        let budget = memoryBudget(deviceMemoryBytes: profile.deviceMemoryBytes)
        let cost = pageCost(profile.avgPageBytes)
        // A spread of zero pages would divide by zero downstream; 1 is the
        // smallest layout that can be drawn.
        let pagesPerSpread = max(profile.pagesPerSpread, 1)

        let fit = max(Int(budget / cost), 1)
        // Only a share of the tier may be spent on pages that are not on screen
        // yet: the visible spread and what was just turned past have first claim.
        let lookAhead = max(fit / WindowConstants.prefetchShare, 1)
        var forward = bounded(lookAhead / pagesPerSpread, 1, WindowConstants.maxForward)
        var back = bounded(forward / 2, 1, WindowConstants.maxBack)
        if profile.mode == .webtoon {
            // A strip scrolls forward; a reader almost never flings back a page.
            forward = bounded(forward * 2, 1, WindowConstants.maxForward)
            back = min(back, 1)
        }
        // The 1 is the spread on screen.
        var cap = (1 + forward + back) * pagesPerSpread

        // A window may never be larger than the tier it is supposed to fit into —
        // twice it, since half of it is meant to be evictable by the time it is
        // reached — nor more than half the disk pool: prefetch must not evict the
        // pages on screen out of the pool that holds them.
        var ceiling = max(Int(budget * 2 / cost), pagesPerSpread)
        if profile.cacheBudgetBytes > 0 {
            // `/ 2 / cost` in that order: the halving happens on the byte scale
            // before the page scale, and rounding once is part of the answer.
            let disk = max(Int(profile.cacheBudgetBytes / 2 / cost), pagesPerSpread)
            ceiling = min(ceiling, disk)
        }
        cap = min(cap, ceiling)
        var inFlight = min(cap, WindowConstants.maxInFlight)

        switch profile.network {
        case .wifi:
            break
        case .offline:
            // Queuing requests against a connection known to be down turns one
            // honest failure into a wall of them.
            forward = 0
            back = 0
            cap = 0
            inFlight = 0
        case .weak:
            // One at a time: parallel requests over a lossy link compete for the
            // same retransmits.
            forward = min(forward, 2)
            back = min(back, 1)
            cap = min(cap, 3)
            inFlight = 1
        case .cellular:
            // The user may be paying per byte.
            cap = max(cap / 2, min(pagesPerSpread, 2))
            inFlight = min(inFlight, 2)
        case .unknown:
            // Not reported is treated as constrained, never as free. The cap is
            // recomputed from the already-shrunk forward/back, in that order.
            forward = min(forward, 2)
            back = min(back, 1)
            cap = min(cap, (1 + forward + back) * pagesPerSpread)
            inFlight = min(inFlight, 2)
        }

        if !profile.stable {
            // Mid-flip: the only useful request is the spread being landed on.
            forward = min(forward, 1)
            back = 0
            cap = min(cap, pagesPerSpread)
            inFlight = min(inFlight, pagesPerSpread)
        }

        return WindowPlan(
            forward: forward,
            back: back,
            cap: cap,
            memoryBudgetBytes: budget,
            inFlight: inFlight
        )
    }

    /// How many decoded pages the UI should keep, given what one decoded page
    /// costs.
    ///
    /// The UI decodes at its own target size, so this is where the pixel cost of a
    /// page reaches the planner. A tier that cannot hold four bitmaps means the UI
    /// must decode smaller, not hold more.
    ///
    /// The clamp is done in the byte domain before the conversion: a caller may
    /// hand this a budget far larger than any real tier, and a trapping
    /// `Int(exactly:)` on that path would be a crash inside a cache sizing rule.
    public static func decodeSlots(
        memoryBudgetBytes: Int64,
        decodedPageBytes: Int64
    ) -> Int {
        if memoryBudgetBytes <= 0 || decodedPageBytes <= 0 {
            return WindowConstants.minDecodeSlots
        }
        let slots = memoryBudgetBytes / decodedPageBytes
        if slots <= Int64(WindowConstants.minDecodeSlots) { return WindowConstants.minDecodeSlots }
        if slots >= Int64(WindowConstants.maxDecodeSlots) { return WindowConstants.maxDecodeSlots }
        return Int(slots)
    }

    /// Physical RAM as this process can describe it; 0 would mean "unknown" to the
    /// planner, which is why the caller never has to guess.
    public static func reportedDeviceMemoryBytes() -> Int64 {
        Int64(clamping: ProcessInfo.processInfo.physicalMemory)
    }
}

/// The plan for one session. Free-function spelling matches the Rust
/// `window::plan`, which the shared contract names `plan_window` on export.
public func planWindow(_ profile: WindowProfile) -> WindowPlan {
    WindowPlanner.plan(profile)
}

/// How many decoded pages the UI should keep for one tier.
public func decodeSlots(memoryBudgetBytes: Int64, decodedPageBytes: Int64) -> Int {
    WindowPlanner.decodeSlots(
        memoryBudgetBytes: memoryBudgetBytes, decodedPageBytes: decodedPageBytes
    )
}

/// How large the memory tier may be, from what the device reported.
public func memoryBudget(deviceMemoryBytes: Int64) -> Int64 {
    WindowPlanner.memoryBudget(deviceMemoryBytes: deviceMemoryBytes)
}
