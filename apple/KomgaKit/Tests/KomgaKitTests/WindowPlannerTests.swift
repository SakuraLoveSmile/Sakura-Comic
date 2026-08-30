import XCTest
@testable import KomgaReader

/// Behaviour of the Stage 8 window planner that the fixture cannot express as a
/// row: the monotonicities and the never-crash properties. These are the Swift
/// mirrors of the Rust unit tests in `reader/window.rs`, and they exist because a
/// table of twenty inputs only proves a planner agrees with twenty inputs — a rule
/// like "a bigger page never buys a bigger window" has to hold for the sizes that
/// are not in the table, since that is where a reader actually lands.
final class WindowPlannerTests: XCTestCase {
    private let kib: Int64 = 1024
    private let mib: Int64 = 1024 * 1024

    private func profile(
        mode: ReadMode, network: NetworkMode = .wifi, device: Int64, avg: Int64, stable: Bool = true
    ) -> WindowProfile {
        WindowProfile(
            deviceMemoryBytes: device,
            cacheBudgetBytes: 0,
            avgPageBytes: avg,
            pagesPerSpread: mode == .double ? 2 : 1,
            mode: mode,
            direction: .ltr,
            network: network,
            stable: stable
        )
    }

    // MARK: - The tier itself

    func testMemoryBudgetIsAFractionOfRamBetweenAFloorAndACeiling() {
        XCTAssertEqual(memoryBudget(deviceMemoryBytes: 0), WindowConstants.memoryDefaultBytes)
        XCTAssertEqual(memoryBudget(deviceMemoryBytes: -5), WindowConstants.memoryDefaultBytes)
        XCTAssertEqual(memoryBudget(deviceMemoryBytes: 64 * mib), WindowConstants.memoryFloorBytes, "floor")
        XCTAssertEqual(memoryBudget(deviceMemoryBytes: 1024 * mib), 128 * mib)
        XCTAssertEqual(
            memoryBudget(deviceMemoryBytes: 16 * 1024 * mib),
            WindowConstants.memoryCeilingBytes,
            "ceiling"
        )
        // A device that reports more RAM than exists still gets the ceiling.
        XCTAssertEqual(
            memoryBudget(deviceMemoryBytes: .max), WindowConstants.memoryCeilingBytes
        )
    }

    // MARK: - Monotonicity properties

    /// The rule that keeps a long session alive: as pages get bigger the window
    /// never grows, and its byte volume stays inside the tier that has to hold it.
    func testBiggerPagesNeverMeanABiggerWindow() {
        let budget = memoryBudget(deviceMemoryBytes: 4096 * mib)
        var previousCap: Int?
        let costs: [Int64] = [256 * kib, mib, 4 * mib, 12 * mib, 24 * mib, 64 * mib]
        for cost in costs {
            let got = planWindow(profile(mode: .double, device: 4096 * mib, avg: cost))
            if let previous = previousCap {
                XCTAssertLessThanOrEqual(got.cap, previous, "\(cost)-byte pages widened the window")
            }
            previousCap = got.cap
            XCTAssertLessThanOrEqual(
                Int64(got.cap) * cost, budget * 2,
                "\(got.cap) pages of \(cost) bytes cannot fit \(budget * 2) bytes of tier"
            )
            XCTAssertLessThanOrEqual(got.forward, WindowConstants.maxForward)
            XCTAssertLessThanOrEqual(got.back, WindowConstants.maxBack)
        }
    }

    /// A better link may only ever mean more requests, never fewer, and no link
    /// may exceed what a good one gets.
    func testABetterNetworkNeverMeansMoreRequests() {
        let base = profile(mode: .single, network: .offline, device: 4096 * mib, avg: mib)
        let wifi = profile(mode: .single, network: .wifi, device: 4096 * mib, avg: mib)
        let wifiPlan = planWindow(wifi)
        var previous = 0
        for network in [NetworkMode.offline, .weak, .cellular, .wifi] {
            var draft = base
            draft.network = network
            let got = planWindow(draft)
            XCTAssertGreaterThanOrEqual(got.cap, previous, "\(network) shrank the window")
            XCTAssertLessThanOrEqual(got.cap, wifiPlan.cap, "\(network) exceeded wifi")
            XCTAssertLessThanOrEqual(got.inFlight, wifiPlan.inFlight, "\(network) exceeded wifi")
            previous = got.cap
        }
        XCTAssertEqual(planWindow(base).cap, 0, "offline queues nothing")
        var unknown = base
        unknown.network = .unknown
        let got = planWindow(unknown)
        XCTAssertGreaterThan(got.cap, 0, "an unreported link still reads")
        XCTAssertLessThan(got.cap, wifiPlan.cap, "an unreported link is not treated as free")
    }

