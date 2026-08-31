//! An in-process ring buffer over the `log` crate.
//!
//! For two stages the core called `log::info!` and friends in a dozen places
//! while nobody ever installed a backend. The `log` crate's default is a sink
//! that drops every record, so those calls were invisible everywhere — including
//! to the acceptance gates that were quietly relying on them.
//!
//! This ring is that backend, and it is installed from
//! [`crate::ffi::application::App::new`], which every FFI entry point goes
//! through. Nothing on the UI side has to opt in, which is the point: a log
//! line the app has to remember to enable is a log line nobody reads.
//!
//! # What it is not
//!
//! It is not a transport. Nothing leaves the process from here. The UI reads
//! [`records`] and [`stats`] and decides what to do with them — logcat, an
//! export sheet, a bug report. Keeping the core free of any "where do logs go"
//! decision is what lets the same ring serve Android, Apple and a smoke binary.

use serde::{Deserialize, Serialize};
use std::collections::VecDeque;
use std::sync::{Mutex, OnceLock};

/// Lines kept per process. The ring exists to answer "what just happened", so
/// what matters is the tail; 512 records is a few tens of kilobytes and covers
/// a whole bootstrap plus a long reader session.
pub const DEFAULT_CAPACITY: usize = 512;

/// One captured line.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogRecord {
    /// `error` | `warn` | `info` | `debug` | `trace`.
    pub level: String,
    /// The `log` target, i.e. the module that wrote it.
    pub target: String,
    pub message: String,
    /// Wall clock when the record was pushed, RFC 3339 with milliseconds.
    pub at: String,
}

/// Counters and the one number that decides whether any of this is real.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogStats {
    /// False when some other logger already owned the global slot, in which
    /// case every other field here describes a ring nobody writes to. Reported
    /// rather than assumed because that is a state the UI has to be able to see.
    pub installed: bool,
    pub capacity: i64,
    /// Records currently held.
    pub retained: i64,
    /// Records evicted because the ring was full.
    pub dropped: i64,
    pub errors: i64,
    pub warnings: i64,
    pub info: i64,
    pub debug: i64,
    pub trace: i64,
    /// The newest error line, if one was ever captured.
    pub last_error: Option<String>,
    /// The level filter the ring installed, as a name. `off` means it installed
    /// nothing because a platform had already picked a level.
    pub max_level: String,
}

/// Slots for the five levels, in `log::Level` order.
const LEVELS: [&str; 5] = ["error", "warn", "info", "debug", "trace"];

#[derive(Default)]
struct Inner {
    records: VecDeque<LogRecord>,
    capacity: usize,
    dropped: u64,
    counts: [u64; 5],
    installed: bool,
    installed_level: Option<String>,
}

/// The ring itself: cheap to push to, safe to read from another thread.
pub struct RingLog {
    inner: Mutex<Inner>,
}

impl Default for RingLog {
    fn default() -> Self {
        Self::new()
    }
}

impl RingLog {
    fn new() -> Self {
        Self {
            inner: Mutex::new(Inner {
                capacity: DEFAULT_CAPACITY,
                ..Default::default()
            }),
        }
    }

    /// Push one record, evicting the oldest when full. Split out from the
    /// `log::Log` impl so the ring's own semantics are testable without the
    /// process-global logger being involved.
    fn push(&self, record: LogRecord) {
        let mut guard = match self.inner.lock() {
            Ok(guard) => guard,
            // A poisoned lock means a panic happened while formatting a line.
            // Losing the ring is better than taking the caller down with it.
            Err(_) => return,
        };
        if let Some(slot) = LEVELS.iter().position(|name| *name == record.level) {
            guard.counts[slot] += 1;
        }
        if guard.records.len() >= guard.capacity.max(1) {
            guard.records.pop_front();
            guard.dropped += 1;
        }
        guard.records.push_back(record);
    }
}

impl log::Log for RingLog {
    fn enabled(&self, _metadata: &log::Metadata<'_>) -> bool {
        // The process-wide filter is the only gate: a second, private one here
        // would mean two places to disagree about whether a line exists.
        true
    }

    fn log(&self, record: &log::Record<'_>) {
        self.push(LogRecord {
            level: record.level().as_str().to_ascii_lowercase(),
            target: record.target().to_string(),
            message: record.args().to_string(),
            at: chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Millis, true),
        });
    }

    fn flush(&self) {}
}

fn ring() -> &'static RingLog {
    static RING: OnceLock<RingLog> = OnceLock::new();
    RING.get_or_init(RingLog::new)
}

