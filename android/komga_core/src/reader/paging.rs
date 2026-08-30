//! Reader layout: how canonical 1-based pages group into spreads, and which
//! gesture moves between them.
//!
//! Contract: `specs/contracts/fixtures/reader/paging.json` — the same file is
//! loaded by the Swift mirror (`KomgaReader.Paging`), so pairing can never
//! drift between platforms.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ReadMode {
    /// One page per spread.
    Single,
    /// Two pages per spread where they can be paired.
    Double,
    /// Continuous vertical column; never pairs.
    Webtoon,
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Direction {
    Ltr,
    Rtl,
    Vertical,
}

impl ReadMode {
    pub fn as_str(self) -> &'static str {
        match self {
            ReadMode::Single => "single",
            ReadMode::Double => "double",
            ReadMode::Webtoon => "webtoon",
        }
    }

    /// Unknown or missing stored text falls back to the default rather than
    /// failing an open: a reader that will not start is worse than one that
    /// starts in the wrong mode.
    pub fn parse(value: &str) -> ReadMode {
        match value {
            "double" => ReadMode::Double,
            "webtoon" => ReadMode::Webtoon,
            _ => ReadMode::Single,
        }
    }
}

impl Direction {
    pub fn as_str(self) -> &'static str {
        match self {
            Direction::Ltr => "ltr",
            Direction::Rtl => "rtl",
            Direction::Vertical => "vertical",
        }
    }

    pub fn parse(value: &str) -> Direction {
        match value {
            "rtl" => Direction::Rtl,
            "vertical" => Direction::Vertical,
            _ => Direction::Ltr,
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Axis {
    Horizontal,
    Vertical,
}

impl Axis {
    pub fn as_str(self) -> &'static str {
        match self {
            Axis::Horizontal => "horizontal",
            Axis::Vertical => "vertical",
        }
    }
}

/// Which way the finger travels to move forward/backward.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Swipe {
    Left,
    Right,
    Up,
    Down,
}

impl Swipe {
    pub fn as_str(self) -> &'static str {
        match self {
            Swipe::Left => "left",
            Swipe::Right => "right",
            Swipe::Up => "up",
            Swipe::Down => "down",
        }
    }
}

/// Which screen half a tap advances from.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Zone {
    Left,
    Right,
    Top,
    Bottom,
}

impl Zone {
    pub fn as_str(self) -> &'static str {
        match self {
            Zone::Left => "left",
            Zone::Right => "right",
            Zone::Top => "top",
            Zone::Bottom => "bottom",
        }
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub struct Nav {
    pub advance: Swipe,
    pub retreat: Swipe,
    pub tap_next: Zone,
    pub tap_prev: Zone,
}

/// The computed layout for one book under one set of reader settings.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Layout {
    pub spreads: Vec<Vec<u32>>,
    pub axis: Axis,
    /// RTL paged reading only: the spread's pages appear on screen reversed.
    pub reversed: bool,
}

impl Layout {
    pub fn spread_count(&self) -> usize {
        self.spreads.len()
    }

    pub fn is_empty(&self) -> bool {
        self.spreads.is_empty()
    }

    /// Pages of one spread arranged left-to-right (horizontal) or
    /// top-to-bottom (vertical) — what the UI actually draws.
    pub fn visual(&self, index: usize) -> Option<Vec<u32>> {
        let spread = self.spreads.get(index)?;
        Some(visual_left_to_right(spread, self.axis, self.reversed))
    }

    /// Spread holding a canonical page; reading position restore goes through
    /// here because the durable state is a page, never a spread index.
    pub fn index_for_page(&self, page: u32) -> Option<usize> {
        self.spreads
            .iter()
            .position(|spread| spread.contains(&page))
    }

    /// The page the reader should land on when restoring to `page`: that page
    /// if present, otherwise the first page of the spread it fell into.
    pub fn entry_page(&self, index: usize) -> Option<u32> {
        self.spreads
            .get(index)
            .and_then(|spread| spread.first().copied())
    }