    func testDirectionDoesNotMoveTheWindowButModeDoes() {
        let ltr = profile(mode: .webtoon, device: 1024 * mib, avg: 8 * mib)
        var rtl = ltr
        rtl.direction = .rtl
        XCTAssertEqual(planWindow(ltr), planWindow(rtl), "the window is reading-order spreads")

        let webtoon = planWindow(ltr)
        var singleDraft = ltr
        singleDraft.mode = .single
        let single = planWindow(singleDraft)
        XCTAssertGreaterThan(webtoon.forward, single.forward, "a strip must look further ahead")
        XCTAssertLessThan(webtoon.back, single.back, "and less far behind")
    }

    /// An unstable center may never ask for more than the spread being landed on.
    func testAnUnstableCenterNeverAsksForMoreThanTheVisibleSpread() {
        for mode in [ReadMode.single, .double, .webtoon] {
            for network in [NetworkMode.wifi, .cellular, .weak, .unknown, .offline] {
                let settled = profile(mode: mode, network: network, device: 8192 * mib, avg: 512 * 1024)
                var flipping = settled
                flipping.stable = false
                let got = planWindow(flipping)
                let before = planWindow(settled)
                XCTAssertLessThanOrEqual(got.cap, before.cap, "\(mode)/\(network)")
                XCTAssertEqual(got.back, 0, "\(mode)")
                XCTAssertLessThanOrEqual(got.forward, 1, "\(mode)")
                XCTAssertLessThanOrEqual(got.cap, settled.pagesPerSpread, "\(mode)")
            }
        }
    }

    // MARK: - Degenerate inputs

    /// Every input has an unknown value, and the answer must still be a window the
    /// reader can use: no traps, and never less than the visible spread.
    func testEdgeProfilesProduceAUsableWindowAndNeverTrap() {
        let edge = WindowProfile(
            deviceMemoryBytes: 0, cacheBudgetBytes: 0, avgPageBytes: 0, pagesPerSpread: 0,
            mode: .double, direction: .ltr, network: .wifi, stable: false
        )
        let got = planWindow(edge)
        XCTAssertGreaterThanOrEqual(got.cap, 1, "pagesPerSpread 0: \(got)")
        XCTAssertEqual(got.forward, 1)
        XCTAssertEqual(got.memoryBudgetBytes, WindowConstants.memoryDefaultBytes)

        let tiny = WindowProfile(
            deviceMemoryBytes: 1, cacheBudgetBytes: 0,
            avgPageBytes: Int64.max / 2, pagesPerSpread: 0,
            mode: .double, direction: .rtl, network: .weak, stable: false
        )
        let small = planWindow(tiny)
        XCTAssertGreaterThanOrEqual(small.cap, 1)
        XCTAssertGreaterThanOrEqual(small.forward, 1)

        var offlineMidFlip = edge
        offlineMidFlip.network = .offline
        XCTAssertEqual(
            planWindow(offlineMidFlip),
            WindowPlan(
                forward: 0, back: 0, cap: 0,
                memoryBudgetBytes: WindowConstants.memoryDefaultBytes, inFlight: 0
            )
        )

        // A disk pool of 1 byte cannot hold a page, and the spread floor keeps the
        // reader able to load the page it is on.
        var starved = edge
        starved.cacheBudgetBytes = 1
        starved.stable = true
        let stillReadable = planWindow(starved)
        XCTAssertGreaterThanOrEqual(stillReadable.cap, max(starved.pagesPerSpread, 1))
    }

    // MARK: - Decode slots

