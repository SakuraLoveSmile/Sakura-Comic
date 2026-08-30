//! Reading-progress throttle: Reader -> SQLite -> pending_mutations -> Komga.
//!
//! Contract: `specs/contracts/fixtures/reader/throttle.json`, shared with the
//! Swift mirror (`KomgaReader.ProgressThrottle`).
//!
//! This is the pure decision layer: it says WHAT leaves and WHEN, given an
//! ordered event stream with explicit timestamps. The durable half lives in
//! `store::read_progress` (the write) and `sync::upload` (the wire call), and
//! the wire bodies come from `store::outbox::request_for` so this module can
//! never invent a second on-the-wire format.
//!
//! The one idea worth stating twice: the throttle gates the NETWORK, never
//! durability. Every page change is committed locally with its outbox row, so
//! `kill -9` between two page turns loses nothing.

use crate::store::outbox::{request_for, Intent};
use serde::Deserialize;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EventKind {
    /// The reader moved to another page.
    Page,
    /// Explicit user statement.
    MarkRead,
    /// Explicit user statement.
    MarkUnread,
    /// Reader closed normally.
    Exit,
    /// App backgrounded — the last moment we can be sure to get a request out.
    Background,
    /// The UI's periodic timer.
    Tick,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Event {
    pub at: i64,
    pub kind: EventKind,
    pub page: Option<u32>,
}

impl Event {
    pub fn page(at: i64, page: u32) -> Self {
        Event {
            at,
            kind: EventKind::Page,
            page: Some(page),
        }
    }

    pub fn of(at: i64, kind: EventKind) -> Self {
        Event {
            at,
            kind,
            page: None,
        }
    }
}

/// The mutation queued in `pending_mutations`, after family coalescing.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PendingIntent {
    Progress { page: u32, completed: bool },
    MarkRead,
    MarkUnread,
}

impl PendingIntent {
    pub fn mutation_type(self) -> &'static str {
        match self {
            PendingIntent::Progress { .. } => "READ_PROGRESS",
            PendingIntent::MarkRead => "MARK_READ",
            PendingIntent::MarkUnread => "MARK_UNREAD",
        }
    }

    fn intent(self) -> Intent {
        match self {
            PendingIntent::Progress { page, completed } => Intent::Progress {
                page: Some(page as i64),
                completed,
            },
            PendingIntent::MarkRead => Intent::MarkRead,
            PendingIntent::MarkUnread => Intent::MarkUnread,
        }
    }
}

/// One request that went out, with the timestamp it fired at.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WireCall {
    pub at: i64,
    pub method: String,
    pub path: String,
    pub body: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    pub book_id: String,
    pub page_count: u32,
    pub interval_ms: i64,
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Snapshot {
    /// Page-position writes committed to SQLite (rule T1).
    pub local_writes: usize,
    /// Rows still sitting in `pending_mutations` for this book.
    pub outbox: Vec<&'static str>,
    /// Locally stored page; 0 means "unread from the start".
    pub page: i64,
    pub completed: bool,
}

/// Finite state machine over the event stream. Deterministic: the clock is an
/// argument, so both platforms can replay the same fixture without a timer.
#[derive(Clone, Debug)]
pub struct ProgressThrottle {
    config: Config,
    current: Option<u32>,
    completed: bool,
    last_upload_at: Option<i64>,
    local_writes: usize,
    pending: Option<PendingIntent>,
}

impl ProgressThrottle {
    /// `restored` is whatever `pending_mutations` still holds for this book when
    /// the reader opens — the row a crash left behind.
    pub fn open(
        config: Config,
        current: Option<u32>,
        last_upload_at: Option<i64>,
        restored: Option<PendingIntent>,
    ) -> Self {
        ProgressThrottle {
            config,
            current,
            completed: matches!(restored, Some(PendingIntent::MarkRead)),
            last_upload_at,
            local_writes: 0,
            pending: restored,
        }
    }