/// Take the `log` backend, if it is still free. Returns whether the ring owns
/// it — true on the first call, and false forever if another logger got there
/// first, which the caller can see in [`stats`] rather than having to guess.
pub fn install() -> bool {
    let r = ring();
    if r.inner.lock().map(|g| g.installed).unwrap_or(false) {
        return true;
    }
    match log::set_logger(r) {
        Ok(()) => {
            // `log`'s own default is `Off`, which would leave this ring as
            // empty as the sink it replaced. Lift it only when nothing has
            // chosen a level, so a platform that picked one keeps its choice.
            let level = if log::max_level() == log::LevelFilter::Off {
                log::set_max_level(log::LevelFilter::Info);
                Some("info".to_string())
            } else {
                None
            };
            if let Ok(mut guard) = r.inner.lock() {
                guard.installed = true;
                guard.installed_level = level;
            }
            true
        }
        Err(_) => false,
    }
}

/// Captured records, newest first, at or above `min_level` when one is given.
pub fn records(limit: usize, min_level: Option<log::LevelFilter>) -> Vec<LogRecord> {
    match ring().inner.lock() {
        Ok(guard) => records_of(&guard, limit, min_level),
        Err(_) => Vec::new(),
    }
}

fn records_of(guard: &Inner, limit: usize, min_level: Option<log::LevelFilter>) -> Vec<LogRecord> {
    guard
        .records
        .iter()
        .rev()
        .filter(|record| match min_level {
            None => true,
            Some(min) => level_filter(&record.level).is_some_and(|level| level <= min),
        })
        .take(limit)
        .cloned()
        .collect()
}

/// Counters for the whole life of the process, plus whether the ring is live.
pub fn stats() -> LogStats {
    match ring().inner.lock() {
        Ok(guard) => stats_of(&guard),
        Err(_) => LogStats::default(),
    }
}

/// The read-side of the ring, as a pure function of its state so the numbers
/// the UI sees are testable without racing the process-global logger.
fn stats_of(guard: &Inner) -> LogStats {
    let last_error = guard
        .records
        .iter()
        .rev()
        .find(|record| record.level == "error")
        .map(|record| format!("{}: {}", record.target, record.message));
    LogStats {
        installed: guard.installed,
        capacity: guard.capacity as i64,
        retained: guard.records.len() as i64,
        dropped: guard.dropped as i64,
        errors: guard.counts[0] as i64,
        warnings: guard.counts[1] as i64,
        info: guard.counts[2] as i64,
        debug: guard.counts[3] as i64,
        trace: guard.counts[4] as i64,
        last_error,
        max_level: match &guard.installed_level {
            Some(level) => level.clone(),
            None => log::max_level().as_str().to_ascii_lowercase(),
        },
    }
}

/// Resize the ring. Only the tail survives a shrink.
pub fn set_capacity(capacity: usize) {
    if let Ok(mut guard) = ring().inner.lock() {
        guard.capacity = capacity.max(1);
        while guard.records.len() > guard.capacity {
            guard.records.pop_front();
            guard.dropped += 1;
        }
    }
}

/// Forget everything. Exists for tests; a running app never calls it.
pub fn reset() {
    if let Ok(mut guard) = ring().inner.lock() {
        guard.records.clear();
        guard.dropped = 0;
        guard.counts = [0; 5];
    }
}

fn level_filter(name: &str) -> Option<log::LevelFilter> {
    match name {
        "error" => Some(log::LevelFilter::Error),
        "warn" => Some(log::LevelFilter::Warn),
        "info" => Some(log::LevelFilter::Info),
        "debug" => Some(log::LevelFilter::Debug),
        "trace" => Some(log::LevelFilter::Trace),
        _ => None,
    }
}

/// Parse a level name coming from the UI. `None` for anything unrecognised
/// means "no filter", so a typo cannot hide every line.
pub fn parse_level(name: &str) -> Option<log::LevelFilter> {
    level_filter(&name.to_ascii_lowercase())
}