    func testDecodeSlotsAreBoundedByTheTierAndClampedAtBothEnds() {
        XCTAssertEqual(decodeSlots(memoryBudgetBytes: 256 * mib, decodedPageBytes: 10 * mib), 25)
        XCTAssertEqual(decodeSlots(memoryBudgetBytes: 16 * mib, decodedPageBytes: 4 * mib), 4, "floor")
        XCTAssertEqual(
            decodeSlots(memoryBudgetBytes: 16 * mib, decodedPageBytes: 32 * mib), 4,
            "a slot bigger than the tier still gets the floor"
        )
        XCTAssertEqual(
            decodeSlots(memoryBudgetBytes: 256 * mib, decodedPageBytes: 512 * 1024),
            WindowConstants.maxDecodeSlots
        )
        XCTAssertEqual(decodeSlots(memoryBudgetBytes: 0, decodedPageBytes: 10 * mib), 4)
        XCTAssertEqual(decodeSlots(memoryBudgetBytes: 256 * mib, decodedPageBytes: 0), 4)
        // Sign-trapping inputs: unknown is unknown, in either direction.
        XCTAssertEqual(decodeSlots(memoryBudgetBytes: -1, decodedPageBytes: -1), 4)
        // A budget that cannot be an Int is still clamped, not trapped.
        XCTAssertEqual(decodeSlots(memoryBudgetBytes: .max, decodedPageBytes: 1), 32)
    }

    // MARK: - Wiring shapes

    /// The plan's window triple feeds `Prefetch.plan` unchanged: this is what makes
    /// the dynamic answer actually reach the reader rather than being a number on
    /// the way out.
    func testThePlanFeedsThePrefetchPlannerUnchanged() {
        let got = planWindow(profile(mode: .double, device: 8192 * mib, avg: 2 * mib))
        let window = got.prefetchWindow
        XCTAssertEqual(window.forward, got.forward)
        XCTAssertEqual(window.back, got.back)
        XCTAssertEqual(window.cap, got.cap)
        var spreads: [[UInt32]] = []
        for index in 0..<100 {
            let first = UInt32(index * 2 + 1)
            spreads.append([first, first + 1])
        }
        let cached: Set<UInt32> = []
        let prefetch = Prefetch.plan(
            spreads: spreads, center: 40, window: window, cached: cached
        )
        XCTAssertEqual(prefetch.queue.count, got.cap, "cap is the queue's ceiling")
        XCTAssertEqual(prefetch.queue.first, UInt32(81), "the center is served first")
    }

    func testOfflineIsTheOnlyPlanThatQueuesNothing() {
        let offline = planWindow(profile(mode: .single, network: .offline, device: 4096 * mib, avg: mib))
        XCTAssertTrue(offline.queuesNothing)
        let wifi = planWindow(profile(mode: .single, network: .wifi, device: 4096 * mib, avg: mib))
        XCTAssertFalse(wifi.queuesNothing)
    }

    /// The app may only ever report a link the contract knows; anything else has to
    /// land on the conservative answer rather than the generous one.
    func testAnUnrecognisedNetworkIsUnknownNeverWifi() {
        XCTAssertEqual(NetworkMode.parse("wifi"), .wifi)
        XCTAssertEqual(NetworkMode.parse("cellular"), .cellular)
        XCTAssertEqual(NetworkMode.parse("weak"), .weak)
        XCTAssertEqual(NetworkMode.parse("offline"), .offline)
        XCTAssertEqual(NetworkMode.parse(""), .unknown)
        XCTAssertEqual(NetworkMode.parse("WIFI"), .unknown, "matching is exact, like Rust")
        XCTAssertEqual(NetworkMode.parse("ethernet"), .unknown)
    }

    /// The stored settings document is the fallback when no plan exists; the plan's
    /// own defaults must not silently disagree with Rust's serde defaults, or a
    /// payload that omits a key would plan differently per platform.
    func testProfileDefaultsMirrorTheRustSerdeDefaults() {
        let bare = WindowProfile()
        XCTAssertEqual(bare.deviceMemoryBytes, 0)
        XCTAssertEqual(bare.cacheBudgetBytes, 0)
        XCTAssertEqual(bare.avgPageBytes, 0)
        XCTAssertEqual(bare.pagesPerSpread, 2)
        XCTAssertEqual(bare.mode, .single)
        XCTAssertEqual(bare.direction, .ltr)
        XCTAssertEqual(bare.network, .wifi)
        XCTAssertTrue(bare.stable)
    }

    /// The device is real, on every platform this builds for: a zero here would mean
    /// the reader silently plans for an unknown device on hardware that reported
    /// fine.
    func testTheDeviceReportsUsableMemory() {
        XCTAssertGreaterThan(WindowPlanner.reportedDeviceMemoryBytes(), 0)
    }
}