    pub fn snapshot(&self) -> Snapshot {
        Snapshot {
            local_writes: self.local_writes,
            outbox: self
                .pending
                .map(|intent| vec![intent.mutation_type()])
                .unwrap_or_default(),
            page: self.current.unwrap_or(0) as i64,
            completed: self.completed,
        }
    }

    /// Feed one event; returns the requests that must go out because of it.
    pub fn apply(&mut self, event: Event) -> Vec<WireCall> {
        match event.kind {
            EventKind::Page => {
                self.record_page(event.page);
                Vec::new()
            }
            EventKind::MarkRead => {
                self.pending = Some(PendingIntent::MarkRead);
                self.completed = true;
                self.flush(event.at)
            }
            EventKind::MarkUnread => {
                self.pending = Some(PendingIntent::MarkUnread);
                self.current = Some(0);
                self.completed = false;
                self.flush(event.at)
            }
            EventKind::Exit | EventKind::Background => {
                if self.pending.is_some() {
                    self.flush(event.at)
                } else {
                    Vec::new()
                }
            }
            // T3: only the timer consults the interval. A page turn never
            // uploads on the spot, however long the interval has aged.
            EventKind::Tick => {
                if self.pending.is_some() && self.due(event.at) {
                    self.flush(event.at)
                } else {
                    Vec::new()
                }
            }
        }
    }

    /// T1 + T5 + T8: clamp into [1, pageCount], ignore a page we are already on,
    /// and never write at all for a book with no pages.
    fn record_page(&mut self, page: Option<u32>) {
        let Some(page) = page else { return };
        if self.config.page_count == 0 {
            return;
        }
        let page = page.clamp(1, self.config.page_count);
        if self.current == Some(page) {
            return;
        }
        self.current = Some(page);
        // T6: finishing the book is derived progress, not an explicit mark.
        self.completed = page >= self.config.page_count;
        self.local_writes += 1;
        self.pending = Some(PendingIntent::Progress {
            page,
            completed: self.completed,
        });
    }

    fn due(&self, at: i64) -> bool {
        match self.last_upload_at {
            // Never uploaded: do not make the user wait an interval.
            None => true,
            Some(last) => at.saturating_sub(last) >= self.config.interval_ms,
        }
    }

