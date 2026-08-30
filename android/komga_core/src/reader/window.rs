//! Dynamic prefetch window: how far to look ahead, how far behind, and how many
//! requests to keep in flight — computed per reading session instead of frozen
//! as a constant.
//!
//! Stage 7 shipped `2/1/12` as a placeholder and said so. Stage 8 replaces it
//! with a decision made from the inputs the objective names: device memory, page
//! size, network, reading direction and device class. The rules are data in
//! `specs/contracts/fixtures/reader/window.json`, shared with the Swift mirror
//! (`KomgaReader.WindowPlanner`), so the two platforms cannot drift apart.
//!
//! The shape of the answer matters more than its exact numbers:
//!
//! * A 24 MB page on a phone must prefetch two pages, not twelve. A window that
//!   cannot fit the memory tier is how a reader OOMs.
//! * A long webtoon scroll runs forward and rarely back, so it trades `back` for
//!   `forward`.
//! * While the center is still moving (a fast flip), the only useful request is
//!   the page being landed on. Issuing a full window on every frame is exactly
//!   the "大量重复请求" failure the acceptance list forbids.
//! * Offline means zero, not a queue of requests that will each fail.

use super::paging::{Direction, ReadMode};
use super::prefetch::Window;
use serde::{Deserialize, Serialize};

/// Fraction of device RAM the reader may use for its memory tier.
pub const MEMORY_FRACTION: i64 = 8;
/// Never size the tier below this: a page cannot be split across evictions.
pub const MEMORY_FLOOR_BYTES: i64 = 16 * 1024 * 1024;
/// Never size it above this either; past a few 4K bitmaps the tier is only
/// waiting to be trimmed by the OS.
pub const MEMORY_CEILING_BYTES: i64 = 256 * 1024 * 1024;
/// What to use when the device did not report its memory at all.
pub const MEMORY_DEFAULT_BYTES: i64 = 32 * 1024 * 1024;
/// What to assume one page costs when the manifest reported no sizes.
pub const DEFAULT_PAGE_BYTES: i64 = 2 * 1024 * 1024;
/// Share of the memory tier that may be spent on pages not yet on screen.
pub const PREFETCH_SHARE: usize = 4;
pub const MAX_FORWARD: usize = 8;
pub const MAX_BACK: usize = 4;
/// Requests a reader should keep in flight at once on a good connection.
pub const MAX_IN_FLIGHT: usize = 4;
/// Floor for the UI's decoded-image cache: the visible spread plus one each side.
pub const MIN_DECODE_SLOTS: usize = 4;
/// Ceiling, because a slot costs a full bitmap and scrolling evicts anyway.
pub const MAX_DECODE_SLOTS: usize = 32;

/// How the reader believes the connection behaves. The UI is the only party that
/// can know this; the core never probes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Network {
    /// Any high-bandwidth, low-latency link (Wi-Fi, ethernet, fast 5G).
    #[default]
    Wifi,
    /// Metered or higher-latency, and the user may be paying per byte.
    Cellular,
    /// Measured slow or lossy: few requests, one at a time.
    Weak,
    /// Known unreachable. Nothing may be queued.
    Offline,
    /// Not reported. Treated as constrained, never as free.
    Unknown,
}

/// Everything the planner may consider. `0` means "unknown" for the byte fields.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Profile {
    /// Total physical RAM reported by the device.
    #[serde(default)]
    pub device_memory_bytes: i64,
    /// The disk cache pool's ceiling, which also bounds one window.
    #[serde(default)]
    pub cache_budget_bytes: i64,
    /// Average encoded page size from the manifest.
    #[serde(default)]
    pub avg_page_bytes: i64,
    /// Pages per spread for the current layout: 1 for single/webtoon, 2 double.
    #[serde(default = "default_pages_per_spread")]
    pub pages_per_spread: usize,
    #[serde(default = "default_mode")]
    pub mode: ReadMode,
    /// Carried in, and proven not to change the answer: the window is measured in
    /// reading-order spreads, so LTR and RTL plan identically.
    #[serde(default = "default_direction")]
    pub direction: Direction,
    #[serde(default)]
    pub network: Network,
    /// False while the center is still moving (a flip landed within the settle
    /// window). Defaults to true: a settled reader is the normal case.
    #[serde(default = "default_stable")]
    pub stable: bool,
}

fn default_pages_per_spread() -> usize {
    2
}

fn default_mode() -> ReadMode {
    ReadMode::Single
}

fn default_direction() -> Direction {
    Direction::Ltr
}

