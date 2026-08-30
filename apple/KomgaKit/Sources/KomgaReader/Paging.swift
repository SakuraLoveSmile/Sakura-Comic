import Foundation

// MARK: - Reader layout (mirror of `reader/paging.rs`)
//
// Contract: `specs/contracts/fixtures/reader/paging.json` — the same file is
// loaded by the Rust core (`komga_core::reader::paging`), so pairing can never
// drift between platforms.
//
// How canonical 1-based pages group into spreads, and which gesture moves between
// them. Direction NEVER changes pairing or the reading order of spreads; it only
// reverses the on-screen order inside a spread (RTL horizontal) and mirrors the
// gestures.

/// One display unit's grouping policy.
public enum ReadMode: String, Sendable, CaseIterable, Codable {
    /// One page per spread.
    case single
    /// Two pages per spread where they can be paired.
    case double
    /// Continuous vertical column; never pairs.
    case webtoon

    /// Unknown or missing stored text falls back to the default rather than
    /// failing an open: a reader that will not start is worse than one that
    /// starts in the wrong mode.
    public static func parse(_ value: String) -> ReadMode {
        ReadMode(rawValue: value) ?? .single
    }
}

public enum Direction: String, Sendable, CaseIterable, Codable {
    case ltr
    case rtl
    case vertical

    public static func parse(_ value: String) -> Direction {
        Direction(rawValue: value) ?? .ltr
    }
}

public enum Axis: String, Sendable, Equatable {
    case horizontal
    case vertical
}

/// Which way the finger travels to move forward/backward.
public enum Swipe: String, Sendable, Equatable {
    case left
    case right
    case up
    case down
}

/// Which screen half a tap advances from.
public enum Zone: String, Sendable, Equatable {
    case left
    case right
    case top
    case bottom
}

/// Which gestures move between spreads under one axis + reversed combination.
public struct Nav: Sendable, Equatable {
    public var advance: Swipe
    public var retreat: Swipe
    public var tapNext: Zone
    public var tapPrev: Zone

    public init(advance: Swipe, retreat: Swipe, tapNext: Zone, tapPrev: Zone) {
        self.advance = advance
        self.retreat = retreat
        self.tapNext = tapNext
        self.tapPrev = tapPrev
    }
}

public func nav(axis: Axis, reversed: Bool) -> Nav {
    Paging.nav(axis: axis, reversed: reversed)
}

/// The computed layout for one book under one set of reader settings.
public struct Layout: Sendable, Equatable {
    /// Spreads in READING order; pages inside a spread are reading order too.
    public var spreads: [[UInt32]]
    public var axis: Axis
    /// RTL paged reading only: the spread's pages appear on screen reversed.
    public var reversed: Bool

    public init(spreads: [[UInt32]], axis: Axis, reversed: Bool) {
        self.spreads = spreads
        self.axis = axis
        self.reversed = reversed
    }

    public var spreadCount: Int { spreads.count }
    public var isEmpty: Bool { spreads.isEmpty }

    /// Pages of one spread arranged left-to-right (horizontal) or top-to-bottom
    /// (vertical) — what the UI actually draws.
    public func visual(_ index: Int) -> [UInt32]? {
        guard spreads.indices.contains(index) else { return nil }
        return Paging.visualLeftToRight(spreads[index], axis: axis, reversed: reversed)
    }

    /// Every spread's on-screen order, in spread order.
    public func allVisual() -> [[UInt32]] {
        (0..<spreadCount).map { visual($0) ?? [] }
    }

    /// Spread holding a canonical page; reading position restore goes through
    /// here because the durable state is a page, never a spread index.
    public func spreadIndex(forPage page: UInt32) -> Int? {
        spreads.firstIndex { $0.contains(page) }
    }

    /// The page the reader should land on when restoring to spread `index`.
    public func entryPage(_ index: Int) -> UInt32? {
        guard spreads.indices.contains(index) else { return nil }
        return spreads[index].first
    }

    public func nav() -> Nav { Paging.nav(axis: axis, reversed: reversed) }
}

public enum Paging {
    /// Group pages into spreads in reading order. Direction never changes pairing.
    ///
    /// `unpairable` lists pages that must stand alone (unknown dimensions — see
    /// the `dimensions` rule in `reader/manifest.json`). Pairing resumes with the
    /// next page rather than skipping content.
    public static func pair(
        pageCount: UInt32,
        mode: ReadMode,
        firstPageSingle: Bool,
        unpairable: Set<UInt32>
    ) -> [[UInt32]] {
        var spreads: [[UInt32]] = []
        if pageCount == 0 { return spreads }
        let double = mode == .double
        var page: UInt32 = 1
        if double && firstPageSingle && !unpairable.contains(1) {
            spreads.append([1])
            page = 2
        }
        while page <= pageCount {
            if !double || unpairable.contains(page) {
                spreads.append([page])
                page += 1
                continue
            }
            // `page + 1` cannot overflow: a page beyond pageCount is rejected by
            // the comparison, and pageCount is bounded by what the server sent.
            let next = page + 1
            if next <= pageCount && !unpairable.contains(next) {
                spreads.append([page, next])
                page = next + 1
            } else {
                spreads.append([page])
                page += 1
            }
        }
        return spreads
    }

    public static func axis(for mode: ReadMode, direction: Direction) -> Axis {
        (mode == .webtoon || direction == .vertical) ? .vertical : .horizontal
    }

    /// Which gestures move between spreads under one axis + reversed combination.
    public static func nav(axis: Axis, reversed: Bool) -> Nav {
        switch axis {
        case .vertical:
            return Nav(advance: .up, retreat: .down, tapNext: .bottom, tapPrev: .top)
        case .horizontal where reversed:
            return Nav(advance: .right, retreat: .left, tapNext: .left, tapPrev: .right)
        case .horizontal:
            return Nav(advance: .left, retreat: .right, tapNext: .right, tapPrev: .left)
        }
    }

    public static func layout(
        pageCount: UInt32,
        mode: ReadMode,
        direction: Direction,
        firstPageSingle: Bool,
        unpairable: Set<UInt32>
    ) -> Layout {
        let axis = axis(for: mode, direction: direction)
        return Layout(
            spreads: pair(
                pageCount: pageCount, mode: mode,
                firstPageSingle: firstPageSingle, unpairable: unpairable
            ),
            axis: axis,
            // Webtoon has nothing to mirror without pairing, so RTL never reverses it.
            reversed: direction == .rtl && axis == .horizontal
        )
    }

    /// Reading order -> on-screen order.
    public static func visualLeftToRight(
        _ spread: [UInt32],
        axis: Axis,
        reversed: Bool
    ) -> [UInt32] {
        reversed && axis == .horizontal ? Array(spread.reversed()) : spread
    }
}