    fn flush(&mut self, at: i64) -> Vec<WireCall> {
        let Some(intent) = self.pending.take() else {
            return Vec::new();
        };
        self.last_upload_at = Some(at);
        let request = request_for(&self.config.book_id, &intent.intent());
        vec![WireCall {
            at,
            method: request.method.as_str().to_string(),
            path: request.path,
            body: request.body,
        }]
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> Config {
        Config {
            book_id: "b1".to_string(),
            page_count: 40,
            interval_ms: 5000,
        }
    }

    #[test]
    fn a_burst_leaves_one_row_and_no_traffic() {
        let mut throttle = ProgressThrottle::open(config(), None, Some(0), None);
        for page in 2u32..14 {
            throttle.apply(Event::page(i64::from(page) * 100, page));
        }
        let shot = throttle.snapshot();
        assert_eq!(shot.local_writes, 12, "one write per distinct page");
        assert_eq!(shot.outbox, vec!["READ_PROGRESS"], "coalesced to one row");
        assert_eq!(shot.page, 13, "the row carries only the last page");
    }

    #[test]
    fn mark_read_body_omits_the_page_so_a_pending_progress_cannot_rewrite_it() {
        let mut throttle = ProgressThrottle::open(config(), None, Some(0), None);
        throttle.apply(Event::page(100, 7));
        let calls = throttle.apply(Event::of(200, EventKind::MarkRead));
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].method, "PATCH");
        assert_eq!(calls[0].body.as_deref(), Some("{\"completed\":true}"));
        assert_eq!(
            throttle.snapshot().page,
            7,
            "the mark does not move the page"
        );
    }

    #[test]
    fn a_finished_book_reports_progress_not_mark_read() {
        let mut throttle = ProgressThrottle::open(config(), Some(39), Some(0), None);
        assert!(
            throttle.apply(Event::page(100, 40)).is_empty(),
            "a page turn is never a request on its own"
        );
        let calls = throttle.apply(Event::of(1500, EventKind::Exit));
        assert_eq!(
            calls[0].body.as_deref(),
            Some("{\"page\":40,\"completed\":true}"),
            "distinguishable from MARK_READ on the server journal"
        );
        assert_eq!(throttle.snapshot().outbox, Vec::<&str>::new());
    }

    /// Property: whatever the interval, an explicit statement or an exit always
    /// gets its request out, and a tick before the interval never does.
    #[test]
    fn only_the_timer_respects_the_interval() {
        for interval in [0i64, 1, 5000, 600_000] {
            let config = Config {
                book_id: "b1".to_string(),
                page_count: 10,
                interval_ms: interval,
            };
            let mut early = ProgressThrottle::open(config.clone(), None, Some(0), None);
            early.apply(Event::page(10, 2));
            assert_eq!(
                early.apply(Event::of(interval / 2, EventKind::Tick)).len(),
                if interval == 0 { 1 } else { 0 },
                "interval {interval}: half-elapsed tick"
            );
            let mut exit = ProgressThrottle::open(config, None, Some(0), None);
            exit.apply(Event::page(10, 2));
            assert_eq!(exit.apply(Event::of(11, EventKind::Exit)).len(), 1);
        }
    }

    #[test]
    fn an_empty_book_can_never_emit_a_page() {
        let config = Config {
            book_id: "b0".to_string(),
            page_count: 0,
            interval_ms: 1000,
        };
        let mut throttle = ProgressThrottle::open(config, None, Some(0), None);
        throttle.apply(Event::page(0, 1));
        let shot = throttle.snapshot();
        assert_eq!((shot.local_writes, shot.page), (0, 0));
        assert_eq!(throttle.apply(Event::of(9000, EventKind::Exit)).len(), 0);
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

    #[derive(Deserialize, Debug, Clone)]
    struct Fixture {
        cases: Vec<Case>,
    }

    #[derive(Deserialize, Debug, Clone)]
    #[serde(rename_all = "camelCase")]
    struct Initial {
        current: Option<u32>,
        last_upload_at: Option<i64>,
    }

    #[derive(Deserialize, Debug, Clone)]
    #[serde(rename_all = "camelCase")]
    struct Restored {
        #[serde(rename = "type")]
        kind: String,
        #[serde(default)]
        page: Option<u32>,
        #[serde(default)]
        completed: bool,
    }

    #[derive(Deserialize, Debug, Clone)]
    #[serde(rename_all = "camelCase")]
    struct RawEvent {
        at: i64,
        kind: EventKind,
        #[serde(default)]
        page: Option<u32>,
    }

    #[derive(Deserialize, Debug, Clone)]
    #[serde(rename_all = "camelCase")]
    struct Input {
        book_id: String,
        page_count: u32,
        interval_ms: i64,
        initial: Initial,
        events: Vec<RawEvent>,
        #[serde(default)]
        restore: Vec<Restored>,
    }

    #[derive(Deserialize, Debug, Clone)]
    #[serde(rename_all = "camelCase")]
    struct Wire {
        at: i64,
        method: String,
        path: String,
        body: Option<serde_json::Value>,
    }

    #[derive(Deserialize, Debug, Clone)]
    #[serde(rename_all = "camelCase")]
    struct Expect {
        local_writes: usize,
        wire_requests: Vec<Wire>,
        outbox_after: Vec<String>,
        final_page: i64,
        final_completed: bool,
    }

    #[derive(Deserialize, Debug, Clone)]
    struct Phase {
        input: Input,
        expect: Expect,
    }

    #[derive(Deserialize, Debug, Clone)]
    struct Case {
        name: String,
        #[serde(default)]
        input: Option<Input>,
        #[serde(default)]
        expect: Option<Expect>,
        #[serde(default)]
        phases: Vec<Phase>,
    }

    fn run(input: &Input, expect: &Expect, name: &str) {
        let restored = input.restore.first().map(|row| match row.kind.as_str() {
            "READ_PROGRESS" => PendingIntent::Progress {
                page: row.page.expect("READ_PROGRESS restore carries a page"),
                completed: row.completed,
            },
            "MARK_READ" => PendingIntent::MarkRead,
            "MARK_UNREAD" => PendingIntent::MarkUnread,
            other => panic!("{name}: unknown restored kind {other}"),
        });
        let mut throttle = ProgressThrottle::open(
            Config {
                book_id: input.book_id.clone(),
                page_count: input.page_count,
                interval_ms: input.interval_ms,
            },
            input.initial.current,
            input.initial.last_upload_at,
            restored,
        );
        let mut calls = Vec::new();
        for event in &input.events {
            calls.extend(throttle.apply(Event {
                at: event.at,
                kind: event.kind,
                page: event.page,
            }));
        }
        let shot = throttle.snapshot();

        assert_eq!(
            shot.local_writes, expect.local_writes,
            "{name}: localWrites"
        );
        assert_eq!(shot.page, expect.final_page, "{name}: finalPage");
        assert_eq!(
            shot.completed, expect.final_completed,
            "{name}: finalCompleted"
        );
        let outbox: Vec<String> = shot.outbox.iter().map(|row| row.to_string()).collect();
        assert_eq!(outbox, expect.outbox_after, "{name}: outboxAfter");

        assert_eq!(
            calls.len(),
            expect.wire_requests.len(),
            "{name}: wire count\n  got  {calls:#?}\n  want {:#?}",
            expect.wire_requests
        );
        for (got, want) in calls.iter().zip(&expect.wire_requests) {
            assert_eq!(got.at, want.at, "{name}: request time");
            assert_eq!(got.method, want.method, "{name}: method at {}", got.at);
            assert_eq!(got.path, want.path, "{name}: path at {}", got.at);
            let body: Option<serde_json::Value> = got.body.as_deref().map(|raw| {
                serde_json::from_str(raw)
                    .unwrap_or_else(|error| panic!("{name}: bad body {raw}: {error}"))
            });
            assert_eq!(body, want.body, "{name}: body at {}", got.at);
        }
    }

    #[test]
    fn throttle_matches_the_shared_contract() {
        let fixture: Fixture = fixture("throttle.json");
        assert!(fixture.cases.len() >= 10);
        for case in &fixture.cases {
            if let (Some(input), Some(expect)) = (&case.input, &case.expect) {
                run(input, expect, &case.name);
            }
            // A multi-phase case replays a real restart: each phase states in
            // its own `restore` what `pending_mutations` still holds, so no
            // expectation is ever fed back in as an input.
            for (index, phase) in case.phases.iter().enumerate() {
                let label = format!("{}[phase {}]", case.name, index + 1);
                run(&phase.input, &phase.expect, &label);
            }
        }
    }

    /// Anti-vacuity: a case that expects no traffic and no writes must still be
    /// distinguished from one that does.
    #[test]
    fn throttle_cases_are_distinct() {
        let fixture: Fixture = fixture("throttle.json");
        let mut seen = std::collections::BTreeSet::new();
        for case in &fixture.cases {
            let key = match (&case.input, &case.expect) {
                (Some(input), Some(expect)) => {
                    format!(
                        "{:?}|{:?}",
                        input.events,
                        (expect.local_writes, &expect.wire_requests)
                    )
                }
                _ => format!("phases:{}", case.phases.len()),
            };
            assert!(seen.insert(key), "duplicate throttle case: {}", case.name);
        }
    }
}