    pub fn nav(&self) -> Nav {
        nav(self.axis, self.reversed)
    }
}

pub fn nav(axis: Axis, reversed: bool) -> Nav {
    let (advance, retreat, tap_next, tap_prev) = match axis {
        Axis::Vertical => (Swipe::Up, Swipe::Down, Zone::Bottom, Zone::Top),
        Axis::Horizontal if reversed => (Swipe::Right, Swipe::Left, Zone::Left, Zone::Right),
        Axis::Horizontal => (Swipe::Left, Swipe::Right, Zone::Right, Zone::Left),
    };
    Nav {
        advance,
        retreat,
        tap_next,
        tap_prev,
    }
}

/// Group pages into spreads in reading order. Direction never changes pairing.
///
/// `unpairable` lists pages that must stand alone (unknown dimensions — see the
/// `dimensions` rule in `reader/manifest.json`). Pairing resumes with the next
/// page rather than skipping content.
pub fn pair(
    page_count: u32,
    mode: ReadMode,
    first_page_single: bool,
    unpairable: &HashSet<u32>,
) -> Vec<Vec<u32>> {
    let mut spreads = Vec::new();
    if page_count == 0 {
        return spreads;
    }
    let double = mode == ReadMode::Double;
    let mut page = 1u32;
    if double && first_page_single && !unpairable.contains(&1) {
        spreads.push(vec![1]);
        page = 2;
    }
    while page <= page_count {
        let standalone = !double || unpairable.contains(&page);
        if standalone {
            spreads.push(vec![page]);
            page += 1;
            continue;
        }
        // `page + 1` cannot overflow: a page beyond `page_count` is rejected by
        // the comparison, and page_count is bounded by what the server sent.
        let next = page + 1;
        if next <= page_count && !unpairable.contains(&next) {
            spreads.push(vec![page, next]);
            page = next + 1;
        } else {
            spreads.push(vec![page]);
            page += 1;
        }
    }
    spreads
}

pub fn axis_for(mode: ReadMode, direction: Direction) -> Axis {
    if mode == ReadMode::Webtoon || direction == Direction::Vertical {
        Axis::Vertical
    } else {
        Axis::Horizontal
    }
}

pub fn layout(
    page_count: u32,
    mode: ReadMode,
    direction: Direction,
    first_page_single: bool,
    unpairable: &HashSet<u32>,
) -> Layout {
    let axis = axis_for(mode, direction);
    Layout {
        spreads: pair(page_count, mode, first_page_single, unpairable),
        axis,
        reversed: direction == Direction::Rtl && axis == Axis::Horizontal,
    }
}

