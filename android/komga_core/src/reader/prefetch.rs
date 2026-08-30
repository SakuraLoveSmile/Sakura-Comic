//! Adjacent-page prefetch: which pages to pull, in what order, when the reader
//! sits on a given spread.
//!
//! Contract: `specs/contracts/fixtures/reader/prefetch.json`, shared with the
//! Swift mirror (`KomgaReader.Prefetch`). The window is expressed in spreads
//! because that is the unit the reader can actually be sitting on: prefetching
//! "one page ahead" in double-page mode leaves half the next screen cold.

use serde::{Deserialize, Serialize};
use std::collections::HashSet;

/// How far to look ahead/behind and how many requests to keep queued.
///
/// Tunables live here as data, seeded from the contract's `defaults`, so the
/// performance phase can retune them without touching call sites.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Window {
    pub forward: usize,
    pub back: usize,
    pub cap: usize,
}

impl Default for Window {
    fn default() -> Self {
        Window {
            forward: 2,
            back: 1,
            cap: 12,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Plan {
    /// Pages to fetch, most useful first.
    pub queue: Vec<u32>,
    /// Cached pages that occupied a window slot, ascending.
    pub dropped: Vec<u32>,
}

/// Spread indices inside the window, in the documented order:
/// center, then forward, then backward.
fn windowed(spread_count: usize, center: usize, forward: usize, back: usize) -> Vec<usize> {
    let mut indices = vec![center];
    for step in 1..=forward {
        if let Some(next) = center.checked_add(step) {
            if next < spread_count {
                indices.push(next);
            }
        }
    }
    for step in 1..=back {
        if let Some(previous) = center.checked_sub(step) {
            indices.push(previous);
        }
    }
    indices
}

/// Build the fetch plan for one spread. A cached page still occupies its slot,
/// so a warm neighbor does not drag a distant page into the window.
pub fn plan(spreads: &[Vec<u32>], center: usize, window: Window, cached: &HashSet<u32>) -> Plan {
    if spreads.is_empty() {
        return Plan::default();
    }
    let center = center.min(spreads.len() - 1);
    let mut queue = Vec::new();
    let mut dropped = Vec::new();
    for index in windowed(spreads.len(), center, window.forward, window.back) {
        for page in &spreads[index] {
            if cached.contains(page) {
                dropped.push(*page);
            } else {
                queue.push(*page);
            }
        }
    }
    // Truncate from the tail: the least useful entries are the ones behind us.
    queue.truncate(window.cap);
    dropped.sort_unstable();
    dropped.dedup();
    Plan { queue, dropped }
}

/// What a moved center does to the previous plan.
#[derive(Clone, Debug, PartialEq, Eq, Default)]
pub struct Superseded {
    pub cancelled: Vec<u32>,
    /// Already downloading: left alone rather than torn down mid-byte, because a
    /// partial file is worse than a wasted one.
    pub kept_in_flight: Vec<u32>,
}

pub fn supersede(previous: &[u32], next: &[u32], in_flight: &HashSet<u32>) -> Superseded {
    let keep: HashSet<u32> = next.iter().copied().collect();
    let mut result = Superseded::default();
    for page in previous {
        if keep.contains(page) {
            continue;
        }
        if in_flight.contains(page) {
            result.kept_in_flight.push(*page);
        } else {
            result.cancelled.push(*page);
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    fn singles(count: usize) -> Vec<Vec<u32>> {
        (1..=count as u32).map(|page| vec![page]).collect()
    }

    fn set(pages: &[u32]) -> HashSet<u32> {
        pages.iter().copied().collect()
    }

    #[test]
    fn defaults_come_from_the_contract() {
        assert_eq!(
            Window::default(),
            Window {
                forward: 2,
                back: 1,
                cap: 12
            }
        );
    }

    /// Property: the plan never contains an out-of-range page, never contains a
    /// cached page, and always leads with the spread on screen.
    #[test]
    fn plan_invariants_hold_for_every_center() {
        let spreads = singles(12);
        for center in 0..14 {
            for (forward, back) in [(0usize, 0usize), (1, 1), (2, 1), (4, 3), (9, 9)] {
                let cached = set(&[3, 4, 5]);
                let window = Window {
                    forward,
                    back,
                    cap: 12,
                };
                let plan = plan(&spreads, center, window, &cached);
                assert!(
                    plan.queue.iter().all(|page| (1..=12).contains(page)),
                    "range: {plan:?}"
                );
                assert!(
                    plan.queue.iter().all(|page| !cached.contains(page)),
                    "cached leaked: {plan:?}"
                );
                let center_pages = &spreads[center.min(spreads.len() - 1)];
                if center_pages.iter().all(|page| cached.contains(page)) {
                    // A fully cached center really can have nothing to fetch.
                    continue;
                }
                assert!(
                    !plan.queue.is_empty(),
                    "center {center} produced an empty queue"
                );
                let first_page_of_center = spreads[center.min(spreads.len() - 1)][0];
                if !cached.contains(&first_page_of_center) {
                    assert_eq!(plan.queue[0], first_page_of_center, "{plan:?}");
                }
            }
        }
    }

    #[test]
    fn supersede_keeps_in_flight_bytes() {
        let got = supersede(&[3, 4, 5, 2], &[20, 21], &set(&[4]));
        assert_eq!(got.cancelled, vec![3, 5, 2]);
        assert_eq!(got.kept_in_flight, vec![4]);
    }
}

#[cfg(test)]
mod contract_tests {
    use super::*;
    use serde::de::DeserializeOwned;

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
    struct Fixture {
        defaults: Window,
        cases: Vec<Case>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Input {
        #[serde(default)]
        spreads: Option<Vec<Vec<u32>>>,
        #[serde(default)]
        spread_count: Option<usize>,
        center: usize,
        forward: usize,
        back: usize,
        #[serde(default)]
        cached: Vec<u32>,
        cap: usize,
        #[serde(default)]
        previous_queue: Vec<u32>,
        #[serde(default)]
        in_flight: Vec<u32>,
        #[serde(default)]
        mode: Option<String>,
        #[serde(default)]
        direction: Option<String>,
    }

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Expect {
        queue: Vec<u32>,
        #[serde(default)]
        dropped: Vec<u32>,
        #[serde(default)]
        cancelled: Vec<u32>,
        #[serde(default)]
        kept_in_flight: Vec<u32>,
    }

    #[derive(Deserialize)]
    struct Case {
        name: String,
        input: Input,
        expect: Expect,
    }

    fn spreads_of(input: &Input) -> Vec<Vec<u32>> {
        match (&input.spreads, input.spread_count) {
            (Some(spreads), _) => spreads.clone(),
            (None, Some(count)) => singles(count),
            (None, None) => Vec::new(),
        }
    }

    fn singles(count: usize) -> Vec<Vec<u32>> {
        (1..=count as u32).map(|page| vec![page]).collect()
    }

    #[test]
    fn prefetch_matches_the_shared_contract() {
        let fixture: Fixture = fixture("prefetch.json");
        assert_eq!(
            Window::default(),
            fixture.defaults,
            "code defaults must equal the contract defaults"
        );
        assert!(fixture.cases.len() >= 10);
        for case in &fixture.cases {
            let spreads = spreads_of(&case.input);
            let cached: HashSet<u32> = case.input.cached.iter().copied().collect();
            let window = Window {
                forward: case.input.forward,
                back: case.input.back,
                cap: case.input.cap,
            };
            let got = plan(&spreads, case.input.center, window, &cached);
            assert_eq!(got.queue, case.expect.queue, "{}: queue", case.name);
            assert_eq!(got.dropped, case.expect.dropped, "{}: dropped", case.name);

            if !case.input.previous_queue.is_empty() {
                let in_flight: HashSet<u32> = case.input.in_flight.iter().copied().collect();
                let moved = supersede(&case.input.previous_queue, &got.queue, &in_flight);
                assert_eq!(
                    moved.cancelled, case.expect.cancelled,
                    "{}: cancelled",
                    case.name
                );
                assert_eq!(
                    moved.kept_in_flight, case.expect.kept_in_flight,
                    "{}: keptInFlight",
                    case.name
                );
            }
        }
    }

    /// Anti-vacuity: identical inputs with identical expectations would let a
    /// wrong window pass.
    #[test]
    fn prefetch_cases_are_distinct() {
        let fixture: Fixture = fixture("prefetch.json");
        let mut seen = std::collections::BTreeSet::new();
        for case in &fixture.cases {
            let key = format!(
                "{:?}|{}|{}|{}|{:?}|{}|{:?}|{:?}",
                spreads_of(&case.input),
                case.input.center,
                case.input.forward,
                case.input.back,
                case.input.cached,
                case.input.cap,
                case.input.mode,
                case.input.direction
            );
            assert!(seen.insert(key), "duplicate prefetch case: {}", case.name);
        }
    }
}