fn default_stable() -> bool {
    true
}

/// The computed window. `forward`/`back`/`cap` feed [`super::prefetch::plan`]
/// unchanged; `memory_budget_bytes` and `in_flight` are new because the memory
/// tier and the request concurrency have to move with the window.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowPlan {
    pub forward: usize,
    pub back: usize,
    pub cap: usize,
    pub memory_budget_bytes: i64,
    pub in_flight: usize,
}

impl WindowPlan {
    pub fn window(&self) -> Window {
        Window {
            forward: self.forward,
            back: self.back,
            cap: self.cap,
        }
    }
}

/// The tunables, as data the contract fixture can pin.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Constants {
    pub memory_fraction: i64,
    pub memory_floor_bytes: i64,
    pub memory_ceiling_bytes: i64,
    pub memory_default_bytes: i64,
    pub default_page_bytes: i64,
    pub prefetch_share: usize,
    pub max_forward: usize,
    pub max_back: usize,
    pub max_in_flight: usize,
    pub min_decode_slots: usize,
    pub max_decode_slots: usize,
}

pub const fn constants() -> Constants {
    Constants {
        memory_fraction: MEMORY_FRACTION,
        memory_floor_bytes: MEMORY_FLOOR_BYTES,
        memory_ceiling_bytes: MEMORY_CEILING_BYTES,
        memory_default_bytes: MEMORY_DEFAULT_BYTES,
        default_page_bytes: DEFAULT_PAGE_BYTES,
        prefetch_share: PREFETCH_SHARE,
        max_forward: MAX_FORWARD,
        max_back: MAX_BACK,
        max_in_flight: MAX_IN_FLIGHT,
        min_decode_slots: MIN_DECODE_SLOTS,
        max_decode_slots: MAX_DECODE_SLOTS,
    }
}

/// How large the memory tier may be, from what the device reported.
pub fn memory_budget(device_memory_bytes: i64) -> i64 {
    if device_memory_bytes <= 0 {
        return MEMORY_DEFAULT_BYTES;
    }
    (device_memory_bytes / MEMORY_FRACTION).clamp(MEMORY_FLOOR_BYTES, MEMORY_CEILING_BYTES)
}

fn page_cost(avg_page_bytes: i64) -> i64 {
    if avg_page_bytes > 0 {
        avg_page_bytes
    } else {
        DEFAULT_PAGE_BYTES
    }
}

/// The plan for one session. Order matters and is the contract: size the tier,
/// derive what fits, shape it by mode, bound it in bytes, then let the network
/// and the reader's motion have the final say.
pub fn plan(profile: &Profile) -> WindowPlan {
    let budget = memory_budget(profile.device_memory_bytes);
    let cost = page_cost(profile.avg_page_bytes);
    let pages_per_spread = profile.pages_per_spread.max(1);

    let fit = (budget / cost).max(1) as usize;
    let look_ahead = (fit / PREFETCH_SHARE).max(1);
    let mut forward = (look_ahead / pages_per_spread).clamp(1, MAX_FORWARD);
    let mut back = (forward / 2).clamp(1, MAX_BACK);
    if profile.mode == ReadMode::Webtoon {
        // A strip scrolls forward; a reader almost never flings back a page.
        forward = (forward * 2).clamp(1, MAX_FORWARD);
        back = back.min(1);
    }
    let mut cap = (1 + forward + back) * pages_per_spread;

    // A window may never be larger than the tier it is supposed to fit into, nor
    // more than half the disk pool: prefetch must not evict the pages on screen.
    let mut ceiling = ((budget * 2 / cost) as usize).max(pages_per_spread);
    if profile.cache_budget_bytes > 0 {
        let disk_ceiling = ((profile.cache_budget_bytes / 2 / cost) as usize).max(pages_per_spread);
        ceiling = ceiling.min(disk_ceiling);
    }
    cap = cap.min(ceiling);
    let mut in_flight = cap.min(MAX_IN_FLIGHT);

    match profile.network {
        Network::Wifi => {}
        Network::Offline => {
            forward = 0;
            back = 0;
            cap = 0;
            in_flight = 0;
        }
        Network::Weak => {
            forward = forward.min(2);
            back = back.min(1);
            cap = cap.min(3);
            in_flight = 1;
        }
        Network::Cellular => {
            cap = (cap / 2).max(pages_per_spread.min(2));
            in_flight = in_flight.min(2);
        }
        Network::Unknown => {
            forward = forward.min(2);
            back = back.min(1);
            cap = cap.min((1 + forward + back) * pages_per_spread);
            in_flight = in_flight.min(2);
        }
    }

    if !profile.stable {
        // Mid-flip: only the spread being landed on is worth asking for.
        forward = forward.min(1);
        back = 0;
        cap = cap.min(pages_per_spread);
        in_flight = in_flight.min(pages_per_spread);
    }

    WindowPlan {
        forward,
        back,
        cap,
        memory_budget_bytes: budget,
        in_flight,
    }
}