/// The process-wide filter as a name. Reported because `install` only lifts
/// `log`'s default of `Off`, so on a platform that picked its own level the
/// ring silently sees less than the core writes — and that is a fact the UI
/// has to be able to read out rather than infer from an empty list.
pub fn max_level_name() -> String {
    log::max_level().as_str().to_ascii_lowercase()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(level: &str, message: &str) -> LogRecord {
        LogRecord {
            level: level.to_string(),
            target: "komga_core::test".to_string(),
            message: message.to_string(),
            at: "1970-01-01T00:00:00.000Z".to_string(),
        }
    }

    fn resize(ring: &RingLog, capacity: usize) {
        if let Ok(mut guard) = ring.inner.lock() {
            guard.capacity = capacity.max(1);
            while guard.records.len() > guard.capacity {
                guard.records.pop_front();
                guard.dropped += 1;
            }
        }
    }

    fn messages(ring: &RingLog) -> Vec<String> {
        let guard = ring.inner.lock().unwrap();
        records_of(&guard, usize::MAX, None)
            .into_iter()
            .map(|record| record.message)
            .collect()
    }

    #[test]
    fn the_ring_keeps_the_newest_records_and_counts_the_evicted_ones() {
        let ring = RingLog::new();
        resize(&ring, 3);
        for n in 0..5 {
            ring.push(record("info", &format!("line {n}")));
        }
        assert_eq!(messages(&ring), vec!["line 4", "line 3", "line 2"]);
        let guard = ring.inner.lock().unwrap();
        assert_eq!(guard.dropped, 2);
    }

    #[test]
    fn a_shrink_evicts_from_the_front_and_a_zero_capacity_still_holds_one() {
        let ring = RingLog::new();
        resize(&ring, 4);
        for n in 0..4 {
            ring.push(record("info", &format!("l{n}")));
        }
        resize(&ring, 0);
        assert_eq!(messages(&ring), vec!["l3"]);
        ring.push(record("info", "l4"));
        assert_eq!(messages(&ring), vec!["l4"]);
    }

    #[test]
    fn stats_count_every_level_even_after_the_line_itself_is_evicted() {
        // "did anything go wrong in this process" has to survive a long
        // session; the retained window cannot be the only place it is written.
        let ring = RingLog::new();
        resize(&ring, 2);
        ring.push(record("error", "boom"));
        ring.push(record("warn", "hmm"));
        ring.push(record("info", "noise"));
        let guard = ring.inner.lock().unwrap();
        let stats = stats_of(&guard);
        assert_eq!((stats.errors, stats.warnings, stats.info), (1, 1, 1));
        assert_eq!((stats.debug, stats.trace), (0, 0));
        assert_eq!(stats.retained, 2);
        assert_eq!(stats.dropped, 1);
    }

    #[test]
    fn the_newest_error_wins_a_last_error_contest() {
        let ring = RingLog::new();
        ring.push(record("error", "first"));
        ring.push(record("info", "in between"));
        ring.push(record("error", "second"));
        let guard = ring.inner.lock().unwrap();
        assert_eq!(
            stats_of(&guard).last_error.as_deref(),
            Some("komga_core::test: second")
        );
    }

    #[test]
    fn without_an_error_line_last_error_is_none_rather_than_a_stale_one() {
        let ring = RingLog::new();
        ring.push(record("info", "all quiet"));
        let guard = ring.inner.lock().unwrap();
        assert_eq!(stats_of(&guard).last_error, None);
    }

    #[test]
    fn a_level_threshold_narrows_the_window_and_a_bad_name_does_not_empty_it() {
        let ring = RingLog::new();
        ring.push(record("error", "e"));
        ring.push(record("warn", "w"));
        ring.push(record("info", "i"));
        ring.push(record("debug", "d"));
        let guard = ring.inner.lock().unwrap();
        let at = |level: log::LevelFilter| {
            records_of(&guard, usize::MAX, Some(level))
                .into_iter()
                .map(|record| record.level)
                .collect::<Vec<_>>()
        };
        // Newest first: the tail of a session is the part that explains it.
        assert_eq!(at(log::LevelFilter::Warn), vec!["warn", "error"]);
        assert_eq!(
            at(log::LevelFilter::Debug),
            vec!["debug", "info", "warn", "error"]
        );
        // `None` is what an unrecognised name maps to, and it must mean "show
        // everything": a typo in a filter box hiding every line would read as
        // "the client logged nothing", which is the opposite of the truth.
        assert_eq!(records_of(&guard, usize::MAX, None).len(), 4);
        assert_eq!(parse_level("INFO"), Some(log::LevelFilter::Info));
        assert_eq!(parse_level("verbose"), None);
    }

    #[test]
    fn a_poisoned_lock_degrades_to_an_empty_ring_instead_of_a_second_panic() {
        // A panic elsewhere while the ring was locked must not turn "read the
        // logs" into the failure that hides every other answer.
        let ring: &'static RingLog = Box::leak(Box::new(RingLog::new()));
        let (tx, rx) = std::sync::mpsc::channel();
        let writer = std::thread::spawn(move || {
            let _guard = ring.inner.lock().unwrap();
            let _ = tx.send(());
            panic!("holding the ring lock while panicking");
        });
        rx.recv().expect("the writer took the lock");
        // Discarded on purpose: the panic is the point of this test, and the
        // poison it leaves behind is what the ring has to survive.
        let _ = writer.join();

        ring.push(record("info", "ignored"));
        let guard = ring
            .inner
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let stats = stats_of(&guard);
        assert_eq!(stats.retained, 0);
        assert_eq!(stats.errors, 0);
        assert!(records_of(&guard, usize::MAX, None).is_empty());
    }
}