/// Reading order -> on-screen order.
pub fn visual_left_to_right(spread: &[u32], axis: Axis, reversed: bool) -> Vec<u32> {
    if reversed && axis == Axis::Horizontal {
        spread.iter().rev().copied().collect()
    } else {
        spread.to_vec()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unpairable(pages: &[u32]) -> HashSet<u32> {
        pages.iter().copied().collect()
    }

    /// Property: every page of the book lands in exactly one spread, in
    /// reading order, for every mode/flag combination. The fixture pins
    /// examples; this pins the invariant the examples are drawn from.
    #[test]
    fn pairing_partitions_the_book_exactly_once() {
        for mode in [ReadMode::Single, ReadMode::Double, ReadMode::Webtoon] {
            for first_page_single in [false, true] {
                for skip in [vec![], vec![1u32], vec![2, 5], vec![7]] {
                    let skip = unpairable(&skip);
                    for page_count in 0u32..40 {
                        let spreads = pair(page_count, mode, first_page_single, &skip);
                        let flat: Vec<u32> = spreads.iter().flatten().copied().collect();
                        let expected: Vec<u32> = (1..=page_count).collect();
                        assert_eq!(
                            flat, expected,
                            "mode={mode:?} first={first_page_single} skip={skip:?} count={page_count}"
                        );
                        assert!(
                            spreads.iter().all(|s| !s.is_empty() && s.len() <= 2),
                            "spread size: {spreads:?}"
                        );
                    }
                }
            }
        }
    }

    /// Property: double mode pairs exactly as often as it can, and never pads a
    /// spread with a phantom page.
    #[test]
    fn double_mode_pairs_at_most_two_pages() {
        let spreads = pair(9, ReadMode::Double, false, &HashSet::new());
        assert_eq!(
            spreads,
            vec![vec![1, 2], vec![3, 4], vec![5, 6], vec![7, 8], vec![9]]
        );
    }

    /// Property: advancing from the first spread always walks to the last one
    /// with strictly increasing pages — in every direction. RTL mirrors the
    /// screen, never the reading order.
    #[test]
    fn advance_always_moves_forward_in_page_order() {
        for mode in [ReadMode::Single, ReadMode::Double, ReadMode::Webtoon] {
            for direction in [Direction::Ltr, Direction::Rtl, Direction::Vertical] {
                let layout = layout(13, mode, direction, true, &HashSet::new());
                let mut last = 0u32;
                for index in 0..layout.spread_count() {
                    let pages = layout.visual(index).unwrap();
                    assert!(!pages.is_empty());
                    let first = *layout.spreads[index].first().unwrap();
                    assert!(
                        first > last,
                        "{mode:?}/{direction:?} index {index}: {first} <= {last}"
                    );
                    last = first;
                }
                // The last spread must be the one holding the final page; with
                // pairing on, it legitimately starts one page earlier.
                assert!(
                    layout.spreads.last().unwrap().contains(&13),
                    "{mode:?}/{direction:?} last spread {:?}",
                    layout.spreads.last()
                );
                assert!(last <= 13);
            }
        }
    }

    #[test]
    fn only_rtl_paged_reading_is_reversed() {
        for direction in [Direction::Ltr, Direction::Rtl, Direction::Vertical] {
            for mode in [ReadMode::Single, ReadMode::Double, ReadMode::Webtoon] {
                let layout = layout(4, mode, direction, false, &HashSet::new());
                assert_eq!(
                    layout.reversed,
                    direction == Direction::Rtl && mode != ReadMode::Webtoon,
                    "{mode:?}/{direction:?}"
                );
            }
        }
    }

    #[test]
    fn restore_recomputes_the_spread_after_a_settings_change() {
        let page = 7u32;
        let single = layout(20, ReadMode::Single, Direction::Ltr, false, &HashSet::new());
        let double = layout(20, ReadMode::Double, Direction::Rtl, false, &HashSet::new());
        assert_eq!(single.index_for_page(page), Some(6));
        // pairing from page 1: [1,2] [3,4] [5,6] [7,8]
        assert_eq!(double.index_for_page(page), Some(3));
        assert_eq!(double.entry_page(3), Some(7));
        assert_eq!(double.visual(3), Some(vec![8, 7]));
        assert_eq!(single.index_for_page(99), None);
    }
}

#[cfg(test)]
mod contract_tests {
    use super::*;
    use serde::de::DeserializeOwned;
    use std::collections::HashMap;

    fn fixture<T: DeserializeOwned>(name: &str) -> T {
        let path = format!(
            "{}/../../specs/contracts/fixtures/reader/{name}",
            env!("CARGO_MANIFEST_DIR")
        );
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("cannot read {path}: {error}"));
        serde_json::from_str(&text).unwrap_or_else(|error| panic!("cannot decode {path}: {error}"))
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Fixture {
        cases: Vec<Case>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Input {
        page_count: u32,
        mode: ReadMode,
        direction: Direction,
        first_page_single: bool,
        #[serde(default)]
        unpairable: Vec<u32>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Expect {
        spreads: Option<Vec<Vec<u32>>>,
        spread_count: usize,
        scroll_axis: String,
        reversed: bool,
        visual_left_to_right: Option<Vec<Vec<u32>>>,
        advance_swipe: String,
        retreat_swipe: String,
        tap_next: String,
        tap_prev: String,
        spread_index_for_page: HashMap<String, usize>,
    }

    #[derive(Deserialize)]
    struct Case {
        name: String,
        input: Input,
        expect: Expect,
    }

    #[test]
    fn paging_matches_the_shared_contract() {
        let fixture: Fixture = fixture("paging.json");
        assert!(!fixture.cases.is_empty());
        for case in &fixture.cases {
            let skip = case
                .input
                .unpairable
                .iter()
                .copied()
                .collect::<HashSet<u32>>();
            let layout = layout(
                case.input.page_count,
                case.input.mode,
                case.input.direction,
                case.input.first_page_single,
                &skip,
            );
            let nav = layout.nav();
            let fail = |what: &str, got: String, want: &str| {
                panic!("{}: {what}\n  got  {got}\n  want {want}", case.name)
            };
            if let Some(spreads) = &case.expect.spreads {
                assert_eq!(&layout.spreads, spreads, "{}: spreads", case.name);
            }
            if let Some(visual) = &case.expect.visual_left_to_right {
                let got: Vec<Vec<u32>> = (0..layout.spread_count())
                    .map(|index| layout.visual(index).unwrap())
                    .collect();
                if &got != visual {
                    fail("visual", format!("{got:?}"), &format!("{visual:?}"));
                }
            }
            if layout.spread_count() != case.expect.spread_count {
                fail(
                    "spreadCount",
                    layout.spread_count().to_string(),
                    &case.expect.spread_count.to_string(),
                );
            }
            if layout.axis.as_str() != case.expect.scroll_axis {
                fail(
                    "scrollAxis",
                    layout.axis.as_str().into(),
                    &case.expect.scroll_axis,
                );
            }
            if layout.reversed != case.expect.reversed {
                fail("reversed", layout.reversed.to_string(), "");
            }
            if nav.advance.as_str() != case.expect.advance_swipe {
                fail(
                    "advanceSwipe",
                    nav.advance.as_str().into(),
                    &case.expect.advance_swipe,
                );
            }
            if nav.retreat.as_str() != case.expect.retreat_swipe {
                fail(
                    "retreatSwipe",
                    nav.retreat.as_str().into(),
                    &case.expect.retreat_swipe,
                );
            }
            if nav.tap_next.as_str() != case.expect.tap_next {
                fail(
                    "tapNext",
                    nav.tap_next.as_str().into(),
                    &case.expect.tap_next,
                );
            }
            if nav.tap_prev.as_str() != case.expect.tap_prev {
                fail(
                    "tapPrev",
                    nav.tap_prev.as_str().into(),
                    &case.expect.tap_prev,
                );
            }
            for (page, want) in &case.expect.spread_index_for_page {
                let page: u32 = page.parse().expect("page key must be a number");
                let got = layout.index_for_page(page);
                assert_eq!(
                    got,
                    Some(*want),
                    "{}: spreadIndexForPage[{page}]",
                    case.name
                );
            }
        }
    }

    /// Anti-vacuity: the case table must actually discriminate. Two cases with
    /// identical inputs and expectations would let a wrong implementation pass.
    #[test]
    fn cases_are_not_duplicates_of_each_other() {
        let fixture: Fixture = fixture("paging.json");
        let mut seen = std::collections::BTreeSet::new();
        for case in &fixture.cases {
            let key = format!(
                "{:?}|{:?}|{:?}|{}|{:?} => {:?}|{:?}|{:?}|{}",
                case.input.mode,
                case.input.direction,
                case.input.page_count,
                case.input.first_page_single,
                case.input.unpairable,
                case.expect.spreads,
                case.expect.spread_count,
                case.expect.visual_left_to_right,
                case.expect.reversed,
            );
            assert!(seen.insert(key.clone()), "duplicate case: {}", case.name);
        }
        assert!(seen.len() >= 12, "expected a discriminating table");
    }
}