/// How many decoded pages the UI should keep, given what one decoded page costs.
///
/// The UI decodes at its own target size, so this is where the pixel cost of a
/// page reaches the planner. A tier that cannot hold four bitmaps means the UI
/// must decode smaller, not hold more.
pub fn decode_slots(memory_budget_bytes: i64, decoded_page_bytes: i64) -> usize {
    if memory_budget_bytes <= 0 || decoded_page_bytes <= 0 {
        return MIN_DECODE_SLOTS;
    }
    let slots = memory_budget_bytes / decoded_page_bytes;
    (slots as usize).clamp(MIN_DECODE_SLOTS, MAX_DECODE_SLOTS)
}

#[cfg(test)]
mod tests {
    use super::*;

    const MIB: i64 = 1024 * 1024;

    fn profile(mode: ReadMode, network: Network, device: i64, avg: i64) -> Profile {
        Profile {
            device_memory_bytes: device,
            cache_budget_bytes: 0,
            avg_page_bytes: avg,
            pages_per_spread: if mode == ReadMode::Double { 2 } else { 1 },
            mode,
            direction: Direction::Ltr,
            network,
            stable: true,
        }
    }

    #[test]
    fn memory_budget_is_a_fraction_of_ram_between_a_floor_and_a_ceiling() {
        assert_eq!(memory_budget(0), MEMORY_DEFAULT_BYTES);
        assert_eq!(memory_budget(-5), MEMORY_DEFAULT_BYTES);
        assert_eq!(memory_budget(64 * MIB), MEMORY_FLOOR_BYTES, "floor");
        assert_eq!(memory_budget(1024 * MIB), 128 * MIB);
        assert_eq!(
            memory_budget(16 * 1024 * MIB),
            MEMORY_CEILING_BYTES,
            "ceiling"
        );
    }

    /// The rule that keeps a long session alive: as pages get bigger the window
    /// never grows, and its byte volume stays inside the tier that has to hold it.
    #[test]
    fn bigger_pages_never_mean_a_bigger_window() {
        let budget = memory_budget(4096 * MIB);
        let mut previous_cap: Option<usize> = None;
        for cost in [256 * 1024, MIB, 4 * MIB, 12 * MIB, 24 * MIB, 64 * MIB] {
            let got = plan(&profile(ReadMode::Double, Network::Wifi, 4096 * MIB, cost));
            if let Some(previous) = previous_cap {
                assert!(
                    got.cap <= previous,
                    "{cost}-byte pages widened the window to {} after {previous}",
                    got.cap
                );
            }
            previous_cap = Some(got.cap);
            assert!(
                (got.cap as i64) * cost <= budget * 2,
                "{} pages of {cost} bytes cannot fit {} bytes of tier",
                got.cap,
                budget * 2
            );
            assert!(got.forward <= MAX_FORWARD && got.back <= MAX_BACK);
        }
    }

    #[test]
    fn a_better_network_never_means_more_requests() {
        let base = profile(ReadMode::Single, Network::Offline, 4096 * MIB, MIB);
        let wifi = plan(&Profile {
            network: Network::Wifi,
            ..base
        });
        let mut previous = 0usize;
        for network in [
            Network::Offline,
            Network::Weak,
            Network::Cellular,
            Network::Wifi,
        ] {
            let got = plan(&Profile { network, ..base });
            assert!(
                got.cap >= previous,
                "{network:?} raised the window above {previous}: {got:?}"
            );
            assert!(got.cap <= wifi.cap, "{network:?} exceeded wifi: {got:?}");
            assert!(got.in_flight <= wifi.in_flight, "{network:?}: {got:?}");
            previous = got.cap;
        }
        assert_eq!(plan(&base).cap, 0, "offline queues nothing");
        let unknown = plan(&Profile {
            network: Network::Unknown,
            ..base
        });
        assert!(unknown.cap > 0 && unknown.cap < wifi.cap, "{unknown:?}");
    }

    #[test]
    fn direction_does_not_move_the_window_but_mode_does() {
        let ltr = profile(ReadMode::Webtoon, Network::Wifi, 1024 * MIB, 8 * MIB);
        let rtl = Profile {
            direction: Direction::Rtl,
            ..ltr
        };
        assert_eq!(
            plan(&ltr),
            plan(&rtl),
            "the window is reading-order spreads"
        );

        let webtoon = plan(&ltr);
        let single = plan(&Profile {
            mode: ReadMode::Single,
            ..ltr
        });
        assert!(
            webtoon.forward > single.forward,
            "a strip must look further ahead: {webtoon:?} vs {single:?}"
        );
        assert!(
            webtoon.back < single.back,
            "and less far behind: {webtoon:?}"
        );
    }

    #[test]
    fn an_unstable_center_never_asks_for_more_than_the_visible_spread() {
        for mode in [ReadMode::Single, ReadMode::Double, ReadMode::Webtoon] {
            for network in [Network::Wifi, Network::Cellular, Network::Weak] {
                let settled = plan(&profile(mode, network, 8192 * MIB, 512 * 1024));
                let flipping = plan(&Profile {
                    stable: false,
                    ..profile(mode, network, 8192 * MIB, 512 * 1024)
                });
                assert!(
                    flipping.cap <= settled.cap,
                    "{mode:?}/{network:?}: unstable {flipping:?} exceeded settled {settled:?}"
                );
                assert_eq!(flipping.back, 0, "{mode:?}");
                assert!(flipping.forward <= 1, "{mode:?}: {flipping:?}");
                assert!(flipping.cap <= settled.pages_per_spread_floor(mode));
            }
        }
    }

    impl WindowPlan {
        /// A settled plan's window is at least one spread wide, so an unstable
        /// plan capped below that would mean the visible page itself was dropped.
        fn pages_per_spread_floor(&self, mode: ReadMode) -> usize {
            if mode == ReadMode::Double {
                2
            } else {
                1
            }
        }
    }

    #[test]
    fn edge_profiles_never_panic_and_always_keep_the_visible_spread() {
        let edge = Profile {
            device_memory_bytes: 0,
            cache_budget_bytes: 0,
            avg_page_bytes: 0,
            pages_per_spread: 0,
            mode: ReadMode::Double,
            direction: Direction::Ltr,
            network: Network::Wifi,
            stable: false,
        };
        let got = plan(&edge);
        assert!(got.cap >= 1, "pages_per_spread 0: {got:?}");
        assert_eq!(got.forward, 1);

        let tiny = Profile {
            device_memory_bytes: 1,
            avg_page_bytes: i64::MAX / 2,
            network: Network::Weak,
            ..edge
        };
        let got = plan(&tiny);
        assert!(got.cap >= 1 && got.forward >= 1, "{got:?}");

        let offline_mid_flip = Profile {
            network: Network::Offline,
            ..edge
        };
        assert_eq!(
            plan(&offline_mid_flip),
            WindowPlan {
                forward: 0,
                back: 0,
                cap: 0,
                memory_budget_bytes: MEMORY_DEFAULT_BYTES,
                in_flight: 0
            }
        );
    }

    #[test]
    fn decode_slots_are_bounded_by_the_tier_and_clamped_at_both_ends() {
        assert_eq!(decode_slots(256 * MIB, 10 * MIB), 25);
        assert_eq!(decode_slots(16 * MIB, 4 * MIB), 4, "MIN_DECODE_SLOTS floor");
        assert_eq!(
            decode_slots(16 * MIB, 32 * MIB),
            4,
            "a slot bigger than the tier still gets the floor"
        );
        assert_eq!(decode_slots(256 * MIB, 512 * 1024), MAX_DECODE_SLOTS);
        assert_eq!(decode_slots(0, 10 * MIB), MIN_DECODE_SLOTS);
        assert_eq!(decode_slots(256 * MIB, 0), MIN_DECODE_SLOTS);
    }

    #[test]
    fn the_plan_feeds_the_prefetch_planner_unchanged() {
        let got = plan(&profile(
            ReadMode::Double,
            Network::Wifi,
            8192 * MIB,
            2 * MIB,
        ));
        let window = got.window();
        assert_eq!(window.forward, got.forward);
        assert_eq!(window.back, got.back);
        assert_eq!(window.cap, got.cap);
    }
}

#[cfg(test)]
mod contract_tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Deserialize)]
    struct Fixture {
        constants: Constants,
        cases: Vec<Case>,
        #[serde(rename = "slotCases")]
        slot_cases: Vec<SlotCase>,
    }

    #[derive(Debug, Deserialize)]
    struct Case {
        name: String,
        input: Profile,
        expect: WindowPlan,
    }

    #[derive(Debug, Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct SlotCase {
        name: String,
        memory_budget_bytes: i64,
        decoded_page_bytes: i64,
        slots: usize,
    }

    fn fixture() -> Fixture {
        let path = format!(
            "{}/../../specs/contracts/fixtures/reader/window.json",
            env!("CARGO_MANIFEST_DIR")
        );
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("cannot read {path}: {error}"));
        serde_json::from_str(&text).unwrap_or_else(|error| panic!("cannot decode {path}: {error}"))
    }

    #[test]
    fn window_matches_the_shared_contract() {
        let fixture = fixture();
        assert_eq!(
            fixture.constants,
            constants(),
            "code constants must equal the contract constants"
        );
        assert!(
            fixture.cases.len() >= 14,
            "thin contract: {}",
            fixture.cases.len()
        );
        for case in &fixture.cases {
            let got = plan(&case.input);
            assert_eq!(got, case.expect, "{}", case.name);
        }
        for case in &fixture.slot_cases {
            assert_eq!(
                decode_slots(case.memory_budget_bytes, case.decoded_page_bytes),
                case.slots,
                "{}",
                case.name
            );
        }
    }

    /// Anti-vacuity, same discipline as every other reader contract: identical
    /// inputs with identical expectations would let a rule that ignores one of
    /// the five named inputs pass unnoticed.
    #[test]
    fn window_cases_isolate_one_input_at_a_time() {
        let fixture = fixture();
        let mut seen = std::collections::BTreeSet::new();
        for case in &fixture.cases {
            assert!(
                seen.insert(format!("{:?}", case.input)),
                "duplicate window input: {}",
                case.name
            );
        }
        let varies = |key: fn(&Profile) -> String, label: &str| {
            let values: std::collections::BTreeSet<String> =
                fixture.cases.iter().map(|case| key(&case.input)).collect();
            assert!(
                values.len() > 1,
                "no case varies {label}, so nothing proves the planner reads it"
            );
        };
        varies(
            |input| input.device_memory_bytes.to_string(),
            "deviceMemoryBytes",
        );
        varies(|input| input.avg_page_bytes.to_string(), "avgPageBytes");
        varies(|input| format!("{:?}", input.mode), "mode");
        varies(|input| format!("{:?}", input.direction), "direction");
        varies(|input| format!("{:?}", input.network), "network");
        varies(
            |input| input.cache_budget_bytes.to_string(),
            "cacheBudgetBytes",
        );
        varies(|input| input.stable.to_string(), "stable");
        varies(|input| input.pages_per_spread.to_string(), "pagesPerSpread");
    }

    /// A fixture that only ever agreed with the code would also agree with a
    /// planner that returned constants. At least one pair of cases must share
    /// every input except one and disagree on the answer.
    #[test]
    fn some_cases_differ_by_exactly_one_input_and_produce_different_plans() {
        let fixture = fixture();
        let mut proven = std::collections::BTreeSet::new();
        for a in &fixture.cases {
            for b in &fixture.cases {
                if a.name == b.name || a.expect == b.expect {
                    continue;
                }
                let mut differs: Vec<&str> = Vec::new();
                if a.input.device_memory_bytes != b.input.device_memory_bytes {
                    differs.push("deviceMemoryBytes");
                }
                if a.input.avg_page_bytes != b.input.avg_page_bytes {
                    differs.push("avgPageBytes");
                }
                if a.input.mode != b.input.mode {
                    differs.push("mode");
                }
                if a.input.network != b.input.network {
                    differs.push("network");
                }
                if a.input.cache_budget_bytes != b.input.cache_budget_bytes {
                    differs.push("cacheBudgetBytes");
                }
                if a.input.stable != b.input.stable {
                    differs.push("stable");
                }
                if a.input.pages_per_spread != b.input.pages_per_spread {
                    differs.push("pagesPerSpread");
                }
                if a.input.direction != b.input.direction {
                    differs.push("direction");
                }
                if differs.len() == 1 {
                    proven.insert(differs[0]);
                }
            }
        }
        for input in [
            "avgPageBytes",
            "mode",
            "network",
            "cacheBudgetBytes",
            "stable",
        ] {
            assert!(
                proven.contains(input),
                "no single-{input} pair changes the plan, so {input} may be ignored"
            );
        }
        assert!(
            !proven.contains("direction"),
            "direction must never change the plan; a pair that differs only by it \
             must produce equal expectations"
        );
    }
}
